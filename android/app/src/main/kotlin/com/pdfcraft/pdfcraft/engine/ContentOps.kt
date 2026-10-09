package com.pdfcraft.pdfcraft.engine

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget
import com.tom_roush.pdfbox.util.Matrix
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** A visual text block (paragraph-ish) built from text operators, used by "Edit text". */
class TextBlock(val ops: List<TextOp>, val lines: List<TextLine>) {
    val rect: RectF get() = lines.map { it.rect }.reduce { a, b -> a.union(b) }
    val text: String get() = lines.joinToString("\n") { it.text }
    val size: Float get() = lines.first().size
    val color: Int get() = ops.first().color
    val fontName: String get() = ops.first().font.name ?: ""
    val leading: Float
        get() = if (lines.size < 2) size * 1.2f
        else (lines.last().baseline - lines.first().baseline) / (lines.size - 1)
}

class TextLine(val ops: MutableList<TextOp>, var text: String, var rect: RectF, val baseline: Float, val size: Float)

object ContentOps {

    // ---------------------------------------------------------------- text blocks

    fun buildTextBlocks(scan: PageScan): List<TextBlock> {
        val ops = scan.texts.filter { op ->
            !op.invisible && op.glyphs.isNotEmpty() && op.text.isNotBlank() && abs(op.angle) < 3f
        }.sortedWith(compareBy({ it.glyphs.first().baselineY }, { it.bounds!!.l }))
        // 1. lines
        val lines = ArrayList<TextLine>()
        for (op in ops) {
            val b = op.bounds!!
            val baseline = op.glyphs.first().baselineY
            val size = op.effectiveSize.coerceAtLeast(1f)
            val line = lines.lastOrNull { l ->
                abs(l.baseline - baseline) < l.size * 0.35f && abs(l.size - size) < l.size * 0.3f &&
                    b.l - l.rect.r < l.size * 2.5f && b.r > l.rect.l - l.size
            }
            if (line == null) {
                lines.add(TextLine(mutableListOf(op), op.text, b, baseline, size))
            } else {
                val gap = b.l - line.rect.r
                val sep = if (gap > line.size * 0.18f && !line.text.endsWith(" ") && !op.text.startsWith(" ")) " " else ""
                if (b.l >= line.rect.l) line.text += sep + op.text else line.text = op.text + sep + line.text
                line.ops.add(op)
                line.rect = line.rect.union(b)
            }
        }
        lines.sortWith(compareBy({ it.baseline }, { it.rect.l }))
        // 2. blocks: consecutive lines with similar size, aligned and close.
        val blocks = ArrayList<MutableList<TextLine>>()
        for (line in lines) {
            val block = blocks.lastOrNull { blk ->
                val last = blk.last()
                val gap = line.baseline - last.baseline
                abs(last.size - line.size) < last.size * 0.15f &&
                    gap > last.size * 0.5f && gap < last.size * 1.9f &&
                    line.rect.l < last.rect.r && line.rect.r > last.rect.l &&
                    abs(line.rect.l - blk.first().rect.l) < last.size * 3f
            }
            if (block == null) blocks.add(mutableListOf(line)) else block.add(line)
        }
        return blocks.map { blk -> TextBlock(blk.flatMap { it.ops }, blk) }
    }

    fun getTextBlocks(args: Map<String, Any?>): List<Map<String, Any?>> = PdfIO.read(args.path, args.password) { od ->
        val page = od.doc.getPage((args["page"] as Number).toInt())
        val blocks = buildTextBlocks(ContentScanner.scan(page))
        blocks.mapIndexed { i, b ->
            val fn = b.fontName.lowercase()
            mapOf(
                "id" to i,
                "text" to b.text,
                "rect" to b.rect.toList(),
                "fontSize" to b.size.toDouble(),
                "color" to b.color.toLong(),
                "bold" to (fn.contains("bold") || fn.contains("black") || fn.contains("heavy") || fn.contains("semibold")),
                "italic" to (fn.contains("italic") || fn.contains("oblique")),
                "serif" to isSerif(fn),
                "fontName" to b.fontName.substringAfter('+'),
                "leading" to b.leading.toDouble(),
                "lines" to b.lines.map { mapOf("text" to it.text, "rect" to it.rect.toList()) },
            )
        }
    }

    private fun isSerif(fn: String) = listOf("times", "serif", "georgia", "garamond", "cambria", "book", "minion", "roman", "palatino")
        .any { fn.contains(it) } && !fn.contains("sans")

