package io.github.kaguramatsuri.andcintosh.core

import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlin.test.*
import org.json.JSONObject

class CoreTests {
    private val mac = UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val phone = UUID.fromString("22222222-2222-2222-2222-222222222222")
    @Test fun independentJavaFixture() {
        val j = JSONObject(File("../../protocol/fixtures/v1.json").readText())
        val a = Hello.decode(j.getString("macHello").unhex()); val b = Hello.decode(j.getString("androidHello").unhex())
        val key = j.getString("key").unhex()
        val tx = CryptoSession(key, a, b, Transport.ble); val rx = CryptoSession(key, b, a, Transport.ble)
        assertEquals(j.getString("root"), tx.root.hex())
        assertEquals(j.getString("macProof"), Crypto.proof(key, a.encode() + b.encode(), Role.MAC).hex())
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
        val a = Hello(Role.MAC, mac, nonce = ByteArray(32) { 1 }); val b = Hello(Role.ANDROID, phone, nonce = ByteArray(32) { 2 })
        val key = ByteArray(32) { 3 }; val frame = CryptoSession(key, a, b, Transport.ble).seal(Record(RecordKind.DATA, bytes = byteArrayOf(1,2,3)))
        val bad = frame.clone(); bad[bad.lastIndex] = (bad.last().toInt() xor 1).toByte()
        assertEquals(Failure.authenticationFailed, assertFailsWith<ProtocolException> { CryptoSession(key,b,a,Transport.ble).open(bad) }.code)
        assertFailsWith<ProtocolException> { CryptoSession(ByteArray(32) { 4 },b,a,Transport.ble).open(frame) }
        assertFailsWith<ProtocolException> { CryptoSession(key,b,a,Transport.tcp).open(frame) }
        assertFailsWith<ProtocolException> { CryptoSession(key,b,a,Transport.ble).open(frame.copyOf(frame.size-1)) }
    }
    @Test fun wifiPreferencesAndStability() {
        val route = TransportCoordinator(); route.path(true,0)
        assertFalse(route.shouldUpgrade(10000)); route.authenticated(true)
        assertFalse(route.shouldUpgrade(4999)); assertTrue(route.shouldUpgrade(5000)); route.activateTCP()
        route.preference(remote=false); assertEquals(Transport.ble,route.current)
        route.preference(remote=true); route.path(true,10000); assertFalse(route.shouldUpgrade(14999)); assertTrue(route.shouldUpgrade(15000))
        route.path(false,15001); assertFalse(route.shouldUpgrade(20000))
    }
    @Test fun originalByteResumeAndDuplicateDelivery() {
        val root = Files.createTempDirectory("andcintosh-test").toFile()
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
    @Test fun badOffsetsPathsAndDigestCannotPublish() {
        assertFailsWith<ProtocolException> { Manifest(UUID.randomUUID(),PayloadKind.FILE,"../escape","x",0,Crypto.digest(byteArrayOf()),mac) }
        val root=Files.createTempDirectory("andcintosh-test").toFile()
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
