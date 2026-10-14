package io.github.kaguramatsuri.ancintosh.ui

import android.app.Application
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.kaguramatsuri.ancintosh.core.Crypto
import io.github.kaguramatsuri.ancintosh.core.Failure
import io.github.kaguramatsuri.ancintosh.core.fail
import io.github.kaguramatsuri.ancintosh.platform.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

class SettingsViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application
    private val settings = DeviceSettings(context)
    val identity: String = settings.identity.toString()
    var mac by mutableStateOf(settings.mac?.toString()); private set
    var wifi by mutableStateOf(settings.wifi); private set
    var name by mutableStateOf(settings.name)
    var macName by mutableStateOf(settings.macName); private set
    private var previousName = settings.name
    var key by mutableStateOf("")
    var hasKey by mutableStateOf(settings.hasKey); private set
    var originalPermissionNeeded by mutableStateOf(settings.originalPermissionNeeded); private set
    var busy by mutableStateOf(false); private set
    var error by mutableStateOf<Int?>(null)
    private val mutableStatus = MutableStateFlow(SyncStatus(running = false))
    val status = mutableStatus.asStateFlow()
    private var binding: ServiceBinding? = null
    private var service: SyncService? = null
    private var observer: Job? = null

    fun refresh() {
        refreshNames()
        originalPermissionNeeded = settings.originalPermissionNeeded
        hasKey = settings.hasKey; mac = settings.mac?.toString()
        service?.let { running -> viewModelScope.launch { running.refreshNotificationAccess(); running.reportDevice() } }
        if (service == null && !busy) viewModelScope.launch { attach(false) }
    }
    private suspend fun attach(reportFailure: Boolean) {
        observer?.cancel(); binding?.close()
        val handle = ServiceBinding(context) {
            service = null; mutableStatus.value = SyncStatus(running = false)
        }
        binding = handle
        try {
            val connected = handle.connect(); service = connected
            observer = viewModelScope.launch {
                connected.status.collect {
                    refreshNames()
                    mutableStatus.value = it; mac = settings.mac?.toString()
                    originalPermissionNeeded = settings.originalPermissionNeeded
                }
            }
        } catch (error: Exception) {
            handle.close(); binding = null
            if (reportFailure) this.error = failureText(error)
        }
    }
    private fun refreshNames() {
        if (name == previousName) name = settings.name
        previousName = settings.name; macName = settings.macName
    }
    fun saveName() = operation {
        val candidate = name
        withContext(Dispatchers.IO) { settings.rename(candidate); service?.reportDevice() }
        name = settings.name; previousName = name
    }
    fun cancelName() { name = settings.name; previousName = settings.name }
    fun start() = operation {
        withContext(Dispatchers.IO) { settings.loadKey() }
        ContextCompat.startForegroundService(context, Intent(context, SyncService::class.java))
        attach(true)
    }
    fun stop() = operation {
        withContext(Dispatchers.IO) { service?.stopSync() }
        observer?.cancel(); binding?.close(); binding = null; service = null
        mutableStatus.value = SyncStatus(running = false)
    }
    fun save() = operation {
        val candidate = key
        withContext(Dispatchers.IO) {
            if (candidate.isEmpty()) { if (!settings.hasKey) fail(Failure.invalidKey) }
            else {
                Crypto.key(candidate)
                val running = service
                if (running != null && running.status.value.running) running.saveKey(candidate) else settings.saveKey(candidate)
            }
        }
        key = ""; hasKey = settings.hasKey
    }
    fun cancelEdit() { key = "" }
    fun wifi(enabled: Boolean) = operation {
        withContext(Dispatchers.IO) {
            settings.wifi = enabled
            service?.wifi(enabled)
        }
        wifi = settings.wifi
    }
    fun sendFiles(uris: List<Uri>) { service?.sendFiles(uris) }
    fun retry(id: UUID) = operation { withContext(Dispatchers.IO) { service?.retry(id) } }
    fun cancel(id: UUID) = operation { withContext(Dispatchers.IO) { service?.cancel(id) } }
    fun originalPermissionGranted() { settings.originalPermissionNeeded = false; originalPermissionNeeded = false }
    private fun operation(block: suspend () -> Unit) {
        if (busy) return
        busy = true; error = null
        viewModelScope.launch {
            try { block() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { this@SettingsViewModel.error = failureText(error) }
            finally { busy = false }
        }
    }
    override fun onCleared() { key = ""; observer?.cancel(); binding?.close(); service = null }
}
