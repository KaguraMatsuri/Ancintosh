package io.github.kaguramatsuri.ancintosh.core

import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlin.test.*

class V2Tests {
    private class Pipe(private val input: Channel<Byte>, private val output: Channel<Byte>) : ByteChannel {
        override suspend fun readExactly(count: Int) = ByteArray(count) { input.receive() }
        override suspend fun write(data: ByteArray) { data.forEach { output.send(it) } }
        override fun close() { input.close(); output.close() }
    }
    @Test fun authenticatedEphemeralHandshakeAndFreshSession() = runBlocking {
        withTimeout(5000) {
            val key = ByteArray(32) { 3 }; val mac = UUID.randomUUID(); val phone = UUID.randomUUID()
            suspend fun connect(): Pair<Authentication, Authentication> = coroutineScope {
                val a = Channel<Byte>(Channel.UNLIMITED); val b = Channel<Byte>(Channel.UNLIMITED)
                val first = async { Handshake.authenticate(Pipe(a,b), Role.MAC, mac, key, transport = Transport.ble, expectedPeer = phone) }
                val second = async { Handshake.authenticate(Pipe(b,a), Role.ANDROID, phone, key, transport = Transport.ble, expectedPeer = mac) }
                first.await() to second.await()
            }
            val (macAuth, phoneAuth) = connect()
            assertContentEquals(macAuth.crypto.root, phoneAuth.crypto.root)
            assertFalse(macAuth.crypto.root.contentEquals(connect().first.crypto.root))
            macAuth.crypto.txSequence = (1L shl 20) - 1; phoneAuth.crypto.rxSequence = (1L shl 20) - 1
            repeat(3) {
                val frame = macAuth.crypto.seal(Record(RecordKind.DATA, bytes = byteArrayOf(1,2,3)))
                assertContentEquals(byteArrayOf(1,2,3), phoneAuth.crypto.open(frame).bytes)
            }
        }
    }
    @Test fun rejectsLegacyPrefixWithoutWaitingForBody() = runBlocking {
        val prefix = "Ciallo~".toByteArray() + byteArrayOf(1)
        val raw = object : ByteChannel {
            override suspend fun readExactly(count: Int): ByteArray { assertEquals(8, count); return prefix }
            override suspend fun write(data: ByteArray) = Unit
            override fun close() = Unit
        }
        assertEquals(Failure.unsupportedVersion, assertFailsWith<ProtocolException> { Handshake.readHello(raw) }.code)
    }
    @Test fun rejectsZeroCurvePoint() {
        assertFails { EphemeralAgreement().agree(ByteArray(32)) }
    }
}
