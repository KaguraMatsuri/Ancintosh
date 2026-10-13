package io.github.kaguramatsuri.ancintosh.core

import java.util.UUID
import java.nio.ByteBuffer
import java.nio.file.Files
import kotlinx.coroutines.channels.Channel
import kotlin.coroutines.CoroutineContext
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlin.test.*

class PipelineTests {
    private fun auth(): Authentication {
        val a = Hello(Role.ANDROID, UUID.randomUUID(), nonce = ByteArray(32) { 1 }, publicKey = ByteArray(32) { 9 })
        val b = Hello(Role.MAC, UUID.randomUUID(), nonce = ByteArray(32) { 2 }, publicKey = ByteArray(32) { 9 })
        return Authentication(b.peer, CryptoSession(ByteArray(32) { 3 }, a, b, Transport.tcp, ByteArray(32) { 9 }))
    }
    @Test fun boundedPayloadsCloseWakesProducerAndReturnsGlobalCapacity() = runBlocking {
        withTimeout(5000) {
            repeat(10) {
                val blocked = CompletableDeferred<Unit>(); val writing = CompletableDeferred<Unit>()
                val raw = object : ByteChannel {
                    override suspend fun readExactly(count: Int): ByteArray = error("No reader")
                    override suspend fun write(data: ByteArray) { writing.complete(Unit); blocked.await() }
                    override fun close() { blocked.complete(Unit) }
                }
                val channel = EncryptedChannel(raw, auth(), Transport.tcp); channel.setDataEpoch(Wire.ZERO_ID)
                val produced = AtomicInteger()
                val producer = async {
                    runCatching {
                        repeat(17) { channel.sendBuffered { produced.incrementAndGet(); Record(RecordKind.DATA, bytes = ByteArray(Wire.TCP_CHUNK)) } }
                    }
                }
                writing.await()
                withTimeout(1000) { while (produced.get() < 16) yield() }
                delay(10)
                assertEquals(16, produced.get())
                channel.close()
                assertTrue(producer.await().isFailure)
            }
        }
    }
    @Test fun awaitingFileAcknowledgementDoesNotSpinBehindQueuedFile() = runBlocking {
        val dispatches = AtomicInteger()
        val dispatcher = object : CoroutineDispatcher() {
            override fun dispatch(context: CoroutineContext, block: Runnable) {
                dispatches.incrementAndGet(); Dispatchers.Default.dispatch(context, block)
            }
        }
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val root = Files.createTempDirectory("ancintosh-ack-idle").toFile()
        val incoming = Channel<Byte>(Channel.UNLIMITED)
        val firstFinished = CompletableDeferred<Unit>(); val begins = AtomicInteger()
        val local = Hello(Role.ANDROID, UUID.randomUUID(), nonce = ByteArray(32) { 1 }, publicKey = ByteArray(32) { 9 })
        val remote = Hello(Role.MAC, UUID.randomUUID(), nonce = ByteArray(32) { 2 }, publicKey = ByteArray(32) { 9 })
        val key = ByteArray(32) { 3 }; val shared = ByteArray(32) { 9 }
        val authentication = Authentication(remote.peer, CryptoSession(key, local, remote, Transport.ble, shared))
        val peerCrypto = CryptoSession(key, remote, local, Transport.ble, shared)
        val rootBytes = ByteBuffer.wrap(authentication.crypto.root); val epoch = UUID(rootBytes.long, rootBytes.long)
        val raw = object : ByteChannel {
            override suspend fun readExactly(count: Int) = ByteArray(count) { incoming.receive() }
            override suspend fun write(data: ByteArray) {
                val record = peerCrypto.open(data)
                if (record.kind == RecordKind.BEGIN) {
                    begins.incrementAndGet()
                    peerCrypto.seal(Record(RecordKind.RESUME, record.id, epoch = epoch)).forEach { incoming.send(it) }
                }
                if (record.kind == RecordKind.FINISH) firstFinished.complete(Unit)
            }
            override fun close() { incoming.close() }
        }
        val store = TransferStore(root) { _, _ -> error("No publication") }
        val session = SessionController(local.peer, scope, store) { }
        try {
            session.installBLE(authentication, EncryptedChannel(raw, authentication, Transport.ble))
            repeat(2) {
                session.enqueue(store.snapshot(ByteArray(100).inputStream(), PayloadKind.FILE, "$it.bin", "x", local.peer))
            }
            withTimeout(2000) { firstFinished.await() }
            delay(20)
            val before = dispatches.get(); delay(100)
            assertTrue(dispatches.get() - before < 10, "Idle file queue is repeatedly scheduling work")
            assertEquals(1, begins.get())
        } finally { session.disconnect(); scope.cancel(); root.deleteRecursively() }
    }
    @Test fun retiredEpochCannotEnqueueOrConsumeSequenceNumbers() = runBlocking {
        val written = AtomicInteger()
        val raw = object : ByteChannel {
            override suspend fun readExactly(count: Int): ByteArray = error("No reader")
            override suspend fun write(data: ByteArray) { written.incrementAndGet() }
            override fun close() = Unit
        }
        val channel = EncryptedChannel(raw, auth(), Transport.tcp)
        channel.setDataEpoch(UUID.randomUUID())
        assertEquals(Failure.peerUnavailable, assertFailsWith<ProtocolException> {
            channel.sendBuffered { Record(RecordKind.DATA, bytes = byteArrayOf(1)) }
        }.code)
        assertEquals(0, written.get()); channel.close()
    }
}
