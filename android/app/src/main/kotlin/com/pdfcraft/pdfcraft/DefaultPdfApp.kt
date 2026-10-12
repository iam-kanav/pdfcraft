package com.pdfcraft.pdfcraft

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.provider.Settings
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import java.io.File

/**
 * Which app opens PDFs, and the ways to make it PDFCraft. Android has no setting for a
 * default PDF app and won't let an app claim it: the user picks "Always" in the system's
 * "Open with" prompt, after clearing another app's default in that app's settings.
 */
object DefaultPdfApp {
    private const val PROBE_NAME = "PDFCraft default app.pdf"

    fun probeUri(context: Context): Uri = Uri.parse("content://${context.packageName}.probe/$PROBE_NAME")

    /** True for the test PDF that [ask] opens; it comes back here when PDFCraft is chosen. */
    fun isProbe(context: Context, uri: Uri): Boolean = uri.authority == "${context.packageName}.probe"

    private fun viewIntent(context: Context) =
        Intent(Intent.ACTION_VIEW).setDataAndType(probeUri(context), "application/pdf")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

    /** {state: self | none | other, app: label of the other app, package}. */
    fun status(context: Context): Map<String, Any?> {
        val pm = context.packageManager
        val intent = viewIntent(context)
        val resolved = pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
            ?: return mapOf("state" to "none")
        val pkg = resolved.activityInfo.packageName
        if (pkg == context.packageName) return mapOf("state" to "self")
        // With no default, Android resolves to its "Open with" chooser, which isn't one of the
        // apps that handle PDFs.
        val handlers = pm.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            .map { it.activityInfo.packageName }
        if (pkg !in handlers) return mapOf("state" to "none")
        // The app's name, as titled on its settings page ("Drive", not "Drive PDF Viewer").
        val app = resolved.activityInfo.applicationInfo.loadLabel(pm).toString()
        return mapOf("state" to "other", "app" to app, "package" to pkg)
    }

    /** Opens the test PDF so Android asks which app to use, with "Always". */
    fun ask(activity: Activity) {
        activity.startActivity(viewIntent(activity))
    }

    /** Opens [pkg]'s settings, where "Open by default" clears its default. */
    fun openAppSettings(activity: Activity, pkg: String) {
        activity.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    fun probeFile(context: Context): File {
        val file = File(context.cacheDir, "probe/$PROBE_NAME")
        if (file.exists()) return file
        file.parentFile?.mkdirs()
        com.tom_roush.pdfbox.android.PDFBoxResourceLoader.init(context.applicationContext)
        PDDocument().use { doc ->
            val page = PDPage()
            doc.addPage(page)
            PDPageContentStream(doc, page).use { cs ->
                cs.beginText()
                cs.setFont(PDType1Font.HELVETICA, 14f)
                cs.newLineAtOffset(72f, page.mediaBox.height - 96f)
                cs.showText("PDFCraft opened this to set the default PDF app. You can close it.")
                cs.endText()
            }
            doc.save(file)
        }
        return file
    }
}

/** Serves the test PDF of [DefaultPdfApp.ask] to whichever app is chosen. */
class DefaultPdfAppProbeProvider : ContentProvider() {
    override fun onCreate() = true

    override fun getType(uri: Uri) = "application/pdf"

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        return ParcelFileDescriptor.open(DefaultPdfApp.probeFile(context!!), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val file = DefaultPdfApp.probeFile(context!!)
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
            addRow(arrayOf<Any>(file.name, file.length()))
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
