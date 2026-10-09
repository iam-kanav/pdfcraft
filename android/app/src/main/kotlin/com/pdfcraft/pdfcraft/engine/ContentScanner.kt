package com.pdfcraft.pdfcraft.engine

import android.graphics.Path
import android.graphics.PointF
import com.tom_roush.pdfbox.contentstream.PDFGraphicsStreamEngine
import com.tom_roush.pdfbox.contentstream.operator.Operator
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.font.PDType3CharProc
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDTransparencyGroup
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImage
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDInlineImage
import com.tom_roush.pdfbox.pdmodel.graphics.state.RenderingMode
import com.tom_roush.pdfbox.util.Matrix
import com.tom_roush.pdfbox.util.Vector
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * A content stream "unit": either the page's own content (id 0) or one invocation of a form XObject.
 * Every recorded item is addressed by (unit id, operator ordinal within that unit's token list).
 */
class ContentUnit(
    val id: Int,
    /** Form stream, or null for the page content. */
    val form: PDFormXObject?,
    val parent: Int?,
    /** Ordinal of the `Do` operator in the parent unit that invoked this form. */
    val doOrdinal: Int?,
)

class Glyph(
    /** Display-space box (top-left origin). */
    val box: RectF,
    val unicode: String?,
    /** TJ adjustment (thousandths of text space) that reproduces this glyph's advance. */
    val adjust: Float,
    val baselineX: Float,
    val baselineY: Float,
)

class TextOp(
    val unit: Int,
    val ordinal: Int,
    val font: PDFont,
    val fontSize: Float,
    /** Effective size on the page (font size × text/CTM scale). */
    val effectiveSize: Float,
    val color: Int,
    val invisible: Boolean,
    /** Rotation of the baseline in display space, degrees. */
    val angle: Float,
    val glyphs: MutableList<Glyph> = ArrayList(),
) {
    val bounds: RectF?
        get() = glyphs.fold(null as RectF?) { acc, g -> acc?.union(g.box) ?: g.box }
    val text: String get() = glyphs.joinToString("") { it.unicode ?: "" }
}

class ImageOp(
    val unit: Int,
    val ordinal: Int,
    /** Resource name for XObject images; null for inline images. */
    val name: COSName?,
    val stream: COSStream?,
    val ctm: Matrix,
    val box: RectF,
    val pixelWidth: Int,
    val pixelHeight: Int,
)

class PathOp(
    val unit: Int,
    val ordinal: Int,
    val box: RectF,
    val clipOnly: Boolean,
    /** Ordinal of the first path-construction operator. */
    val startOrdinal: Int = ordinal,
    val ctm: Matrix = Matrix(),
    val stroked: Boolean = false,
    val filled: Boolean = false,
    val strokeColor: Int = 0xFF000000.toInt(),
    val fillColor: Int = 0xFF000000.toInt(),
)

class FormOp(val unit: Int, val ordinal: Int, val name: COSName, val childUnit: Int, val box: RectF)

class PageScan(val geom: PageGeom) {
    val units = ArrayList<ContentUnit>()
    val texts = ArrayList<TextOp>()
    val images = ArrayList<ImageOp>()
    val paths = ArrayList<PathOp>()
    val forms = ArrayList<FormOp>()
}

/**
 * Walks a page's content (including nested form XObjects) and records where every glyph,
 * image and painted path ends up on the page, keyed by operator position so the content
 * can later be rewritten precisely.
 */
class ContentScanner private constructor(page: PDPage) : PDFGraphicsStreamEngine(page) {
    private val geom = PageGeom(page)
    val result = PageScan(geom)

    private class Frame(val unit: Int) {
        var counter = 0
    }

    private val frames = ArrayList<Frame>()
    private var suppress = 0
    private var curUnit = 0
    private var curOrdinal = 0
    private var curOperands: List<COSBase> = emptyList()
    private var currentText: TextOp? = null

    // Path tracking (user space)
    private var pathMinX = Float.MAX_VALUE
    private var pathMinY = Float.MAX_VALUE
    private var pathMaxX = -Float.MAX_VALUE
    private var pathMaxY = -Float.MAX_VALUE
    private var currentPoint = PointF()
    private var pendingClip = false

    companion object {
        fun scan(page: PDPage): PageScan {
            val s = ContentScanner(page)
            s.result.units.add(ContentUnit(0, null, null, null))
            s.frames.add(Frame(0))
            s.processPage(page)
            return s.result
        }

        /** Reports (image stream, width pt, height pt) for every image drawn on the page. */
        fun scanImagePlacements(page: PDPage, cb: (COSStream, Float, Float) -> Unit) {
            val scan = scan(page)
            for (img in scan.images) {
                val s = img.stream ?: continue
                cb(s, img.box.width, img.box.height)
            }
        }
    }

    override fun processOperator(operator: Operator, operands: MutableList<COSBase>) {
        if (suppress > 0) {
            super.processOperator(operator, operands)
            return
        }
        val frame = frames.last()
        val ordinal = frame.counter++
        val savedUnit = curUnit
        val savedOrdinal = curOrdinal
        val savedOperands = curOperands
        curUnit = frame.unit
        curOrdinal = ordinal
        curOperands = operands
        currentText = null
        try {
            super.processOperator(operator, operands)
        } finally {
            currentText = null
            curUnit = savedUnit
            curOrdinal = savedOrdinal
            curOperands = savedOperands
        }
    }

    override fun showForm(form: PDFormXObject) {
        enterForm(form) { super.showForm(form) }
    }

    override fun showTransparencyGroup(form: PDTransparencyGroup) {
        enterForm(form) { super.showTransparencyGroup(form) }
    }

    private fun enterForm(form: PDFormXObject, body: () -> Unit) {
        if (suppress > 0) {
            body()
            return
        }
        val id = result.units.size
        result.units.add(ContentUnit(id, form, curUnit, curOrdinal))
        val name = curOperands.firstOrNull() as? COSName
        val bbox = form.bBox
        val box = if (bbox != null) {
            val m = form.matrix.multiply(graphicsState.currentTransformationMatrix)
            userRectToDisplay(
                listOf(
                    m.mapPoint(bbox.lowerLeftX, bbox.lowerLeftY), m.mapPoint(bbox.upperRightX, bbox.lowerLeftY),
                    m.mapPoint(bbox.lowerLeftX, bbox.upperRightY), m.mapPoint(bbox.upperRightX, bbox.upperRightY),
                ),
            )
        } else {
            RectF(0f, 0f, geom.width, geom.height)
        }
        if (name != null) result.forms.add(FormOp(curUnit, curOrdinal, name, id, box))
        frames.add(Frame(id))
        try {
            body()
        } finally {
            frames.removeAt(frames.size - 1)
        }
    }

    override fun processType3Stream(charProc: PDType3CharProc, textRenderingMatrix: Matrix) {
        suppress++
        try {
            super.processType3Stream(charProc, textRenderingMatrix)
        } finally {
            suppress--
        }
    }

    private fun userRectToDisplay(pts: List<FloatArray>): RectF {
        val d = pts.map { geom.toDisplay(it[0], it[1]) }
        return RectF(d.minOf { it[0] }, d.minOf { it[1] }, d.maxOf { it[0] }, d.maxOf { it[1] })
    }

    override fun showGlyph(textRenderingMatrix: Matrix, font: PDFont, code: Int, unicode: String?, displacement: Vector) {
        super.showGlyph(textRenderingMatrix, font, code, unicode, displacement)
        if (suppress > 0) return
        val gs = graphicsState
        val ts = gs.textState
        val desc = font.fontDescriptor
        var ascent = (desc?.ascent ?: 0f) / 1000f
        var descent = (desc?.descent ?: 0f) / 1000f
        if (ascent <= 0f || ascent > 1.5f) ascent = 0.85f
        if (descent >= 0f || descent < -0.8f) descent = -0.22f
        val w = if (font.isVertical) 1f else displacement.x
        val trm = textRenderingMatrix
        val corners = listOf(
            trm.mapPoint(0f, descent), trm.mapPoint(w, descent),
            trm.mapPoint(0f, ascent), trm.mapPoint(w, ascent),
        )
        val box = userRectToDisplay(corners)
        val base = geom.toDisplay(trm.translateX, trm.translateY)
        val fs = ts.fontSize
        val isSpace = code == 32 && font !is com.tom_roush.pdfbox.pdmodel.font.PDType0Font
        val tw = if (isSpace) ts.wordSpacing else 0f
        val adjust = if (fs != 0f) -((displacement.x * fs + ts.characterSpacing + tw) * 1000f / fs) else 0f

        var op = currentText
        if (op == null) {
            val color = try { gs.nonStrokingColor.toRGB() or 0xFF000000.toInt() } catch (_: Exception) { 0xFF000000.toInt() }
            val scaleY = kotlin.math.sqrt(trm.scaleY * trm.scaleY + trm.shearX * trm.shearX)
            // Angle of the baseline in display space (y down).
            val p0 = geom.toDisplay(trm.translateX, trm.translateY)
            val p1 = trm.mapPoint(1f, 0f).let { geom.toDisplay(it[0], it[1]) }
            val angle = Math.toDegrees(kotlin.math.atan2((p1[1] - p0[1]).toDouble(), (p1[0] - p0[0]).toDouble())).toFloat()
            op = TextOp(
                unit = curUnit, ordinal = curOrdinal, font = font, fontSize = fs,
                effectiveSize = abs(scaleY), color = color,
                invisible = ts.renderingMode == RenderingMode.NEITHER,
                angle = angle,
            )
            result.texts.add(op)
            currentText = op
        }
        op.glyphs.add(Glyph(box, unicode, adjust, base[0], base[1]))
    }

    override fun drawImage(pdImage: PDImage) {
        if (suppress > 0) return
        val ctm = graphicsState.currentTransformationMatrix.clone()
        val box = userRectToDisplay(
            listOf(ctm.mapPoint(0f, 0f), ctm.mapPoint(1f, 0f), ctm.mapPoint(0f, 1f), ctm.mapPoint(1f, 1f)),
        )
        val (name, stream) = when (pdImage) {
            is PDImageXObject -> (curOperands.firstOrNull() as? COSName) to pdImage.cosObject
            is PDInlineImage -> null to null
            else -> null to null
        }
        result.images.add(ImageOp(curUnit, curOrdinal, name, stream, ctm, box, pdImage.width, pdImage.height))
    }

    private var pathStart = -1

    private fun addPoint(x: Float, y: Float) {
        if (pathStart < 0 && suppress == 0) pathStart = curOrdinal
        pathMinX = min(pathMinX, x); pathMinY = min(pathMinY, y)
        pathMaxX = max(pathMaxX, x); pathMaxY = max(pathMaxY, y)
    }

    private fun resetPath() {
        pathMinX = Float.MAX_VALUE; pathMinY = Float.MAX_VALUE
        pathMaxX = -Float.MAX_VALUE; pathMaxY = -Float.MAX_VALUE
    }

    private fun finishPath(clipOnly: Boolean, stroked: Boolean = false, filled: Boolean = false) {
        if (suppress == 0 && pathMinX <= pathMaxX) {
            val d = userRectToDisplay(
                listOf(floatArrayOf(pathMinX, pathMinY), floatArrayOf(pathMaxX, pathMaxY), floatArrayOf(pathMinX, pathMaxY), floatArrayOf(pathMaxX, pathMinY)),
            )
            val gs = graphicsState
            fun rgb(c: com.tom_roush.pdfbox.pdmodel.graphics.color.PDColor?) =
                try { (c?.toRGB() ?: 0) or 0xFF000000.toInt() } catch (_: Exception) { 0xFF000000.toInt() }
            result.paths.add(
                PathOp(
                    curUnit, curOrdinal, d, clipOnly,
                    startOrdinal = if (pathStart >= 0) pathStart else curOrdinal,
                    ctm = gs.currentTransformationMatrix.clone(),
                    stroked = stroked, filled = filled,
                    strokeColor = rgb(gs.strokingColor), fillColor = rgb(gs.nonStrokingColor),
                ),
            )
        }
        pendingClip = false
        pathStart = -1
        resetPath()
    }

    override fun appendRectangle(p0: PointF, p1: PointF, p2: PointF, p3: PointF) {
        addPoint(p0.x, p0.y); addPoint(p1.x, p1.y); addPoint(p2.x, p2.y); addPoint(p3.x, p3.y)
        currentPoint = PointF(p0.x, p0.y)
    }

    override fun clip(windingRule: Path.FillType) {
        pendingClip = true
    }

    override fun moveTo(x: Float, y: Float) {
        addPoint(x, y); currentPoint = PointF(x, y)
    }

    override fun lineTo(x: Float, y: Float) {
        addPoint(x, y); currentPoint = PointF(x, y)
    }

    override fun curveTo(x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float) {
        addPoint(x1, y1); addPoint(x2, y2); addPoint(x3, y3); currentPoint = PointF(x3, y3)
    }

    override fun getCurrentPoint(): PointF = currentPoint

    override fun closePath() {}

    override fun endPath() = finishPath(clipOnly = true)

    override fun strokePath() = finishPath(clipOnly = false, stroked = true)

    override fun fillPath(windingRule: Path.FillType) = finishPath(clipOnly = false, filled = true)

    override fun fillAndStrokePath(windingRule: Path.FillType) = finishPath(clipOnly = false, stroked = true, filled = true)

    override fun shadingFill(shadingName: COSName) {}
}
