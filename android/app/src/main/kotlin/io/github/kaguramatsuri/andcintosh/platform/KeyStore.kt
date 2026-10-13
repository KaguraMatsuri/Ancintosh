package io.github.kaguramatsuri.andcintosh.platform

import android.content.Context
import android.Manifest
import android.content.pm.PackageManager
import android.bluetooth.BluetoothManager
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.os.Build
import io.github.kaguramatsuri.andcintosh.core.ManagedConfiguration
import io.github.kaguramatsuri.andcintosh.core.DeviceInformation
import io.github.kaguramatsuri.andcintosh.core.DeviceKind
import io.github.kaguramatsuri.andcintosh.core.Record
import io.github.kaguramatsuri.andcintosh.core.RecordKind
import org.json.JSONObject
import io.github.kaguramatsuri.andcintosh.core.Crypto
import io.github.kaguramatsuri.andcintosh.core.Failure
import io.github.kaguramatsuri.andcintosh.core.fail
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class DeviceSettings(context: Context) {
    companion object { private val configurationLock = Any() }
    private val prefs = context.getSharedPreferences("andcintosh", Context.MODE_PRIVATE)
    private val application = context.applicationContext
    private val systemName: String get() {
        val configured = try { Settings.Global.getString(application.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } }
            catch (_: SecurityException) { null }
        if (configured != null) return configured
        if (application.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
            val bluetooth = try { application.getSystemService(BluetoothManager::class.java)?.adapter?.name }
                catch (_: SecurityException) { null }
            if (!bluetooth.isNullOrBlank()) return bluetooth
        }
        return Build.MODEL
    }
    val name: String get() = prefs.getString("pendingName", null) ?: prefs.getString("name", null) ?: systemName
    val renameRequest: UUID? get() = prefs.getString("renameRequest", null)?.let(UUID::fromString)
    val macName: String? get() = prefs.getString("macName", null)
    fun information(kind: DeviceKind): DeviceInformation = synchronized(configurationLock) {
        DeviceInformation(name, kind, wifi, renameRequest)
    }
    @android.annotation.SuppressLint("UseKtx")
    fun rejectRename(request: UUID): Unit = synchronized(configurationLock) {
        if (renameRequest == request && !prefs.edit().remove("pendingName").remove("renameRequest").commit()) fail(Failure.permissionDenied)
    }
    // Check the durable commit result before sending the request over BLE.
    @android.annotation.SuppressLint("UseKtx")
    fun rename(name: String): Unit = synchronized(configurationLock) {
        val candidate = name.ifEmpty { systemName }
        // Use the existing frame bound before creating a durable request.
        Record(RecordKind.DEVICE_INFORMATION, metadata = DeviceInformation(candidate,
            DeviceKind.phone, wifi, UUID.randomUUID()).json().toString().toByteArray()).encode()
        if (!prefs.edit().putString("pendingName", candidate).putString("renameRequest", UUID.randomUUID().toString()).commit()) fail(Failure.permissionDenied)
    }
    fun applyConfiguration(value: ManagedConfiguration, json: String): Unit = synchronized(configurationLock) {
        val editor = prefs.edit()
        if (value.revision >= prefs.getLong("configurationRevision", -1)) {
            editor.putLong("configurationRevision", value.revision).putString("macName", value.mac.name)
                .putString("configuration", json)
        }
        value.device?.let { device ->
            val storage = "device.${device.id}"
            val previous = prefs.getString(storage, null)?.let { JSONObject(it).getLong("revision") } ?: -1
            if (value.revision >= previous) {
                editor.putString(storage, json)
                if (device.id == identity) editor.putString("name", device.name)
            }
            if (device.id == identity && renameRequest != null && device.renameRequest == renameRequest) {
                editor.remove("pendingName").remove("renameRequest")
            }
        }
        if (!editor.commit()) fail(Failure.permissionDenied)
    }
    val identity: UUID by lazy {
        prefs.getString("identity", null)?.let { UUID.fromString(it) }
            ?: UUID.randomUUID().also { prefs.edit().putString("identity", it.toString()).commit() }
    }
    var wifi: Boolean
        get() = prefs.getBoolean("wifi", true)
        set(value) { prefs.edit().putBoolean("wifi", value).commit() }
    var mac: UUID?
        get() = prefs.getString("mac", null)?.let(UUID::fromString)
        set(value) { prefs.edit().putString("mac", value?.toString()).commit() }
    val hasKey: Boolean get() = prefs.contains("key") && prefs.contains("iv")
    var originalPermissionNeeded: Boolean
        get() = prefs.getBoolean("originalPermissionNeeded", false)
        set(value) { prefs.edit().putBoolean("originalPermissionNeeded", value).apply() }
    fun saveKey(hex: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val wrapped = cipher.doFinal(Crypto.key(hex))
        if (!prefs.edit().putString("key", Base64.encodeToString(wrapped, Base64.NO_WRAP))
                .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).commit()) fail(Failure.permissionDenied)
    }
    fun loadKey(): ByteArray {
        val key = prefs.getString("key", null) ?: fail(Failure.invalidKey)
        val iv = prefs.getString("iv", null) ?: fail(Failure.invalidKey)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        return cipher.doFinal(Base64.decode(key, Base64.NO_WRAP)).also { if (it.size != 32) fail(Failure.invalidKey) }
    }
    private fun wrappingKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore"); store.load(null)
        (store.getKey("Andcintosh.wrap", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder("Andcintosh.wrap", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }
}
