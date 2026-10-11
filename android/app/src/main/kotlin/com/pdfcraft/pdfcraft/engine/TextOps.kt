package com.pdfcraft.pdfcraft.engine

import android.graphics.Bitmap
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDCheckBox
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDChoice
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDRadioButton
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDTerminalField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDTextField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDVariableText
import com.tom_roush.pdfbox.pdmodel.common.PDStream
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.graphics.state.RenderingMode
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Positioned text/image extraction (for smart reading mode) and OCR text layers. */
object TextOps {

    /** 'serif' | 'sans' | 'mono' from font flags and name. */
    private fun familyOf(font: PDFont): String {
        val name = (font.name ?: "").lowercase()
        val d = font.fontDescriptor
        if (d?.isFixedPitch == true || listOf("mono", "courier", "consol", "menlo", "code").any { name.contains(it) }) return "mono"
        if (name.contains("sans") || listOf("arial", "helvetica", "verdana", "calibri", "segoe", "roboto", "inter", "lato", "open").any { name.contains(it) }) return "sans"
        if (d?.isSerif == true || listOf("times", "serif", "georgia", "garamond", "cambria", "minion", "palatino", "book", "roman").any { name.contains(it) }) return "serif"
        return "sans"
    }

    private fun styleOf(font: PDFont): Pair<Boolean, Boolean> {
        val name = (font.name ?: "").lowercase()
        val d = font.fontDescriptor
        val bold = name.contains("bold") || name.contains("black") || name.contains("heavy") || name.contains("semibold") ||
            (d != null && (d.isForceBold || d.fontWeight >= 600f))
        val italic = name.contains("italic") || name.contains("oblique") ||
            (d != null && (d.isItalic || abs(d.italicAngle) > 0.5f))
        return bold to italic
    }

    /**
     * The document of the last [extractPages] call. Smart reading extracts a
     * document in many small batches; re-parsing the file for each one is a
     * large part of its loading time. Closed after a short idle period, and
     * reloaded when the file changes.
     */
    private class CachedDoc(val key: List<Any?>, val od: OpenedDoc)

    private val cacheLock = Any()
    private var cached: CachedDoc? = null
    private var closeTask: ScheduledFuture<*>? = null
    private val scheduler = Executors.newSingleThreadScheduledExecutor()

    private fun <T> readCached(path: String, password: String?, block: (OpenedDoc) -> T): T = synchronized(cacheLock) {
        closeTask?.cancel(false)
        val file = File(path)
        val key = listOf(file.absolutePath, file.lastModified(), file.length(), password)
        val entry = cached?.takeIf { it.key == key } ?: run {
            cached?.od?.close()
            cached = null
            CachedDoc(key, PdfIO.load(path, password)).also { cached = it }
        }
        try {
            block(entry.od)
        } finally {
            closeTask = scheduler.schedule({
                synchronized(cacheLock) {
                    if (cached === entry) {
                        entry.od.close()
                        cached = null
                    }
                }
            }, 20, TimeUnit.SECONDS)
        }
    }

    /** Returns RawPageContent maps for the requested pages (0-based). */
    fun extractPages(args: Map<String, Any?>): List<Map<String, Any?>> = readCached(args.path, args.password) { od ->
        val doc = od.doc
        val pages = (args["pages"] as List<*>?)?.map { (it as Number).toInt() } ?: (0 until doc.numberOfPages).toList()
        val withImages = args["images"] != false
        val fields = fieldsByWidget(doc)
        pages.filter { it in 0 until doc.numberOfPages }.map { pi ->
            val page = doc.getPage(pi)
            val scan = try { ContentScanner.scan(page) } catch (_: Exception) { null }
            val g = PageGeom(page)
            val links = try {
                page.annotations.filterIsInstance<com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationLink>().mapNotNull { l ->
                    val uri = (l.action as? com.tom_roush.pdfbox.pdmodel.interactive.action.PDActionURI)?.uri ?: return@mapNotNull null
                    val r = g.rectToDisplay(l.rectangle ?: return@mapNotNull null)
                    RectF(r[0], r[1], r[2], r[3]) to uri
                }
            } catch (_: Exception) { emptyList() }
            mapOf(
                "page" to pi + 1,
                "width" to g.width.toDouble(),
                "height" to g.height.toDouble(),
                "lines" to (scan?.let { buildLines(it, links, fieldTexts(page, g, fields)) } ?: emptyList()),
                "images" to if (withImages && scan != null) extractImages(scan) else emptyList<Any>(),
            )
        }
    }

