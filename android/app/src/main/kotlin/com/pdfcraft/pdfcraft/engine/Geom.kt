package com.pdfcraft.pdfcraft.engine

import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.util.Matrix
import kotlin.math.max
import kotlin.math.min

/**
 * Converts between "display space" (what the user sees: top-left origin, y down,
 * page rotation applied, crop box relative, PDF points) and PDF user space.
 *
 * All coordinates exchanged with the Dart side are in display space.
 */
class PageGeom(page: PDPage) {
    val crop: PDRectangle = page.cropBox
    val rotation: Int = ((page.rotation % 360) + 360) % 360
    private val llx = crop.lowerLeftX
    private val lly = crop.lowerLeftY
    private val urx = crop.upperRightX
    private val ury = crop.upperRightY

    /** Display width/height. */
    val width: Float = if (rotation == 90 || rotation == 270) crop.height else crop.width
    val height: Float = if (rotation == 90 || rotation == 270) crop.width else crop.height

    /**
     * Matrix mapping display coordinates with a bottom-left origin (x right, y up) to user space.
     * Prefixing drawn content with `cm` of this matrix lets us draw upright in display orientation.
     */
    val displayUpMatrix: Matrix = when (rotation) {
        90 -> Matrix(0f, 1f, -1f, 0f, urx, lly)
        180 -> Matrix(-1f, 0f, 0f, -1f, urx, ury)
        270 -> Matrix(0f, -1f, 1f, 0f, llx, ury)
        else -> Matrix(1f, 0f, 0f, 1f, llx, lly)
    }

    /** Rotation-only part of [displayUpMatrix] (used for appearance stream /Matrix). */
    val rotationOnly: Matrix = when (rotation) {
        90 -> Matrix(0f, 1f, -1f, 0f, 0f, 0f)
        180 -> Matrix(-1f, 0f, 0f, -1f, 0f, 0f)
        270 -> Matrix(0f, -1f, 1f, 0f, 0f, 0f)
        else -> Matrix()
    }

    /** Display (top-left origin) point → user space. */
    fun toUser(dx: Float, dy: Float): FloatArray {
        val x = dx
        val y = height - dy
        val m = displayUpMatrix
        return floatArrayOf(
            m.scaleX * x + m.shearX * y + m.translateX,
            m.shearY * x + m.scaleY * y + m.translateY,
        )
    }

    /** User space point → display (top-left origin). */
    fun toDisplay(ux: Float, uy: Float): FloatArray {
        val m = displayUpMatrix
        // Inverse of a rotation+translation matrix.
        val tx = ux - m.translateX
        val ty = uy - m.translateY
        // [a b; c d] with a=scaleX, b=shearY, c=shearX, d=scaleY; inverse of orthonormal = transpose.
        val x = m.scaleX * tx + m.shearY * ty
        val y = m.shearX * tx + m.scaleY * ty
        return floatArrayOf(x, height - y)
    }

    /** Display rect (left, top, right, bottom) → user-space PDRectangle. */
    fun rectToUser(l: Float, t: Float, r: Float, b: Float): PDRectangle {
        val p1 = toUser(l, t)
        val p2 = toUser(r, b)
        val x0 = min(p1[0], p2[0])
        val y0 = min(p1[1], p2[1])
        return PDRectangle(x0, y0, max(p1[0], p2[0]) - x0, max(p1[1], p2[1]) - y0)
    }

    /** User-space rectangle → display rect [l, t, r, b]. */
    fun rectToDisplay(r: PDRectangle): FloatArray = rectToDisplay(r.lowerLeftX, r.lowerLeftY, r.upperRightX, r.upperRightY)

    fun rectToDisplay(x0: Float, y0: Float, x1: Float, y1: Float): FloatArray {
        val a = toDisplay(x0, y0)
        val b = toDisplay(x1, y1)
        return floatArrayOf(min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1]))
    }
}

/** Axis-aligned rectangle in some coordinate space. */
data class RectF(val l: Float, val t: Float, val r: Float, val b: Float) {
    val width get() = r - l
    val height get() = b - t
    fun intersects(o: RectF): Boolean = l < o.r && o.l < r && t < o.b && o.t < b
    fun intersectionArea(o: RectF): Float {
        val w = min(r, o.r) - max(l, o.l)
        val h = min(b, o.b) - max(t, o.t)
        return if (w > 0 && h > 0) w * h else 0f
    }
    val area get() = max(0f, width) * max(0f, height)
    fun contains(x: Float, y: Float) = x >= l && x <= r && y >= t && y <= b
    fun union(o: RectF) = RectF(min(l, o.l), min(t, o.t), max(r, o.r), max(b, o.b))
    fun toList(): List<Double> = listOf(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble())

    companion object {
        fun fromAny(v: Any?): RectF {
            val list = v as List<*>
            return RectF(
                (list[0] as Number).toFloat(), (list[1] as Number).toFloat(),
                (list[2] as Number).toFloat(), (list[3] as Number).toFloat(),
            )
        }
    }
}

/** Transforms a point with a PDF matrix. */
fun Matrix.mapPoint(x: Float, y: Float): FloatArray =
    floatArrayOf(scaleX * x + shearX * y + translateX, shearY * x + scaleY * y + translateY)

/** Bounding box of the unit square transformed by this matrix (image placement). */
fun Matrix.unitSquareBounds(): FloatArray {
    val pts = listOf(mapPoint(0f, 0f), mapPoint(1f, 0f), mapPoint(0f, 1f), mapPoint(1f, 1f))
    return floatArrayOf(
        pts.minOf { it[0] }, pts.minOf { it[1] }, pts.maxOf { it[0] }, pts.maxOf { it[1] },
    )
}

fun parseColor(v: Any?, default: Int = 0xFF000000.toInt()): Int = when (v) {
    is Number -> v.toLong().toInt()
    else -> default
}

fun colorComponents(argb: Int): FloatArray = floatArrayOf(
    ((argb shr 16) and 0xFF) / 255f,
    ((argb shr 8) and 0xFF) / 255f,
    (argb and 0xFF) / 255f,
)

fun colorAlpha(argb: Int): Float = ((argb ushr 24) and 0xFF) / 255f
