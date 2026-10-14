package io.github.kaguramatsuri.ancintosh.platform

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.github.kaguramatsuri.ancintosh.core.NotificationMessage
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

internal data class NotificationTarget(val channel: Channel<NotificationEnvelope>, val id: UUID = UUID.randomUUID())
internal data class NotificationEnvelope(val target: NotificationTarget, val value: NotificationMessage)
internal object NotificationBridge {
    @Volatile var connected = false
    @Volatile private var destination: NotificationTarget? = null
    val changes = MutableStateFlow(0L)
    fun changed() { changes.update { it + 1 } }
    @Synchronized fun bind(channel: Channel<NotificationEnvelope>?) {
        if (destination?.channel === channel) return
        destination = channel?.let { NotificationTarget(it) }
    }
    fun target(): NotificationTarget? = destination
    fun allowed(context: Context): Boolean = context.getSystemService(NotificationManager::class.java)
        .isNotificationListenerAccessGranted(ComponentName(context, NotificationListener::class.java))
}

class NotificationListener : NotificationListenerService() {
    private val identifiers = linkedMapOf<String, UUID>()
    private data class Input(val target: NotificationTarget, val id: UUID, val application: String, val title: String, val body: String, val removed: Boolean)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inputs = Channel<Input>(128, BufferOverflow.DROP_OLDEST)
    override fun onCreate() {
        super.onCreate()
        scope.launch {
            val names = linkedMapOf<String, String>()
            for (input in inputs) {
                if (NotificationBridge.target() !== input.target) continue
                val value = if (input.removed) NotificationMessage(input.id, NotificationMessage.Action.remove)
                else {
                    val name = names[input.application] ?: try {
                        packageManager.getApplicationLabel(packageManager.getApplicationInfo(input.application, 0)).toString()
                    } catch (_: android.content.pm.PackageManager.NameNotFoundException) { input.application }
                    if (names.size == 128) names.remove(names.keys.first())
                    names[input.application] = name
                    NotificationMessage.bounded(input.id, name, input.title, input.body)
                }
                if (NotificationBridge.target() === input.target) input.target.channel.trySend(NotificationEnvelope(input.target, value))
            }
        }
    }
    override fun onListenerConnected() { NotificationBridge.connected = true; NotificationBridge.changed() }
    override fun onListenerDisconnected() { NotificationBridge.connected = false; identifiers.clear(); NotificationBridge.changed() }
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val target = NotificationBridge.target() ?: return
        if (sbn.packageName == packageName || sbn.notification.flags and (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_GROUP_SUMMARY) != 0) return
        val id = identifiers[sbn.key] ?: UUID.randomUUID().also {
            if (identifiers.size == 128) identifiers.remove(identifiers.keys.first())
            identifiers[sbn.key] = it
        }
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && body.isEmpty()) return
        inputs.trySend(Input(target, id, sbn.packageName, title, body, false))
    }
    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val id = identifiers.remove(sbn.key) ?: return
        val target = NotificationBridge.target() ?: return
        inputs.trySend(Input(target, id, "", "", "", true))
    }
    override fun onDestroy() {
        NotificationBridge.connected = false; identifiers.clear(); NotificationBridge.changed()
        inputs.close(); scope.cancel(); super.onDestroy()
    }
}
