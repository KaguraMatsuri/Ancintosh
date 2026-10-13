package io.github.kaguramatsuri.ancintosh.core

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

interface ByteChannel {
    suspend fun readExactly(count: Int): ByteArray
    suspend fun write(data: ByteArray)
    fun close()
}
data class Authentication(val peer: UUID, val crypto: CryptoSession)
object Handshake {
    suspend fun readHello(channel: ByteChannel): Hello {
        val prefix = channel.readExactly(8)
        if (!prefix.copyOfRange(0, 7).contentEquals(Wire.MAGIC)) fail(Failure.invalidHandshake)
        if (prefix[7].toInt() != Wire.VERSION) fail(Failure.unsupportedVersion)
        return Hello.decode(prefix + channel.readExactly(Wire.HELLO_SIZE - 8))
    }

    suspend fun authenticate(channel: ByteChannel, role: Role, identity: UUID, key: ByteArray,
                             context: UUID = Wire.ZERO_ID, transport: Transport, expectedPeer: UUID? = null): Authentication {
        val ephemeral = EphemeralAgreement()
        val local = Hello(role, identity, context, Crypto.nonce(), ephemeral.publicKey)
        channel.write(local.encode())
        val remote = readHello(channel)
        if (remote.role == role || remote.context != context || (expectedPeer != null && expectedPeer != remote.peer)) fail(Failure.authenticationFailed)
        val transcript = Crypto.transcript(local, remote, transport)
        channel.write(Crypto.proof(key, transcript, role))
        if (!MessageDigest.isEqual(channel.readExactly(32), Crypto.proof(key, transcript, remote.role))) fail(Failure.authenticationFailed)
        val shared = ephemeral.agree(remote.publicKey)
        val crypto = try { CryptoSession(key, local, remote, transport, shared) } finally { shared.fill(0) }
        val finishedKey = Crypto.derive(crypto.root, byteArrayOf(), "finished")
        try {
            channel.write(Crypto.proof(finishedKey, transcript, role))
            if (!MessageDigest.isEqual(channel.readExactly(32), Crypto.proof(finishedKey, transcript, remote.role))) fail(Failure.authenticationFailed)
        } finally { finishedKey.fill(0) }
        return Authentication(remote.peer, crypto)
    }
}
class EncryptedChannel(private val raw: ByteChannel, authentication: Authentication, val transport: Transport) {
    val root = authentication.crypto.root
    private val crypto = authentication.crypto
    private data class Write(val record: Record, val completion: CompletableDeferred<Unit>?, val buffered: Boolean)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val writes = Channel<Write>(Channel.UNLIMITED)
    private val lifetime = ChannelLifetime()
    private val slots = TransferSlots(16)
    private val reader = Mutex()
    @Volatile private var dataEpoch: UUID? = null
    private val discarded = java.util.concurrent.ConcurrentHashMap.newKeySet<UUID>()
    init {
        scope.launch {
            try {
                for (write in writes) {
                    try {
                        if (lifetime.closed) fail(Failure.peerUnavailable)
                        if (!write.buffered || (write.record.epoch == dataEpoch && !discarded.contains(write.record.id))) raw.write(crypto.seal(write.record))
                        write.completion?.complete(Unit)
                    } catch (error: Exception) { write.completion?.completeExceptionally(error); throw error }
                    finally { if (write.buffered) releaseSlot() }
                }
            } catch (_: Exception) { close() }
        }
    }
    suspend fun send(record: Record) {
        if (lifetime.closed) fail(Failure.peerUnavailable)
        val done = CompletableDeferred<Unit>()
        writes.send(Write(record, done, false)); done.await()
    }
    suspend fun sendBuffered(produce: suspend () -> Record) {
        slots.acquire(lifetime)
        try { TransferSlots.shared.acquire(lifetime) }
        catch (error: Exception) { slots.release(); throw error }
        try {
            currentCoroutineContext().ensureActive()
            if (lifetime.closed) fail(Failure.peerUnavailable)
            val record = produce()
            if (lifetime.closed || record.epoch != dataEpoch) fail(Failure.peerUnavailable)
            if (discarded.contains(record.id)) fail(Failure.cancelled)
            if (record.kind != RecordKind.DATA || record.bytes.size > (if (transport == Transport.tcp) Wire.TCP_CHUNK else Wire.BLE_CHUNK)) fail(Failure.oversizedRecord)
            writes.send(Write(record, null, true))
        } catch (error: Exception) { releaseSlot(); throw error }
    }
    fun setDataEpoch(epoch: UUID?) { dataEpoch = epoch }
    fun discardBuffered(id: UUID) { discarded.add(id) }
    private fun releaseSlot() { slots.release(); TransferSlots.shared.release() }
    suspend fun receive(): Record = reader.withLock {
        val header = raw.readExactly(12); val size = ByteBuffer.wrap(header).int
        if (size < 16 + Wire.HEADER_SIZE || size > Wire.MAX_PLAINTEXT + 16) fail(Failure.invalidFrame)
        crypto.open(header + raw.readExactly(size))
    }
    @Synchronized fun close() {
        if (lifetime.closed) return
        lifetime.closed = true
        slots.removeClosedWaiters(); TransferSlots.shared.removeClosedWaiters()
        writes.close(); raw.close(); scope.cancel()
        while (true) {
            val write = writes.tryReceive().getOrNull() ?: break
            write.completion?.completeExceptionally(ProtocolException(Failure.peerUnavailable))
            if (write.buffered) releaseSlot()
        }
        discarded.clear()
    }
}
