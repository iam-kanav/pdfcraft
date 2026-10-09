package com.pdfcraft.pdfcraft.engine

import android.content.Context
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.font.PDType0Font
import io.flutter.FlutterInjector
import java.io.File
import java.util.UUID

class EngineException(val code: String, message: String) : Exception(message)

/** A loaded document together with the information needed to save it back faithfully. */
class OpenedDoc(
    val doc: PDDocument,
    val password: String?,
    val wasEncrypted: Boolean,
    val permissionBits: Int,
    val keyLength: Int,
) : AutoCloseable {
    private val fonts = HashMap<String, PDFont>()

    /** Lazily embeds one of the bundled Noto fonts (subsetted on save). */
    fun font(bold: Boolean = false, italic: Boolean = false, serif: Boolean = false): PDFont {
        val family = if (serif) "NotoSerif" else "NotoSans"
        val style = when {
            bold && italic -> "BoldItalic"
            bold -> "Bold"
            italic -> "Italic"
            else -> "Regular"
        }
        val name = "$family-$style"
        return fonts.getOrPut(name) {
            PdfIO.openAsset("assets/fonts/$name.ttf").use { PDType0Font.load(doc, it, true) }
        }
    }

    override fun close() = doc.close()
}

object PdfIO {
    lateinit var context: Context

    fun openAsset(assetPath: String) =
        context.assets.open(FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetPath))

    fun load(path: String, password: String? = null): OpenedDoc {
        val file = File(path)
        if (!file.exists()) throw EngineException("NOT_FOUND", "File not found: $path")
        val doc = try {
            PDDocument.load(file, password ?: "", MemoryUsageSetting.setupMixed(64L * 1024 * 1024))
        } catch (e: com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException) {
            throw EngineException("PASSWORD", "Password required or incorrect")
        }
        val enc = doc.encryption
        return OpenedDoc(
            doc = doc,
            password = password,
            wasEncrypted = doc.isEncrypted,
            permissionBits = enc?.permissions ?: -4,
            keyLength = enc?.length ?: 128,
        )
    }

    /** Opens [path], runs [block], saves to [out] (which may equal [path]). */
    fun <T> edit(path: String, password: String?, out: String, block: (OpenedDoc) -> T): T {
        load(path, password).use { od ->
            val r = block(od)
            save(od, out)
            return r
        }
    }

    fun <T> read(path: String, password: String?, block: (OpenedDoc) -> T): T =
        load(path, password).use(block)

    /**
     * Saves the document atomically. Previously-encrypted documents stay protected:
     * the password used to open them becomes the open password and the original
     * permission bits are preserved.
     */
    fun save(od: OpenedDoc, out: String, keepSecurity: Boolean = true) {
        val doc = od.doc
        if (od.wasEncrypted) {
            if (keepSecurity) {
                val pw = od.password ?: ""
                val owner = if (pw.isNotEmpty()) pw else UUID.randomUUID().toString()
                val policy = StandardProtectionPolicy(owner, pw, AccessPermission(od.permissionBits))
                policy.encryptionKeyLength = if (od.keyLength >= 256) 256 else 128
                doc.protect(policy)
            } else {
                doc.isAllSecurityToBeRemoved = true
            }
        }
        writeAtomically(doc, out)
    }

    fun writeAtomically(doc: PDDocument, out: String) {
        val target = File(out)
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, ".${target.name}.${System.nanoTime()}.tmp")
        try {
            doc.save(tmp)
        } catch (e: Exception) {
            tmp.delete()
            throw e
        }
        // Close before replacing in case the source file is the target.
        doc.close()
        if (target.exists() && !target.delete()) {
            tmp.delete()
            throw EngineException("IO", "Cannot replace $out")
        }
        if (!tmp.renameTo(target)) {
            tmp.copyTo(target, overwrite = true)
            tmp.delete()
        }
    }
}
