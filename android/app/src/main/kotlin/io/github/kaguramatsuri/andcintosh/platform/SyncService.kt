package io.github.kaguramatsuri.andcintosh.platform

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.Context
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.bluetooth.BluetoothAdapter
import android.os.Binder
import android.os.IBinder
import io.github.kaguramatsuri.andcintosh.core.*
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import org.json.JSONObject

class SyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var peripheral: BLEPeripheral
    private lateinit var tcp: TCPClient
    lateinit var session: SessionController; private set
    lateinit var files: FileAccess; private set
    val events = MutableSharedFlow<SyncEvent>(extraBufferCapacity = 32)
    inner class LocalBinder : Binder() { val service get() = this@SyncService }
    private val binder = LocalBinder()
    private val radio = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!::peripheral.isInitialized) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_OFF -> scope.launch { session.disconnect(); peripheral.stop() }
                BluetoothAdapter.STATE_ON -> scope.launch { runCatching { peripheral.start() } }
            }
        }
    }
    override fun onCreate() {
        super.onCreate()
        val copy = JSONObject(assets.open("copy.json").bufferedReader().use { it.readText() })
        val channel = NotificationChannel("andcintosh.connection", copy.getString("notification_channel"), NotificationManager.IMPORTANCE_LOW)
        channel.setSound(null, null)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        startForeground(1, Notification.Builder(this, channel.id).setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Andcintosh").setContentText(copy.getString("notification_body")).setOngoing(true).build())
        val settings = DeviceSettings(this)
        val store = TransferStore(File(filesDir, "state")) { file, manifest -> FileAccess.publish(this, file, manifest) }
        files = FileAccess(this, store, settings.identity)
        session = SessionController(settings.identity, scope, store) { event ->
            if (event is SyncEvent.Delivered) files.apply(event.result)
            if (event is SyncEvent.Offer) scope.launch { tcp.connect(event) }
            events.tryEmit(event)
        }
        tcp = TCPClient(this, scope, session)
        peripheral = BLEPeripheral(this, scope, settings, session) { events.tryEmit(SyncEvent.Failed(Wire.ZERO_ID, it)) }
        tcp.start()
        registerReceiver(radio, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), Context.RECEIVER_EXPORTED)
        scope.launch { session.restore(); session.wifi(settings.wifi); peripheral.start() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY
    override fun onBind(intent: Intent?): IBinder = binder
    suspend fun stopSync() { session.disconnect(true); stopSelf() }
    override fun onDestroy() {
        if (::peripheral.isInitialized) peripheral.stop()
        if (::tcp.isInitialized) tcp.stop()
        runCatching { unregisterReceiver(radio) }
        scope.cancel(); super.onDestroy()
    }
}
