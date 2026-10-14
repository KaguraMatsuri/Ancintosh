package io.github.kaguramatsuri.ancintosh.core

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import org.json.JSONObject

enum class Failure { invalidKey, unsupportedVersion, invalidHandshake, authenticationFailed, invalidFrame, replay, oversizedRecord,
    invalidManifest, invalidOffset, digestMismatch, sourceUnavailable, originalUnavailable, insufficientSpace,
    cancelled, peerUnavailable, timeout, permissionDenied, invalidName, unsupported }
class ProtocolException(val code: Failure) : Exception(code.name)
enum class Role(val wire: Int) { MAC(1), ANDROID(2) }
enum class Transport { ble, tcp }
enum class PayloadKind(val wire: Int) { TEXT(1), IMAGE(2), FILE(3) }
enum class RecordKind(val wire: Int) {
    BEGIN(1), DATA(2), FINISH(3), ACK(4), RESUME(5), CANCEL(6), WIFI_PREFERENCE(7), TCP_OFFER(8), GOODBYE(9), FAILURE(10), TRANSPORT_SWITCH(11), DEVICE_INFORMATION(12), CONFIGURATION(13), NOTIFICATION(14)
}
object Wire {
    val MAGIC = "Ciallo~".toByteArray(Charsets.US_ASCII)
    const val VERSION = 2
    const val HELLO_SIZE = 105
    const val MAX_PLAINTEXT = 65536
    const val HEADER_SIZE = 45
    const val MAX_METADATA = 8192
    const val TCP_CHUNK = MAX_PLAINTEXT - HEADER_SIZE
    const val BLE_CHUNK = 4096
    val ZERO_ID = UUID(0, 0)
}
fun fail(code: Failure): Nothing = throw ProtocolException(code)
fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 255) }
fun String.unhex(): ByteArray {
    if (length % 2 != 0 || !all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) fail(Failure.invalidKey)
    return ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
fun ByteBuffer.putUUID(id: UUID): ByteBuffer = putLong(id.mostSignificantBits).putLong(id.leastSignificantBits)
fun ByteBuffer.uuid(): UUID = UUID(long, long)

data class Hello(val role: Role, val peer: UUID, val context: UUID = Wire.ZERO_ID, val nonce: ByteArray, val publicKey: ByteArray) {
    init { if (nonce.size != 32 || publicKey.size != 32) fail(Failure.invalidHandshake) }
    fun encode(): ByteArray = ByteBuffer.allocate(Wire.HELLO_SIZE).order(ByteOrder.BIG_ENDIAN)
        .put(Wire.MAGIC).put(Wire.VERSION.toByte()).put(role.wire.toByte()).putUUID(peer).putUUID(context).put(nonce).put(publicKey).array()
    companion object {
        fun decode(data: ByteArray): Hello {
            if (data.size != Wire.HELLO_SIZE || !data.copyOfRange(0, 7).contentEquals(Wire.MAGIC)) fail(Failure.invalidHandshake)
            val b = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN); b.position(7)
            if (b.get().toInt() != Wire.VERSION) fail(Failure.invalidHandshake)
            val role = Role.entries.firstOrNull { it.wire == b.get(b.position()).toInt() } ?: fail(Failure.invalidHandshake)
            b.get()
            val id = b.uuid(); val context = b.uuid(); val nonce = ByteArray(32); b.get(nonce)
            val publicKey = ByteArray(32); b.get(publicKey)
            return Hello(role, id, context, nonce, publicKey)
        }
    }
}

data class Record(val kind: RecordKind, val id: UUID = Wire.ZERO_ID, val offset: Long = 0,
                  val metadata: ByteArray = byteArrayOf(), val bytes: ByteArray = byteArrayOf(), val epoch: UUID = Wire.ZERO_ID) {
    fun encode(): ByteArray {
        if (offset < 0 || metadata.size > Wire.MAX_METADATA || Wire.HEADER_SIZE + metadata.size + bytes.size > Wire.MAX_PLAINTEXT) fail(Failure.oversizedRecord)
        return ByteBuffer.allocate(Wire.HEADER_SIZE + metadata.size + bytes.size).order(ByteOrder.BIG_ENDIAN)
            .put(kind.wire.toByte()).putUUID(epoch).putUUID(id).putLong(offset).putInt(metadata.size).put(metadata).put(bytes).array()
    }
    fun json(): JSONObject = JSONObject(metadata.toString(Charsets.UTF_8))
    companion object {
        fun decode(data: ByteArray): Record {
            if (data.size < Wire.HEADER_SIZE || data.size > Wire.MAX_PLAINTEXT) fail(Failure.invalidFrame)
            val b = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
            val value = b.get().toInt()
            val kind = RecordKind.entries.firstOrNull { it.wire == value } ?: fail(Failure.invalidFrame)
            val epoch = b.uuid(); val id = b.uuid(); val offset = b.long; val size = b.int
            if (offset < 0 || size < 0 || size > Wire.MAX_METADATA || size > b.remaining()) fail(Failure.invalidFrame)
            val metadata = ByteArray(size); b.get(metadata)
            val bytes = ByteArray(b.remaining()); b.get(bytes)
            return Record(kind, id, offset, metadata, bytes, epoch)
        }
    }
}

data class Manifest(val id: UUID, val kind: PayloadKind, val name: String, val mime: String,
                    val size: Long, val sha256: String, val origin: UUID) {
    init {
        if (size < 0 || mime.isEmpty() || mime.toByteArray().size > 255 || sha256.length != 64 || sha256.unhex().size != 32) fail(Failure.invalidManifest)
        if (name.isEmpty() || name == "." || name == ".." || name.toByteArray().size > 240 || name.any { it == '/' || it == '\\' || it == '\u0000' }) fail(Failure.invalidName)
    }
    fun json(): JSONObject = JSONObject().put("id", id.toString()).put("kind", kind.wire).put("name", name)
        .put("mime", mime).put("size", size).put("sha256", sha256.lowercase()).put("origin", origin.toString())
    companion object {
        fun decode(j: JSONObject): Manifest = Manifest(UUID.fromString(j.getString("id")),
            PayloadKind.entries.firstOrNull { it.wire == j.getInt("kind") } ?: fail(Failure.invalidManifest),
            j.getString("name"), j.getString("mime"), j.getLong("size"), j.getString("sha256"), UUID.fromString(j.getString("origin")))
    }
}
fun JSONObject.bytes(): ByteArray = toString().toByteArray(Charsets.UTF_8)
