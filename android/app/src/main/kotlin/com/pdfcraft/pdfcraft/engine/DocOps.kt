package com.pdfcraft.pdfcraft.engine

import android.graphics.Bitmap
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.multipdf.PDFMergerUtility
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageDestination
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineNode
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget
import java.io.File
import java.util.Calendar
import kotlin.math.max
import kotlin.math.min

/** Document-level operations: info, metadata, security, page organization, compression. */
object DocOps {

    fun info(args: Map<String, Any?>): Map<String, Any?> = PdfIO.read(args.path, args.password) { od ->
        val doc = od.doc
        val info = doc.documentInformation
        val ap = doc.currentAccessPermission
        val form = doc.documentCatalog.acroForm
        mapOf(
            "pageCount" to doc.numberOfPages,
            "version" to doc.version.toDouble(),
            "encrypted" to od.wasEncrypted,
            "keyLength" to if (od.wasEncrypted) od.keyLength else 0,
            "isOwner" to ap.isOwnerPermission,
            "title" to info.title,
            "author" to info.author,
            "subject" to info.subject,
            "keywords" to info.keywords,
            "creator" to info.creator,
            "producer" to info.producer,
            "created" to info.creationDate?.timeInMillis,
            "modified" to info.modificationDate?.timeInMillis,
            "permissions" to permissionsMap(ap),
            "fieldCount" to (form?.fieldTree?.count() ?: 0),
            "pages" to doc.pages.map { p ->
                val g = PageGeom(p)
                listOf(g.width.toDouble(), g.height.toDouble(), g.rotation)
            },
            "fileSize" to File(args.path).length(),
        )
    }

    fun permissionsMap(ap: AccessPermission) = mapOf(
        "print" to ap.canPrint(),
        "printHigh" to ap.canPrintFaithful(),
        "modify" to ap.canModify(),
        "copy" to ap.canExtractContent(),
        "annotate" to ap.canModifyAnnotations(),
        "fillForms" to ap.canFillInForm(),
        "extractAccessibility" to ap.canExtractForAccessibility(),
        "assemble" to ap.canAssembleDocument(),
    )

