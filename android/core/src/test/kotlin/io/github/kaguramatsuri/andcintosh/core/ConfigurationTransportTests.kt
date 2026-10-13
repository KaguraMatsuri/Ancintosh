package io.github.kaguramatsuri.andcintosh.core

import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONObject
import kotlin.test.*

class ConfigurationTransportTests {
    private class Pipe(val crypto: CryptoSession) : ByteChannel {
        val input = Channel<Byte>(Channel.UNLIMITED)
        val written = mutableListOf<Record>()
        override suspend fun readExactly(count: Int) = ByteArray(count) { input.receive() }
        override suspend fun write(data: ByteArray) { synchronized(written) { written.add(crypto.open(data)) } }
        override fun close() { input.close() }
        suspend fun send(record: Record) { crypto.seal(record).forEach { input.send(it) } }
        fun has(kind: RecordKind): Boolean = synchronized(written) { written.any { it.kind == kind } }
    }
    @Test fun configurationUsesBLEWhileFileRouteIsTCP() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val root = Files.createTempDirectory("andcintosh-config").toFile()
        val events = Channel<SyncEvent>(Channel.UNLIMITED)
        val mac = UUID.randomUUID(); val phone = UUID.randomUUID(); val key = ByteArray(32) { 4 }; val shared = ByteArray(32) { 9 }
        fun channel(transport: Transport, context: UUID = Wire.ZERO_ID): Pair<Pipe, EncryptedChannel> {
            val a = Hello(Role.ANDROID, phone, context, ByteArray(32) { 1 }, ByteArray(32) { 9 })
            val b = Hello(Role.MAC, mac, context, ByteArray(32) { 2 }, ByteArray(32) { 9 })
            val raw = Pipe(CryptoSession(key,b,a,transport,shared))
            return raw to EncryptedChannel(raw, Authentication(mac,CryptoSession(key,a,b,transport,shared)),transport)
        }
        val session = SessionController(phone,scope,TransferStore(root) { _, _ -> error("No file") }) { events.send(it) }
        try {
            withTimeout(5000) {
                val (bleRaw,ble) = channel(Transport.ble)
                session.installBLE(Authentication(mac, CryptoSession(key,
                    Hello(Role.ANDROID,phone,nonce=ByteArray(32){1},publicKey=ByteArray(32){9}),
                    Hello(Role.MAC,mac,nonce=ByteArray(32){2},publicKey=ByteArray(32){9}),Transport.ble,shared)),ble)
                session.reportDevice(DeviceInformation("legacy",DeviceKind.phone,true))
                assertFalse(bleRaw.has(RecordKind.DEVICE_INFORMATION))
                bleRaw.send(Record(RecordKind.WIFI_PREFERENCE,metadata=JSONObject().put("enabled",true).put("configuration",true).toString().toByteArray()))
                val context = UUID.randomUUID()
                val offer = JSONObject().put("id",context.toString()).put("secret",ByteArray(32){3}.hex())
                    .put("addresses",org.json.JSONArray().put(JSONObject().put("host","192.0.2.1").put("port",12345)))
                bleRaw.send(Record(RecordKind.TCP_OFFER,metadata=offer.toString().toByteArray()))
                while (events.receive() !is SyncEvent.Offer) { }
                val (tcpRaw,tcp) = channel(Transport.tcp,context); session.installTCP(context,tcp)
                val configuration = JSONObject(FileFixture.value()).apply { getJSONObject("mac").put("id",mac.toString()) }
                bleRaw.send(Record(RecordKind.CONFIGURATION,metadata=configuration.toString().toByteArray()))
                var received: SyncEvent.Configuration? = null
                while (received == null) received = events.receive() as? SyncEvent.Configuration
                assertEquals(DeviceKind.pad,received.value.device?.kind)
                val rejected = UUID.randomUUID()
                bleRaw.send(Record(RecordKind.FAILURE,rejected,metadata=JSONObject().put("code","oversizedRecord").put("configuration",true).toString().toByteArray()))
                val failure = events.receive() as SyncEvent.ConfigurationRejected
                assertEquals(rejected,failure.request)
                assertEquals(Failure.oversizedRecord,failure.code)
                session.reportDevice(DeviceInformation("phone",DeviceKind.phone,true))
                assertTrue(bleRaw.has(RecordKind.DEVICE_INFORMATION)); assertFalse(tcpRaw.has(RecordKind.DEVICE_INFORMATION))
                tcpRaw.send(Record(RecordKind.CONFIGURATION,metadata=configuration.toString().toByteArray()))
                while (!bleRaw.has(RecordKind.TRANSPORT_SWITCH)) yield()
                assertEquals(mac,session.connected)
            }
        } finally { session.disconnect(); scope.cancel(); root.deleteRecursively() }
    }
    private object FileFixture {
        fun value() = JSONObject(java.io.File("../../protocol/fixtures/configuration.json").readText()).getJSONObject("configuration").toString()
    }
}
