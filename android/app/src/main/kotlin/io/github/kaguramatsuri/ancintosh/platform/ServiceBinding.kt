package io.github.kaguramatsuri.ancintosh.platform

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import io.github.kaguramatsuri.ancintosh.core.Failure
import io.github.kaguramatsuri.ancintosh.core.fail
import kotlinx.coroutines.CompletableDeferred

/** Binds only to an already started service; opening a screen never starts the radio. */
class ServiceBinding(private val context: Context, private val disconnected: () -> Unit = {}) : AutoCloseable {
    private var bound = false
    private var ready = CompletableDeferred<SyncService>()
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) { ready.complete((binder as SyncService.LocalBinder).service) }
        override fun onServiceDisconnected(name: ComponentName) { close(); disconnected() }
        override fun onNullBinding(name: ComponentName) { close(); disconnected() }
        override fun onBindingDied(name: ComponentName) { close(); disconnected() }
    }
    suspend fun connect(): SyncService {
        if (!bound) {
            ready = CompletableDeferred()
            bound = context.bindService(Intent(context, SyncService::class.java), connection, 0)
        }
        if (!bound) fail(Failure.peerUnavailable)
        return ready.await()
    }
    override fun close() {
        if (bound) { context.unbindService(connection); bound = false }
        if (!ready.isCompleted) ready.cancel()
    }
}
