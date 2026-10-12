package io.github.kaguramatsuri.andcintosh.platform

import android.app.AlertDialog
import android.content.DialogInterface
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.view.ContextThemeWrapper
import io.github.kaguramatsuri.andcintosh.R
import io.github.kaguramatsuri.andcintosh.core.*
import io.github.kaguramatsuri.andcintosh.ui.failureText
import java.util.UUID
import kotlinx.coroutines.*

class SyncTileService : TileService() {
    private var panel: AlertDialog? = null
    private var cleanup: (() -> Unit)? = null
    override fun onStartListening() {
        qsTile?.apply { label = getString(R.string.sync); state = Tile.STATE_INACTIVE; updateTile() }
    }
    override fun onClick() {
        if (isLocked) unlockAndRun { openPanel() } else openPanel()
    }
    private fun openPanel() {
        if (panel?.isShowing == true) return
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var service: SyncService? = null
        var transfer: UUID? = null
        var sending: Job? = null
        var collector: Job? = null
        var complete = false
        var attempted = false
        val handle = ServiceBinding(this)
        val dialog = object : AlertDialog(ContextThemeWrapper(this@SyncTileService, android.R.style.Theme_DeviceDefault_Dialog_Alert)) {
            override fun onWindowFocusChanged(hasFocus: Boolean) {
                super.onWindowFocusChanged(hasFocus)
                if (hasFocus && !attempted) { attempted = true; attempt() }
            }
            fun attempt() {
                if (sending?.isActive == true || !window!!.decorView.hasWindowFocus()) return
                setMessage(getString(R.string.focus_wait))
                getButton(DialogInterface.BUTTON_POSITIVE)?.isEnabled = false
                sending = scope.launch {
                    var snapshot: Snapshot? = null
                    var enqueued = false
                    try {
                        val active = service ?: handle.connect().also { service = it }
                        if (!active.status.value.ready || active.session.connected == null) fail(Failure.peerUnavailable)
                        transfer?.let { withContext(Dispatchers.IO) { active.cancel(it) } }; transfer = null
                        if (collector == null) collector = scope.launch {
                            active.events.collect { event ->
                                when {
                                    event is SyncEvent.Completed && event.id == transfer -> { complete = true; dismiss() }
                                    event is SyncEvent.Failed && (event.id == transfer || event.id == Wire.ZERO_ID) -> {
                                        setMessage(getString(failureText(event.code))); getButton(DialogInterface.BUTTON_POSITIVE).isEnabled = true
                                    }
                                    event is SyncEvent.Disconnected -> {
                                        setMessage(getString(R.string.error_peer)); getButton(DialogInterface.BUTTON_POSITIVE).isEnabled = true
                                    }
                                }
                            }
                        }
                        withContext(Dispatchers.IO) { snapshot = active.files.clipboardSnapshot(); ensureActive() }
                        val prepared = snapshot!!
                        transfer = prepared.manifest.id
                        withContext(Dispatchers.IO) { active.enqueue(prepared) }
                        enqueued = true
                        setMessage(getString(R.string.syncing))
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (error: Exception) {
                        setMessage(getString(if (service == null) R.string.start_first else failureText(error)))
                        getButton(DialogInterface.BUTTON_POSITIVE).isEnabled = true
                    } finally { if (!enqueued) snapshot?.file?.delete() }
                }
            }
        }
        dialog.setTitle(getString(R.string.sync))
        dialog.setMessage(getString(R.string.focus_wait))
        dialog.setButton(DialogInterface.BUTTON_POSITIVE, getString(R.string.retry)) { _, _ -> }
        dialog.setButton(DialogInterface.BUTTON_NEGATIVE, getString(R.string.cancel)) { _, _ -> dialog.dismiss() }
        dialog.setOnShowListener {
            dialog.getButton(DialogInterface.BUTTON_POSITIVE).isEnabled = false
            dialog.getButton(DialogInterface.BUTTON_POSITIVE).setOnClickListener { dialog.attempt() }
        }
        val dispose = {
            if (!complete) transfer?.let { id -> service?.cancelAsync(id) }
            scope.cancel(); handle.close(); panel = null; cleanup = null
        }
        cleanup = dispose
        dialog.setOnDismissListener { dispose() }
        panel = dialog
        showDialog(dialog)
    }
    override fun onDestroy() { panel?.dismiss(); cleanup?.invoke(); super.onDestroy() }
}
