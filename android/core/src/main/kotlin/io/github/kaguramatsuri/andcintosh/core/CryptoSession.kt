package io.github.kaguramatsuri.andcintosh.core

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.KeyPairGenerator
import java.security.KeyFactory
import java.security.spec.NamedParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object Crypto {
    private val random = SecureRandom()
    fun nonce(): ByteArray = ByteArray(32).also(random::nextBytes)
    fun key(hex: String): ByteArray { if (hex.length != 64) fail(Failure.invalidKey); return hex.unhex() }
    fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).hex()
    fun hmac(key: ByteArray, input: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(input)
    }
    fun derive(key: ByteArray, salt: ByteArray, info: ByteArray, count: Int = 32): ByteArray {
        if (count < 0 || count > 255 * 32) fail(Failure.invalidKey)
        val prk = hmac(if (salt.isEmpty()) ByteArray(32) else salt, key)
        var previous = byteArrayOf(); val output = ByteArray(count); var offset = 0; var counter = 1
        while (offset < count) {
            previous = hmac(prk, previous + info + counter.toByte())
            val size = minOf(previous.size, count - offset); previous.copyInto(output, offset, 0, size)
            offset += size; counter++
        }
        return output
    }
    fun derive(key: ByteArray, salt: ByteArray, info: String, count: Int = 32): ByteArray = derive(key, salt, info.toByteArray(), count)
    fun transcript(local: Hello, remote: Hello, transport: Transport): ByteArray {
        val mac = if (local.role == Role.MAC) local else remote
        val android = if (local.role == Role.ANDROID) local else remote
        return "Andcintosh/v2/${transport.name}/".toByteArray(Charsets.UTF_8) + mac.encode() + android.encode()
    }
    fun proof(key: ByteArray, transcript: ByteArray, role: Role): ByteArray = hmac(key, "Andcintosh/v2/proof/".toByteArray() + role.wire.toByte() + transcript)
}

class EphemeralAgreement {
    private val pair = KeyPairGenerator.getInstance("XDH").apply { initialize(NamedParameterSpec.X25519) }.generateKeyPair()
    val publicKey: ByteArray get() = pair.public.encoded.let {
        if (it.size != 44 || !it.copyOfRange(0, 12).contentEquals(PREFIX)) fail(Failure.invalidHandshake)
        it.copyOfRange(12, 44)
    }
    fun agree(remote: ByteArray): ByteArray {
        if (remote.size != 32) fail(Failure.invalidHandshake)
        val key = KeyFactory.getInstance("XDH").generatePublic(X509EncodedKeySpec(PREFIX + remote))
        return KeyAgreement.getInstance("XDH").run {
            init(pair.private); doPhase(key, true); generateSecret()
        }.also { if (it.size != 32 || it.all { b -> b == 0.toByte() }) fail(Failure.authenticationFailed) }
    }
    companion object { private val PREFIX = "302a300506032b656e032100".unhex() }
}

class CryptoSession(key: ByteArray, local: Hello, remote: Hello, transport: Transport, sharedSecret: ByteArray) {
    val root: ByteArray
    private var txKey: SecretKeySpec
    private var rxKey: SecretKeySpec
    private val txPrefix: ByteArray
    private val rxPrefix: ByteArray
    private val txCipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val rxCipher = Cipher.getInstance("AES/GCM/NoPadding")
    internal var txSequence = 0L
    private var txEpoch = 0L
    private var rxEpoch = 0L
    private val txDirection: String
    private val rxDirection: String
    internal var rxSequence = 0L
    init {
        if (key.size != 32 || sharedSecret.size != 32 || sharedSecret.all { it == 0.toByte() } || local.role == remote.role || local.context != remote.context || local.nonce.contentEquals(remote.nonce)) fail(Failure.invalidHandshake)
        val mac = if (local.role == Role.MAC) local else remote
        val android = if (local.role == Role.ANDROID) local else remote
        val transcript = Crypto.transcript(local, remote, transport)
        root = Crypto.derive(sharedSecret, Crypto.hmac(key, mac.nonce + android.nonce), "Andcintosh/v2/session/${Crypto.digest(transcript)}")
        val tx = if (local.role == Role.MAC) "mac" else "android"
        val rx = if (local.role == Role.MAC) "android" else "mac"
        txDirection = tx; rxDirection = rx
        txKey = SecretKeySpec(Crypto.derive(root, byteArrayOf(), "key/$tx/0"), "AES")
        rxKey = SecretKeySpec(Crypto.derive(root, byteArrayOf(), "key/$rx/0"), "AES")
        txPrefix = Crypto.derive(root, byteArrayOf(), "nonce/$tx", 4)
        rxPrefix = Crypto.derive(root, byteArrayOf(), "nonce/$rx", 4)
    }
    fun seal(record: Record): ByteArray {
        if (txSequence == Long.MAX_VALUE) fail(Failure.invalidFrame)
        val epoch = txSequence ushr 20
        if (epoch != txEpoch) { txKey = SecretKeySpec(Crypto.derive(root, byteArrayOf(), "key/$txDirection/$epoch"), "AES"); txEpoch = epoch }
        val data = record.encode()
        val header = ByteBuffer.allocate(12).putInt(data.size + 16).putLong(txSequence).array()
        val nonce = txPrefix + ByteBuffer.allocate(8).putLong(txSequence).array()
        txCipher.init(Cipher.ENCRYPT_MODE, txKey, GCMParameterSpec(128, nonce)); txCipher.updateAAD(header)
        val result = header + txCipher.doFinal(data); txSequence++
        return result
    }
    fun open(frame: ByteArray): Record {
        if (frame.size < 28) fail(Failure.invalidFrame)
        val b = ByteBuffer.wrap(frame); val size = b.int; val sequence = b.long
        if (size < 16 + Wire.HEADER_SIZE || size > Wire.MAX_PLAINTEXT + 16 || size != b.remaining()) fail(Failure.invalidFrame)
        if (sequence != rxSequence || rxSequence == Long.MAX_VALUE) fail(Failure.replay)
        val epoch = sequence ushr 20
        if (epoch != rxEpoch) { rxKey = SecretKeySpec(Crypto.derive(root, byteArrayOf(), "key/$rxDirection/$epoch"), "AES"); rxEpoch = epoch }
        val nonce = rxPrefix + ByteBuffer.allocate(8).putLong(sequence).array()
        rxCipher.init(Cipher.DECRYPT_MODE, rxKey, GCMParameterSpec(128, nonce)); rxCipher.updateAAD(frame, 0, 12)
        val data = try { rxCipher.doFinal(frame, 12, size) } catch (_: Exception) { fail(Failure.authenticationFailed) }
        val result = Record.decode(data); rxSequence++
        return result
    }
}
