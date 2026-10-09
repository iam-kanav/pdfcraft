package com.pdfcraft.pdfcraft.engine

import com.tom_roush.pdfbox.contentstream.operator.Operator
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdfparser.PDFStreamParser
import com.tom_roush.pdfbox.pdfwriter.ContentStreamWriter
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDStream
import com.tom_roush.pdfbox.pdmodel.documentinterchange.markedcontent.PDPropertyList
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState
import com.tom_roush.pdfbox.util.Matrix
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Watermarks, page numbers, headers/footers — all tagged as pagination artifacts so they can be removed later. */
object Stamps {
    private val ARTIFACT = COSName.getPDFName("Artifact")

    private fun artifactProps(subtype: String): PDPropertyList {
        val d = COSDictionary()
        d.setItem(COSName.TYPE, COSName.getPDFName("Pagination"))
        d.setItem(COSName.SUBTYPE, COSName.getPDFName(subtype))
        d.setBoolean(COSName.getPDFName("PDFCraft"), true)
        return PDPropertyList.create(d)
    }

    private fun pagesArg(args: Map<String, Any?>, count: Int): List<Int> =
        (args["pages"] as List<*>?)?.map { (it as Number).toInt() }?.filter { it in 0 until count } ?: (0 until count).toList()

    /**
     * args: text | imagePath, fontSize, color, opacity, rotation, position (center|tile|top|bottom),
     * imageScale (fraction of page width), layer (over|under), pages.
     */
    fun watermark(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val text = (args["text"] as String?)?.ifBlank { null }
            val image = (args["imagePath"] as String?)?.let { PDImageXObject.createFromFileByContent(File(it), doc) }
            if (text == null && image == null) throw EngineException("ARGS", "Watermark needs text or an image")
            val fontSize = (args["fontSize"] as Number?)?.toFloat() ?: 48f
            val color = colorComponents(parseColor(args["color"], 0xFFE11D48.toInt()))
            val opacity = (args["opacity"] as Number?)?.toFloat() ?: 0.3f
            val rotation = (args["rotation"] as Number?)?.toFloat() ?: 45f
            val position = args["position"] as String? ?: "center"
            val under = args["layer"] == "under"
            val font = od.font(bold = args["bold"] != false)
            val safeText = text?.let { ContentOps.sanitize(font, it).replace("\n", " ") }
            for (i in pagesArg(args, doc.numberOfPages)) {
                val page = doc.getPage(i)
                val g = PageGeom(page)
                val mode = if (under) PDPageContentStream.AppendMode.PREPEND else PDPageContentStream.AppendMode.APPEND
                PDPageContentStream(doc, page, mode, true, !under).use { cs ->
                    cs.beginMarkedContent(ARTIFACT, artifactProps("Watermark"))
                    cs.saveGraphicsState()
                    cs.transform(g.displayUpMatrix)
                    val gs = PDExtendedGraphicsState()
                    gs.nonStrokingAlphaConstant = opacity
                    gs.strokingAlphaConstant = opacity
                    cs.setGraphicsStateParameters(gs)
                    val (w, h) = if (safeText != null) {
                        font.getStringWidth(safeText) / 1000f * fontSize to fontSize
                    } else {
                        val iw = g.width * ((args["imageScale"] as Number?)?.toFloat() ?: 0.5f)
                        iw to iw * image!!.height / image.width
                    }
                    val anchors = when (position) {
                        "tile" -> {
                            val stepX = max(w * 1.3f, 120f)
                            val stepY = max(h * 4f, 120f)
                            val list = ArrayList<Pair<Float, Float>>()
                            var y = stepY / 2
                            var row = 0
                            while (y < g.height + stepY) {
                                var x = if (row % 2 == 0) stepX / 2 else 0f
                                while (x < g.width + stepX) { list.add(x to y); x += stepX }
                                y += stepY; row++
                            }
                            list
                        }
                        "top" -> listOf(g.width / 2 to g.height - max(h, 30f) - 20f)
                        "bottom" -> listOf(g.width / 2 to max(h, 30f) + 20f)
                        else -> listOf(g.width / 2 to g.height / 2)
                    }
                    val rad = Math.toRadians(rotation.toDouble())
                    for ((cx, cy) in anchors) {
                        cs.saveGraphicsState()
                        val m = Matrix(cos(rad).toFloat(), sin(rad).toFloat(), -sin(rad).toFloat(), cos(rad).toFloat(), cx, cy)
                        cs.transform(m)
                        if (safeText != null) {
                            cs.setNonStrokingColor(color[0], color[1], color[2])
                            cs.beginText()
                            cs.setFont(font, fontSize)
                            cs.newLineAtOffset(-w / 2, -h * 0.35f)
                            cs.showText(safeText)
                            cs.endText()
                        } else {
                            cs.drawImage(image, -w / 2, -h / 2, w, h)
                        }
                        cs.restoreGraphicsState()
                    }
                    cs.restoreGraphicsState()
                    cs.endMarkedContent()
                }
            }
        }
    }

    /**
     * Page numbers / header & footer text.
     * args: format ("Page {n} of {N}"), position (top-left|top-center|top-right|bottom-left|bottom-center|bottom-right),
     * fontSize, color, startNumber, margin, pages (subset), kind (Footer|Header).
     */
    fun pageNumbers(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val format = args["format"] as String? ?: "{n}"
            val position = args["position"] as String? ?: "bottom-center"
            val size = (args["fontSize"] as Number?)?.toFloat() ?: 10f
            val color = colorComponents(parseColor(args["color"], 0xFF000000.toInt()))
            val start = (args["startNumber"] as Number?)?.toInt() ?: 1
            val margin = (args["margin"] as Number?)?.toFloat() ?: 28f
            val font = od.font()
            val pages = pagesArg(args, doc.numberOfPages)
            val total = pages.size + start - 1
            val kind = if (position.startsWith("top")) "Header" else "Footer"
            for ((n, i) in pages.withIndex()) {
                val page = doc.getPage(i)
                val g = PageGeom(page)
                val label = ContentOps.sanitize(
                    font,
                    format.replace("{n}", (start + n).toString()).replace("{N}", total.toString())
                        .replace("{p}", (i + 1).toString()).replace("{P}", doc.numberOfPages.toString()),
                )
                val tw = font.getStringWidth(label) / 1000f * size
                val x = when {
                    position.endsWith("left") -> margin
                    position.endsWith("right") -> g.width - margin - tw
                    else -> (g.width - tw) / 2
                }
                val y = if (position.startsWith("top")) g.height - margin - size * 0.8f else margin
                PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
                    cs.beginMarkedContent(ARTIFACT, artifactProps(kind))
                    cs.saveGraphicsState()
                    cs.transform(g.displayUpMatrix)
                    cs.setNonStrokingColor(color[0], color[1], color[2])
                    cs.beginText()
                    cs.setFont(font, size)
                    cs.newLineAtOffset(max(0f, x), y)
                    cs.showText(label)
                    cs.endText()
                    cs.restoreGraphicsState()
                    cs.endMarkedContent()
                }
            }
        }
    }

    /** Removes pagination artifacts (Watermark / Header / Footer) and watermark annotations. Returns removed count. */
    fun removeArtifacts(args: Map<String, Any?>): Int {
        val kinds = (args["kinds"] as List<*>?)?.map { it as String }?.toSet() ?: setOf("Watermark")
        var removed = 0
        PdfIO.edit(args.path, args.password, args.out) { od ->
            for (page in od.doc.pages) {
                val n = stripArtifacts(od.doc, page, kinds)
                removed += n
                if ("Watermark" in kinds) {
                    val annots = page.annotations
                    val keep = annots.filter { it.subtype != "Watermark" }
                    if (keep.size != annots.size) {
                        removed += annots.size - keep.size
                        page.annotations = keep
                    }
                }
            }
        }
        return removed
    }

    private fun stripArtifacts(doc: com.tom_roush.pdfbox.pdmodel.PDDocument, page: PDPage, kinds: Set<String>): Int {
        val tokens = PDFStreamParser(page).also { it.parse() }.tokens
        val out = ArrayList<Any>(tokens.size)
        val operands = ArrayList<COSBase>()
        var skipDepth = 0
        var removed = 0
        for (t in tokens) {
            if (t !is Operator) {
                if (skipDepth == 0) operands.add(t as COSBase)
                continue
            }
            val name = t.name
            if (skipDepth > 0) {
                if (name == "BMC" || name == "BDC") skipDepth++
                if (name == "EMC") skipDepth--
                operands.clear()
                continue
            }
            if (name == "BDC" && operands.size >= 2 && operands[0] == ARTIFACT) {
                val props = when (val p = operands[1]) {
                    is COSDictionary -> p
                    is COSName -> page.resources?.getProperties(p)?.cosObject
                    else -> null
                }
                val subtype = props?.getNameAsString(COSName.SUBTYPE)
                if (subtype != null && subtype in kinds) {
                    skipDepth = 1
                    removed++
                    operands.clear()
                    continue
                }
            }
            out.addAll(operands)
            out.add(t)
            operands.clear()
        }
        out.addAll(operands)
        if (removed > 0) {
            val bytes = ByteArrayOutputStream().also { ContentStreamWriter(it).writeTokens(out) }.toByteArray()
            val stream = PDStream(doc)
            stream.createOutputStream(COSName.FLATE_DECODE).use { it.write(bytes) }
            page.setContents(stream)
        }
        return removed
    }

}
