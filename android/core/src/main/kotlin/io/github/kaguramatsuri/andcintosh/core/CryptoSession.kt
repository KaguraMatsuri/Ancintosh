package io.github.kaguramatsuri.andcintosh.core

import java.nio.ByteBuffer
import java.security.MessageDigest
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
    fun proof(key: ByteArray, transcript: ByteArray, role: Role): ByteArray = hmac(key, "Andcintosh/v1/proof/".toByteArray() + role.wire.toByte() + transcript)
}

class CryptoSession(key: ByteArray, local: Hello, remote: Hello, transport: Transport) {
    val root: ByteArray
    private val txKey: SecretKeySpec
    private val rxKey: SecretKeySpec
    private val txPrefix: ByteArray
    private val rxPrefix: ByteArray
    private val txCipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val rxCipher = Cipher.getInstance("AES/GCM/NoPadding")
    private var txSequence = 0L
    private var rxSequence = 0L
    init {
        if (key.size != 32 || local.role == remote.role || local.context != remote.context || local.nonce.contentEquals(remote.nonce)) fail(Failure.invalidHandshake)
        val mac = if (local.role == Role.MAC) local else remote
        val android = if (local.role == Role.ANDROID) local else remote
        val transcript = mac.encode() + android.encode()
        root = Crypto.derive(key, mac.nonce + android.nonce, "Andcintosh/v1/${transport.name}/${Crypto.digest(transcript)}")
        val tx = if (local.role == Role.MAC) "mac" else "android"
        val rx = if (local.role == Role.MAC) "android" else "mac"
        txKey = SecretKeySpec(Crypto.derive(root, byteArrayOf(), "key/$tx"), "AES")
        rxKey = SecretKeySpec(Crypto.derive(root, byteArrayOf(), "key/$rx"), "AES")
        txPrefix = Crypto.derive(root, byteArrayOf(), "nonce/$tx", 4)
        rxPrefix = Crypto.derive(root, byteArrayOf(), "nonce/$rx", 4)
    }
    fun seal(record: Record): ByteArray {
        if (txSequence == Long.MAX_VALUE) fail(Failure.invalidFrame)
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
        val nonce = rxPrefix + ByteBuffer.allocate(8).putLong(sequence).array()
        rxCipher.init(Cipher.DECRYPT_MODE, rxKey, GCMParameterSpec(128, nonce)); rxCipher.updateAAD(frame, 0, 12)
        val data = try { rxCipher.doFinal(frame, 12, size) } catch (_: Exception) { fail(Failure.authenticationFailed) }
        val result = Record.decode(data); rxSequence++
        return result
    }
}