    fun setMetadata(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val info = od.doc.documentInformation
            val fields = args["fields"] as Map<*, *>
            fun v(k: String) = (fields[k] as String?)?.ifBlank { null }
            if (fields.containsKey("title")) info.title = v("title")
            if (fields.containsKey("author")) info.author = v("author")
            if (fields.containsKey("subject")) info.subject = v("subject")
            if (fields.containsKey("keywords")) info.keywords = v("keywords")
            if (fields.containsKey("creator")) info.creator = v("creator")
            if (fields.containsKey("producer")) info.producer = v("producer")
            info.modificationDate = Calendar.getInstance()
            if (args["stripXmp"] == true) od.doc.documentCatalog.metadata = null
            od.doc.documentInformation = info
        }
    }

    /** Applies password protection. Opening with the current password is required if the file is already protected. */
    fun protect(args: Map<String, Any?>) {
        val od = PdfIO.load(args.path, args.password)
        od.use {
            val doc = od.doc
            if (od.wasEncrypted && !doc.currentAccessPermission.isOwnerPermission) {
                throw EngineException("PERMISSION", "The permissions password is required to change security")
            }
            val user = args["userPassword"] as String? ?: ""
            val owner = (args["ownerPassword"] as String?)?.ifEmpty { null }
                ?: if (user.isNotEmpty()) user else java.util.UUID.randomUUID().toString()
            val p = args["permissions"] as Map<*, *>? ?: emptyMap<String, Any>()
            val ap = AccessPermission()
            fun flag(k: String) = p[k] as Boolean? ?: true
            ap.setCanPrint(flag("print"))
            ap.setCanPrintFaithful(flag("printHigh"))
            ap.setCanModify(flag("modify"))
            ap.setCanExtractContent(flag("copy"))
            ap.setCanModifyAnnotations(flag("annotate"))
            ap.setCanFillInForm(flag("fillForms"))
            ap.setCanExtractForAccessibility(flag("extractAccessibility"))
            ap.setCanAssembleDocument(flag("assemble"))
            if (od.wasEncrypted) doc.isAllSecurityToBeRemoved = false
            val policy = StandardProtectionPolicy(owner, user, ap)
            policy.encryptionKeyLength = (args["keyLength"] as Int?) ?: 256
            doc.protect(policy)
            PdfIO.writeAtomically(doc, args.out)
        }
    }

    fun removeSecurity(args: Map<String, Any?>) {
        val od = PdfIO.load(args.path, args.password)
        od.use {
            if (od.wasEncrypted && !od.doc.currentAccessPermission.isOwnerPermission && (args.password ?: "").isEmpty()) {
                throw EngineException("PERMISSION", "The permissions password is required to remove security")
            }
            PdfIO.save(od, args.out, keepSecurity = false)
        }
    }

    /**
     * Rebuilds a document from a list of page specs. Each spec is one of:
     *  {"index": n, "rotate": deg?}                — page n (0-based) of the main document
     *  {"file": path, "password": pw?, "index": n, "rotate": deg?} — page of another document
     *  {"blank": true, "width": w, "height": h}   — new blank page
     * Covers reorder, delete, duplicate, extract, insert, rotate and merge.
     */
    fun organize(args: Map<String, Any?>): Map<String, Any?> {
        val specs = (args["pages"] as List<*>).map { it as Map<*, *> }
        if (specs.isEmpty()) throw EngineException("ARGS", "The result must contain at least one page")
        val main = PdfIO.load(args.path, args.password)
        val opened = ArrayList<OpenedDoc>()
        try {
            val doc = main.doc
            val originalCount = doc.numberOfPages
            // Append every referenced external document once (keeps forms, outlines, structure).
            val fileOffsets = HashMap<String, Int>()
            for (spec in specs) {
                val f = spec["file"] as String? ?: continue
                if (fileOffsets.containsKey(f)) continue
                val other = PdfIO.load(f, spec["password"] as String?)
                opened.add(other)
                if (other.wasEncrypted) other.doc.isAllSecurityToBeRemoved = true
                fileOffsets[f] = doc.numberOfPages
                PDFMergerUtility().appendDocument(doc, other.doc)
            }
            val all = doc.pages.toList()
            val used = HashSet<PDPage>()
            val result = ArrayList<PDPage>()
            for (spec in specs) {
                val page: PDPage = if (spec["blank"] == true) {
                    val w = (spec["width"] as Number?)?.toFloat() ?: PDRectangle.A4.width
                    val h = (spec["height"] as Number?)?.toFloat() ?: PDRectangle.A4.height
                    PDPage(PDRectangle(w, h))
                } else {
                    val f = spec["file"] as String?
                    val idx = (spec["index"] as Number).toInt() + (if (f != null) fileOffsets[f]!! else 0)
                    if (f == null && idx >= originalCount) throw EngineException("ARGS", "Page index out of range")
                    val src = all[idx]
                    if (used.add(src)) src else clonePage(src)
                }
                val rot = (spec["rotate"] as Number?)?.toInt() ?: 0
                if (rot != 0) page.rotation = (((page.rotation + rot) % 360) + 360) % 360
                result.add(page)
            }
            val tree = doc.pages
            for (p in all) tree.remove(p)
            for (p in result) tree.add(p)
            val removed = all.filter { it !in used }.toSet()
            if (removed.isNotEmpty()) cleanupRemovedPages(doc, removed)
            PdfIO.save(main, args.out)
            return mapOf("pageCount" to result.size)
        } finally {
            opened.forEach { it.close() }
            main.close()
        }
    }

    /** Shallow page copy that shares content/resources; annotations are copied (widgets dropped). */
    private fun clonePage(src: PDPage): PDPage {
        val dict = COSDictionary()
        for ((k, v) in src.cosObject.entrySet()) {
            if (k == COSName.PARENT || k == COSName.ANNOTS) continue
            dict.setItem(k, v)
        }
        // Inherited attributes must be made explicit since the parent changes.
        dict.setItem(COSName.RESOURCES, src.resources.cosObject)
        dict.setItem(COSName.MEDIA_BOX, src.mediaBox.cosArray)
        dict.setItem(COSName.CROP_BOX, src.cropBox.cosArray)
        dict.setInt(COSName.ROTATE, src.rotation)
        val page = PDPage(dict)
        val annots = src.annotations.filter { it !is PDAnnotationWidget }.map { a ->
            val copy = COSDictionary(a.cosObject)
            copy.removeItem(COSName.P)
            copy.removeItem(COSName.getPDFName("Popup"))
            com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotation.createAnnotation(copy)
        }
        if (annots.isNotEmpty()) page.annotations = annots
        return page
    }

    /** Removes outline entries and form fields that point to deleted pages. */
    private fun cleanupRemovedPages(doc: PDDocument, removed: Set<PDPage>) {
        val removedDicts = removed.map { it.cosObject }.toSet()
        doc.documentCatalog.documentOutline?.let { pruneOutline(it, removedDicts) }
        val form = doc.documentCatalog.acroForm ?: return
        val fields = form.fields.toMutableList()
        val keep = fields.filter { f ->
            val widgets = f.widgets
            widgets.isEmpty() || widgets.any { w -> w.page == null || w.page.cosObject !in removedDicts }
        }
        if (keep.size != fields.size) form.fields = keep
    }

    private fun pruneOutline(node: PDOutlineNode, removed: Set<COSDictionary>) {
        val children = node.children().toList()
        for (item in children) {
            pruneOutline(item, removed)
            val dest = try {
                item.destination ?: (item.action as? com.tom_roush.pdfbox.pdmodel.interactive.action.PDActionGoTo)?.destination
            } catch (e: Exception) {
                null
            }
            val pageDict = (dest as? PDPageDestination)?.page?.cosObject
            if (pageDict != null && pageDict in removed && !item.hasChildren()) unlinkOutlineItem(node, item)
        }
    }

    private fun unlinkOutlineItem(parent: PDOutlineNode, item: com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem) {
        val d = item.cosObject
        val prev = d.getDictionaryObject(COSName.PREV) as? COSDictionary
        val next = d.getDictionaryObject(COSName.NEXT) as? COSDictionary
        val p = parent.cosObject
        if (prev != null) { if (next != null) prev.setItem(COSName.NEXT, next) else prev.removeItem(COSName.NEXT) }
        else if (next != null) p.setItem(COSName.FIRST, next) else p.removeItem(COSName.FIRST)
        if (next != null) { if (prev != null) next.setItem(COSName.PREV, prev) else next.removeItem(COSName.PREV) }
        else if (prev != null) p.setItem(COSName.LAST, prev) else p.removeItem(COSName.LAST)
        val count = p.getInt(COSName.COUNT, 0)
        if (count > 0) p.setInt(COSName.COUNT, count - 1) else if (count < 0) p.setInt(COSName.COUNT, count + 1)
    }

    /** Splits into several files. `ranges`: list of [start, end] (1-based, inclusive). */
    fun split(args: Map<String, Any?>): List<String> {
        val ranges = (args["ranges"] as List<*>).map { r -> (r as List<*>).map { (it as Number).toInt() } }
        val outDir = File(args["outDir"] as String).apply { mkdirs() }
        val base = args["baseName"] as String
        val outputs = ArrayList<String>()
        for ((i, r) in ranges.withIndex()) {
            val out = File(outDir, "${base}_part${i + 1}.pdf").absolutePath
            organize(
                mapOf(
                    "path" to args.path, "password" to args.password, "out" to out,
                    "pages" to (r[0]..r[1]).map { mapOf("index" to it - 1) },
                ),
            )
            outputs.add(out)
        }
        return outputs
    }

    /** Sets the crop box. `crops`: list of {page: 0-based, rect: [l,t,r,b] in display space}. */
    fun crop(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            for (c in args["crops"] as List<*>) {
                c as Map<*, *>
                val page = od.doc.getPage((c["page"] as Number).toInt())
                val r = RectF.fromAny(c["rect"])
                val g = PageGeom(page)
                val user = g.rectToUser(max(0f, r.l), max(0f, r.t), min(g.width, r.r), min(g.height, r.b))
                if (user.width < 10 || user.height < 10) throw EngineException("ARGS", "Crop area too small")
                page.cropBox = user
                page.trimBox = null
                page.bleedBox = null
                page.artBox = null
            }
        }
    }

    /**
     * Compresses by downsampling/re-encoding images and Flate-encoding uncompressed streams.
     * `dpi`: target image resolution; `quality`: JPEG quality 0..1.
     */
    fun compress(args: Map<String, Any?>): Map<String, Any?> {
        val dpi = (args["dpi"] as Number?)?.toFloat() ?: 150f
        val quality = (args["quality"] as Number?)?.toFloat() ?: 0.7f
        val grayscale = args["grayscale"] == true
        val before = File(args.path).length()
        var imagesProcessed = 0
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            // Largest on-page size (in points) for each image object.
            val placement = HashMap<COSStream, Float>()
            for (page in doc.pages) {
                try {
                    ContentScanner.scanImagePlacements(page) { stream, wPt, hPt ->
                        val m = max(wPt, hPt)
                        placement[stream] = max(placement[stream] ?: 0f, m)
                    }
                } catch (_: Exception) {
                }
            }
            val done = HashSet<COSStream>()
            for (page in doc.pages) {
                compressResources(doc, page.resources, placement, done, dpi, quality, grayscale) { imagesProcessed++ }
                page.cosObject.removeItem(COSName.getPDFName("Thumb"))
                for (s in page.contentStreams) flateIfUncompressed(s.cosObject)
            }
            doc.documentCatalog.cosObject.removeItem(COSName.getPDFName("PieceInfo"))
        }
        val after = File(args.out).length()
        return mapOf("before" to before, "after" to after, "images" to imagesProcessed)
    }

    private fun compressResources(
        doc: PDDocument, res: PDResources?, placement: Map<COSStream, Float>, done: MutableSet<COSStream>,
        dpi: Float, quality: Float, grayscale: Boolean, onImage: () -> Unit,
    ) {
        if (res == null) return
        for (name in res.xObjectNames.toList()) {
            val xo = try { res.getXObject(name) } catch (_: Exception) { null } ?: continue
            when (xo) {
                is PDFormXObject -> {
                    if (done.add(xo.cosObject)) {
                        flateIfUncompressed(xo.cosObject)
                        compressResources(doc, xo.resources, placement, done, dpi, quality, grayscale, onImage)
                    }
                }
                is PDImageXObject -> {
                    if (!done.add(xo.cosObject)) continue
                    val replaced = recompressImage(doc, xo, placement[xo.cosObject], dpi, quality, grayscale) ?: continue
                    res.put(name, replaced)
                    onImage()
                }
            }
        }
    }

    private fun recompressImage(
        doc: PDDocument, img: PDImageXObject, placedPt: Float?, dpi: Float, quality: Float, grayscale: Boolean,
    ): PDImageXObject? {
        if (img.isStencil || img.bitsPerComponent == 1) return null
        val w = img.width
        val h = img.height
        if (w * h < 64 * 64) return null
        val origSize = img.cosObject.length
        val longest = max(w, h).toFloat()
        val target = if (placedPt != null && placedPt > 0) placedPt / 72f * dpi else longest
        val scale = min(1f, target / longest)
        val outW = max(1, (w * scale).toInt())
        val outH = max(1, (h * scale).toInt())
        val sub = max(1, (1f / scale).toInt())
        var bmp: Bitmap = try { img.getImage(null, sub) } catch (_: Exception) { return null } ?: return null
        if (bmp.width != outW || bmp.height != outH) {
            val s = Bitmap.createScaledBitmap(bmp, outW, outH, true)
            if (s != bmp) bmp.recycle()
            bmp = s
        }
        if (grayscale) bmp = toGray(bmp)
        val hasAlpha = img.cosObject.getDictionaryObject(COSName.SMASK) != null
        val result = try {
            if (hasAlpha) {
                // Keep transparency: re-encode the color with JPEG and reuse the original soft mask.
                val opaque = Bitmap.createBitmap(bmp.width, bmp.height, Bitmap.Config.ARGB_8888)
                android.graphics.Canvas(opaque).apply { drawColor(android.graphics.Color.WHITE); drawBitmap(bmp, 0f, 0f, null) }
                val j = JPEGFactory.createFromImage(doc, opaque, quality)
                opaque.recycle()
                j.cosObject.setItem(COSName.SMASK, img.cosObject.getItem(COSName.SMASK))
                j
            } else {
                JPEGFactory.createFromImage(doc, bmp, quality)
            }
        } finally {
            bmp.recycle()
        }
        // Keep the original if re-encoding didn't help (e.g. already tight JPEG).
        return if (result.cosObject.length < origSize * 0.95) result else null
    }

    private fun toGray(src: Bitmap): Bitmap {
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(out)
        val p = android.graphics.Paint()
        p.colorFilter = android.graphics.ColorMatrixColorFilter(android.graphics.ColorMatrix().apply { setSaturation(0f) })
        c.drawBitmap(src, 0f, 0f, p)
        src.recycle()
        return out
    }

    private fun flateIfUncompressed(stream: COSStream) {
        if (stream.filters != null) return
        val data = stream.createRawInputStream().use { it.readBytes() }
        if (data.size < 512) return
        stream.createOutputStream(COSName.FLATE_DECODE).use { it.write(data) }
    }

    /** Flattens form fields and annotations into page content. */
    fun flatten(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val form = doc.documentCatalog.acroForm
            if (form != null) {
                try { form.refreshAppearances() } catch (_: Exception) {}
                form.flatten()
            }
            if (args["annotations"] != false) {
                for (page in doc.pages) AnnotOps.flattenPageAnnotations(doc, page)
            }
        }
    }
}

val Map<String, Any?>.path: String get() = this["path"] as String
val Map<String, Any?>.out: String get() = (this["out"] as String?) ?: path
val Map<String, Any?>.password: String? get() = (this["password"] as String?)?.ifEmpty { null }
