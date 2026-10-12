package io.github.kaguramatsuri.andcintosh.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.kaguramatsuri.andcintosh.R

@Composable
fun AndcintoshTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context), content = content)
}

@Composable
fun SettingsScreen(model: SettingsViewModel, start: () -> Unit, sendFiles: () -> Unit, addTile: () -> Unit,
                   originalPermission: () -> Unit, notificationPermission: () -> Unit) {
    val state by model.status.collectAsStateWithLifecycle()
    val context = LocalContext.current
    Scaffold { insets ->
        LazyColumn(modifier = Modifier.fillMaxSize().padding(insets).imePadding(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Text(stringResource(R.string.connection), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(if (!state.running) R.string.stopped else if (state.peer != null) R.string.connected else R.string.waiting))
                SelectionContainer {
                    Column {
                        Text(stringResource(R.string.device_id), style = MaterialTheme.typography.labelLarge)
                        Text(model.identity)
                        Text(stringResource(R.string.mac_id), style = MaterialTheme.typography.labelLarge)
                        Text(model.mac ?: stringResource(R.string.not_paired))
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (state.running) Button(onClick = model::stop, enabled = !model.busy) { Text(stringResource(R.string.stop)) }
                    else Button(onClick = start, enabled = !model.busy && model.hasKey) { Text(stringResource(R.string.start)) }
                }
            }
            item {
                OutlinedTextField(value = model.key, onValueChange = { model.key = it }, label = { Text(stringResource(R.string.key)) },
                    modifier = Modifier.fillMaxWidth(), singleLine = true, enabled = !model.busy,
                    visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                Text(stringResource(R.string.key_help), style = MaterialTheme.typography.bodySmall)
                if (model.hasKey) Text(stringResource(R.string.key_saved), style = MaterialTheme.typography.bodySmall)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = model::save, enabled = !model.busy) { Text(stringResource(R.string.save)) }
                    TextButton(onClick = model::cancelEdit, enabled = !model.busy && model.key.isNotEmpty()) { Text(stringResource(R.string.cancel)) }
                }
            }
            item {
                Row(modifier = Modifier.fillMaxWidth().toggleable(value = model.wifi, role = Role.Switch, enabled = !model.busy, onValueChange = model::wifi), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(stringResource(R.string.wifi), modifier = Modifier.weight(1f))
                    Switch(checked = model.wifi, onCheckedChange = null)
                }
                if (!model.wifi) Text(stringResource(R.string.bluetooth_visibility), style = MaterialTheme.typography.bodySmall)
            }
            item {
                Text(stringResource(R.string.operations), style = MaterialTheme.typography.titleMedium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledTonalButton(onClick = addTile) { Text(stringResource(R.string.add_tile)) }
                    FilledTonalButton(onClick = sendFiles, enabled = state.ready && state.peer != null && !state.preparing && !model.busy) {
                        Text(stringResource(if (state.preparing) R.string.preparing else R.string.send_files))
                    }
                }
                Text(stringResource(R.string.downloads_help), style = MaterialTheme.typography.bodySmall)
                if (context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    TextButton(onClick = notificationPermission) { Text(stringResource(R.string.notification_permission)) }
                }
                if (model.originalPermissionNeeded) {
                    Text(stringResource(R.string.original_help), style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = originalPermission) { Text(stringResource(R.string.original_permission)) }
                }
            }
            if (state.transfers.isNotEmpty()) item { Text(stringResource(R.string.transfers), style = MaterialTheme.typography.titleMedium) }
            items(state.transfers, key = { it.id }) { transfer ->
                val progressLabel = stringResource(R.string.progress)
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(transfer.name)
                    LinearProgressIndicator(progress = { (transfer.bytes.toDouble() / maxOf(1, transfer.size)).toFloat().coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = progressLabel })
                    Text("${android.text.format.Formatter.formatFileSize(context, transfer.bytes)} / ${android.text.format.Formatter.formatFileSize(context, transfer.size)}")
                    if (transfer.failure != null) Text(stringResource(failureText(transfer.failure)))
                    else if (state.peer == null) Text(stringResource(R.string.paused))
                    FlowRow {
                        if (transfer.failure != null) TextButton(onClick = { model.retry(transfer.id) }, enabled = !model.busy && state.peer != null) { Text(stringResource(R.string.retry)) }
                        TextButton(onClick = { model.cancel(transfer.id) }, enabled = !model.busy) { Text(stringResource(R.string.cancel)) }
                    }
                }
            }
            state.failure?.let { code -> item { Text(stringResource(failureText(code))) } }
        }
    }
    model.error?.let { message ->
        AlertDialog(onDismissRequest = { model.error = null }, title = { Text(stringResource(R.string.operation_failed)) }, text = { Text(stringResource(message)) },
            confirmButton = { TextButton(onClick = { model.error = null }) { Text(stringResource(R.string.confirm)) } })
    }
}
