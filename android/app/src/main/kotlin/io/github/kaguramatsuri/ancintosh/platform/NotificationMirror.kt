package io.github.kaguramatsuri.ancintosh.platform

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import io.github.kaguramatsuri.ancintosh.R
import io.github.kaguramatsuri.ancintosh.core.NotificationMessage
import java.util.UUID

class NotificationMirror(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    init {
        val channel = NotificationChannel(CHANNEL, context.getString(R.string.share_notifications), NotificationManager.IMPORTANCE_LOW)
        channel.setSound(null, null); channel.enableVibration(false)
        manager.createNotificationChannel(channel)
    }
    val permitted: Boolean get() = context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED &&
        manager.areNotificationsEnabled() && manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    fun apply(peer: UUID, value: NotificationMessage) {
        val tag = prefix(peer) + value.id
        if (value.action == NotificationMessage.Action.remove) { manager.cancel(tag, 2); return }
        if (!permitted) return
        val notification = Notification.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(value.title).setSubText(value.application).setContentText(value.body)
            .setStyle(Notification.BigTextStyle().bigText(value.body)).setOnlyAlertOnce(true).build()
        manager.notify(tag, 2, notification)
    }
    fun clear(peer: UUID) {
        for (notification in manager.activeNotifications) if (notification.tag?.startsWith(prefix(peer)) == true) manager.cancel(notification.tag, notification.id)
    }
    private fun prefix(peer: UUID): String = "Ancintosh.mirror.$peer."
    companion object { private const val CHANNEL = "Ancintosh.mirror" }
}
