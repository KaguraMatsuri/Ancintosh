package io.github.kaguramatsuri.ancintosh.platform

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
import io.github.kaguramatsuri.ancintosh.R
import io.github.kaguramatsuri.ancintosh.core.*
import io.github.kaguramatsuri.ancintosh.ui.MainActivity
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class FileTransfer(val id: UUID, val name: String, val size: Long, val bytes: Long = 0, val failure: Failure? = null, val sending: Boolean = true)
data class SyncStatus(val running: Boolean = true, val ready: Boolean = false, val peer: UUID? = null,
                      val preparing: Boolean = false, val failure: Failure? = null, val transfers: List<FileTransfer> = emptyList(), val configurationGeneration: Long = 0)

class SyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycle = Mutex()
    private var restored = false
    private val failures = linkedMapOf<String, Failure>()
    private val operationSources = java.util.concurrent.ConcurrentHashMap<UUID, String>()
    private fun operationSource(id: UUID) = operationSources[id] ?: ("transfer/" + id)
    @Synchronized private fun recordFailure(source: String, code: Failure) {
        failures.remove(source); failures[source] = code
        mutableStatus.update { it.copy(failure = failures.values.lastOrNull()) }
    }
    @Synchronized private fun clearFailure(source: String) {
        if (failures.remove(source) != null) mutableStatus.update { it.copy(failure = failures.values.lastOrNull()) }
    }
    @Volatile private var generation = 0L
    private val fileJobs = java.util.concurrent.ConcurrentHashMap.newKeySet<Job>()
    private val preparation = Mutex()
    private val deviceReporting = Mutex()
    private val notificationReporting = Mutex()
    private var startup: Job? = null
    private lateinit var peripheral: BLEPeripheral
    private lateinit var tcp: TCPClient
    private lateinit var settings: DeviceSettings
    private lateinit var notificationMirror: NotificationMirror
    private val notificationInput = Channel<NotificationEnvelope>(128, BufferOverflow.DROP_OLDEST)
    private var notificationPolicy = false
    lateinit var session: SessionController; private set
    lateinit var files: FileAccess; private set
    private val mutableStatus = MutableStateFlow(SyncStatus(running = false))
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
        notificationMirror = NotificationMirror(this)
        val store = TransferStore(File(filesDir, "state"), stagedPublish = { file, manifest, check, commit ->
            FileAccess.publish(this, file, manifest, commit, check)
        }) { file, manifest -> FileAccess.publish(this, file, manifest) }
        files = FileAccess(this, store, settings.identity)
        session = SessionController(settings.identity, scope, store) { event ->
            if (event is SyncEvent.Connected && session.connected != event.peer) return@SessionController
            if (event is SyncEvent.Disconnected && session.connected != null) return@SessionController
            if (event is SyncEvent.Delivered) files.apply(event.result)
            if (event is SyncEvent.Disconnected && ::peripheral.isInitialized) { peripheral.sessionDisconnected(); operationSources.clear(); refreshNotificationAccess() }
            if (event is SyncEvent.Offer) scope.launch { tcp.connect(event) }
            if (event is SyncEvent.Connected || event is SyncEvent.ConfigurationReady) reportDevice()
            if (event is SyncEvent.Connected || event is SyncEvent.Disconnected || event is SyncEvent.TransportChanged) tcp.sessionChanged()
            if (event is SyncEvent.Connected) clearFailure("connection")
            if (event is SyncEvent.TransferStarted && event.manifest.kind != PayloadKind.FILE) {
                operationSources[event.manifest.id] = if (event.sending) "clipboard/out" else "clipboard/in"
            }
            if (event is SyncEvent.Failed) {
                recordFailure(if (event.id == Wire.ZERO_ID) "connection" else operationSource(event.id), event.code)
                operationSources.remove(event.id)
            }
            if (event is SyncEvent.Progress && event.offset > 0) clearFailure(operationSource(event.id))
            if (event is SyncEvent.Completed) { clearFailure(operationSource(event.id)); operationSources.remove(event.id) }
            if (event is SyncEvent.TransferStopped) { clearFailure(operationSource(event.id)); operationSources.remove(event.id) }
            if (event is SyncEvent.Delivered) clearFailure(operationSource(event.result.manifest.id))
            if (event is SyncEvent.Configuration) {
                val accepted = settings.renameRequest != null && event.value.device?.id == settings.identity && event.value.device?.renameRequest == settings.renameRequest
                settings.applyConfiguration(event.value, event.json)
                if (accepted) clearFailure("configuration")
                refreshNotificationAccess()
            }
            if (event is SyncEvent.Notification) {
                try { notificationMirror.apply(event.peer, event.value) }
                catch (_: SecurityException) { recordFailure("notification", Failure.permissionDenied); refreshNotificationAccess() }
            }
            if (event is SyncEvent.ConfigurationRejected) { settings.rejectRename(event.request); recordFailure("configuration",event.code) }
            mutableStatus.update { current ->
                when (event) {
                    is SyncEvent.Connected -> current.copy(peer = event.peer)
                    is SyncEvent.Disconnected -> current.copy(peer = null)
                    is SyncEvent.Progress -> current.copy(transfers = current.transfers.map { if (it.id == event.id) it.copy(bytes = event.offset, failure = if (event.offset > 0) null else it.failure) else it })
                    is SyncEvent.Failed -> current.copy(transfers = current.transfers.map { if (it.id == event.id) it.copy(failure = event.code) else it })
                    is SyncEvent.Completed -> current.copy(transfers = current.transfers.filterNot { it.id == event.id })
                    is SyncEvent.TransferStopped -> current.copy(transfers = current.transfers.filterNot { it.id == event.id })
                    is SyncEvent.Delivered -> current.copy(transfers = current.transfers.filterNot { it.id == event.result.manifest.id })
                    is SyncEvent.TransferStarted -> if (event.manifest.kind != PayloadKind.FILE || current.transfers.any { it.id == event.manifest.id }) current
                        else current.copy(transfers = current.transfers + FileTransfer(event.manifest.id, event.manifest.name, event.manifest.size, sending = event.sending))
                    is SyncEvent.Configuration -> current.copy(configurationGeneration = current.configurationGeneration + 1)
                    is SyncEvent.ConfigurationRejected -> current.copy(configurationGeneration = current.configurationGeneration + 1)
                    else -> current
                }
            }
            if (event !is SyncEvent.Notification) events.emit(event)
        }
        scope.launch { for (value in notificationInput) if (NotificationBridge.target() === value.target) session.enqueueNotification(value.value) }
        scope.launch { NotificationBridge.changes.collect { refreshNotificationAccess() } }
        tcp = TCPClient(this, scope, session)
        peripheral = BLEPeripheral(this, scope, settings, session) { code ->
            recordFailure("connection", code)
            events.tryEmit(SyncEvent.Failed(Wire.ZERO_ID, code))
        }
        registerReceiver(radio, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED).apply {
            addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED); addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        }, Context.RECEIVER_EXPORTED)
        refreshPowerState()

    }
    suspend fun reportDevice() = deviceReporting.withLock {
        val kind = if (resources.configuration.smallestScreenWidthDp >= 600) DeviceKind.pad else DeviceKind.phone
        refreshNotificationAccess()
        session.reportDevice(settings.information(kind).copy(notificationAccess = currentNotificationAccess()))
    }
    private fun currentNotificationAccess(): NotificationAccess = NotificationAccess(
        capture = NotificationBridge.connected && NotificationBridge.allowed(this), display = notificationMirror.permitted)
    suspend fun refreshNotificationAccess(): Unit = notificationReporting.withLock {
        val access = currentNotificationAccess()
        if (access.capture && access.display) clearFailure("notification")
        val enabled = status.value.running && settings.notifications && session.connected != null
        session.notificationAccess(access)
        if (notificationPolicy != enabled || session.sharesNotifications != enabled) {
            notificationPolicy = enabled
            session.notificationPolicy(enabled)
            if (!enabled) settings.mac?.let(notificationMirror::clear)
        }
        NotificationBridge.bind(if (enabled && access.capture) notificationInput else null)
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
        currentCoroutineContext().ensureActive()
        session.wifi(DeviceSettings(this).wifi); tcp.start(); peripheral.start()
        mutableStatus.update { it.copy(running = true, ready = true) }
        clearFailure("connection")
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!status.value.running) {
            foregroundNotification()
            mutableStatus.update { it.copy(running = true, ready = false) }
            val cycle = ++generation
            startup = scope.launch {
                lifecycle.withLock {
                    try {
                        if (cycle != generation) return@withLock
                        if (!restored) {
                            session.restore(); restored = true
                            val restoredFiles = session.outgoingFiles().map {
                                FileTransfer(it.snapshot.manifest.id, it.snapshot.manifest.name, it.snapshot.manifest.size, it.offset, it.failed)
                            }
                            mutableStatus.update { it.copy(transfers = restoredFiles) }
                        }
                        ensureActive()
                        if (cycle == generation) startRadio()
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (error: Exception) { report(error) }
                }
            }
        }
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?): IBinder = binder
    suspend fun saveKey(hex: String) {
        Crypto.key(hex)
        lifecycle.withLock {
            peripheral.prepareStop()
            session.closeGracefully()
            peripheral.stop()?.join()
            DeviceSettings(this).saveKey(hex)
            peripheral.start()
            mutableStatus.update { it.copy(ready = true) }
            clearFailure("connection")
        }
    }
    suspend fun wifi(enabled: Boolean) { DeviceSettings(this).wifi = enabled; session.wifi(enabled); tcp.sessionChanged() }
    suspend fun enqueue(snapshot: Snapshot) {
        if (!status.value.ready) fail(Failure.peerUnavailable)
        if (snapshot.manifest.kind != PayloadKind.FILE) operationSources[snapshot.manifest.id] = "clipboard/out"
        try { session.enqueue(snapshot) }
        catch (error: Exception) { operationSources.remove(snapshot.manifest.id); throw error }
    }
    fun sendFiles(uris: List<Uri>) {
        val cycle = generation
        val job = scope.launch(start = CoroutineStart.LAZY) {
            preparation.withLock {
                mutableStatus.update { it.copy(preparing = true) }
                try {
                    if (!status.value.ready || session.connected == null) fail(Failure.peerUnavailable)
                    for (uri in uris) {
                        val context = currentCoroutineContext()
                        val snapshot = files.snapshot(uri, PayloadKind.FILE) { context.ensureActive() }
                        if (cycle != generation || !status.value.ready || session.connected == null) {
                            files.release(snapshot); throw CancellationException()
                        }
                        val row = FileTransfer(snapshot.manifest.id, snapshot.manifest.name, snapshot.manifest.size)
                        mutableStatus.update { it.copy(transfers = it.transfers + row) }
                        try { session.enqueue(snapshot); clearFailure("files") }
                        catch (error: Exception) {
                            if (session.outgoingFiles().any { it.snapshot.manifest.id == snapshot.manifest.id }) {
                                val code = (error as? ProtocolException)?.code ?: Failure.sourceUnavailable
                                mutableStatus.update { it.copy(transfers = it.transfers.map { row -> if (row.id == snapshot.manifest.id) row.copy(failure = code) else row }) }
                            } else {
                                mutableStatus.update { it.copy(transfers = it.transfers.filterNot { row -> row.id == snapshot.manifest.id }) }
                                files.release(snapshot)
                            }
                            throw error
                        }
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) { report(error, "files") }
                finally { mutableStatus.update { it.copy(preparing = false) } }
            }
        }
        fileJobs.add(job); job.invokeOnCompletion { fileJobs.remove(job) }; job.start()
    }
    suspend fun retry(id: UUID) {
        mutableStatus.update { it.copy(transfers = it.transfers.map { row -> if (row.id == id) row.copy(failure = null) else row }) }
        session.retry(id)
    }
    suspend fun cancel(id: UUID) {
        session.cancel(id)
        mutableStatus.update { it.copy(transfers = it.transfers.filterNot { row -> row.id == id }) }
    }
    fun cancelAsync(id: UUID) { scope.launch { runCatching { cancel(id) } } }
    suspend fun stopSync(): Unit = withContext(NonCancellable) {
        generation++
        mutableStatus.update { it.copy(running = false, ready = false) }
        if (NotificationBridge.target()?.channel === notificationInput) NotificationBridge.bind(null)
        startup?.cancelAndJoin(); startup = null
        val preparing = fileJobs.toList()
        preparing.forEach { it.cancel() }; preparing.joinAll()
        lifecycle.withLock {
            peripheral.prepareStop()
            try { session.closeGracefully() }
            catch (error: Exception) { report(error) }
            finally { peripheral.stop()?.join(); tcp.stop(); session.abortChannels() }
        }
        mutableStatus.update { it.copy(peer = null) }
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    private fun report(error: Exception, source: String = "connection") {
        recordFailure(source, (error as? ProtocolException)?.code ?: if (error is SecurityException) Failure.permissionDenied else Failure.sourceUnavailable)
    }
    override fun onDestroy() {
        generation++
        startup?.cancel(); fileJobs.forEach { it.cancel() }
        if (NotificationBridge.target()?.channel === notificationInput) NotificationBridge.bind(null)
        notificationInput.close()
        if (::peripheral.isInitialized) peripheral.stop()
        if (::tcp.isInitialized) tcp.stop()
        if (::session.isInitialized) session.abortChannels()
        runCatching { unregisterReceiver(radio) }
        scope.cancel(); super.onDestroy()
    }
}
