package com.pdfcraft.pdfcraft.engine

import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSFloat
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.blend.BlendMode
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDColor
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDDeviceRGB
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState
import com.tom_roush.pdfbox.pdmodel.interactive.action.PDActionGoTo
import com.tom_roush.pdfbox.pdmodel.interactive.action.PDActionURI
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotation
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationLine
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationLink
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationPopup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationSquareCircle
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationText
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceDictionary
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceStream
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDBorderStyleDictionary
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageFitDestination
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageDestination
import com.tom_roush.pdfbox.util.Matrix
import java.io.File
import java.util.Calendar
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Creation, listing, editing and flattening of annotations (comments, markup, drawings, links, stamps). */
object AnnotOps {

    fun add(args: Map<String, Any?>): List<String> {
        val ids = ArrayList<String>()
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            for (a in (args["annotations"] as List<*>)) {
                a as Map<*, *>
                val page = doc.getPage((a["page"] as Number).toInt())
                val annot = build(od, page, a)
                annot.setPage(page)
                val list = page.annotations
                list.add(annot)
                page.annotations = list
                ids.add(annot.annotationName)
            }
        }
        return ids
    }

    private fun rgb(argb: Int): PDColor = PDColor(colorComponents(argb), PDDeviceRGB.INSTANCE)

    private fun build(od: OpenedDoc, page: PDPage, a: Map<*, *>): PDAnnotation {
        val doc = od.doc
        val g = PageGeom(page)
        val type = a["type"] as String
        val color = parseColor(a["color"], 0xFFFFD400.toInt())
        val opacity = (a["opacity"] as Number?)?.toFloat() ?: 1f
        val width = (a["strokeWidth"] as Number?)?.toFloat() ?: 2f
        val annot: PDAnnotation = when (type) {
            "highlight", "underline", "strikeout", "squiggly" -> {
                val sub = when (type) {
                    "highlight" -> PDAnnotationTextMarkup.SUB_TYPE_HIGHLIGHT
                    "underline" -> PDAnnotationTextMarkup.SUB_TYPE_UNDERLINE
                    "strikeout" -> PDAnnotationTextMarkup.SUB_TYPE_STRIKEOUT
                    else -> PDAnnotationTextMarkup.SUB_TYPE_SQUIGGLY
                }
                val m = PDAnnotationTextMarkup(sub)
                val rects = (a["rects"] as List<*>).map { RectF.fromAny(it) }
                val quads = FloatArray(rects.size * 8)
                for ((i, r) in rects.withIndex()) {
                    // QuadPoints order: upper-left, upper-right, lower-left, lower-right (in user space).
                    val ul = g.toUser(r.l, r.t); val ur = g.toUser(r.r, r.t)
                    val ll = g.toUser(r.l, r.b); val lr = g.toUser(r.r, r.b)
                    floatArrayOf(ul[0], ul[1], ur[0], ur[1], ll[0], ll[1], lr[0], lr[1]).copyInto(quads, i * 8)
                }
                m.quadPoints = quads
                m.rectangle = boundsOf(quads.toList().chunked(2).map { floatArrayOf(it[0], it[1]) }, 1f)
                m.color = rgb(color)
                m.constantOpacity = opacity
                markupAppearance(doc, m, type, rects, g, color, opacity)
                m
            }
            "ink" -> {
                val m = PDAnnotationMarkup()
                m.cosObject.setName(COSName.SUBTYPE, "Ink")
                val paths = (a["paths"] as List<*>).map { p -> (p as List<*>).map { (it as Number).toFloat() } }
                val userPaths = paths.map { p ->
                    val out = FloatArray(p.size)
                    for (i in p.indices step 2) {
                        val u = g.toUser(p[i], p[i + 1]); out[i] = u[0]; out[i + 1] = u[1]
                    }
                    out
                }
                m.setInkList(userPaths.toTypedArray())
                m.rectangle = boundsOf(userPaths.flatMap { it.toList().chunked(2).map { c -> floatArrayOf(c[0], c[1]) } }, width + 2)
                m.color = rgb(color)
                m.constantOpacity = opacity
                m.setBorderStyle(PDBorderStyleDictionary().apply { this.width = width })
                inkAppearance(doc, m, userPaths, color, opacity, width)
                m
            }
            "square", "circle" -> {
                val m = PDAnnotationSquareCircle(if (type == "square") PDAnnotationSquareCircle.SUB_TYPE_SQUARE else PDAnnotationSquareCircle.SUB_TYPE_CIRCLE)
                val r = RectF.fromAny(a["rect"])
                val user = g.rectToUser(r.l - width / 2, r.t - width / 2, r.r + width / 2, r.b + width / 2)
                m.rectangle = user
                m.color = rgb(color)
                a["fillColor"]?.let { m.interiorColor = rgb(parseColor(it)) }
                m.constantOpacity = opacity
                m.setBorderStyle(PDBorderStyleDictionary().apply { this.width = width })
                shapeAppearance(doc, m, user, type, color, a["fillColor"]?.let { parseColor(it) }, opacity, width)
                m
            }
            "line", "arrow" -> {
                val m = PDAnnotationLine()
                val p = (a["points"] as List<*>).map { (it as Number).toFloat() }
                val s = g.toUser(p[0], p[1]); val e = g.toUser(p[2], p[3])
                m.line = floatArrayOf(s[0], s[1], e[0], e[1])
                if (type == "arrow") m.endPointEndingStyle = PDAnnotationLine.LE_OPEN_ARROW
                val pad = width * 5 + 2
                m.rectangle = boundsOf(listOf(s, e), pad)
                m.color = rgb(color)
                m.constantOpacity = opacity
                m.setBorderStyle(PDBorderStyleDictionary().apply { this.width = width })
                lineAppearance(doc, m, s, e, type == "arrow", color, opacity, width)
                m
            }
            "freetext" -> {
                val dict = COSDictionary()
                dict.setItem(COSName.TYPE, COSName.ANNOT)
                dict.setName(COSName.SUBTYPE, "FreeText")
                val m = PDAnnotationMarkup(dict)
                val r = RectF.fromAny(a["rect"])
                m.rectangle = g.rectToUser(r.l, r.t, r.r, r.b)
                val text = a["text"] as String? ?: ""
                m.contents = text
                val size = (a["fontSize"] as Number?)?.toFloat() ?: 14f
                val c = colorComponents(color)
                m.setDefaultAppearance("/Helv $size Tf ${c[0]} ${c[1]} ${c[2]} rg")
                m.constantOpacity = opacity
                val border = (a["borderWidth"] as Number?)?.toFloat() ?: 0f
                m.setBorderStyle(PDBorderStyleDictionary().apply { this.width = border })
                freeTextAppearance(od, m, g, r, text, size, color, a["fillColor"]?.let { parseColor(it) }, border, opacity)
                m
            }
            "note" -> {
                val m = PDAnnotationText()
                val x = (a["x"] as Number).toFloat(); val y = (a["y"] as Number).toFloat()
                m.rectangle = g.rectToUser(x, y, x + 22f, y + 22f)
                m.name = PDAnnotationText.NAME_COMMENT
                m.color = rgb(color)
                m.isNoZoom = true
                m.isNoRotate = true
                noteAppearance(doc, m, color)
                m
            }
            "stamp" -> {
                val dict = COSDictionary()
                dict.setItem(COSName.TYPE, COSName.ANNOT)
                dict.setName(COSName.SUBTYPE, "Stamp")
                val m = PDAnnotationMarkup(dict)
                val r = RectF.fromAny(a["rect"])
                m.rectangle = g.rectToUser(r.l, r.t, r.r, r.b)
                m.cosObject.setName(COSName.NAME, (a["name"] as String?) ?: "Signature")
                val img = PDImageXObject.createFromFileByContent(File(a["imagePath"] as String), doc)
                stampAppearance(doc, m, g, r, img, opacity)
                m
            }
            "link" -> {
                val m = PDAnnotationLink()
                val r = RectF.fromAny(a["rect"])
                m.rectangle = g.rectToUser(r.l, r.t, r.r, r.b)
                m.setBorderStyle(PDBorderStyleDictionary().apply { this.width = 0f })
                val url = a["url"] as String?
                if (url != null) {
                    m.action = PDActionURI().apply { uri = url }
                } else {
                    val target = doc.getPage((a["targetPage"] as Number).toInt())
                    val dest = PDPageFitDestination()
                    dest.page = target
                    m.destination = dest
                }
                m
            }
            else -> throw EngineException("ARGS", "Unknown annotation type $type")
        }
        if (annot is PDAnnotationMarkup) {
            (a["contents"] as String?)?.let { if (type != "freetext") annot.contents = it }
            annot.titlePopup = (a["author"] as String?) ?: "PDFCraft user"
            annot.creationDate = Calendar.getInstance()
        }
        annot.isPrinted = true
        annot.annotationName = (a["id"] as String?) ?: UUID.randomUUID().toString()
        annot.setModifiedDate(Calendar.getInstance())
        return annot
    }

    private fun boundsOf(points: List<FloatArray>, pad: Float): PDRectangle {
        val minX = points.minOf { it[0] } - pad; val minY = points.minOf { it[1] } - pad
        val maxX = points.maxOf { it[0] } + pad; val maxY = points.maxOf { it[1] } + pad
        return PDRectangle(minX, minY, maxX - minX, maxY - minY)
    }

    // ------------------------------------------------------------- appearance streams

    private fun newAppearance(doc: PDDocument, annot: PDAnnotation, bbox: PDRectangle, matrix: Matrix? = null): PDAppearanceStream {
        val ap = PDAppearanceStream(doc)
        ap.bBox = bbox
        ap.resources = PDResources()
        if (matrix != null) ap.setMatrix(matrix.createAffineTransform())
        val dict = PDAppearanceDictionary()
        dict.setNormalAppearance(ap)
        annot.appearance = dict
        return ap
    }

    private fun gsAlpha(cs: PDPageContentStream, opacity: Float, multiply: Boolean = false) {
        if (opacity >= 1f && !multiply) return
        val gs = PDExtendedGraphicsState()
        gs.nonStrokingAlphaConstant = opacity
        gs.strokingAlphaConstant = opacity
        if (multiply) gs.blendMode = BlendMode.MULTIPLY
        cs.setGraphicsStateParameters(gs)
    }

    private fun markupAppearance(doc: PDDocument, m: PDAnnotationTextMarkup, type: String, rects: List<RectF>, g: PageGeom, color: Int, opacity: Float) {
        val ap = newAppearance(doc, m, m.rectangle)
        val c = colorComponents(color)
        PDPageContentStream(doc, ap).use { cs ->
            gsAlpha(cs, opacity, multiply = type == "highlight")
            cs.setNonStrokingColor(c[0], c[1], c[2])
            cs.setStrokingColor(c[0], c[1], c[2])
            cs.transform(g.displayUpMatrix)
            for (r in rects) {
                val h = r.height
                val yb = g.height - r.b
                when (type) {
                    "highlight" -> { cs.addRect(r.l, yb, r.width, h); cs.fill() }
                    "underline" -> {
                        cs.setLineWidth(max(0.6f, h / 14f))
                        cs.moveTo(r.l, yb + h * 0.08f); cs.lineTo(r.r, yb + h * 0.08f); cs.stroke()
                    }
                    "strikeout" -> {
                        cs.setLineWidth(max(0.6f, h / 14f))
                        cs.moveTo(r.l, yb + h * 0.45f); cs.lineTo(r.r, yb + h * 0.45f); cs.stroke()
                    }
                    else -> {
                        cs.setLineWidth(max(0.5f, h / 18f))
                        val step = max(2f, h / 6f)
                        var x = r.l
                        var up = true
                        cs.moveTo(x, yb + h * 0.06f)
                        while (x < r.r) {
                            x = min(r.r, x + step)
                            cs.lineTo(x, yb + if (up) h * 0.14f else h * 0.02f)
                            up = !up
                        }
                        cs.stroke()
                    }
                }
            }
        }
    }

    private fun inkAppearance(doc: PDDocument, m: PDAnnotationMarkup, paths: List<FloatArray>, color: Int, opacity: Float, width: Float) {
        val ap = newAppearance(doc, m, m.rectangle)
        val c = colorComponents(color)
        PDPageContentStream(doc, ap).use { cs ->
            gsAlpha(cs, opacity)
            cs.setStrokingColor(c[0], c[1], c[2])
            cs.setLineWidth(width)
            cs.setLineCapStyle(1)
            cs.setLineJoinStyle(1)
            for (p in paths) {
                if (p.size < 2) continue
                cs.moveTo(p[0], p[1])
                if (p.size == 2) cs.lineTo(p[0] + 0.01f, p[1])
                // Smooth with quadratic midpoints rendered as cubic curves.
                var i = 2
                while (i + 3 < p.size) {
                    val mx = (p[i] + p[i + 2]) / 2; val my = (p[i + 1] + p[i + 3]) / 2
                    cs.curveTo(p[i], p[i + 1], p[i], p[i + 1], mx, my)
                    i += 2
                }
                if (i + 1 < p.size) cs.lineTo(p[p.size - 2], p[p.size - 1])
                cs.stroke()
            }
        }
    }

    private fun shapeAppearance(doc: PDDocument, m: PDAnnotation, user: PDRectangle, type: String, color: Int, fill: Int?, opacity: Float, width: Float) {
        val ap = newAppearance(doc, m, user)
        val c = colorComponents(color)
        PDPageContentStream(doc, ap).use { cs ->
            gsAlpha(cs, opacity)
            cs.setStrokingColor(c[0], c[1], c[2])
            cs.setLineWidth(width)
            if (fill != null) {
                val f = colorComponents(fill)
                cs.setNonStrokingColor(f[0], f[1], f[2])
            }
            val x = user.lowerLeftX + width / 2; val y = user.lowerLeftY + width / 2
            val w = user.width - width; val h = user.height - width
            if (type == "square") cs.addRect(x, y, w, h) else ContentOps.ellipsePath(cs, x, y, w, h)
            if (fill != null) cs.fillAndStroke() else cs.stroke()
        }
    }

    private fun lineAppearance(doc: PDDocument, m: PDAnnotation, s: FloatArray, e: FloatArray, arrow: Boolean, color: Int, opacity: Float, width: Float) {
        val ap = newAppearance(doc, m, m.rectangle)
        val c = colorComponents(color)
        PDPageContentStream(doc, ap).use { cs ->
            gsAlpha(cs, opacity)
            cs.setStrokingColor(c[0], c[1], c[2])
            cs.setLineWidth(width)
            cs.setLineCapStyle(1)
            cs.setLineJoinStyle(1)
            cs.moveTo(s[0], s[1]); cs.lineTo(e[0], e[1]); cs.stroke()
            if (arrow) ContentOps.arrowHead(cs, s[0], s[1], e[0], e[1], max(8f, width * 4))
        }
    }

    private fun freeTextAppearance(
        od: OpenedDoc, m: PDAnnotationMarkup, g: PageGeom, r: RectF, text: String, size: Float,
        color: Int, fill: Int?, border: Float, opacity: Float,
    ) {
        val doc = od.doc
        val ap = newAppearance(doc, m, PDRectangle(0f, 0f, r.width, r.height), g.rotationOnly)
        val font = od.font()
        PDPageContentStream(doc, ap).use { cs ->
            gsAlpha(cs, opacity)
            if (fill != null) {
                val f = colorComponents(fill)
                cs.setNonStrokingColor(f[0], f[1], f[2])
                cs.addRect(0f, 0f, r.width, r.height); cs.fill()
            }
            if (border > 0) {
                val c = colorComponents(color)
                cs.setStrokingColor(c[0], c[1], c[2])
                cs.setLineWidth(border)
                cs.addRect(border / 2, border / 2, r.width - border, r.height - border); cs.stroke()
            }
            val pad = 2f + border
            val lines = ContentOps.wrap(font, size, ContentOps.sanitize(font, text), r.width - pad * 2)
            val c = colorComponents(color)
            cs.setNonStrokingColor(c[0], c[1], c[2])
            var y = r.height - pad - size * 0.9f
            for (line in lines) {
                if (y < -size) break
                if (line.isNotEmpty()) {
                    cs.beginText(); cs.setFont(font, size); cs.newLineAtOffset(pad, y); cs.showText(line); cs.endText()
                }
                y -= size * 1.2f
            }
        }
    }

    private fun noteAppearance(doc: PDDocument, m: PDAnnotation, color: Int) {
        val rect = m.rectangle
        val ap = newAppearance(doc, m, PDRectangle(0f, 0f, rect.width, rect.height))
        val c = colorComponents(color)
        PDPageContentStream(doc, ap).use { cs ->
            val w = rect.width; val h = rect.height
            cs.setNonStrokingColor(c[0], c[1], c[2])
            cs.setStrokingColor(0.25f, 0.25f, 0.25f)
            cs.setLineWidth(0.8f)
            // Speech bubble
            cs.moveTo(2f, h - 2f); cs.lineTo(w - 2f, h - 2f); cs.lineTo(w - 2f, 7f)
            cs.lineTo(10f, 7f); cs.lineTo(5f, 1.5f); cs.lineTo(6f, 7f); cs.lineTo(2f, 7f); cs.closePath()
            cs.fillAndStroke()
            cs.setStrokingColor(0.2f, 0.2f, 0.2f)
            for (i in 0 until 3) {
                val y = h - 7f - i * 4f
                cs.moveTo(5.5f, y); cs.lineTo(w - 5.5f, y); cs.stroke()
            }
        }
    }

    private fun stampAppearance(doc: PDDocument, m: PDAnnotation, g: PageGeom, r: RectF, img: PDImageXObject, opacity: Float) {
        val ap = newAppearance(doc, m, PDRectangle(0f, 0f, r.width, r.height), g.rotationOnly)
        PDPageContentStream(doc, ap).use { cs ->
            gsAlpha(cs, opacity)
            cs.drawImage(img, 0f, 0f, r.width, r.height)
        }
    }

    // ------------------------------------------------------------- list / delete / update

    private fun idOf(a: PDAnnotation, pageIndex: Int, index: Int): String =
        a.annotationName?.ifEmpty { null } ?: "p$pageIndex#$index"

    fun list(args: Map<String, Any?>): List<Map<String, Any?>> = PdfIO.read(args.path, args.password) { od ->
        val result = ArrayList<Map<String, Any?>>()
        val only = (args["page"] as Number?)?.toInt()
        for ((pi, page) in od.doc.pages.withIndex()) {
            if (only != null && pi != only) continue
            val g = PageGeom(page)
            for ((i, a) in page.annotations.withIndex()) {
                if (a is PDAnnotationWidget || a is PDAnnotationPopup) continue
                val r = a.rectangle ?: continue
                val d = g.rectToDisplay(r)
                val color = try { a.color?.toRGB() } catch (_: Exception) { null }
                val map = HashMap<String, Any?>()
                map["id"] = idOf(a, pi, i)
                map["page"] = pi
                map["type"] = a.subtype
                map["rect"] = d.map { it.toDouble() }
                map["contents"] = a.contents
                map["color"] = color?.let { (it or 0xFF000000.toInt()).toLong() }
                map["modified"] = a.modifiedDate
                if (a is PDAnnotationMarkup) {
                    map["author"] = a.titlePopup
                    map["opacity"] = a.constantOpacity.toDouble()
                    map["subject"] = a.subject
                }
                if (a is PDAnnotationLink) {
                    val act = try { a.action } catch (_: Exception) { null }
                    if (act is PDActionURI) map["url"] = act.uri
                    val dest = try { a.destination ?: (act as? PDActionGoTo)?.destination } catch (_: Exception) { null }
                    if (dest is PDPageDestination) {
                        val p = dest.page
                        map["targetPage"] = if (p != null) od.doc.pages.indexOf(p) else dest.pageNumber
                    }
                }
                result.add(map)
            }
        }
        result
    }

    private fun find(doc: PDDocument, pageIndex: Int, id: String): Pair<PDPage, PDAnnotation>? {
        val page = doc.getPage(pageIndex)
        for ((i, a) in page.annotations.withIndex()) if (idOf(a, pageIndex, i) == id) return page to a
        return null
    }

    fun delete(args: Map<String, Any?>): Int {
        var n = 0
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val targets = (args["ids"] as List<*>).map { it as Map<*, *> }
            for ((pi, items) in targets.groupBy { (it["page"] as Number).toInt() }) {
                val page = od.doc.getPage(pi)
                val ids = items.map { it["id"] as String }.toSet()
                val annots = page.annotations
                val removed = annots.withIndex().filter { (i, a) -> idOf(a, pi, i) in ids }.map { it.value }
                val removedDicts = removed.map { it.cosObject }.toSet()
                val keep = annots.filter { a ->
                    a !in removed && !(a is PDAnnotationPopup && a.cosObject.getDictionaryObject(COSName.PARENT) in removedDicts)
                }
                n += annots.size - keep.size
                page.annotations = keep
            }
        }
        return n
    }

    /** Updates contents/color/opacity and/or moves+resizes an annotation to a new display rect. */
    fun update(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val pi = (args["page"] as Number).toInt()
            val (page, a) = find(od.doc, pi, args["id"] as String) ?: throw EngineException("ARGS", "Annotation not found")
            args["contents"]?.let { a.contents = it as String }
            if (args.containsKey("color")) {
                val c = parseColor(args["color"])
                a.color = rgb(c)
            }
            (args["opacity"] as Number?)?.let { if (a is PDAnnotationMarkup) a.constantOpacity = it.toFloat() }
            args["rect"]?.let { rv ->
                val g = PageGeom(page)
                val newRect = RectF.fromAny(rv)
                val oldUser = a.rectangle
                val newUser = g.rectToUser(newRect.l, newRect.t, newRect.r, newRect.b)
                val sx = newUser.width / oldUser.width; val sy = newUser.height / oldUser.height
                fun mx(x: Float) = newUser.lowerLeftX + (x - oldUser.lowerLeftX) * sx
                fun my(y: Float) = newUser.lowerLeftY + (y - oldUser.lowerLeftY) * sy
                val d = a.cosObject
                for (key in listOf("QuadPoints", "L", "Vertices", "CL")) {
                    val arr = d.getDictionaryObject(COSName.getPDFName(key)) as? COSArray ?: continue
                    d.setItem(COSName.getPDFName(key), mapPairs(arr, ::mx, ::my))
                }
                (d.getDictionaryObject(COSName.getPDFName("InkList")) as? COSArray)?.let { ink ->
                    val out = COSArray()
                    for (i in 0 until ink.size()) out.add(mapPairs(ink.getObject(i) as COSArray, ::mx, ::my))
                    d.setItem(COSName.getPDFName("InkList"), out)
                }
                a.rectangle = newUser
            }
            a.setModifiedDate(Calendar.getInstance())
            if (args["contents"] != null && a.subtype == "FreeText") {
                // Regenerate the FreeText appearance with the new text.
                val g = PageGeom(page)
                val d = g.rectToDisplay(a.rectangle)
                val r = RectF(d[0], d[1], d[2], d[3])
                val da = (a as PDAnnotationMarkup).defaultAppearance ?: ""
                val size = Regex("([0-9.]+) Tf").find(da)?.groupValues?.get(1)?.toFloatOrNull() ?: 14f
                val nums = Regex("([0-9.]+) ([0-9.]+) ([0-9.]+) rg").find(da)?.groupValues
                val color = if (nums != null) {
                    (0xFF shl 24) or ((nums[1].toFloat() * 255).toInt() shl 16) or ((nums[2].toFloat() * 255).toInt() shl 8) or (nums[3].toFloat() * 255).toInt()
                } else 0xFF000000.toInt()
                freeTextAppearance(od, a, g, r, a.contents ?: "", size, color, null, a.borderStyle?.width ?: 0f, a.constantOpacity)
            }
        }
    }

    private fun mapPairs(arr: COSArray, fx: (Float) -> Float, fy: (Float) -> Float): COSArray {
        val out = COSArray()
        for (i in 0 until arr.size()) {
            val v = (arr.getObject(i) as com.tom_roush.pdfbox.cos.COSNumber).floatValue()
            out.add(COSFloat(if (i % 2 == 0) fx(v) else fy(v)))
        }
        return out
    }

    // ------------------------------------------------------------- flatten

    /** Draws each annotation's normal appearance into the page content and removes the annotation. */
    fun flattenPageAnnotations(doc: PDDocument, page: PDPage, keepLinks: Boolean = true) {
        val annots = page.annotations
        val keep = ArrayList<PDAnnotation>()
        val toDraw = ArrayList<PDAnnotation>()
        for (a in annots) {
            when {
                a is PDAnnotationLink && keepLinks -> keep.add(a)
                a is PDAnnotationPopup -> {}
                a is PDAnnotationWidget -> keep.add(a)
                a.isHidden || a.isNoView -> {}
                a.normalAppearanceStream == null -> keep.add(a)
                else -> toDraw.add(a)
            }
        }
        if (toDraw.isEmpty()) return
        PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
            for (a in toDraw) {
                val ap = a.normalAppearanceStream
                val bbox = ap.bBox ?: continue
                val rect = a.rectangle ?: continue
                val form = PDFormXObject(ap.cosObject)
                // Matrix A maps the transformed BBox to Rect (PDF 32000 12.5.5).
                val m = ap.matrix
                val pts = listOf(
                    m.mapPoint(bbox.lowerLeftX, bbox.lowerLeftY), m.mapPoint(bbox.upperRightX, bbox.lowerLeftY),
                    m.mapPoint(bbox.lowerLeftX, bbox.upperRightY), m.mapPoint(bbox.upperRightX, bbox.upperRightY),
                )
                val minX = pts.minOf { it[0] }; val minY = pts.minOf { it[1] }
                val maxX = pts.maxOf { it[0] }; val maxY = pts.maxOf { it[1] }
                if (abs(maxX - minX) < 1e-3 || abs(maxY - minY) < 1e-3) continue
                val sx = rect.width / (maxX - minX); val sy = rect.height / (maxY - minY)
                cs.saveGraphicsState()
                cs.transform(Matrix(sx, 0f, 0f, sy, rect.lowerLeftX - minX * sx, rect.lowerLeftY - minY * sy))
                cs.drawForm(form)
                cs.restoreGraphicsState()
            }
        }
        page.annotations = keep
    }

    fun flatten(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            for (page in od.doc.pages) flattenPageAnnotations(od.doc, page)
        }
    }
}