    private class SpanBuilder(
        val size: Float, val bold: Boolean, val italic: Boolean, val font: String, var x0: Float,
        val color: Int, val family: String,
    ) {
        val text = StringBuilder()
        var x1 = x0
        var underline = false
        var strike = false
        var link: String? = null
        fun same(o: SpanBuilder) = bold == o.bold && italic == o.italic && color == o.color && family == o.family &&
            abs(size - o.size) <= 0.5f && underline == o.underline && strike == o.strike && link == o.link
    }

    private class LineBuilder(val baseline: Float, val size: Float) {
        val spans = ArrayList<SpanBuilder>()
        var x0 = Float.MAX_VALUE; var y0 = Float.MAX_VALUE; var x1 = -Float.MAX_VALUE; var y1 = -Float.MAX_VALUE
        fun toMap() = mapOf(
            "spans" to spans.filter { it.text.isNotEmpty() }.map {
                val rgb = it.color and 0xFFFFFF
                // Near-black ink is treated as the default text color.
                val r = (rgb shr 16) and 0xFF; val gg = (rgb shr 8) and 0xFF; val b = rgb and 0xFF
                val isDefault = r < 40 && gg < 40 && b < 40
                mapOf(
                    "text" to it.text.toString(), "size" to it.size.toDouble(), "bold" to it.bold,
                    "italic" to it.italic, "font" to it.font, "x0" to it.x0.toDouble(), "x1" to it.x1.toDouble(),
                    "color" to if (isDefault) null else (0xFF000000.toInt() or rgb).toLong(),
                    "family" to it.family, "underline" to it.underline, "strike" to it.strike, "link" to it.link,
                )
            },
            "x0" to x0.toDouble(), "y0" to y0.toDouble(), "x1" to x1.toDouble(), "y1" to y1.toDouble(),
        )
    }

    /** Terminal form fields by the dictionary of each of their widgets. */
    private fun fieldsByWidget(doc: PDDocument): Map<COSDictionary, PDTerminalField> {
        val form = try { doc.documentCatalog.acroForm } catch (_: Exception) { null } ?: return emptyMap()
        val out = HashMap<COSDictionary, PDTerminalField>()
        try {
            for (f in form.fieldTree) if (f is PDTerminalField) for (w in f.widgets) out[w.cosObject] = f
        } catch (_: Exception) {}
        return out
    }

    /** A form field's value, placed where its widget is (display coordinates). */
    private class FieldText(val box: RectF, val text: String, val size: Float)

    /**
     * Values typed into the form fields on [page]. They live in widget
     * annotations, not the page content, so the content scan doesn't see them.
     */
    private fun fieldTexts(page: PDPage, g: PageGeom, fields: Map<COSDictionary, PDTerminalField>): List<FieldText> {
        if (fields.isEmpty()) return emptyList()
        val out = ArrayList<FieldText>()
        val widgets = try { page.annotations.filterIsInstance<PDAnnotationWidget>() } catch (_: Exception) { emptyList() }
        for (w in widgets) {
            try {
                val f = fields[w.cosObject] ?: continue
                if (w.isHidden || w.isNoView) continue
                val r = g.rectToDisplay(w.rectangle ?: continue)
                val box = RectF(r[0], r[1], r[2], r[3])
                val onState = w.appearance?.normalAppearance?.takeIf { it.isSubDictionary }
                    ?.subDictionary?.keys?.map { it.name }?.firstOrNull { it != "Off" }
                val text = when (f) {
                    is PDTextField -> if (f.isPassword) null else f.value
                    is PDCheckBox -> if (w.appearanceState?.name?.let { it != "Off" } ?: f.isChecked) "☑" else "☐"
                    is PDRadioButton -> if (onState != null && f.valueAsString == onState) "◉" else "○"
                    is PDChoice -> f.value.joinToString(", ")
                    else -> null
                }?.trim()
                if (text.isNullOrEmpty()) continue
                val da = (f as? PDVariableText)?.defaultAppearance ?: ""
                val daSize = Regex("([0-9.]+)\\s+Tf").find(da)?.groupValues?.get(1)?.toFloatOrNull() ?: 0f
                // 0 means "auto size": fit the box, as viewers do.
                val size = if (daSize > 0f) daSize else min(box.height * 0.7f, 12f).coerceAtLeast(6f)
                out.add(FieldText(box, text, size))
            } catch (_: Exception) {}
        }
        return out
    }

