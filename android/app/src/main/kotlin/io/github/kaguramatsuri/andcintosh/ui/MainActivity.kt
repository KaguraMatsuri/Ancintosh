package io.github.kaguramatsuri.andcintosh.ui

import android.Manifest
import android.app.StatusBarManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.ViewModelProvider
import io.github.kaguramatsuri.andcintosh.R
import io.github.kaguramatsuri.andcintosh.platform.SyncTileService

class MainActivity : ComponentActivity() {
    private lateinit var model: SettingsViewModel
    private val radio = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
            getSystemService(BluetoothManager::class.java).adapter?.isEnabled == true) model.start()
    }
    private val bluetooth = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants[Manifest.permission.BLUETOOTH_CONNECT] == true && grants[Manifest.permission.BLUETOOTH_ADVERTISE] == true) startWithBluetooth()
        else model.error = R.string.error_permission
    }
    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }
    private val original = registerForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        if (allowed) model.originalPermissionGranted() else model.error = R.string.error_permission
    }
    private val documents = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) model.sendFiles(uris)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        model = ViewModelProvider(this)[SettingsViewModel::class.java]
        setContent {
            AndcintoshTheme {
                SettingsScreen(model, start = { requestStart() }, sendFiles = { documents.launch(arrayOf("*/*")) }, addTile = {
                    getSystemService(StatusBarManager::class.java).requestAddTileService(
                        ComponentName(this, SyncTileService::class.java), getString(R.string.sync),
                        Icon.createWithResource(this, android.R.drawable.stat_notify_sync), mainExecutor) { }
                }, originalPermission = { original.launch(Manifest.permission.ACCESS_MEDIA_LOCATION) }, notificationPermission = {
                    notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                })
            }
        }
    }
    override fun onResume() { super.onResume(); if (::model.isInitialized) model.refresh() }
    private fun requestStart() {
        val required = arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        if (required.any { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) bluetooth.launch(required)
        else startWithBluetooth()
    }
    private fun startWithBluetooth() {
        if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) { model.error = R.string.error_permission; return }
        val adapter = getSystemService(BluetoothManager::class.java).adapter
        if (adapter == null) model.error = R.string.error_unsupported
        else if (!adapter.isEnabled) radio.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
        else model.start()
    }
}
