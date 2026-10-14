package io.github.kaguramatsuri.ancintosh.core

import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONObject
import kotlin.test.*

class NotificationTests {
    @Test fun sharedFixtureAndUnicodeBudget() {
        val fixture = JSONObject(File("../../protocol/fixtures/notification.json").readText())
        val value = NotificationMessage.decode(fixture.getJSONObject("upsert"))
        assertEquals("Ciallo~", value.title)
        assertEquals(value.id, NotificationMessage.decode(fixture.getJSONObject("remove")).id)
        assertEquals(true, NotificationAccess.decode(fixture.getJSONObject("access")).enabled)
        val body = "👩🏽‍💻\"\n".repeat(2000)
        val clipped = NotificationMessage.bounded(UUID.randomUUID(), "Ancintosh", "Mac", body)
        assertTrue(body.startsWith(clipped.body)); assertTrue(clipped.json().bytes().size <= Wire.MAX_METADATA)
        val queue = NotificationQueue()
        queue.append(value); queue.append(value.copy(action = NotificationMessage.Action.remove))
        assertEquals(1, queue.size); assertEquals(NotificationMessage.Action.remove, queue.pop()?.action)
        repeat(256) { queue.append(value.copy(id = UUID.randomUUID())) }
        assertEquals(NotificationQueue.CAPACITY, queue.size)
    }
    private class Pipe(val crypto: CryptoSession) : ByteChannel {
        val input = Channel<Byte>(Channel.UNLIMITED)
        val written = mutableListOf<Record>()
        override suspend fun readExactly(count: Int) = ByteArray(count) { input.receive() }
        override suspend fun write(data: ByteArray) { synchronized(written) { written.add(crypto.open(data)) } }
        override fun close() { input.close() }
        suspend fun send(record: Record) { crypto.seal(record).forEach { input.send(it) } }
        fun messages(): List<Record> = synchronized(written) { written.filter { it.kind == RecordKind.NOTIFICATION } }
    }
    @Test fun permissionPolicyAndLegacyCapabilityGate() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val root = Files.createTempDirectory("ancintosh-notification").toFile()
        val mac = UUID.randomUUID(); val phone = UUID.randomUUID(); val key = ByteArray(32) { 4 }; val shared = ByteArray(32) { 9 }
        val a = Hello(Role.ANDROID, phone, nonce = ByteArray(32) { 1 }, publicKey = ByteArray(32) { 9 })
        val b = Hello(Role.MAC, mac, nonce = ByteArray(32) { 2 }, publicKey = ByteArray(32) { 9 })
        val client = CryptoSession(key, a, b, Transport.ble, shared)
        val pipe = Pipe(CryptoSession(key, b, a, Transport.ble, shared))
        val events = Channel<SyncEvent>(Channel.UNLIMITED)
        val session = SessionController(phone, scope, TransferStore(root) { _, _ -> error("unexpectedFile") }) { events.send(it) }
        try {
            withTimeout(5000) {
                session.notificationAccess(NotificationAccess(true, true))
                session.installBLE(Authentication(mac, client), EncryptedChannel(pipe, Authentication(mac, client), Transport.ble))
                session.notificationPolicy(true)
                val value = NotificationMessage.bounded(UUID.randomUUID(), "Galaxy S24 Ultra", "Ciallo~", "Mac")
                session.enqueueNotification(value)
                assertTrue(pipe.messages().isEmpty()) // No notification record is sent to a legacy peer.
                val preference = JSONObject().put("enabled", true).put("configuration", true).put("notifications", NotificationAccess(true, true, true).json())
                pipe.send(Record(RecordKind.WIFI_PREFERENCE, metadata = preference.bytes()))
                while (events.receive() !is SyncEvent.ConfigurationReady) { }
                session.enqueueNotification(value)
                while (pipe.messages().isEmpty()) yield()
                assertEquals(value.id, pipe.messages().single().id)
                session.notificationPolicy(false)
                session.enqueueNotification(value.copy(id = UUID.randomUUID()))
                delay(20); assertEquals(1, pipe.messages().size)
            }
        } finally { session.disconnect(); scope.cancel(); root.deleteRecursively() }
    }
}
