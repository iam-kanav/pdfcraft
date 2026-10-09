package com.pdfcraft.pdfcraft.engine

import com.tom_roush.pdfbox.contentstream.operator.Operator
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.cos.COSFloat
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSNumber
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.cos.COSString
import com.tom_roush.pdfbox.pdfparser.PDFStreamParser
import com.tom_roush.pdfbox.pdfwriter.ContentStreamWriter
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDStream
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.util.Matrix
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

typealias OpKey = Pair<Int, Int>

/** Planned modifications of a page's content, addressed by (unit, operator ordinal). */
class RewritePlan {
    /** Per text operator: which glyphs (by index) to remove. */
    val removeGlyphs = HashMap<OpKey, BooleanArray>()
    val glyphFonts = HashMap<OpKey, PDFont>()
    val glyphAdjusts = HashMap<OpKey, FloatArray>()

    /** Operators to drop together with their operands. */
    val dropOps = HashSet<OpKey>()

    /** Painting operators to replace by `n` (path is not painted, clipping preserved). */
    val noPaintOps = HashSet<OpKey>()

    /** Replace an operator (and its operands) with arbitrary tokens. */
    val replaceOps = HashMap<OpKey, List<Any>>()

    /** New name for the XObject operand of a `Do` operator. */
    val renameXObject = HashMap<OpKey, COSName>()

    fun removeGlyph(op: TextOp, index: Int) {
        val key = op.unit to op.ordinal
        val flags = removeGlyphs.getOrPut(key) { BooleanArray(op.glyphs.size) }
        flags[index] = true
        glyphFonts[key] = op.font
        glyphAdjusts.getOrPut(key) { FloatArray(op.glyphs.size) { op.glyphs[it].adjust } }
    }

    fun removeAllGlyphs(op: TextOp) {
        for (i in op.glyphs.indices) removeGlyph(op, i)
    }

    fun touchedUnits(): Set<Int> =
        (removeGlyphs.keys + dropOps + noPaintOps + replaceOps.keys + renameXObject.keys).map { it.first }.toSet()

    val isEmpty get() = touchedUnits().isEmpty()
}

object ContentRewriter {
    private val PAINT_OPS = setOf("S", "s", "f", "F", "f*", "B", "B*", "b", "b*")

    /**
     * Applies [plan] to [page]. Forms whose content changes are copied (the original form object
     * stays untouched for any other users) and the invoking `Do` is redirected to the copy.
     */
    fun apply(doc: PDDocument, page: PDPage, scan: PageScan, plan: RewritePlan) {
        if (plan.isEmpty) return
        // Propagate: a touched child unit forces its parent to be rewritten (to rename the Do).
        val touched = plan.touchedUnits().toMutableSet()
        var changed = true
        while (changed) {
            changed = false
            for (u in scan.units) {
                if (u.id in touched && u.parent != null && u.parent !in touched) {
                    touched.add(u.parent); changed = true
                }
            }
        }
        // Children first (higher ids are always nested deeper than their parents).
        for (unit in scan.units.sortedByDescending { it.id }) {
            if (unit.id !in touched) continue
            val form = unit.form
            val tokens = if (form == null) PDFStreamParser(page).also { it.parse() }.tokens
            else PDFStreamParser(form).also { it.parse() }.tokens
            val newTokens = rewriteTokens(unit.id, tokens, plan)
            val bytes = ByteArrayOutputStream().also { ContentStreamWriter(it).writeTokens(newTokens) }.toByteArray()
            if (form == null) {
                val stream = PDStream(doc)
                stream.createOutputStream(COSName.FLATE_DECODE).use { it.write(bytes) }
                page.setContents(stream)
            } else {
                val copy = copyForm(doc, form, bytes)
                val parentRes = resourcesOf(page, scan, unit.parent!!)
                val name = parentRes.add(copy)
                plan.renameXObject[unit.parent to unit.doOrdinal!!] = name
            }
        }
    }

    fun resourcesOf(page: PDPage, scan: PageScan, unitId: Int): PDResources {
        val unit = scan.units[unitId]
        val form = unit.form ?: return page.resources ?: PDResources().also { page.resources = it }
        return form.resources ?: PDResources().also { form.resources = it }
    }

    private fun copyForm(doc: PDDocument, form: PDFormXObject, content: ByteArray): PDFormXObject {
        val src = form.cosObject
        val stream: COSStream = doc.document.createCOSStream()
        for ((k, v) in src.entrySet()) {
            if (k == COSName.LENGTH || k == COSName.FILTER || k == COSName.DECODE_PARMS) continue
            stream.setItem(k, v)
        }
        stream.createOutputStream(COSName.FLATE_DECODE).use { it.write(content) }
        return PDFormXObject(stream)
    }

