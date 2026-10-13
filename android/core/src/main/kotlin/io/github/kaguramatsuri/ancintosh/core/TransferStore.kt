package io.github.kaguramatsuri.ancintosh.core

import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class Snapshot(val manifest: Manifest, val file: File)
data class OutboundJob(val peer: UUID, val snapshot: Snapshot, val user: Boolean, var offset: Long = 0,
                       var begun: Boolean = false, var waiting: Boolean = false, var finished: Boolean = false,
                       var failed: Failure? = null)
data class Received(val manifest: Manifest, val file: File, val output: String, val fresh: Boolean)
typealias PublicationCommit = (() -> String) -> String
typealias StagedPublisher = (File, Manifest, () -> Unit, PublicationCommit) -> String

private data class Incoming(val manifest: Manifest, val peer: UUID, val directory: File, var handle: RandomAccessFile?,
                            var written: Long, var durable: Long, var complete: Boolean, var delivered: Boolean, var output: String?, var generation: UUID = UUID.randomUUID())

class TransferStore(val root: File, private val stagedPublish: StagedPublisher? = null, private val publish: (File, Manifest) -> String) {
    private val incoming = mutableMapOf<String, Incoming>()
    private val readers = mutableMapOf<File, RandomAccessFile>()
    private val epochs = mutableMapOf<UUID, UUID>()
    private val verifications = mutableMapOf<String, AtomicBoolean>()
    private val verification = Mutex()
    init { listOf(root, File(root, "outgoing"), File(root, "incoming"), File(root, "clipboard")).forEach { it.mkdirs() } }

