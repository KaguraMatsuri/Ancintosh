package io.github.kaguramatsuri.ancintosh.core

import java.util.UUID
import org.json.JSONObject

enum class DeviceKind { mac, phone, pad }
data class DeviceInformation(val name: String, val kind: DeviceKind, val wifi: Boolean, val renameRequest: UUID? = null) {
    fun json(): JSONObject = JSONObject().put("name", name).put("kind", kind.name).put("wifi", wifi)
        .apply { renameRequest?.let { put("renameRequest", it.toString()) } }
}
data class ManagedDevice(val id: UUID, val name: String, val kind: DeviceKind, val wifi: Boolean,
                         val priority: Int, val renameRequest: UUID?) {
    companion object {
        fun decode(j: JSONObject): ManagedDevice {
            val priority = j.getInt("priority"); if (priority < 0) fail(Failure.invalidFrame)
            return ManagedDevice(UUID.fromString(j.getString("id")), j.getString("name"), DeviceKind.valueOf(j.getString("kind")),
                j.getBoolean("wifi"), priority, j.optionalUUID("renameRequest"))
        }
    }
}
data class ManagedConfiguration(val revision: Long, val mac: ManagedDevice, val device: ManagedDevice?,
                                val primary: UUID?, val lockEnabled: Boolean, val lockDelaySeconds: Int) {
    companion object {
        fun decode(j: JSONObject): ManagedConfiguration {
            val revision = j.getLong("revision"); val delay = j.getInt("lockDelaySeconds")
            val mac = ManagedDevice.decode(j.getJSONObject("mac"))
            if (revision < 0 || delay !in 1..3600 || mac.kind != DeviceKind.mac) fail(Failure.invalidFrame)
            val device = if (j.isNull("device")) null else ManagedDevice.decode(j.getJSONObject("device"))
            if (device?.kind == DeviceKind.mac) fail(Failure.invalidFrame)
            return ManagedConfiguration(revision, mac, device, j.optionalUUID("primary"), j.getBoolean("lockEnabled"), delay)
        }
    }
}
private fun JSONObject.optionalUUID(key: String): UUID? = if (isNull(key)) null else UUID.fromString(getString(key))
