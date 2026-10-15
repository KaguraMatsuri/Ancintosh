package io.github.kaguramatsuri.ancintosh.core

import java.text.BreakIterator
import java.util.Locale
import java.util.UUID
import org.json.JSONObject

data class NotificationAccess(val capture: Boolean = false, val display: Boolean = false, val enabled: Boolean? = null) {
    fun json(): JSONObject = JSONObject().put("capture", capture).put("display", display).apply { enabled?.let { put("enabled", it) } }
    companion object {
        fun decode(j: JSONObject): NotificationAccess = NotificationAccess(j.getBoolean("capture"), j.getBoolean("display"), if (j.isNull("enabled")) null else j.getBoolean("enabled"))
    }
}
data class NotificationMessage(val id: UUID, val action: Action, val application: String = "", val title: String = "", val body: String = "") {
    enum class Action { upsert, remove }
    fun json(): JSONObject = JSONObject().put("id", id.toString()).put("action", action.name)
        .put("application", application).put("title", title).put("body", body)
    fun validated(): NotificationMessage {
        if (id == Wire.ZERO_ID || (action == Action.upsert && application.isEmpty()) || json().bytes().size > Wire.MAX_METADATA) fail(Failure.invalidFrame)
        return this
    }
    companion object {
        fun sourceID(device: UUID, source: String): UUID {
            val bytes = Crypto.digest((device.toString() + "/" + source).toByteArray(Charsets.UTF_8)).unhex().copyOf(16)
            bytes[6] = ((bytes[6].toInt() and 15) or 128).toByte()
            bytes[8] = ((bytes[8].toInt() and 63) or 128).toByte()
            val buffer = java.nio.ByteBuffer.wrap(bytes)
            return UUID(buffer.long, buffer.long)
        }
        fun decode(j: JSONObject): NotificationMessage = NotificationMessage(UUID.fromString(j.getString("id")), Action.valueOf(j.getString("action")),
            j.getString("application"), j.getString("title"), j.getString("body")).validated()
        fun bounded(id: UUID, application: String, title: String, body: String): NotificationMessage {
            val app = prefix(application, 128); val heading = prefix(title, 256); val text = prefix(body, Wire.MAX_METADATA)
            val iterator = BreakIterator.getCharacterInstance(Locale.ROOT); iterator.setText(text)
            val boundaries = mutableListOf(0)
            var next = iterator.next()
            while (next != BreakIterator.DONE) { boundaries.add(next); next = iterator.next() }
            var low = 0; var high = boundaries.lastIndex
            while (low < high) {
                val middle = (low + high + 1) / 2
                if (NotificationMessage(id, Action.upsert, app, heading, text.substring(0, boundaries[middle])).json().bytes().size <= Wire.MAX_METADATA) low = middle else high = middle - 1
            }
            return NotificationMessage(id, Action.upsert, app, heading, text.substring(0, boundaries[low])).validated()
        }
        private fun prefix(value: String, count: Int): String {
            val iterator = BreakIterator.getCharacterInstance(Locale.ROOT); iterator.setText(value)
            var end = 0
            repeat(count) {
                val next = iterator.next(); if (next == BreakIterator.DONE) return value
                end = next
            }
            return value.substring(0, end)
        }
    }
}
class NotificationQueue {
    companion object { const val CAPACITY = 128 }
    private val values = linkedMapOf<UUID, NotificationMessage>()
    val size: Int get() = values.size
    fun append(value: NotificationMessage) {
        if (!values.containsKey(value.id) && values.size == CAPACITY) values.remove(values.keys.first())
        values[value.id] = value
    }
    fun pop(): NotificationMessage? = values.keys.firstOrNull()?.let { values.remove(it) }
    fun clear() = values.clear()
}
