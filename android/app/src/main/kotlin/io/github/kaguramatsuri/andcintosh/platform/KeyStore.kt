package io.github.kaguramatsuri.andcintosh.platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
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
    private val prefs = context.getSharedPreferences("andcintosh", Context.MODE_PRIVATE)
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