    /**
     * Edits text blocks: the original glyphs are removed from the content stream and the
     * new text is written in the same place using an embedded font matching the style.
     * `edits`: [{id, text, fontSize?, color?, bold?, italic?, serif?, rect?}]
     */
    fun editTextBlocks(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val page = doc.getPage((args["page"] as Number).toInt())
            val scan = ContentScanner.scan(page)
            val blocks = buildTextBlocks(scan)
            val plan = RewritePlan()
            val edits = (args["edits"] as List<*>).map { it as Map<*, *> }
            val writes = ArrayList<TextWrite>()
            for (e in edits) {
                val block = blocks.getOrNull((e["id"] as Number).toInt()) ?: throw EngineException("ARGS", "Text block not found")
                block.ops.forEach { plan.removeAllGlyphs(it) }
                val text = e["text"] as String? ?: ""
                if (text.isEmpty()) continue
                val fn = block.fontName.lowercase()
                val bold = e["bold"] as Boolean? ?: (fn.contains("bold") || fn.contains("black") || fn.contains("semibold"))
                val italic = e["italic"] as Boolean? ?: (fn.contains("italic") || fn.contains("oblique"))
                val serif = e["serif"] as Boolean? ?: isSerif(fn)
                val size = (e["fontSize"] as Number?)?.toFloat() ?: block.size
                val color = (e["color"] as Number?)?.toLong()?.toInt() ?: block.color
                val rect = e["rect"]?.let { RectF.fromAny(it) } ?: block.rect
                val firstBaseline = if (e["rect"] != null) rect.t + size * 0.9f else block.lines.first().baseline
                val leading = if (block.lines.size > 1) block.leading else size * 1.25f
                val font = od.font(bold, italic, serif)
                // Let the box grow to the right until the next text block on the same band (or the
                // page margin) before wrapping — like Acrobat's text boxes, and safe for columns.
                val g = PageGeom(page)
                var rightLimit = g.width - max(18f, min(rect.l, 72f))
                for (other in blocks) {
                    if (other === block) continue
                    val o = other.rect
                    if (o.b > rect.t && o.t < rect.b && o.l >= rect.r - 1f) rightLimit = min(rightLimit, o.l - 6f)
                }
                val available = if (e["rect"] == null) rightLimit - rect.l else 0f
                writes.add(TextWrite(text, font, size, color, rect.l, firstBaseline, max(max(rect.width, size * 2), available), leading))
            }
            ContentRewriter.apply(doc, page, scan, plan)
            if (writes.isNotEmpty()) {
                PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
                    val g = PageGeom(page)
                    cs.transform(g.displayUpMatrix)
                    for (w in writes) drawText(cs, g, w)
                }
            }
        }
    }

    class TextWrite(
        val text: String, val font: PDFont, val size: Float, val color: Int,
        val x: Float, val baseline: Float, val maxWidth: Float, val leading: Float,
        val align: Int = 0,
    )

    /** Draws wrapped text in display coordinates (content stream already transformed to display-up space). */
    fun drawText(cs: PDPageContentStream, g: PageGeom, w: TextWrite) {
        val lines = wrap(w.font, w.size, sanitize(w.font, w.text), w.maxWidth)
        val c = colorComponents(w.color)
        cs.setNonStrokingColor(c[0], c[1], c[2])
        var y = w.baseline
        for (line in lines) {
            if (line.isNotEmpty()) {
                val lw = w.font.getStringWidth(line) / 1000f * w.size
                val dx = when (w.align) {
                    1 -> (w.maxWidth - lw) / 2
                    2 -> w.maxWidth - lw
                    else -> 0f
                }
                cs.beginText()
                cs.setFont(w.font, w.size)
                cs.newLineAtOffset(w.x + dx, g.height - y)
                cs.showText(line)
                cs.endText()
            }
            y += w.leading
        }
    }

    /** Replaces characters the font cannot encode. */
    fun sanitize(font: PDFont, text: String): String {
        val sb = StringBuilder()
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            val s = String(Character.toChars(cp))
            if (s == "\n" || s == "\t") sb.append(if (s == "\t") "    " else s)
            else if (cp < 32) {
                // skip control characters
            } else {
                val ok = try { font.encode(s); true } catch (_: Exception) { false }
                sb.append(if (ok) s else "?")
            }
            i += Character.charCount(cp)
        }
        return sb.toString()
    }

    fun wrap(font: PDFont, size: Float, text: String, maxWidth: Float): List<String> {
        val result = ArrayList<String>()
        fun width(s: String) = font.getStringWidth(s) / 1000f * size
        for (para in text.split("\n")) {
            if (para.isEmpty()) { result.add(""); continue }
            var line = StringBuilder()
            for (word in para.split(" ")) {
                val candidate = if (line.isEmpty()) word else "$line $word"
                if (width(candidate) <= maxWidth || line.isEmpty()) {
                    if (line.isEmpty() && width(word) > maxWidth) {
                        // Hard-break very long words.
                        var chunk = StringBuilder()
                        for (ch in word) {
                            if (width(chunk.toString() + ch) > maxWidth && chunk.isNotEmpty()) {
                                result.add(chunk.toString()); chunk = StringBuilder()
                            }
                            chunk.append(ch)
                        }
                        line = chunk
                    } else {
                        line = StringBuilder(candidate)
                    }
                } else {
                    result.add(line.toString())
                    line = StringBuilder(word)
                }
            }
            result.add(line.toString())
        }
        return result
    }

    // ---------------------------------------------------------------- images

    fun getImageObjects(args: Map<String, Any?>): List<Map<String, Any?>> = PdfIO.read(args.path, args.password) { od ->
        val page = od.doc.getPage((args["page"] as Number).toInt())
        val scan = ContentScanner.scan(page)
        scan.images.mapIndexed { i, img ->
            mapOf("id" to i, "rect" to img.box.toList(), "pw" to img.pixelWidth, "ph" to img.pixelHeight, "inline" to (img.name == null))
        }.filter { (it["rect"] as List<*>).let { r -> (r[2] as Double) - (r[0] as Double) > 4 && (r[3] as Double) - (r[1] as Double) > 4 } }
    }

    /** `action`: delete | move (rect) | replace (imagePath). */
    fun editImage(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val page = doc.getPage((args["page"] as Number).toInt())
            val scan = ContentScanner.scan(page)
            val img = scan.images.getOrNull((args["id"] as Number).toInt()) ?: throw EngineException("ARGS", "Image not found")
            val g = scan.geom
            val plan = RewritePlan()
            val key = img.unit to img.ordinal
            when (args["action"]) {
                "delete" -> plan.dropOps.add(key)
                "move", "replace" -> {
                    var name = img.name ?: throw EngineException("UNSUPPORTED", "Inline images can only be deleted")
                    val target = args["rect"]?.let { RectF.fromAny(it) } ?: img.box
                    var finalRect = target
                    if (args["action"] == "replace") {
                        val newImg = PDImageXObject.createFromFileByContent(File(args["imagePath"] as String), doc)
                        name = ContentRewriter.resourcesOf(page, scan, img.unit).add(newImg)
                        // Fit the new image inside the target box preserving aspect ratio.
                        val ar = newImg.width.toFloat() / newImg.height
                        val boxAr = target.width / target.height
                        finalRect = if (ar > boxAr) {
                            val h = target.width / ar
                            RectF(target.l, target.t + (target.height - h) / 2, target.r, target.t + (target.height + h) / 2)
                        } else {
                            val w = target.height * ar
                            RectF(target.l + (target.width - w) / 2, target.t, target.l + (target.width + w) / 2, target.b)
                        }
                    }
                    val newCtm = if (args["action"] == "replace") uprightCtm(g, finalRect)
                    else remapCtm(g, img.ctm, img.box, finalRect)
                    plan.replaceOps[key] = ContentRewriter.transformedDo(name, img.ctm, newCtm)
                }
                else -> throw EngineException("ARGS", "Unknown image action")
            }
            ContentRewriter.apply(doc, page, scan, plan)
        }
    }

    /** CTM mapping the image unit square upright onto a display rect. */
    fun uprightCtm(g: PageGeom, r: RectF): Matrix {
        val s = Matrix(r.width, 0f, 0f, r.height, r.l, g.height - r.b)
        return s.multiply(g.displayUpMatrix)
    }

    /** Re-maps an existing CTM so that its display box [from] becomes [to] (keeps rotation/flip). */
    fun remapCtm(g: PageGeom, ctm: Matrix, from: RectF, to: RectF): Matrix {
        val up = g.displayUpMatrix
        val upInv = ContentRewriter.invert(up)
        val sx = to.width / from.width
        val sy = to.height / from.height
        // In display-up space: x' = (x - from.l) * sx + to.l ; y' = (y - fromBottomUp) * sy + toBottomUp
        val fromB = g.height - from.b
        val toB = g.height - to.b
        val a = Matrix(sx, 0f, 0f, sy, to.l - from.l * sx, toB - fromB * sy)
        return ctm.multiply(upInv).multiply(a).multiply(up)
    }

    // ---------------------------------------------------------------- vector shapes

    private fun vectorPaths(scan: PageScan) = scan.paths.withIndex().filter { (_, p) ->
        !p.clipOnly && (p.box.width >= 3f || p.box.height >= 3f) &&
            // Ignore full-page backgrounds.
            !(p.box.width > scan.geom.width * 0.95f && p.box.height > scan.geom.height * 0.95f)
    }

    fun getVectorObjects(args: Map<String, Any?>): List<Map<String, Any?>> = PdfIO.read(args.path, args.password) { od ->
        val page = od.doc.getPage((args["page"] as Number).toInt())
        val scan = ContentScanner.scan(page)
        vectorPaths(scan).map { (i, p) ->
            mapOf(
                "id" to i, "rect" to p.box.toList(), "stroked" to p.stroked, "filled" to p.filled,
                "strokeColor" to p.strokeColor.toLong(), "fillColor" to p.fillColor.toLong(),
            )
        }
    }

    /**
     * Edits existing vector paths. `ids`: path ids from [getVectorObjects];
     * `action`: delete | transform (from rect → to rect, display space) | recolor (strokeColor?, fillColor?).
     */
    fun editVectors(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val page = doc.getPage((args["page"] as Number).toInt())
            val scan = ContentScanner.scan(page)
            val g = scan.geom
            val ids = (args["ids"] as List<*>).map { (it as Number).toInt() }
            val paths = ids.map { scan.paths.getOrNull(it) ?: throw EngineException("ARGS", "Shape not found") }
            val plan = RewritePlan()
            when (args["action"]) {
                "delete" -> paths.forEach { plan.noPaintOps.add(it.unit to it.ordinal) }
                "transform" -> {
                    val from = RectF.fromAny(args["from"])
                    val to = RectF.fromAny(args["to"])
                    val up = g.displayUpMatrix
                    val sx = if (from.width > 0.01f) to.width / from.width else 1f
                    val sy = if (from.height > 0.01f) to.height / from.height else 1f
                    val a = Matrix(sx, 0f, 0f, sy, to.l - from.l * sx, (g.height - to.b) - (g.height - from.b) * sy)
                    val t = ContentRewriter.invert(up).multiply(a).multiply(up)
                    for (p in paths) {
                        // c × X × CTM = c × CTM × T  ⇒  X = CTM × T × CTM⁻¹
                        val x = p.ctm.multiply(t).multiply(ContentRewriter.invert(p.ctm))
                        plan.insertBefore.getOrPut(p.unit to p.startOrdinal) { ArrayList() }.addAll(
                            listOf(
                                com.tom_roush.pdfbox.contentstream.operator.Operator.getOperator("q"),
                                com.tom_roush.pdfbox.cos.COSFloat(x.scaleX), com.tom_roush.pdfbox.cos.COSFloat(x.shearY),
                                com.tom_roush.pdfbox.cos.COSFloat(x.shearX), com.tom_roush.pdfbox.cos.COSFloat(x.scaleY),
                                com.tom_roush.pdfbox.cos.COSFloat(x.translateX), com.tom_roush.pdfbox.cos.COSFloat(x.translateY),
                                com.tom_roush.pdfbox.contentstream.operator.Operator.getOperator("cm"),
                            ),
                        )
                        plan.insertAfter.getOrPut(p.unit to p.ordinal) { ArrayList() }
                            .add(com.tom_roush.pdfbox.contentstream.operator.Operator.getOperator("Q"))
                    }
                }
                "recolor" -> {
                    val stroke = args["strokeColor"]?.let { colorComponents(parseColor(it)) }
                    val fill = args["fillColor"]?.let { colorComponents(parseColor(it)) }
                    for (p in paths) {
                        val tokens = ArrayList<Any>()
                        tokens.add(com.tom_roush.pdfbox.contentstream.operator.Operator.getOperator("q"))
                        if (stroke != null) {
                            stroke.forEach { tokens.add(com.tom_roush.pdfbox.cos.COSFloat(it)) }
                            tokens.add(com.tom_roush.pdfbox.contentstream.operator.Operator.getOperator("RG"))
                        }
                        if (fill != null) {
                            fill.forEach { tokens.add(com.tom_roush.pdfbox.cos.COSFloat(it)) }
                            tokens.add(com.tom_roush.pdfbox.contentstream.operator.Operator.getOperator("rg"))
                        }
                        plan.insertBefore.getOrPut(p.unit to p.startOrdinal) { ArrayList() }.addAll(tokens)
                        plan.insertAfter.getOrPut(p.unit to p.ordinal) { ArrayList() }
                            .add(com.tom_roush.pdfbox.contentstream.operator.Operator.getOperator("Q"))
                    }
                }
                else -> throw EngineException("ARGS", "Unknown shape action")
            }
            ContentRewriter.apply(doc, page, scan, plan)
        }
    }

    // ---------------------------------------------------------------- add content

    /**
     * Adds permanent page content. items: [{type: text|image|rect|ellipse|line|arrow, page, ...}]
     * Coordinates are display space.
     */
    fun addContent(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val items = (args["items"] as List<*>).map { it as Map<*, *> }
            for ((pageIndex, pageItems) in items.groupBy { (it["page"] as Number).toInt() }) {
                val page = doc.getPage(pageIndex)
                val g = PageGeom(page)
                PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
                    cs.transform(g.displayUpMatrix)
                    for (item in pageItems) drawItem(od, doc, cs, g, item)
                }
            }
        }
    }

    fun drawItem(od: OpenedDoc, doc: PDDocument, cs: PDPageContentStream, g: PageGeom, item: Map<*, *>) {
        val opacity = (item["opacity"] as Number?)?.toFloat() ?: 1f
        cs.saveGraphicsState()
        if (opacity < 1f) {
            val gs = PDExtendedGraphicsState()
            gs.nonStrokingAlphaConstant = opacity
            gs.strokingAlphaConstant = opacity
            cs.setGraphicsStateParameters(gs)
        }
        when (item["type"]) {
            "text" -> {
                val size = (item["fontSize"] as Number?)?.toFloat() ?: 12f
                val font = od.font(item["bold"] == true, item["italic"] == true, item["serif"] == true)
                val x = (item["x"] as Number).toFloat()
                val y = (item["y"] as Number).toFloat()
                val width = (item["width"] as Number?)?.toFloat() ?: (g.width - x - 10f)
                drawText(
                    cs, g,
                    TextWrite(
                        item["text"] as String, font, size, parseColor(item["color"]), x, y + size * 0.88f,
                        max(width, size), size * ((item["lineHeight"] as Number?)?.toFloat() ?: 1.25f),
                        align = (item["align"] as Number?)?.toInt() ?: 0,
                    ),
                )
            }
            "image" -> {
                val r = RectF.fromAny(item["rect"])
                val img = PDImageXObject.createFromFileByContent(File(item["imagePath"] as String), doc)
                cs.drawImage(img, r.l, g.height - r.b, r.width, r.height)
            }
            "rect", "ellipse" -> {
                val r = RectF.fromAny(item["rect"])
                applyStroke(cs, item)
                val y = g.height - r.b
                if (item["type"] == "rect") cs.addRect(r.l, y, r.width, r.height)
                else ellipsePath(cs, r.l, y, r.width, r.height)
                paint(cs, item)
            }
            "line", "arrow" -> {
                val p = (item["points"] as List<*>).map { (it as Number).toFloat() }
                applyStroke(cs, item)
                cs.moveTo(p[0], g.height - p[1])
                cs.lineTo(p[2], g.height - p[3])
                cs.stroke()
                if (item["type"] == "arrow") {
                    val w = (item["strokeWidth"] as Number?)?.toFloat() ?: 2f
                    arrowHead(cs, p[0], g.height - p[1], p[2], g.height - p[3], max(8f, w * 4))
                }
            }
        }
        cs.restoreGraphicsState()
    }

    private fun applyStroke(cs: PDPageContentStream, item: Map<*, *>) {
        val sc = colorComponents(parseColor(item["strokeColor"] ?: item["color"]))
        cs.setStrokingColor(sc[0], sc[1], sc[2])
        cs.setLineWidth((item["strokeWidth"] as Number?)?.toFloat() ?: 2f)
        item["fillColor"]?.let {
            val fc = colorComponents(parseColor(it))
            cs.setNonStrokingColor(fc[0], fc[1], fc[2])
        }
    }

    private fun paint(cs: PDPageContentStream, item: Map<*, *>) {
        val hasFill = item["fillColor"] != null
        val hasStroke = ((item["strokeWidth"] as Number?)?.toFloat() ?: 2f) > 0f
        when {
            hasFill && hasStroke -> cs.fillAndStroke()
            hasFill -> cs.fill()
            else -> cs.stroke()
        }
    }

    fun ellipsePath(cs: PDPageContentStream, x: Float, y: Float, w: Float, h: Float) {
        val k = 0.552284749831f
        val cx = x + w / 2; val cy = y + h / 2
        val rx = w / 2; val ry = h / 2
        cs.moveTo(cx + rx, cy)
        cs.curveTo(cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry)
        cs.curveTo(cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy)
        cs.curveTo(cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry)
        cs.curveTo(cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy)
        cs.closePath()
    }

    fun arrowHead(cs: PDPageContentStream, x1: Float, y1: Float, x2: Float, y2: Float, len: Float) {
        val ang = kotlin.math.atan2((y2 - y1).toDouble(), (x2 - x1).toDouble())
        val a1 = ang + Math.PI * 5 / 6
        val a2 = ang - Math.PI * 5 / 6
        cs.moveTo((x2 + len * kotlin.math.cos(a1)).toFloat(), (y2 + len * kotlin.math.sin(a1)).toFloat())
        cs.lineTo(x2, y2)
        cs.lineTo((x2 + len * kotlin.math.cos(a2)).toFloat(), (y2 + len * kotlin.math.sin(a2)).toFloat())
        cs.stroke()
    }

    // ---------------------------------------------------------------- redaction

    /**
     * True redaction: removes glyphs, image pixels, vector paths and annotations under the
     * given areas from the file, then paints opaque boxes. `areas`: [{page, rects: [[l,t,r,b]...]}]
     */
    fun redact(args: Map<String, Any?>): Map<String, Any?> {
        var glyphs = 0
        var images = 0
        var paths = 0
        var annots = 0
        val fill = parseColor(args["fillColor"], 0xFF000000.toInt())
        val overlay = args["overlayText"] as String?
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val areas = (args["areas"] as List<*>).map { it as Map<*, *> }
            for ((pageIndex, entries) in areas.groupBy { (it["page"] as Number).toInt() }) {
                val page = doc.getPage(pageIndex)
                val rects = entries.flatMap { e -> (e["rects"] as List<*>).map { RectF.fromAny(it) } }
                if (rects.isEmpty()) continue
                val scan = ContentScanner.scan(page)
                val plan = RewritePlan()
                for (op in scan.texts) {
                    for ((i, gl) in op.glyphs.withIndex()) {
                        val b = gl.box
                        val cx = (b.l + b.r) / 2; val cy = (b.t + b.b) / 2
                        val hit = rects.any { r ->
                            r.contains(cx, cy) || (b.area > 0 && r.intersectionArea(b) / b.area > 0.2f)
                        }
                        if (hit) { plan.removeGlyph(op, i); glyphs++ }
                    }
                }
                for (img in scan.images) {
                    val hits = rects.filter { it.intersects(img.box) }
                    if (hits.isEmpty()) continue
                    images++
                    val key = img.unit to img.ordinal
                    val covered = hits.any { it.l <= img.box.l && it.t <= img.box.t && it.r >= img.box.r && it.b >= img.box.b }
                    if (covered || img.name == null || img.stream == null) { plan.dropOps.add(key); continue }
                    val replacement = redactImage(doc, scan.geom, img, hits)
                    if (replacement == null) plan.dropOps.add(key)
                    else plan.renameXObject[key] = ContentRewriter.resourcesOf(page, scan, img.unit).add(replacement)
                }
                for (p in scan.paths) {
                    if (p.clipOnly) continue
                    val inside = rects.any { r -> r.l <= p.box.l + 0.5f && r.t <= p.box.t + 0.5f && r.r >= p.box.r - 0.5f && r.b >= p.box.b - 0.5f }
                    if (inside) { plan.noPaintOps.add(p.unit to p.ordinal); paths++ }
                }
                ContentRewriter.apply(doc, page, scan, plan)
                // Annotations / widgets overlapping the areas are removed entirely.
                val g = scan.geom
                val keep = page.annotations.filter { a ->
                    val r = a.rectangle ?: return@filter true
                    val d = g.rectToDisplay(r)
                    val box = RectF(d[0], d[1], d[2], d[3])
                    val hit = rects.any { it.intersects(box) }
                    if (hit) {
                        annots++
                        if (a is PDAnnotationWidget) removeWidgetField(doc, a)
                    }
                    !hit
                }
                page.annotations = keep
                // Paint the redaction marks.
                PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
                    cs.transform(g.displayUpMatrix)
                    val c = colorComponents(fill)
                    cs.setNonStrokingColor(c[0], c[1], c[2])
                    for (r in rects) cs.addRect(r.l, g.height - r.b, r.width, r.height)
                    cs.fill()
                    if (!overlay.isNullOrBlank()) {
                        val font = od.font(bold = true)
                        val lum = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2]
                        for (r in rects) {
                            val size = min(r.height * 0.6f, 12f)
                            if (size < 4f) continue
                            val text = sanitize(font, overlay)
                            val tw = font.getStringWidth(text) / 1000f * size
                            if (tw > r.width) continue
                            cs.beginText()
                            cs.setFont(font, size)
                            if (lum < 0.5f) cs.setNonStrokingColor(1f, 1f, 1f) else cs.setNonStrokingColor(0f, 0f, 0f)
                            cs.newLineAtOffset(r.l + (r.width - tw) / 2, g.height - r.b + (r.height - size * 0.7f) / 2)
                            cs.showText(text)
                            cs.endText()
                        }
                        cs.setNonStrokingColor(c[0], c[1], c[2])
                    }
                }
            }
            if (args["removeMetadata"] == true) {
                od.doc.documentCatalog.metadata = null
                od.doc.documentInformation = com.tom_roush.pdfbox.pdmodel.PDDocumentInformation()
            }
        }
        return mapOf("glyphs" to glyphs, "images" to images, "paths" to paths, "annotations" to annots)
    }

    private fun removeWidgetField(doc: PDDocument, widget: PDAnnotationWidget) {
        val form = doc.documentCatalog.acroForm ?: return
        val fields = form.fields.toMutableList()
        val target = form.fieldTree.firstOrNull { f -> f.widgets.any { it.cosObject == widget.cosObject } } ?: return
        if (fields.remove(target)) form.fields = fields
        else target.parent?.let { parent ->
            val kids = parent.children.toMutableList()
            if (kids.remove(target)) parent.children = kids
        }
    }

    /** Paints the redacted regions into a copy of the image's pixels. */
    private fun redactImage(doc: PDDocument, g: PageGeom, img: ImageOp, rects: List<RectF>): PDImageXObject? {
        val xobj = try { PDImageXObject(com.tom_roush.pdfbox.pdmodel.common.PDStream(img.stream), null) } catch (_: Exception) { return null }
        val bmp = try { xobj.image } catch (_: Exception) { null } ?: return null
        val mutable = if (bmp.isMutable && bmp.config == Bitmap.Config.ARGB_8888) bmp else bmp.copy(Bitmap.Config.ARGB_8888, true).also { bmp.recycle() }
        val canvas = Canvas(mutable)
        val paint = Paint().apply { color = Color.BLACK; style = Paint.Style.FILL; isAntiAlias = false }
        val inv = ContentRewriter.invert(img.ctm)
        val w = mutable.width.toFloat()
        val h = mutable.height.toFloat()
        for (r in rects) {
            val path = android.graphics.Path()
            val corners = listOf(r.l to r.t, r.r to r.t, r.r to r.b, r.l to r.b)
            for ((i, c) in corners.withIndex()) {
                val u = g.toUser(c.first, c.second)
                val unit = inv.mapPoint(u[0], u[1])
                val px = unit[0] * w
                val py = (1f - unit[1]) * h
                if (i == 0) path.moveTo(px, py) else path.lineTo(px, py)
            }
            path.close()
            canvas.drawPath(path, paint)
            // Also cover a 1px margin to defeat antialiasing remnants.
            paint.style = Paint.Style.STROKE; paint.strokeWidth = 2f
            canvas.drawPath(path, paint)
            paint.style = Paint.Style.FILL
        }
        val isJpeg = xobj.suffix == "jpg"
        val out = if (isJpeg) JPEGFactory.createFromImage(doc, mutable, 0.9f) else LosslessFactory.createFromImage(doc, mutable)
        mutable.recycle()
        return out
    }
}