    /**
     * Adds form field values to [lines]: onto the line beside the field (e.g.
     * "Name:"), or as lines of their own. The analyzer orders spans by x and
     * lines by y, so they only need the right position.
     */
    private fun addFieldTexts(lines: MutableList<LineBuilder>, fields: List<FieldText>) {
        for (f in fields) {
            val parts = f.text.split(Regex("\r\n|\r|\n")).map { it.trim() }.filter { it.isNotEmpty() }
            val single = parts.size == 1
            for ((k, part) in parts.withIndex()) {
                val baseline = if (single) (f.box.t + f.box.b) / 2 + f.size * 0.35f else f.box.t + f.size * (k + 1) * 1.15f
                val beside = lines.filter { abs(it.baseline - baseline) < max(it.size, f.size) * 0.6f }
                    .minByOrNull { abs(it.baseline - baseline) }
                val size = beside?.size ?: f.size
                val x0 = f.box.l + 2f
                val x1 = min(f.box.r, x0 + part.length * size * 0.5f).coerceAtLeast(x0 + size * 0.5f)
                val line = beside ?: LineBuilder(baseline, size).also { lines.add(it) }
                line.spans.add(SpanBuilder(size, false, false, "", x0, 0xFF000000.toInt(), "sans").apply {
                    text.append(part)
                    this.x1 = x1
                })
                line.x0 = min(line.x0, x0); line.x1 = max(line.x1, x1)
                line.y0 = min(line.y0, baseline - size * 0.8f); line.y1 = max(line.y1, baseline + size * 0.2f)
            }
        }
    }

    private fun buildLines(
        scan: PageScan,
        links: List<Pair<RectF, String>> = emptyList(),
        fields: List<FieldText> = emptyList(),
    ): List<Map<String, Any?>> {
        val lines = ArrayList<LineBuilder>()
        // Thin painted paths (underline / strikethrough candidates).
        val thin = scan.paths.filter { !it.clipOnly && it.box.height <= 2.5f && it.box.width > 2f }
        var line: LineBuilder? = null
        for (op in scan.texts) {
            if (abs(op.angle) > 3f) continue
            val (bold, italic) = styleOf(op.font)
            val size = (op.effectiveSize * 10).toInt() / 10f
            val fontName = (op.font.name ?: "").substringAfter('+')
            val family = familyOf(op.font)
            val color = op.color
            for (gl in op.glyphs) {
                val u = gl.unicode ?: continue
                if (u.isEmpty()) continue
                val b = gl.box
                var cur = line
                val sameLine = cur != null && abs(gl.baselineY - cur.baseline) < max(cur.size, size) * 0.45f &&
                    b.l >= cur.x1 - max(cur.size, size) * 0.6f
                if (!sameLine) {
                    cur = LineBuilder(gl.baselineY, size)
                    lines.add(cur)
                    line = cur
                }
                cur!!
                val last = cur.spans.lastOrNull()
                val gap = if (last == null) 0f else b.l - last.x1
                val em = max(size, 1f)
                val isSpace = u.isBlank()
                val candidate = SpanBuilder(size, bold, italic, fontName, b.l, color, family)
                if (!isSpace) {
                    val gx = (b.l + b.r) / 2
                    for (p in thin) {
                        if (gx < p.box.l || gx > p.box.r || p.box.height > max(1.5f, size * 0.15f)) continue
                        val cy = (p.box.t + p.box.b) / 2
                        if (cy >= gl.baselineY - size * 0.05f && cy <= gl.baselineY + size * 0.22f) candidate.underline = true
                        else if (cy < gl.baselineY - size * 0.15f && cy > gl.baselineY - size * 0.6f) candidate.strike = true
                    }
                    if (links.isNotEmpty()) {
                        candidate.link = links.firstOrNull { (r, _) -> r.contains(gx, gl.baselineY - size * 0.3f) }?.second
                    }
                } else {
                    // Spaces inherit the current decoration so words don't split around them.
                    cur.spans.lastOrNull()?.let { candidate.underline = it.underline; candidate.strike = it.strike; candidate.link = it.link }
                }
                if (last != null && !isSpace && gap > em * 0.8f) {
                    // Big gap: new span (table cell / gutter)
                    cur.spans.add(candidate)
                } else if (last == null || !last.same(candidate)) {
                    if (last != null && gap > em * 0.15f && !last.text.endsWith(" ") && !isSpace) last.text.append(' ')
                    cur.spans.add(candidate)
                } else if (gap > em * 0.15f && !last.text.endsWith(" ") && !isSpace) {
                    last.text.append(' ')
                }
                val span = cur.spans.last()
                if (isSpace) {
                    if (!span.text.endsWith(" ") && span.text.isNotEmpty()) span.text.append(' ')
                } else {
                    span.text.append(u)
                    span.x1 = max(span.x1, b.r)
                    cur.x0 = min(cur.x0, b.l); cur.x1 = max(cur.x1, b.r)
                    cur.y0 = min(cur.y0, b.t); cur.y1 = max(cur.y1, b.b)
                }
            }
        }
        addFieldTexts(lines, fields)
        return lines.filter { l -> l.spans.any { it.text.isNotBlank() } }.map { l ->
            l.spans.forEach { s -> while (s.text.endsWith(" ")) s.text.setLength(s.text.length - 1) }
            l.toMap()
        }
    }

