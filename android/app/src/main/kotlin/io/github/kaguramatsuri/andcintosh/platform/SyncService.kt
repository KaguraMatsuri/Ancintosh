package io.github.kaguramatsuri.andcintosh.platform

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.net.Uri
import android.os.Binder
import android.os.IBinder
import android.os.PowerManager
import io.github.kaguramatsuri.andcintosh.R
import io.github.kaguramatsuri.andcintosh.core.*
import io.github.kaguramatsuri.andcintosh.ui.MainActivity
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class FileTransfer(val id: UUID, val name: String, val size: Long, val bytes: Long = 0, val failure: Failure? = null)
data class SyncStatus(val running: Boolean = true, val ready: Boolean = false, val peer: UUID? = null,
                      val preparing: Boolean = false, val failure: Failure? = null, val transfers: List<FileTransfer> = emptyList(), val configurationGeneration: Long = 0)

class SyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val preparation = Mutex()
    private val deviceReporting = Mutex()
    private var startup: Job? = null
    private lateinit var peripheral: BLEPeripheral
    private lateinit var tcp: TCPClient
    private lateinit var settings: DeviceSettings
    lateinit var session: SessionController; private set
    lateinit var files: FileAccess; private set
    private val mutableStatus = MutableStateFlow(SyncStatus())
    val status = mutableStatus.asStateFlow()
    val events = MutableSharedFlow<SyncEvent>(extraBufferCapacity = 32)
    inner class LocalBinder : Binder() { val service get() = this@SyncService }
    private val binder = LocalBinder()
    private val radio = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!::peripheral.isInitialized || !status.value.running) return
            scope.launch {
                if (!status.value.running) return@launch
                try {
                    if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) { refreshPowerState(); return@launch }
                    when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                        BluetoothAdapter.STATE_OFF -> { peripheral.stop()?.join(); session.disconnect() }
                        BluetoothAdapter.STATE_ON -> peripheral.start()
                    }
                } catch (error: Exception) { report(error) }
            }
        }
    }
    override fun onCreate() {
        super.onCreate()
        foregroundNotification()
        settings = DeviceSettings(this)
        val store = TransferStore(File(filesDir, "state"), stagedPublish = { file, manifest, check, commit ->
            FileAccess.publish(this, file, manifest, commit, check)
        }) { file, manifest -> FileAccess.publish(this, file, manifest) }
        files = FileAccess(this, store, settings.identity)
        session = SessionController(settings.identity, scope, store) { event ->
            if (event is SyncEvent.Connected && session.connected != event.peer) return@SessionController
            if (event is SyncEvent.Disconnected && session.connected != null) return@SessionController
            if (event is SyncEvent.Delivered) files.apply(event.result)
            if (event is SyncEvent.Disconnected && ::peripheral.isInitialized) peripheral.sessionDisconnected()
            if (event is SyncEvent.Offer) scope.launch { tcp.connect(event) }
            if (event is SyncEvent.Connected || event is SyncEvent.ConfigurationReady) reportDevice()
            if (event is SyncEvent.Configuration) settings.applyConfiguration(event.value, event.json)
            if (event is SyncEvent.ConfigurationRejected) settings.rejectRename(event.request)
            mutableStatus.update { current ->
                when (event) {
                    is SyncEvent.Connected -> current.copy(peer = event.peer, failure = null)
                    is SyncEvent.Disconnected -> current.copy(peer = null)
                    is SyncEvent.Progress -> current.copy(transfers = current.transfers.map { if (it.id == event.id) it.copy(bytes = event.offset) else it })
                    is SyncEvent.Failed -> current.copy(failure = event.code, transfers = current.transfers.map { if (it.id == event.id) it.copy(failure = event.code) else it })
                    is SyncEvent.Completed -> current.copy(transfers = current.transfers.filterNot { it.id == event.id })
                    is SyncEvent.Configuration -> current.copy(configurationGeneration = current.configurationGeneration + 1)
                    is SyncEvent.ConfigurationRejected -> current.copy(failure = event.code, configurationGeneration = current.configurationGeneration + 1)
                    else -> current
                }
            }
            events.emit(event)
        }
        tcp = TCPClient(this, scope, session)
        peripheral = BLEPeripheral(this, scope, settings, session) { code ->
            mutableStatus.update { it.copy(failure = code) }
            events.tryEmit(SyncEvent.Failed(Wire.ZERO_ID, code))
        }
        registerReceiver(radio, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED).apply {
            addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED); addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        }, Context.RECEIVER_EXPORTED)
        refreshPowerState()
        startup = scope.launch {
            try {
                session.restore()
                val restored = session.outgoingFiles().map { FileTransfer(it.snapshot.manifest.id, it.snapshot.manifest.name, it.snapshot.manifest.size, it.offset, it.failed) }
                mutableStatus.update { it.copy(transfers = restored) }
                startRadio()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { report(error) }
        }
    }
    suspend fun reportDevice() = deviceReporting.withLock {
        val kind = if (resources.configuration.smallestScreenWidthDp >= 600) DeviceKind.pad else DeviceKind.phone
        session.reportDevice(settings.information(kind))
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        scope.launch {
            try { reportDevice() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { report(error) }
        }
    }
    private fun foregroundNotification() {
        val channel = NotificationChannel("andcintosh.connection", getString(R.string.notification_channel), NotificationManager.IMPORTANCE_LOW)
        channel.setSound(null, null)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val content = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(1, Notification.Builder(this, channel.id).setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(getString(R.string.app_name)).setContentText(getString(R.string.notification_body))
            .setContentIntent(content).setOngoing(true).setOnlyAlertOnce(true).build())
    }
    private fun refreshPowerState() {
        val power = getSystemService(PowerManager::class.java)
        peripheral.powerState(power.isInteractive, power.isPowerSaveMode || power.isDeviceIdleMode)
    }
    private suspend fun startRadio() {
        session.wifi(DeviceSettings(this).wifi); tcp.start(); peripheral.start()
        mutableStatus.update { it.copy(running = true, ready = true, failure = null) }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!status.value.running) {
            foregroundNotification()
            mutableStatus.update { it.copy(running = true, ready = false) }
            startup = scope.launch {
                try { startRadio() }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) { report(error) }
            }
        }
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?): IBinder = binder
    suspend fun saveKey(hex: String) {
        Crypto.key(hex)
        peripheral.stop()?.join(); session.disconnect(true)
        DeviceSettings(this).saveKey(hex)
        peripheral.start()
        mutableStatus.update { it.copy(ready = true, failure = null) }
    }
    suspend fun wifi(enabled: Boolean) { DeviceSettings(this).wifi = enabled; session.wifi(enabled) }
    suspend fun enqueue(snapshot: Snapshot) {
        if (!status.value.ready) fail(Failure.peerUnavailable)
        session.enqueue(snapshot)
    }
    fun sendFiles(uris: List<Uri>) {
        scope.launch {
            preparation.withLock {
                mutableStatus.update { it.copy(preparing = true, failure = null) }
                try {
                    if (!status.value.ready || session.connected == null) fail(Failure.peerUnavailable)
                    for (uri in uris) {
                        val snapshot = files.snapshot(uri, PayloadKind.FILE)
                        val row = FileTransfer(snapshot.manifest.id, snapshot.manifest.name, snapshot.manifest.size)
                        mutableStatus.update { it.copy(transfers = it.transfers + row) }
                        try { session.enqueue(snapshot) }
                        catch (error: Exception) {
                            mutableStatus.update { it.copy(transfers = it.transfers.filterNot { row -> row.id == snapshot.manifest.id }) }
                            snapshot.file.delete(); throw error
                        }
                    }
                } catch (error: Exception) { report(error) }
                finally { mutableStatus.update { it.copy(preparing = false) } }
            }
        }
    }
    suspend fun retry(id: UUID) {
        mutableStatus.update { it.copy(failure = null, transfers = it.transfers.map { row -> if (row.id == id) row.copy(failure = null) else row }) }
        session.retry(id)
    }
    suspend fun cancel(id: UUID) {
        session.cancel(id)
        mutableStatus.update { it.copy(transfers = it.transfers.filterNot { row -> row.id == id }) }
    }
    fun cancelAsync(id: UUID) { scope.launch { runCatching { cancel(id) } } }
    suspend fun stopSync() {
        startup?.cancelAndJoin()
        mutableStatus.update { it.copy(running = false, ready = false) }
        peripheral.stop()?.join(); session.disconnect(true); tcp.stop()
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    private fun report(error: Exception) {
        mutableStatus.update { it.copy(failure = (error as? ProtocolException)?.code ?: if (error is SecurityException) Failure.permissionDenied else Failure.sourceUnavailable) }
    }
    override fun onDestroy() {
        if (::peripheral.isInitialized) peripheral.stop()
        if (::tcp.isInitialized) tcp.stop()
        runCatching { unregisterReceiver(radio) }
        scope.cancel(); super.onDestroy()
    }
}
