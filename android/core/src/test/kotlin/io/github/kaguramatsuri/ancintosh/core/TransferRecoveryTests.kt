package io.github.kaguramatsuri.ancintosh.core

import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONArray
import org.json.JSONObject
import kotlin.test.*

class TransferRecoveryTests {
    private class Pipe {
        private val frames = Channel<ByteArray>(1)
        private var buffered = byteArrayOf()
        suspend fun read(count: Int): ByteArray {
            val output = ByteArray(count); var offset = 0
            while (offset < count) {
                if (buffered.isEmpty()) buffered = frames.receive()
                val n = minOf(buffered.size, count - offset)
                buffered.copyInto(output, offset, 0, n); offset += n
                buffered = buffered.copyOfRange(n, buffered.size)
            }
            return output
        }
        suspend fun write(bytes: ByteArray) { frames.send(bytes) }
        fun close() { frames.close() }
    }
    private fun pair(): Pair<ByteChannel,ByteChannel> {
        val a = Pipe(); val b = Pipe()
        fun channel(input: Pipe, output: Pipe) = object : ByteChannel {
            override suspend fun readExactly(count: Int) = input.read(count)
            override suspend fun write(data: ByteArray) = output.write(data)
            override fun close() { input.close(); output.close() }
        }
        return channel(a,b) to channel(b,a)
    }
    @Test fun boundedDuplexTcpFilesCompleteWithoutBlockingTheirAcknowledgements() = runBlocking {
        val root = Files.createTempDirectory("ancintosh-duplex").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val channels = mutableListOf<ByteChannel>()
        val completions = ConcurrentHashMap.newKeySet<UUID>()
        val received = ConcurrentHashMap<UUID,String>()
        val aOffer = CompletableDeferred<SyncEvent.Offer>(); val bOffer = CompletableDeferred<SyncEvent.Offer>()
        val leftStore = TransferStore(File(root,"a")) { file, _ -> file.absolutePath }
        val rightStore = TransferStore(File(root,"b")) { file, _ -> file.absolutePath }
        val mac = UUID.randomUUID(); val phone = UUID.randomUUID()
        val left = SessionController(mac, scope, leftStore) {
            if (it is SyncEvent.Completed) completions.add(it.id)
            if (it is SyncEvent.Delivered) received[it.result.manifest.id] = it.result.output
            if (it is SyncEvent.Offer) aOffer.complete(it)
        }
        val right = SessionController(phone, scope, rightStore) {
            if (it is SyncEvent.Completed) completions.add(it.id)
            if (it is SyncEvent.Delivered) received[it.result.manifest.id] = it.result.output
            if (it is SyncEvent.Offer) bOffer.complete(it)
        }
        try {
            withTimeout(15000) {
                val (a,b) = pair(); channels += listOf(a,b)
                val key = ByteArray(32) { 7 }
                val authA = async { Handshake.authenticate(a, Role.MAC, mac, key, transport = Transport.ble) }
                val authB = async { Handshake.authenticate(b, Role.ANDROID, phone, key, transport = Transport.ble) }
                val encryptedA = EncryptedChannel(a, authA.await(), Transport.ble)
                val encryptedB = EncryptedChannel(b, authB.await(), Transport.ble)
                left.installBLE(authA.await(), encryptedA); right.installBLE(authB.await(), encryptedB)
                val context = UUID.randomUUID(); val secret = ByteArray(32) { 5 }
                val offer = JSONObject().put("id", context.toString()).put("secret", secret.hex())
                    .put("addresses", JSONArray().put(JSONObject().put("host","192.0.2.1").put("port",12345))).bytes()
                encryptedA.send(Record(RecordKind.TCP_OFFER, metadata = offer))
                encryptedB.send(Record(RecordKind.TCP_OFFER, metadata = offer))
                val first = aOffer.await(); val second = bOffer.await()
                assertContentEquals(first.binding, second.binding)
                val (c,d) = pair(); channels += listOf(c,d)
                val tcpA = async { Handshake.authenticate(c, Role.MAC, mac, first.binding, context, Transport.tcp) }
                val tcpB = async { Handshake.authenticate(d, Role.ANDROID, phone, second.binding, context, Transport.tcp) }
                left.installTCP(context, EncryptedChannel(c,tcpA.await(),Transport.tcp))
                right.installTCP(context, EncryptedChannel(d,tcpB.await(),Transport.tcp))
                val bytes = ByteArray(8 * 1024 * 1024) { 19 }
                val one = leftStore.snapshot(bytes.inputStream(),PayloadKind.FILE,"one.bin","x",mac)
                val two = rightStore.snapshot(bytes.inputStream(),PayloadKind.FILE,"two.bin","x",phone)
                left.enqueue(one); right.enqueue(two)
                withTimeout(7000) { while (completions.size < 2) delay(5) }
                assertContentEquals(bytes, File(received.getValue(one.manifest.id)).readBytes())
                assertContentEquals(bytes, File(received.getValue(two.manifest.id)).readBytes())
                assertTrue(left.outgoingFiles().isEmpty()); assertTrue(right.outgoingFiles().isEmpty())
            }
        } finally {
            left.disconnect(); right.disconnect()
            channels.forEach { it.close() }; scope.cancel()
            leftStore.closeHandles(); rightStore.closeHandles(); root.deleteRecursively()
        }
    }
    @Test fun retentionProtectsIncompleteTransfersAndPublishedFiles() = runBlocking {
        val root = Files.createTempDirectory("ancintosh-retention").toFile()
        var now = 1_700_000_000_000L
        val output = File(root, "keep.bin")
        val store = TransferStore(root, now = { now }) { file, _ -> file.copyTo(output, overwrite = false).absolutePath }
        try {
            val peer = UUID.randomUUID(); val bytes = byteArrayOf(1,2,3)
            val manifest = Manifest(UUID.randomUUID(),PayloadKind.FILE,"keep.bin","x",3,Crypto.digest(bytes),peer)
            assertEquals(0L,store.begin(manifest,peer))
            store.append(peer,manifest.id,0,bytes); store.finish(peer,manifest.id); store.delivered(peer,manifest.id)
            assertEquals(3L,store.begin(manifest,peer))
            assertFalse(store.finish(peer,manifest.id).fresh)
            val pending = manifest.copy(id = UUID.randomUUID(),name = "pending.bin")
            store.begin(pending,peer); store.append(peer,pending.id,0,byteArrayOf(1)); store.checkpoint(peer)
            now += 31L * 86400 * 1000
            assertEquals(0L,store.begin(manifest,peer))
            assertEquals(1L,store.begin(pending,peer))
            assertContentEquals(bytes,output.readBytes())
        } finally { store.closeHandles(); root.deleteRecursively() }
    }
    @Test fun outgoingCollectionKeepsLivePreparationAndRemovesOrphans() {
        val root = Files.createTempDirectory("ancintosh-outgoing").toFile()
        val store = TransferStore(root) { _, _ -> error("No incoming publication") }
        try {
            val snapshot = store.snapshot(byteArrayOf(1).inputStream(),PayloadKind.TEXT,"text","text/plain",UUID.randomUUID())
            val orphan = File(root,"outgoing/orphan.blob"); orphan.writeBytes(byteArrayOf(2))
            store.collectOutgoing(emptySet())
            assertTrue(snapshot.file.exists()); assertFalse(orphan.exists())
            store.release(snapshot.file); assertFalse(snapshot.file.exists())
        } finally { store.closeHandles(); root.deleteRecursively() }
    }
    @Test fun notificationIdsRemainStableBeyondTheOldRegistryLimitAndBackoffStaysBounded() {
        val device = UUID.randomUUID()
        val ids = (0..256).map { NotificationMessage.sourceID(device,"notification/" + it) }
        assertEquals(257,ids.toSet().size)
        assertEquals(ids.first(),NotificationMessage.sourceID(device,"notification/0"))
        assertNotEquals(ids.first(),NotificationMessage.sourceID(UUID.randomUUID(),"notification/0"))
        assertTrue(ids.all { it != Wire.ZERO_ID })
        val backoff = RecoveryBackoff()
        val delays = listOf(5000L,15000L,30000L,60000L)
        repeat(100) { assertEquals(delays[minOf(it,3)],backoff.nextMillis()) }
        assertEquals(5000L,RecoveryBackoff().nextMillis())
    }
    @Test fun gracefulExitIsReceivedAsIntentionalBeforeTheSocketCloses() = runBlocking {
        val root = Files.createTempDirectory("ancintosh-goodbye").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val stopped = CompletableDeferred<SyncEvent.Disconnected>()
        val leftStore = TransferStore(File(root,"a")) { f, _ -> f.path }
        val rightStore = TransferStore(File(root,"b")) { f, _ -> f.path }
        val mac = UUID.randomUUID(); val phone = UUID.randomUUID()
        val left = SessionController(phone,scope,leftStore) { }
        val right = SessionController(mac,scope,rightStore) { if (it is SyncEvent.Disconnected) stopped.complete(it) }
        val (a,b) = pair()
        try {
            withTimeout(5000) {
                val key = ByteArray(32) { 2 }
                val aa = async { Handshake.authenticate(a,Role.ANDROID,phone,key,transport = Transport.ble) }
                val bb = async { Handshake.authenticate(b,Role.MAC,mac,key,transport = Transport.ble) }
                left.installBLE(aa.await(),EncryptedChannel(a,aa.await(),Transport.ble))
                right.installBLE(bb.await(),EncryptedChannel(b,bb.await(),Transport.ble))
                left.closeGracefully()
                assertTrue(stopped.await().intentional)
                assertNull(left.connected); assertNull(right.connected)
            }
        } finally { left.disconnect(); right.disconnect(); a.close(); b.close(); scope.cancel(); root.deleteRecursively() }
    }
    @Test fun receiptCapacityIsPerPeerAndLeavesThePublishedFileUntouched() {
        val root = Files.createTempDirectory("ancintosh-history-limit").toFile()
        val peer = UUID.randomUUID(); val other = UUID.randomUUID(); val now = System.currentTimeMillis()
        val output = File(root,"keep.bin"); output.writeBytes(byteArrayOf(7))
        try {
            repeat(4098) { index ->
                val owner = if (index == 4097) other else peer
                val id = UUID(0,index.toLong()+1)
                val manifest = Manifest(id,PayloadKind.FILE,"keep.bin","x",0,Crypto.digest(byteArrayOf()),owner)
                val directory = File(root,"incoming/" + owner + "/" + id); directory.mkdirs()
                File(directory,"state.json").writeText(JSONObject().put("manifest",manifest.json()).put("peer",owner.toString())
                    .put("durable",0).put("complete",true).put("delivered",true).put("output",output.path)
                    .put("completedAt",now+(index-4098)*1000L).toString())
            }
            val store = TransferStore(root) { _, _ -> error("No publication") }
            store.restore()
            assertEquals(4096,File(root,"incoming/" + peer).listFiles()!!.size)
            assertEquals(1,File(root,"incoming/" + other).listFiles()!!.size)
            assertContentEquals(byteArrayOf(7),output.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun gracefulExitDuringBleDataDoesNotTurnIntoAnUnexpectedDisconnect() = runBlocking {
        val root = Files.createTempDirectory("ancintosh-active-goodbye").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val stopped = CompletableDeferred<SyncEvent.Disconnected>()
        val receiving = CompletableDeferred<Unit>(); val allowReader = CompletableDeferred<Unit>()
        val leftStore = TransferStore(File(root,"a")) { f, _ -> f.path }
        val rightStore = TransferStore(File(root,"b")) { f, _ -> f.path }
        val mac = UUID.randomUUID(); val phone = UUID.randomUUID()
        val left = SessionController(phone,scope,leftStore) { }
        val right = SessionController(mac,scope,rightStore) {
            if (it is SyncEvent.Disconnected) stopped.complete(it)
            if (it is SyncEvent.Progress && it.offset > 0 && !receiving.isCompleted) {
                receiving.complete(Unit); allowReader.await()
            }
        }
        val (a,b) = pair()
        try {
            withTimeout(5000) {
                val key = ByteArray(32) { 2 }
                val aa = async { Handshake.authenticate(a,Role.ANDROID,phone,key,transport = Transport.ble) }
                val bb = async { Handshake.authenticate(b,Role.MAC,mac,key,transport = Transport.ble) }
                left.installBLE(aa.await(),EncryptedChannel(a,aa.await(),Transport.ble))
                right.installBLE(bb.await(),EncryptedChannel(b,bb.await(),Transport.ble))
                val snapshot = leftStore.snapshot(ByteArray(1024*1024).inputStream(),PayloadKind.FILE,"active.bin","x",phone)
                left.enqueue(snapshot)
                receiving.await()
                val closing = async { left.closeGracefully() }
                yield(); allowReader.complete(Unit)
                closing.await()
                assertTrue(stopped.await().intentional)
                assertNull(left.connected)
                assertTrue(snapshot.file.exists())
            }
        } finally {
            allowReader.complete(Unit); left.disconnect(); right.disconnect(); a.close(); b.close()
            scope.cancel(); leftStore.closeHandles(); rightStore.closeHandles(); root.deleteRecursively()
        }
    }

    @Test fun unresponsivePeerCannotBlockLocalGracefulTeardownIndefinitely() = runBlocking {
        val root = Files.createTempDirectory("ancintosh-exit-deadline").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val closed = CompletableDeferred<Unit>()
        val raw = object : ByteChannel {
            override suspend fun readExactly(count: Int): ByteArray { closed.await(); fail(Failure.peerUnavailable) }
            override suspend fun write(data: ByteArray) = Unit
            override fun close() { closed.complete(Unit) }
        }
        val local = Hello(Role.ANDROID,UUID.randomUUID(),nonce = ByteArray(32) { 1 },publicKey = ByteArray(32) { 9 })
        val remote = Hello(Role.MAC,UUID.randomUUID(),nonce = ByteArray(32) { 2 },publicKey = ByteArray(32) { 9 })
        val auth = Authentication(remote.peer,CryptoSession(ByteArray(32) { 3 },local,remote,Transport.ble,ByteArray(32) { 9 }))
        val store = TransferStore(root) { f, _ -> f.path }
        val session = SessionController(local.peer,scope,store) { }
        try {
            session.installBLE(auth,EncryptedChannel(raw,auth,Transport.ble))
            withTimeout(3500) { session.closeGracefully() }
            assertNull(session.connected)
            assertTrue(closed.isCompleted)
        } finally { session.abortChannels(); scope.cancel(); root.deleteRecursively() }
    }

}