    private fun extractImages(scan: PageScan): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val seen = HashSet<Any>()
        for (img in scan.images) {
            val box = img.box
            if (box.width < 24 || box.height < 24) continue
            val stream = img.stream ?: continue
            if (!seen.add(stream to box)) continue
            val bmp = try {
                val x = PDImageXObject(PDStream(stream), null)
                val sub = max(1, max(x.width, x.height) / 1400)
                x.getImage(null, sub)
            } catch (_: Exception) { null } ?: continue
            val bytes = ByteArrayOutputStream().use { bos ->
                if (bmp.hasAlpha()) bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
                else bmp.compress(Bitmap.CompressFormat.JPEG, 85, bos)
                bos.toByteArray()
            }
            out.add(
                mapOf(
                    "x0" to box.l.toDouble(), "y0" to box.t.toDouble(), "x1" to box.r.toDouble(), "y1" to box.b.toDouble(),
                    "bytes" to bytes, "pw" to bmp.width, "ph" to bmp.height,
                ),
            )
            bmp.recycle()
            if (out.size >= 12) break
        }
        return out
    }

    /**
     * Adds an invisible OCR text layer. pages: [{page, words: [{text, rect:[l,t,r,b]}]}] in display space.
     */
    fun addOcrLayer(args: Map<String, Any?>): Int {
        var count = 0
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val font = od.font()
            for (p in (args["pages"] as List<*>)) {
                p as Map<*, *>
                val page = doc.getPage((p["page"] as Number).toInt())
                val g = PageGeom(page)
                val words = (p["words"] as List<*>).map { it as Map<*, *> }
                if (words.isEmpty()) continue
                PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
                    cs.transform(g.displayUpMatrix)
                    cs.beginText()
                    cs.setRenderingMode(RenderingMode.NEITHER)
                    for (w in words) {
                        val text = ContentOps.sanitize(font, (w["text"] as String).replace("\n", " ")).trim()
                        if (text.isEmpty()) continue
                        val r = RectF.fromAny(w["rect"])
                        val size = max(1f, r.height * 0.85f)
                        val natural = font.getStringWidth(text) / 1000f * size
                        if (natural <= 0f) continue
                        cs.setFont(font, size)
                        cs.setHorizontalScaling(r.width / natural * 100f)
                        // Absolute positioning via the text matrix.
                        cs.setTextMatrix(com.tom_roush.pdfbox.util.Matrix(1f, 0f, 0f, 1f, r.l, g.height - r.b + r.height * 0.2f))
                        cs.showText(text + " ")
                        count++
                    }
                    cs.endText()
                }
            }
        }
        return count
    }
}
