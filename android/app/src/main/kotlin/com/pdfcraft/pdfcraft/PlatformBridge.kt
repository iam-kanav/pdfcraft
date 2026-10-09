package com.pdfcraft.pdfcraft

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors

/** Android integration: "Open with"/share intents, saving to Downloads, all-files access, device scan and printing. */
class PlatformBridge(private val activity: Activity) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private var initial: Map<String, Any?>? = null
    private val io = Executors.newSingleThreadExecutor()

    init {
        handleIntent(activity.intent, live = false)
    }

    fun handleIntent(intent: Intent?, live: Boolean) {
        if (intent == null) return
        val uris = ArrayList<Uri>()
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { uris.add(it) }
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
            }
            else -> return
        }
        if (uris.isEmpty()) return
        // Consume so that a configuration change doesn't re-deliver it.
        intent.action = Intent.ACTION_MAIN
        io.execute {
            val files = uris.mapNotNull { copyToCache(it) }
            if (files.isEmpty()) return@execute
            val payload = mapOf("files" to files)
            activity.runOnUiThread {
                if (live && sink != null) sink?.success(payload) else initial = payload
                if (!live && sink != null) { sink?.success(payload); initial = null }
            }
        }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun copyToCache(uri: Uri): Map<String, Any?>? = try {
        val mime = activity.contentResolver.getType(uri)
        var name = displayName(uri) ?: "document_${System.currentTimeMillis()}"
        name = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        if (!name.contains('.') && mime == "application/pdf") name += ".pdf"
        val dir = File(activity.cacheDir, "incoming/${System.nanoTime()}").apply { mkdirs() }
        val out = File(dir, name)
        activity.contentResolver.openInputStream(uri)!!.use { input -> FileOutputStream(out).use { input.copyTo(it) } }
        mapOf("path" to out.absolutePath, "name" to name, "mime" to mime, "uri" to uri.toString())
    } catch (e: Exception) {
        android.util.Log.w("PDFCraft", "copy failed for $uri", e)
        null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun onActivityResult(requestCode: Int) {}

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takeInitialIntent" -> {
                result.success(initial)
                initial = null
            }
            "saveToDownloads" -> io.execute {
                try {
                    val r = saveToDownloads(call.argument<String>("path")!!, call.argument<String>("name")!!, call.argument<String>("mime") ?: "application/pdf")
                    activity.runOnUiThread { result.success(r) }
                } catch (e: Exception) {
                    activity.runOnUiThread { result.error("IO", e.message, null) }
                }
            }
            "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
            "requestAllFilesAccess" -> {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val i = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${activity.packageName}"))
                        activity.startActivity(i)
                    }
                    result.success(null)
                } catch (e: Exception) {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                    result.success(null)
                }
            }
            "scanDevicePdfs" -> io.execute {
                val list = scanDevicePdfs()
                activity.runOnUiThread { result.success(list) }
            }
            "print" -> {
                printPdf(call.argument<String>("path")!!, call.argument<String>("name") ?: "Document")
                result.success(null)
            }
            "externalStorageRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
            else -> result.notImplemented()
        }
    }

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager() else true

    private fun saveToDownloads(path: String, name: String, mime: String): String {
        val src = File(path)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/PDFCraft")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = activity.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IllegalStateException("Cannot create download")
            resolver.openOutputStream(uri)!!.use { out -> FileInputStream(src).use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Download/PDFCraft/$name"
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "PDFCraft").apply { mkdirs() }
        val out = File(dir, name)
        src.copyTo(out, overwrite = true)
        return out.absolutePath
    }

    private fun scanDevicePdfs(): List<Map<String, Any?>> {
        if (!hasAllFilesAccess()) return emptyList()
        val root = Environment.getExternalStorageDirectory()
        val out = ArrayList<Map<String, Any?>>()
        fun walk(dir: File, depth: Int) {
            if (depth > 8 || out.size > 2000) return
            val children = dir.listFiles() ?: return
            for (f in children) {
                if (f.name.startsWith(".")) continue
                if (f.isDirectory) {
                    if (depth == 0 && f.name == "Android") continue
                    walk(f, depth + 1)
                } else if (f.name.endsWith(".pdf", ignoreCase = true)) {
                    out.add(mapOf("path" to f.absolutePath, "size" to f.length(), "modified" to f.lastModified()))
                }
            }
        }
        walk(root, 0)
        return out
    }

    private fun printPdf(path: String, name: String) {
        val pm = activity.getSystemService(Context.PRINT_SERVICE) as PrintManager
        pm.print(name, object : PrintDocumentAdapter() {
            override fun onLayout(
                oldAttributes: PrintAttributes?, newAttributes: PrintAttributes?, cancellationSignal: CancellationSignal?,
                callback: LayoutResultCallback, extras: Bundle?,
            ) {
                if (cancellationSignal?.isCanceled == true) { callback.onLayoutCancelled(); return }
                val info = PrintDocumentInfo.Builder(name).setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT).build()
                callback.onLayoutFinished(info, true)
            }

            override fun onWrite(
                pages: Array<out PageRange>?, destination: ParcelFileDescriptor, cancellationSignal: CancellationSignal?,
                callback: WriteResultCallback,
            ) {
                try {
                    FileInputStream(path).use { input -> FileOutputStream(destination.fileDescriptor).use { input.copyTo(it) } }
                    callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
                } catch (e: Exception) {
                    callback.onWriteFailed(e.message)
                }
            }
        }, null)
    }
}
