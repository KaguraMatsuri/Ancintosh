package io.github.kaguramatsuri.andcintosh.ui

import android.Manifest
import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import io.github.kaguramatsuri.andcintosh.R
import io.github.kaguramatsuri.andcintosh.core.*
import io.github.kaguramatsuri.andcintosh.platform.*
import java.util.UUID
import kotlinx.coroutines.*

class ShareReceiverActivity : ComponentActivity() {
    private lateinit var model: ShareViewModel
    private val original = registerForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        if (allowed) { DeviceSettings(this).originalPermissionNeeded = false; model.needsOriginal = false; model.send() }
        else model.permissionDenied()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        model = ViewModelProvider(this)[ShareViewModel::class.java]
        model.initialize(intent, savedInstanceState == null)
        setContent {
            AndcintoshTheme {
                LaunchedEffect(model.complete) { if (model.complete) finish() }
                Scaffold { insets ->
                    Column(Modifier.fillMaxSize().padding(insets).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text(stringResource(R.string.share_title), style = MaterialTheme.typography.titleLarge)
                        Text(stringResource(model.message))
                        if (!model.failed) CircularProgressIndicator()
                        if (model.needsOriginal) {
                            Text(stringResource(R.string.original_help))
                            Button(onClick = { original.launch(Manifest.permission.ACCESS_MEDIA_LOCATION) }) { Text(stringResource(R.string.original_permission)) }
                        }
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (model.failed) Button(onClick = model::send) { Text(stringResource(R.string.retry)) }
                            TextButton(onClick = { finish() }) { Text(stringResource(R.string.cancel)) }
                        }
                    }
                }
            }
        }
    }
}

class ShareViewModel(application: Application) : AndroidViewModel(application) {
    var message by mutableIntStateOf(R.string.syncing); private set
    var failed by mutableStateOf(false)
    var needsOriginal by mutableStateOf(false)
    var complete by mutableStateOf(false); private set
    private var service: SyncService? = null
    private val binding = ServiceBinding(application) { service = null; failed = true; message = R.string.error_peer }
    private var pending: UUID? = null
    private var sending: Job? = null
    private var collector: Job? = null
    private var request: Intent? = null
    fun permissionDenied() { failed = true; message = R.string.error_permission }
    fun initialize(intent: Intent, automatically: Boolean) {
        if (request != null) return
        request = intent
        if (automatically) send() else { failed = true; message = R.string.interrupted }
    }
    fun send() {
        if (sending?.isActive == true) return
        failed = false; message = R.string.syncing
        sending = viewModelScope.launch {
            var snapshot: Snapshot? = null
            var enqueued = false
            try {
                val active = service ?: binding.connect().also { service = it }
                if (!active.status.value.ready || active.session.connected == null) fail(Failure.peerUnavailable)
                pending?.let { withContext(Dispatchers.IO) { active.cancel(it) } }; pending = null
                if (collector == null) collector = viewModelScope.launch {
                    active.events.collect { event ->
                        when {
                            event is SyncEvent.Completed && event.id == pending -> complete = true
                            event is SyncEvent.Failed && event.id == pending -> { failed = true; message = failureText(event.code) }
                            event is SyncEvent.Disconnected -> { failed = true; message = R.string.error_peer }
                        }
                    }
                }
                withContext(Dispatchers.IO) { snapshot = active.files.shareSnapshot(request!!); ensureActive() }
                val prepared = snapshot!!
                pending = prepared.manifest.id
                withContext(Dispatchers.IO) { active.enqueue(prepared) }; enqueued = true
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                failed = true; message = if (service == null) R.string.start_first else failureText(error)
                val context = getApplication<Application>()
                needsOriginal = DeviceSettings(context).originalPermissionNeeded &&
                    context.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED
            } finally { if (!enqueued) snapshot?.file?.delete() }
        }
    }
    override fun onCleared() {
        if (!complete) pending?.let { service?.cancelAsync(it) }
        binding.close(); request = null; service = null
    }
}
