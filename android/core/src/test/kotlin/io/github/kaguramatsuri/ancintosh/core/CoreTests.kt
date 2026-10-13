package io.github.kaguramatsuri.ancintosh.core

import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlin.test.*
import org.json.JSONObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import java.nio.ByteBuffer

class CoreTests {
    private val mac = UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val phone = UUID.fromString("22222222-2222-2222-2222-222222222222")
    @Test fun cancellingActiveFileKeepsAuthenticatedConnection() = runBlocking {
        val root = Files.createTempDirectory("ancintosh-active-cancel").toFile()
        val scope = CoroutineScope(SupervisorJob() + coroutineContext.minusKey(Job))
        val input = Channel<Byte>(Channel.UNLIMITED)
        val blocked = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val local = Hello(Role.ANDROID, phone, nonce = ByteArray(32) { 1 }, publicKey = ByteArray(32) { 9 })
        val remote = Hello(Role.MAC, mac, nonce = ByteArray(32) { 2 }, publicKey = ByteArray(32) { 9 })
        val key = ByteArray(32) { 3 }
        val peerCrypto = CryptoSession(key, remote, local, Transport.ble, ByteArray(32) { 9 })
        val auth = Authentication(mac, CryptoSession(key, local, remote, Transport.ble, ByteArray(32) { 9 }))
        val epochBytes = ByteBuffer.wrap(auth.crypto.root)
        val epoch = UUID(epochBytes.long, epochBytes.long)
        val writes = mutableListOf<RecordKind>(); val disconnects = mutableListOf<SyncEvent.Disconnected>()
        val raw = object : ByteChannel {
            override suspend fun readExactly(count: Int): ByteArray = ByteArray(count) { input.receive() }
            override suspend fun write(data: ByteArray) {
                val record = peerCrypto.open(data)
                writes.add(record.kind)
                if (record.kind == RecordKind.BEGIN) {
                    peerCrypto.seal(Record(RecordKind.RESUME, record.id, epoch = epoch)).forEach { input.send(it) }
                }
                if (record.kind == RecordKind.DATA) { blocked.complete(Unit); release.await() }
            }
            override fun close() { input.close() }
        }
        try {
            val store = TransferStore(root) { _, _ -> error("Unexpected publication") }
            val session = SessionController(phone, scope, store) { if (it is SyncEvent.Disconnected) disconnects.add(it) }
            session.installBLE(auth, EncryptedChannel(raw, auth, Transport.ble))
            val source = store.snapshot(ByteArray(16384) { 7 }.inputStream(), PayloadKind.FILE, "active.bin", "application/octet-stream", phone)
            session.enqueue(source)
            withTimeout(2000) { blocked.await() }
            val cancellation = launch { session.cancel(source.manifest.id) }
            yield()
            assertFalse(source.file.exists())
            release.complete(Unit)
            withTimeout(2000) { cancellation.join() }
            yield()
            assertEquals(mac, session.connected)
            assertTrue(disconnects.isEmpty())
            assertTrue(session.outgoingFiles().isEmpty())
            assertEquals(1, writes.count { it == RecordKind.DATA })
            assertTrue(RecordKind.CANCEL in writes)
            session.disconnect(true)
        } finally { release.complete(Unit); scope.cancel(); input.close(); root.deleteRecursively() }
    }
    @Test fun cancellingRestoredOfflineFileDeletesSnapshotAndJournalEntry() = runBlocking {
        val root = Files.createTempDirectory("ancintosh-cancel").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val store = TransferStore(root) { _, _ -> error("No incoming file should publish") }
            val source = store.snapshot(byteArrayOf(1, 2, 3).inputStream(), PayloadKind.FILE, "cancel.bin", "application/octet-stream", phone)
            store.persist(listOf(OutboundJob(mac, source, true)))
            val controller = SessionController(phone, scope, store) { }
            controller.restore()
            assertEquals(1, controller.outgoingFiles().size)
            controller.cancel(source.manifest.id)
            assertFalse(source.file.exists())
            assertTrue(controller.outgoingFiles().isEmpty())
            assertTrue(TransferStore(root) { _, _ -> error("Unexpected publication") }.restore().isEmpty())
        } finally { scope.cancel(); root.deleteRecursively() }
    }
    @Test fun independentJavaV2Fixture() {
        val j = JSONObject(File("../../protocol/fixtures/v2.json").readText())
        val a = Hello.decode(j.getString("macHello").unhex()); val b = Hello.decode(j.getString("androidHello").unhex())
        val key = j.getString("key").unhex()
        val tx = CryptoSession(key, a, b, Transport.ble, j.getString("sharedSecret").unhex()); val rx = CryptoSession(key, b, a, Transport.ble, j.getString("sharedSecret").unhex())
        assertEquals(j.getString("root"), tx.root.hex())
        assertEquals(j.getString("macProof"), Crypto.proof(key, Crypto.transcript(a, b, Transport.ble), Role.MAC).hex())
        val record = Record.decode(j.getString("record").unhex())
        val frame = tx.seal(record); assertEquals(j.getString("sealed"), frame.hex())
        assertContentEquals(record.bytes, rx.open(frame).bytes)
        assertEquals(Failure.replay, assertFailsWith<ProtocolException> { rx.open(frame) }.code)
    }
    @Test fun hkdfRFC5869() {
        val result = Crypto.derive(ByteArray(22) { 0x0b }, "000102030405060708090a0b0c".unhex(), "f0f1f2f3f4f5f6f7f8f9".unhex(), 42)
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", result.hex())
    }
    @Test fun rejectTamperWrongKeyAndTransport() {
        val a = Hello(Role.MAC, mac, nonce = ByteArray(32) { 1 }, publicKey = ByteArray(32) { 9 }); val b = Hello(Role.ANDROID, phone, nonce = ByteArray(32) { 2 }, publicKey = ByteArray(32) { 9 })
        val key = ByteArray(32) { 3 }; val frame = CryptoSession(key, a, b, Transport.ble, ByteArray(32) { 9 }).seal(Record(RecordKind.DATA, bytes = byteArrayOf(1,2,3)))
        val bad = frame.clone(); bad[bad.lastIndex] = (bad.last().toInt() xor 1).toByte()
        assertEquals(Failure.authenticationFailed, assertFailsWith<ProtocolException> { CryptoSession(key,b,a, Transport.ble, ByteArray(32) { 9 }).open(bad) }.code)
        assertFailsWith<ProtocolException> { CryptoSession(ByteArray(32) { 4 },b,a, Transport.ble, ByteArray(32) { 9 }).open(frame) }
        assertFailsWith<ProtocolException> { CryptoSession(key,b,a, Transport.tcp, ByteArray(32) { 9 }).open(frame) }
        assertFailsWith<ProtocolException> { CryptoSession(key,b,a, Transport.ble, ByteArray(32) { 9 }).open(frame.copyOf(frame.size-1)) }
    }
    @Test fun wifiPreferencesAndStability() {
        val route = TransportCoordinator(); route.path(true,0)
        assertFalse(route.shouldUpgrade(10000)); route.authenticated(true)
        assertFalse(route.shouldUpgrade(4999)); assertTrue(route.shouldUpgrade(5000)); route.activateTCP()
        route.preference(remote=false); assertEquals(Transport.ble,route.current)
        route.preference(remote=true); route.path(true,10000); assertFalse(route.shouldUpgrade(14999)); assertTrue(route.shouldUpgrade(15000))
        route.path(false,15001); assertFalse(route.shouldUpgrade(20000))
    }
    @Test fun originalByteResumeAndDuplicateDelivery() = runBlocking {
        val root = Files.createTempDirectory("ancintosh-test").toFile()
        try {
            val downloads=File(root,"downloads").apply { mkdirs() }
            val store=TransferStore(File(root,"state")) { file, manifest ->
                val target=File(downloads,manifest.name); Files.move(file.toPath(),target.toPath()); target.absolutePath
            }
            val bytes=ByteArray(200000) { (it%251).toByte() }
            val source=store.snapshot(bytes.inputStream(),PayloadKind.FILE,"source.bin","application/octet-stream",mac)
            assertEquals(0,store.begin(source.manifest,phone))
            store.append(phone,source.manifest.id,0,bytes.copyOfRange(0,20000));store.checkpoint(phone)
            store.append(phone,source.manifest.id,20000,bytes.copyOfRange(20000,30000))
            assertEquals(20000,store.begin(source.manifest,phone))
            store.append(phone,source.manifest.id,20000,bytes.copyOfRange(20000,bytes.size))
            val result=store.finish(phone,source.manifest.id)
            assertContentEquals(bytes,File(result.output).readBytes());assertTrue(result.fresh)
            store.delivered(phone,source.manifest.id);assertFalse(store.finish(phone,source.manifest.id).fresh)
        } finally { root.deleteRecursively() }
    }
    @Test fun badOffsetsPathsAndDigestCannotPublish() = runBlocking {
        assertFailsWith<ProtocolException> { Manifest(UUID.randomUUID(),PayloadKind.FILE,"../escape","x",0,Crypto.digest(byteArrayOf()),mac) }
        val root=Files.createTempDirectory("ancintosh-test").toFile()
        try {
            var published=false
            val store=TransferStore(root) { _,_ -> published=true;"unexpected" }
            val source=store.snapshot(byteArrayOf(1,2,3).inputStream(),PayloadKind.FILE,"test","x",mac)
            store.begin(source.manifest,phone)
            assertFailsWith<ProtocolException> { store.append(phone,source.manifest.id,1,byteArrayOf(1)) }
            store.append(phone,source.manifest.id,0,byteArrayOf(3,2,1))
            assertEquals(Failure.digestMismatch,assertFailsWith<ProtocolException> { store.finish(phone,source.manifest.id) }.code)
            assertFalse(published)
        } finally { root.deleteRecursively() }
    }
}
