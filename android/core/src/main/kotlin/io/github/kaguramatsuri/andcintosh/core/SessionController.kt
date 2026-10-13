package io.github.kaguramatsuri.andcintosh.core

import java.util.UUID
import java.nio.ByteBuffer
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

sealed interface SyncEvent {
    data class Connected(val peer: UUID) : SyncEvent
    data class Disconnected(val peer: UUID, val intentional: Boolean) : SyncEvent
    data class Delivered(val peer: UUID, val result: Received) : SyncEvent
    data class Progress(val id: UUID, val offset: Long, val size: Long) : SyncEvent
    data class Failed(val id: UUID, val code: Failure) : SyncEvent
    data class Completed(val id: UUID) : SyncEvent
    data class Offer(val peer: UUID, val context: UUID, val addresses: List<Pair<String, Int>>, val binding: ByteArray) : SyncEvent
}

class SessionController(val identity: UUID, private val scope: CoroutineScope, private val store: TransferStore,
                        private val events: suspend (SyncEvent) -> Unit) {
    private val state = Mutex()
    private val queue = mutableListOf<OutboundJob>()
    private var pumping = false
    @Volatile private var peer: UUID? = null
    @Volatile private var ble: EncryptedChannel? = null
    @Volatile private var tcp: EncryptedChannel? = null
    @Volatile private var offer: UUID? = null
    @Volatile private var epoch: UUID = Wire.ZERO_ID
    @Volatile private var awaitingFallback = false
    private var currentClipboard: File? = null
    private val lastProgress = mutableMapOf<UUID, Long>()
    var wifi = true; private set
    @Volatile private var remoteWifi = true
    val connected: UUID? get() = peer
    suspend fun outgoingFiles(): List<OutboundJob> = state.withLock { queue.filter { it.snapshot.manifest.kind == PayloadKind.FILE }.map { it.copy() } }
    suspend fun restore() = state.withLock { queue.addAll(store.restore()) }

    suspend fun installBLE(auth: Authentication, channel: EncryptedChannel) {
        ble?.close(); tcp?.close(); tcp = null; ble = channel; peer = auth.peer; offer = null
        val root = ByteBuffer.wrap(channel.root)
        epoch = UUID(root.long, root.long); awaitingFallback = false
        channel.setDataEpoch(epoch)
        store.selectEpoch(auth.peer, epoch)
        state.withLock {
            queue.removeAll { it.snapshot.manifest.kind != PayloadKind.FILE }
            queue.forEach { it.begun = false; it.waiting = false; it.finished = false }
        }
        scope.launch { readLoop(channel, false) }
        channel.send(Record(RecordKind.WIFI_PREFERENCE, metadata = JSONObject().put("enabled", wifi).bytes()))
        events(SyncEvent.Connected(auth.peer)); pump()
    }
    suspend fun installTCP(context: UUID, channel: EncryptedChannel) {
        if (!wifi || !remoteWifi || context != offer || ble == null) { channel.close(); fail(Failure.authenticationFailed) }
        tcp?.close(); tcp = channel
        epoch = context; awaitingFallback = false
        ble?.setDataEpoch(null); channel.setDataEpoch(epoch)
        peer?.let { store.selectEpoch(it, epoch) }
        reset(); scope.launch { readLoop(channel, true) }; pump()
    }
    suspend fun wifi(enabled: Boolean) {
        wifi = enabled
        if (!enabled && tcp != null) tcpLost()
        ble?.send(Record(RecordKind.WIFI_PREFERENCE, metadata = JSONObject().put("enabled", enabled).bytes()))
        pump()
    }
    suspend fun requestUpgrade() { if (wifi && ble != null) ble?.send(Record(RecordKind.WIFI_PREFERENCE, metadata = JSONObject().put("enabled", true).bytes())) }
    suspend fun tcpLost() {
        val previous = tcp; tcp = null; offer = null; awaitingFallback = true; previous?.close()
        ble?.setDataEpoch(null)
        peer?.let(store::checkpoint); reset()
        ble?.send(Record(RecordKind.TRANSPORT_SWITCH, metadata = JSONObject().put("transport", "ble").bytes()))
    }
    suspend fun disconnect(intentional: Boolean = false) {
        val current = peer ?: return
        if (intentional) runCatching { ble?.send(Record(RecordKind.GOODBYE)) }
        peer = null; ble?.close(); ble = null; tcp?.close(); tcp = null; offer = null
        store.checkpoint(current); store.closeHandles(); reset(); events(SyncEvent.Disconnected(current, intentional))
    }
    suspend fun enqueue(snapshot: Snapshot) {
        val target = peer ?: fail(Failure.peerUnavailable)
        state.withLock {
            if (snapshot.manifest.kind != PayloadKind.FILE) {
                queue.removeAll { !it.begun && it.snapshot.manifest.kind != PayloadKind.FILE }
                queue.add(0, OutboundJob(target, snapshot, true))
            } else queue.add(OutboundJob(target, snapshot, true))
            store.persist(queue)
        }
        pump()
    }
    suspend fun retry(id: UUID) {
        state.withLock { queue.firstOrNull { it.snapshot.manifest.id == id }?.let { it.failed = null; it.begun = false; it.waiting = false; it.finished = false }; store.persist(queue) }
        pump()
    }
    suspend fun cancel(id: UUID) {
        val source = state.withLock {
            val source = queue.firstOrNull { it.snapshot.manifest.id == id }?.snapshot?.file
            queue.removeAll { it.snapshot.manifest.id == id }; store.persist(queue); source
        }
        if (source != null) store.release(source)
        (tcp ?: ble)?.discardBuffered(id)
        runCatching { (tcp ?: ble)?.send(Record(RecordKind.CANCEL, id, epoch = epoch)) }
        peer?.let { store.cancel(it, id) }; pump()
    }
    private suspend fun reset() = state.withLock { queue.forEach { it.begun = false; it.waiting = false; it.finished = false }; store.persist(queue) }
    private fun nextReadyJob(): OutboundJob? {
        queue.firstOrNull { it.snapshot.manifest.kind != PayloadKind.FILE && !it.finished && !it.waiting && it.failed == null }?.let { return it }
        return queue.firstOrNull { it.snapshot.manifest.kind == PayloadKind.FILE && it.failed == null }
            ?.takeIf { !it.finished && !it.waiting }
    }
    private fun pump() { scope.launch { drain() } }
    private suspend fun drain() {
        state.withLock { if (pumping) return; pumping = true }
        try {
            while (peer != null && !awaitingFallback) {
                val channel = tcp ?: ble ?: return
                val job = state.withLock { nextReadyJob()?.copy() } ?: return
                val selectedEpoch = epoch
                try {
                    if (job.begun && job.offset < job.snapshot.manifest.size) {
                        channel.sendBuffered {
                            val count = minOf(if (channel.transport == Transport.tcp) Wire.TCP_CHUNK.toLong() else Wire.BLE_CHUNK.toLong(), job.snapshot.manifest.size - job.offset).toInt()
                            val bytes = store.read(job.snapshot, job.offset, count)
                            if (bytes.isEmpty()) fail(Failure.sourceUnavailable)
                            state.withLock {
                                val current = queue.firstOrNull { it.snapshot.manifest.id == job.snapshot.manifest.id } ?: fail(Failure.cancelled)
                                if (selectedEpoch != epoch || channel !== (tcp ?: ble) || awaitingFallback) fail(Failure.peerUnavailable)
                                if (current.offset != job.offset) fail(Failure.invalidOffset)
                                current.offset += bytes.size
                                Record(RecordKind.DATA, job.snapshot.manifest.id, job.offset, bytes = bytes, epoch = selectedEpoch)
                            }
                        }
                    } else {
                        val record = state.withLock {
                            val current = queue.firstOrNull { it.snapshot.manifest.id == job.snapshot.manifest.id } ?: return@withLock null
                            if (!current.begun) {
                                current.begun = true; current.waiting = true
                                Record(RecordKind.BEGIN, current.snapshot.manifest.id, metadata = current.snapshot.manifest.json().bytes(), epoch = selectedEpoch)
                            } else {
                                current.finished = true
                                Record(RecordKind.FINISH, current.snapshot.manifest.id, current.offset, epoch = selectedEpoch)
                            }
                        } ?: continue
                        channel.send(record)
                    }
                    val progress = state.withLock { queue.firstOrNull { it.snapshot.manifest.id == job.snapshot.manifest.id }?.offset } ?: continue
                    val now = System.nanoTime()
                    if (progress == job.snapshot.manifest.size || now - (lastProgress[job.snapshot.manifest.id] ?: 0L) >= 200_000_000L) {
                        lastProgress[job.snapshot.manifest.id] = now
                        events(SyncEvent.Progress(job.snapshot.manifest.id, progress, job.snapshot.manifest.size))
                    }
                } catch (error: Exception) {
                    if (error is ProtocolException && error.code == Failure.cancelled) continue
                    if (error is ProtocolException && error.code == Failure.sourceUnavailable) {
                        state.withLock { queue.firstOrNull { it.snapshot.manifest.id == job.snapshot.manifest.id }?.failed = error.code; store.persist(queue) }; events(SyncEvent.Failed(job.snapshot.manifest.id, error.code))
                    } else {
                        reset()
                        if (channel === (tcp ?: ble)) { if (channel.transport == Transport.tcp) tcpLost() else disconnect() }
                        return
                    }
                }
            }
        } finally {
            val ready = state.withLock {
                pumping = false
                nextReadyJob() != null
            }
            if (ready && peer != null && !awaitingFallback) pump()
        }
    }
    private suspend fun readLoop(channel: EncryptedChannel, isTCP: Boolean) {
        try {
            while ((if (isTCP) tcp else ble) === channel) {
                val record = channel.receive()
                if ((if (isTCP) tcp else ble) !== channel) return
                receive(record, channel, isTCP)
            }
        } catch (_: Exception) {
            if ((if (isTCP) tcp else ble) !== channel) return
            if (isTCP) tcpLost() else disconnect()
        }
    }
    private suspend fun receive(record: Record, channel: EncryptedChannel, isTCP: Boolean) {
        val current = peer ?: return
        val transfer = record.kind in listOf(RecordKind.BEGIN, RecordKind.DATA, RecordKind.FINISH, RecordKind.ACK, RecordKind.RESUME, RecordKind.CANCEL, RecordKind.FAILURE)
        if (transfer && (awaitingFallback || record.epoch != epoch || channel !== (tcp ?: ble))) return
        try {
            when (record.kind) {
                RecordKind.BEGIN -> {
                    val manifest = Manifest.decode(record.json()); if (manifest.id != record.id) fail(Failure.invalidManifest)
                    channel.send(Record(RecordKind.RESUME, record.id, store.begin(manifest, current, record.epoch), epoch = record.epoch))
                }
                RecordKind.DATA -> store.append(current, record.id, record.offset, record.bytes, record.epoch)?.let {
                    channel.send(Record(RecordKind.ACK, record.id, it, JSONObject().put("complete", false).bytes(), epoch = record.epoch))
                }
                RecordKind.FINISH -> {
                    val result = store.finish(current, record.id, record.epoch)
                    if (result.fresh) {
                        events(SyncEvent.Delivered(current, result)); store.delivered(current, record.id)
                        if (result.manifest.kind != PayloadKind.FILE) {
                            currentClipboard = result.file
                            val retained = state.withLock { queue.map { it.snapshot.file }.toSet() }
                            store.collectClipboard(retained + result.file)
                        }
                    }
                    channel.send(Record(RecordKind.ACK, record.id, result.manifest.size, JSONObject().put("complete", true).bytes(), epoch = record.epoch))
                }
                RecordKind.RESUME -> state.withLock {
                    queue.firstOrNull { it.snapshot.manifest.id == record.id }?.let {
                        if (record.offset > it.snapshot.manifest.size) fail(Failure.invalidOffset)
                        it.offset = record.offset; it.begun = true; it.waiting = false; it.finished = false
                    }
                }
                RecordKind.ACK -> if (record.json().getBoolean("complete")) {
                    val job = state.withLock {
                        val job = queue.firstOrNull { it.snapshot.manifest.id == record.id } ?: return@withLock null
                        if (record.offset != job.snapshot.manifest.size) fail(Failure.invalidOffset)
                        queue.remove(job); store.persist(queue); job
                    }
                    job?.let { store.release(it.snapshot.file); events(SyncEvent.Completed(record.id)) }
                }
                RecordKind.CANCEL -> { state.withLock { queue.removeAll { it.snapshot.manifest.id == record.id }; store.persist(queue) }; store.cancel(current, record.id) }
                RecordKind.WIFI_PREFERENCE -> {
                    if (isTCP) fail(Failure.invalidFrame)
                    remoteWifi = record.json().getBoolean("enabled")
                    if (!remoteWifi) tcpLost()
                }
                RecordKind.TCP_OFFER -> {
                    if (isTCP || !wifi || !remoteWifi) fail(Failure.invalidFrame)
                    val j = record.json(); val context = UUID.fromString(j.getString("id")); val secret = j.getString("secret").unhex()
                    val array = j.getJSONArray("addresses"); if (secret.size != 32 || array.length() !in 1..8) fail(Failure.invalidFrame)
                    val addresses = (0 until array.length()).map { array.getJSONObject(it).let { a -> a.getString("host") to a.getInt("port") } }
                    offer = context
                    events(SyncEvent.Offer(current, context, addresses, Crypto.derive(channel.root, secret, "Andcintosh/v2/tcp-binding")))
                }
                RecordKind.GOODBYE -> { if (isTCP) fail(Failure.invalidFrame); disconnect(true) }
                RecordKind.TRANSPORT_SWITCH -> {
                    if (isTCP || record.epoch == Wire.ZERO_ID || record.json().getString("transport") != "ble") fail(Failure.invalidFrame)
                    val previous = tcp; tcp = null; previous?.close(); offer = null
                    epoch = record.epoch; awaitingFallback = false
                    ble?.setDataEpoch(epoch)
                    store.selectEpoch(current, epoch)
                    store.checkpoint(current); reset()
                }
                RecordKind.FAILURE -> {
                    val code = Failure.valueOf(record.json().getString("code"))
                    val pending = state.withLock {
                        val job = queue.firstOrNull { it.snapshot.manifest.id == record.id } ?: return@withLock false
                        job.failed = code; store.persist(queue); true
                    }
                    if (pending) events(SyncEvent.Failed(record.id, code))
                }
            }
        } catch (error: ProtocolException) {
            if (transfer && record.epoch != epoch) return
            if (record.kind in listOf(RecordKind.BEGIN, RecordKind.DATA, RecordKind.FINISH, RecordKind.RESUME)) {
                channel.send(Record(RecordKind.FAILURE, record.id, metadata = JSONObject().put("code", error.code.name).bytes(), epoch = record.epoch))
                events(SyncEvent.Failed(record.id, error.code))
            } else throw error
        } catch (error: Exception) {
            if (record.kind in listOf(RecordKind.BEGIN, RecordKind.DATA, RecordKind.FINISH)) {
                val code = if (error is SecurityException) Failure.permissionDenied else Failure.sourceUnavailable
                channel.send(Record(RecordKind.FAILURE, record.id, metadata = JSONObject().put("code", code.name).bytes(), epoch = record.epoch))
                events(SyncEvent.Failed(record.id, code))
            } else throw error
        }
        pump()
    }
}
