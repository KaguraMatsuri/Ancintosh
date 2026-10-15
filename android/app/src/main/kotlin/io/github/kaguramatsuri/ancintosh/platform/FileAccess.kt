package io.github.kaguramatsuri.ancintosh.platform

import android.Manifest as AndroidManifest
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.github.kaguramatsuri.ancintosh.core.*
import java.io.File
import java.util.UUID
import org.json.JSONObject

class FileAccess(private val context: Context, private val store: TransferStore, private val identity: UUID) {
    fun release(snapshot: Snapshot) = store.release(snapshot.file)
    fun shareSnapshot(intent: Intent): Snapshot {
        if (intent.action != Intent.ACTION_SEND) fail(Failure.unsupported)
        if (intent.type == "text/plain") {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT) ?: fail(Failure.sourceUnavailable)
            return store.snapshot(text.toString().toByteArray(Charsets.UTF_8).inputStream(), PayloadKind.TEXT,
                UUID.randomUUID().toString(), "text/plain;charset=utf-8", identity)
        }
        if (intent.type?.startsWith("image/") == true) {
            val uri = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: fail(Failure.originalUnavailable)
            return snapshot(uri, PayloadKind.IMAGE)
        }
        fail(Failure.unsupported)
    }
    fun snapshot(uri: Uri, kind: PayloadKind, check: () -> Unit = {}): Snapshot {
        if (uri.scheme != "content") fail(Failure.originalUnavailable)
        val resolver = context.contentResolver
        val mime = resolver.getType(uri) ?: "application/octet-stream"
        if (kind == PayloadKind.IMAGE && !mime.startsWith("image/")) fail(Failure.originalUnavailable)
        var name: String? = null
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) name = it.getString(0)
        }
        if (DocumentsContract.isDocumentUri(context, uri)) {
            resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use {
                if (it.moveToFirst() && it.getInt(0) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0) fail(Failure.originalUnavailable)
            }
        }
        var original = uri
        if (uri.authority == MediaStore.AUTHORITY && mime.startsWith("image/")) {
            if (context.checkSelfPermission(AndroidManifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                DeviceSettings(context).originalPermissionNeeded = true
                fail(Failure.permissionDenied)
            }
            original = MediaStore.setRequireOriginal(uri)
        }
        val input = resolver.openInputStream(original) ?: fail(Failure.originalUnavailable)
        return store.snapshot(input, kind, name ?: fail(Failure.invalidName), mime, identity, check)
    }
    fun clipboardSnapshot(): Snapshot {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        val clip = clipboard.primaryClip ?: fail(Failure.sourceUnavailable)
        if (clip.itemCount != 1) fail(Failure.unsupported)
        val item = clip.getItemAt(0)
        val uri = item.uri
        if (uri != null) {
            if (context.contentResolver.getType(uri)?.startsWith("image/") != true) fail(Failure.unsupported)
            return snapshot(uri, PayloadKind.IMAGE)
        }
        val text = item.text ?: fail(Failure.originalUnavailable)
        return store.snapshot(text.toString().toByteArray(Charsets.UTF_8).inputStream(), PayloadKind.TEXT,
            UUID.randomUUID().toString(), "text/plain;charset=utf-8", identity)
    }
    fun apply(result: Received) {
        if (result.manifest.kind == PayloadKind.FILE) return
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        if (result.manifest.kind == PayloadKind.TEXT) {
            clipboard.setPrimaryClip(ClipData.newPlainText("Ancintosh", result.file.readText(Charsets.UTF_8)))
        } else {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", result.file)
            clipboard.setPrimaryClip(ClipData(ClipDescription("Ancintosh", arrayOf(result.manifest.mime)), ClipData.Item(uri)))
        }
    }
    companion object {
        fun publish(context: Context, file: File, manifest: Manifest, commit: PublicationCommit = { it() }, check: () -> Unit = {}): String {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, manifest.name)
                put(MediaStore.MediaColumns.MIME_TYPE, manifest.mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/Ancintosh")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: fail(Failure.permissionDenied)
            var committed = false
            try {
                resolver.openFileDescriptor(uri, "w")?.use { descriptor ->
                    java.io.FileOutputStream(descriptor.fileDescriptor).use { output ->
                        file.inputStream().use { input ->
                            val bytes = ByteArray(65536)
                            while (true) { check(); val count = input.read(bytes); if (count < 0) break; output.write(bytes, 0, count) }
                        }
                        check(); output.fd.sync()
                    }
                } ?: fail(Failure.permissionDenied)
                val result = commit {
                    val pending = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                    if (resolver.update(uri, pending, null, null) != 1) fail(Failure.permissionDenied)
                    uri.toString()
                }
                committed = true; file.delete(); return result
            } finally { if (!committed) resolver.delete(uri, null, null) }
        }
    }
}

class ClipboardFileProvider : FileProvider() {
    override fun getType(uri: Uri): String? {
        val id = uri.pathSegments.getOrNull(1)
        if (id != null && runCatching { UUID.fromString(id) }.isSuccess) {
            val file = File(context!!.filesDir, "state/clipboard/$id/manifest.json")
            if (file.isFile) return JSONObject(file.readText()).getString("mime")
        }
        return super.getType(uri)
    }
}
