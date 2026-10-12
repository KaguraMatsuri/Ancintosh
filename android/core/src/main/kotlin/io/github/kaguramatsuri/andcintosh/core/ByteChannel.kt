package io.github.kaguramatsuri.andcintosh.core

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

interface ByteChannel {
    suspend fun readExactly(count: Int): ByteArray
    suspend fun write(data: ByteArray)
    fun close()
}
data class Authentication(val peer: UUID, val crypto: CryptoSession)
object Handshake {
    suspend fun authenticate(channel: ByteChannel, role: Role, identity: UUID, key: ByteArray,
                             context: UUID = Wire.ZERO_ID, transport: Transport, expectedPeer: UUID? = null): Authentication {
        val local = Hello(role, identity, context, Crypto.nonce())
        channel.write(local.encode())
        val remote = Hello.decode(channel.readExactly(Wire.HELLO_SIZE))
        if (remote.role == role || remote.context != context || (expectedPeer != null && expectedPeer != remote.peer)) fail(Failure.authenticationFailed)
        val transcript = if (role == Role.MAC) local.encode() + remote.encode() else remote.encode() + local.encode()
        channel.write(Crypto.proof(key, transcript, role))
        if (!MessageDigest.isEqual(channel.readExactly(32), Crypto.proof(key, transcript, remote.role))) fail(Failure.authenticationFailed)
        return Authentication(remote.peer, CryptoSession(key, local, remote, transport))
    }
}
class EncryptedChannel(private val raw: ByteChannel, authentication: Authentication, val transport: Transport) {
    val root = authentication.crypto.root
    private val crypto = authentication.crypto
    private val writer = Mutex()
    private val reader = Mutex()
    suspend fun send(record: Record) = writer.withLock { raw.write(crypto.seal(record)) }
    suspend fun receive(): Record = reader.withLock {
        val header = raw.readExactly(12); val size = ByteBuffer.wrap(header).int
        if (size < 16 + Wire.HEADER_SIZE || size > Wire.MAX_PLAINTEXT + 16) fail(Failure.invalidFrame)
        crypto.open(header + raw.readExactly(size))
    }
    fun close() = raw.close()
}