    private fun rewriteTokens(unit: Int, tokens: List<Any>, plan: RewritePlan): List<Any> {
        val out = ArrayList<Any>(tokens.size)
        val operands = ArrayList<COSBase>()
        var ordinal = 0
        for (t in tokens) {
            if (t !is Operator) {
                operands.add(t as COSBase)
                continue
            }
            val key = unit to ordinal++
            val name = t.name
            when {
                key in plan.replaceOps -> out.addAll(plan.replaceOps[key]!!)
                key in plan.dropOps -> {}
                key in plan.noPaintOps && name in PAINT_OPS -> out.add(Operator.getOperator("n"))
                key in plan.removeGlyphs -> {
                    val replaced = removeGlyphs(name, operands, plan.removeGlyphs[key]!!, plan.glyphAdjusts[key]!!, plan.glyphFonts[key]!!)
                    if (replaced != null) out.addAll(replaced)
                    else {
                        // Unable to map glyphs to bytes: drop the whole text operator (safe for redaction).
                        when (name) {
                            "'" -> out.add(Operator.getOperator("T*"))
                            "\"" -> {
                                out.add(operands[0]); out.add(Operator.getOperator("Tw"))
                                out.add(operands[1]); out.add(Operator.getOperator("Tc"))
                                out.add(Operator.getOperator("T*"))
                            }
                        }
                    }
                }
                key in plan.renameXObject && name == "Do" -> {
                    out.add(plan.renameXObject[key]!!)
                    out.add(t)
                }
                else -> {
                    out.addAll(operands)
                    out.add(t)
                }
            }
            operands.clear()
        }
        out.addAll(operands)
        return out
    }

    /** Returns replacement tokens for a text-showing operator with some glyphs removed, or null on mismatch. */
    private fun removeGlyphs(op: String, operands: List<COSBase>, flags: BooleanArray, adjusts: FloatArray, font: PDFont): List<Any>? {
        val prefix = ArrayList<Any>()
        val elements: List<COSBase> = when (op) {
            "Tj" -> listOf(operands.getOrNull(0) ?: return null)
            "TJ" -> (operands.getOrNull(0) as? COSArray ?: return null).toList()
            "'" -> {
                prefix.add(Operator.getOperator("T*"))
                listOf(operands.getOrNull(0) ?: return null)
            }
            "\"" -> {
                if (operands.size < 3) return null
                prefix.add(operands[0]); prefix.add(Operator.getOperator("Tw"))
                prefix.add(operands[1]); prefix.add(Operator.getOperator("Tc"))
                prefix.add(Operator.getOperator("T*"))
                listOf(operands[2])
            }
            else -> return null
        }
        val arr = COSArray()
        var glyphIndex = 0
        var pendingNumber = 0f
        fun flushNumber() {
            if (pendingNumber != 0f) arr.add(COSFloat(pendingNumber))
            pendingNumber = 0f
        }
        for (el in elements) {
            when (el) {
                is COSNumber -> pendingNumber += el.floatValue()
                is COSString -> {
                    val bytes = el.bytes
                    val input = ByteArrayInputStream(bytes)
                    val kept = ByteArrayOutputStream()
                    var pos = 0
                    while (input.available() > 0) {
                        val before = input.available()
                        font.readCode(input)
                        val len = before - input.available()
                        if (glyphIndex >= flags.size) return null
                        if (flags[glyphIndex]) {
                            if (kept.size() > 0) {
                                flushNumber(); arr.add(COSString(kept.toByteArray())); kept.reset()
                            }
                            pendingNumber += adjusts[glyphIndex]
                        } else {
                            if (pendingNumber != 0f && kept.size() == 0) flushNumber()
                            kept.write(bytes, pos, len)
                        }
                        pos += len
                        glyphIndex++
                    }
                    if (kept.size() > 0) {
                        flushNumber(); arr.add(COSString(kept.toByteArray()))
                    }
                }
                else -> {}
            }
        }
        if (glyphIndex != flags.size) return null
        flushNumber()
        return prefix + listOf(arr, Operator.getOperator("TJ"))
    }

    /** Builds a `cm` + Do replacement that re-maps an image from [ctm] to [newCtm]. */
    fun transformedDo(name: COSName, ctm: Matrix, newCtm: Matrix): List<Any> {
        val x = newCtm.multiply(invert(ctm))
        return listOf(
            Operator.getOperator("q"),
            COSFloat(x.scaleX), COSFloat(x.shearY), COSFloat(x.shearX), COSFloat(x.scaleY),
            COSFloat(x.translateX), COSFloat(x.translateY), Operator.getOperator("cm"),
            name, Operator.getOperator("Do"),
            Operator.getOperator("Q"),
        )
    }

    fun invert(m: Matrix): Matrix {
        val a = m.scaleX; val b = m.shearY; val c = m.shearX; val d = m.scaleY
        val e = m.translateX; val f = m.translateY
        val det = a * d - b * c
        if (det == 0f) return Matrix()
        val ia = d / det; val ib = -b / det; val ic = -c / det; val id = a / det
        val ie = -(e * ia + f * ic)
        val iff = -(e * ib + f * id)
        return Matrix(ia, ib, ic, id, ie, iff)
    }
}