    fun snapshot(input: InputStream, kind: PayloadKind, name: String, mime: String, origin: UUID): Snapshot {
        val id = UUID.randomUUID(); val file = File(root, "outgoing/$id.blob")
        var success = false
        try {
            val digest = MessageDigest.getInstance("SHA-256"); var size = 0L
            input.use { source -> RandomAccessFile(file, "rw").use { target ->
                val buffer = ByteArray(65536)
                while (true) {
                    val count = source.read(buffer); if (count < 0) break; if (count == 0) continue
                    target.write(buffer, 0, count); digest.update(buffer, 0, count); size += count
                }
                target.fd.sync()
            } }
            val manifest = Manifest(id, kind, name, mime, size, digest.digest().hex(), origin)
            success = true
            return Snapshot(manifest, file)
        } finally { if (!success) file.delete() }
    }
    @Synchronized fun read(snapshot: Snapshot, offset: Long, count: Int): ByteArray {
        val handle = readers.getOrPut(snapshot.file) { RandomAccessFile(snapshot.file, "r") }
        handle.seek(offset); val bytes = ByteArray(count); val read = handle.read(bytes)
        return if (read < 0) byteArrayOf() else bytes.copyOf(read)
    }
    @Synchronized fun release(file: File) { readers.remove(file)?.close(); if (file.parentFile == File(root, "outgoing")) file.delete() }
    @Synchronized fun closeHandles() {
        readers.values.forEach { runCatching { it.close() } }; readers.clear()
        verifications.values.forEach { it.set(true) }
        incoming.values.forEach { runCatching { it.handle?.close() }; it.handle = null }
    }
    @Synchronized fun collectClipboard(keeping: Set<File>) {
        File(root,"clipboard").listFiles()?.forEach { directory ->
            if (keeping.none { it.parentFile == directory }) directory.deleteRecursively()
        }
    }
    @Synchronized fun persist(jobs: List<OutboundJob>) {
        val array = JSONArray()
        jobs.filter { it.snapshot.manifest.kind == PayloadKind.FILE }.forEach {
            array.put(JSONObject().put("peer", it.peer.toString()).put("manifest", it.snapshot.manifest.json())
                .put("file", it.snapshot.file.name).put("offset", it.offset).put("failed", it.failed?.name))
        }
        atomic(File(root, "outgoing.json"), array.toString().toByteArray())
    }
    @Synchronized fun restore(): List<OutboundJob> {
        val state = File(root, "outgoing.json"); if (!state.exists()) return emptyList()
        val array = JSONArray(state.readText())
        return (0 until array.length()).mapNotNull {
            val job = array.getJSONObject(it); val name = job.getString("file")
            if (File(name).name != name) return@mapNotNull null
            val file = File(root, "outgoing/$name"); if (!file.isFile) return@mapNotNull null
            OutboundJob(UUID.fromString(job.getString("peer")), Snapshot(Manifest.decode(job.getJSONObject("manifest")), file), true,
                failed = job.optString("failed").takeIf { it.isNotEmpty() }?.let(Failure::valueOf))
        }
    }
    @Synchronized fun selectEpoch(peer: UUID, epoch: UUID) {
        if (epochs[peer] != epoch) incoming.filterValues { it.peer == peer }.keys.forEach { verifications[it]?.set(true) }
        epochs[peer] = epoch
    }
    @Synchronized fun begin(manifest: Manifest, peer: UUID, epoch: UUID? = null): Long {
        if (epoch != null && epochs[peer] != epoch) fail(Failure.invalidOffset)
        val key = "$peer/${manifest.id}"
        verifications.remove(key)?.set(true)
        incoming[key]?.let {
            if (it.manifest != manifest) fail(Failure.invalidManifest)
            if (it.complete) return manifest.size
            it.generation = UUID.randomUUID()
            if (it.handle == null) it.handle = RandomAccessFile(File(it.directory, "data.part"), "rw")
            it.handle!!.setLength(it.durable); it.handle!!.seek(it.durable); it.written = it.durable
            return it.durable
        }
        val directory = File(root, "incoming/$key"); directory.mkdirs()
        val state = File(directory, "state.json")
        val stored = if (state.isFile) JSONObject(state.readText()) else null
        if (stored != null && (Manifest.decode(stored.getJSONObject("manifest")) != manifest || stored.getString("peer") != peer.toString())) fail(Failure.invalidManifest)
        val durable = stored?.getLong("durable") ?: 0
        val complete = stored?.optBoolean("complete") ?: false
        val file = File(directory, "data.part")
        val handle = if (complete) null else RandomAccessFile(file, "rw")
        if (handle != null) { if (handle.length() < durable) { handle.close(); fail(Failure.invalidOffset) }; handle.setLength(durable); handle.seek(durable) }
        val item = Incoming(manifest, peer, directory, handle, durable, durable, complete,
            stored?.optBoolean("delivered") ?: false, stored?.optString("output")?.takeIf { it.isNotEmpty() })
        incoming[key] = item; save(item)
        return if (complete) manifest.size else durable
    }
    @Synchronized fun append(peer: UUID, id: UUID, offset: Long, bytes: ByteArray, epoch: UUID? = null): Long? {
        if (epoch != null && epochs[peer] != epoch) fail(Failure.invalidOffset)
        val item = incoming["$peer/$id"] ?: fail(Failure.invalidOffset)
        if (item.complete || offset != item.written || bytes.size > item.manifest.size - item.written) fail(Failure.invalidOffset)
        item.handle!!.write(bytes); item.written += bytes.size
        if (item.written - item.durable < 4 * 1024 * 1024) return null
        item.handle!!.fd.sync(); item.durable = item.written; save(item)
        return item.durable
    }
    suspend fun finish(peer: UUID, id: UUID, epoch: UUID? = null): Received = verification.withLock {
        withContext(Dispatchers.IO) {
            val key = "$peer/$id"
            val cancelled = AtomicBoolean(false)
            val item = synchronized(this@TransferStore) {
                if (epoch != null && epochs[peer] != epoch) fail(Failure.invalidOffset)
                val found = incoming[key] ?: fail(Failure.invalidOffset)
                if (found.complete) return@withContext Received(found.manifest, File(found.output!!), found.output!!, !found.delivered)
                if (found.written != found.manifest.size) fail(Failure.invalidOffset)
                found.handle?.fd?.sync(); found.handle?.close(); found.handle = null
                verifications[key] = cancelled
                found
            }
            val generation = item.generation
            val part = File(item.directory, "data.part")
            val check = {
                if (cancelled.get()) fail(Failure.cancelled)
                synchronized(this@TransferStore) {
                    if (incoming[key]?.generation != generation || (epoch != null && epochs[peer] != epoch)) fail(Failure.invalidOffset)
                }
            }
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                part.inputStream().use { input ->
                    val bytes = ByteArray(65536)
                    while (true) { check(); val count = input.read(bytes); if (count < 0) break; digest.update(bytes, 0, count) }
                }
                check()
                if (digest.digest().hex() != item.manifest.sha256.lowercase()) { cancel(peer, id); fail(Failure.digestMismatch) }
                val commit: PublicationCommit = { publish ->
                    synchronized(this@TransferStore) {
                        check()
                        val output = publish()
                        val complete = item.copy(complete = true, durable = item.manifest.size, output = output)
                        save(complete); incoming[key] = complete
                        output
                    }
                }
                val output = if (item.manifest.kind == PayloadKind.FILE) {
                    stagedPublish?.invoke(part, item.manifest, check, commit) ?: commit { publish(part, item.manifest) }
                } else commit {
                    val directory = File(root, "clipboard/$id"); directory.mkdirs()
                    val target = File(directory, item.manifest.name)
                    Files.move(part.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    atomic(File(directory, "manifest.json"), item.manifest.json().bytes())
                    target.absolutePath
                }
                Received(item.manifest, if (item.manifest.kind == PayloadKind.FILE) part else File(output), output, true)
            } finally {
                synchronized(this@TransferStore) { if (verifications[key] === cancelled) verifications.remove(key) }
            }
        }
    }
    @Synchronized fun delivered(peer: UUID, id: UUID) { incoming["$peer/$id"]?.let { it.delivered = true; save(it) } }
    @Synchronized fun checkpoint(peer: UUID) {
        incoming.values.filter { it.peer == peer && !it.complete }.forEach {
            it.handle?.fd?.sync(); it.durable = it.written; save(it)
        }
    }
    @Synchronized fun cancel(peer: UUID, id: UUID) {
        val item = incoming["$peer/$id"]
        if (item?.complete == true) return
        verifications.remove("$peer/$id")?.set(true)
        incoming.remove("$peer/$id")?.handle?.close(); File(root, "incoming/$peer/$id").deleteRecursively()
    }
    private fun save(item: Incoming) {
        atomic(File(item.directory, "state.json"), JSONObject().put("manifest", item.manifest.json())
            .put("peer", item.peer.toString()).put("durable", item.durable).put("complete", item.complete)
            .put("delivered", item.delivered).put("output", item.output).bytes())
    }
    private fun atomic(file: File, bytes: ByteArray) {
        val temp = File(file.parentFile, "${file.name}.tmp")
        RandomAccessFile(temp, "rw").use { it.setLength(0); it.write(bytes); it.fd.sync() }
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }
}
