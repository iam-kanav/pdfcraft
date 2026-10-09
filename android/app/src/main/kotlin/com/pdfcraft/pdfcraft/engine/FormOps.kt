package com.pdfcraft.pdfcraft.engine

import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.font.PDType0Font
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDAcroForm
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDButton
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDCheckBox
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDChoice
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDPushButton
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDRadioButton
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDSignatureField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDTerminalField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDTextField
import com.tom_roush.pdfbox.pdmodel.interactive.form.PDVariableText

/** Interactive form (AcroForm) reading and filling. */
object FormOps {

    private fun pageIndexOf(doc: PDDocument, w: PDAnnotationWidget): Int {
        val p = w.page
        if (p != null) {
            val i = doc.pages.indexOf(p)
            if (i >= 0) return i
        }
        for ((i, page) in doc.pages.withIndex()) {
            if (page.annotations.any { it.cosObject == w.cosObject }) return i
        }
        return -1
    }

    private fun typeOf(f: PDField): String = when (f) {
        is PDTextField -> "text"
        is PDCheckBox -> "checkbox"
        is PDRadioButton -> "radio"
        is PDChoice -> if (f.isCombo) "combo" else "list"
        is PDPushButton -> "button"
        is PDSignatureField -> "signature"
        else -> "unknown"
    }

    /** Widget on-state name (export value) for checkboxes/radios. */
    private fun onState(w: PDAnnotationWidget): String? {
        val n = w.appearance?.normalAppearance ?: return null
        if (!n.isSubDictionary) return null
        return n.subDictionary.keys.map { it.name }.firstOrNull { it != "Off" }
    }

    fun list(args: Map<String, Any?>): List<Map<String, Any?>> = PdfIO.read(args.path, args.password) { od ->
        val doc = od.doc
        val form = doc.documentCatalog.acroForm ?: return@read emptyList()
        val result = ArrayList<Map<String, Any?>>()
        for (f in form.fieldTree) {
            if (f !is PDTerminalField) continue
            val type = typeOf(f)
            for ((wi, w) in f.widgets.withIndex()) {
                val pi = pageIndexOf(doc, w)
                if (pi < 0) continue
                val r = w.rectangle ?: continue
                val g = PageGeom(doc.getPage(pi))
                val m = HashMap<String, Any?>()
                m["name"] = f.fullyQualifiedName
                m["label"] = f.alternateFieldName ?: f.partialName
                m["type"] = type
                m["widget"] = wi
                m["page"] = pi
                m["rect"] = g.rectToDisplay(r).map { it.toDouble() }
                m["readOnly"] = f.isReadOnly
                m["required"] = f.isRequired
                m["hidden"] = w.isHidden || w.isNoView
                when (f) {
                    is PDTextField -> {
                        m["value"] = f.value ?: ""
                        m["multiline"] = f.isMultiline
                        m["password"] = f.isPassword
                        m["maxLen"] = f.maxLen
                        val da = (f as PDVariableText).defaultAppearance ?: ""
                        m["fontSize"] = Regex("([0-9.]+)\\s+Tf").find(da)?.groupValues?.get(1)?.toDoubleOrNull()
                    }
                    is PDCheckBox -> {
                        m["value"] = f.isChecked
                        m["onValue"] = onState(w) ?: f.onValue
                    }
                    is PDRadioButton -> {
                        m["value"] = f.valueAsString
                        m["onValue"] = onState(w)
                    }
                    is PDChoice -> {
                        m["value"] = f.value
                        m["options"] = f.optionsDisplayValues
                        m["exportValues"] = f.optionsExportValues
                        m["multiSelect"] = f.isMultiSelect
                        m["editable"] = f.cosObject.getInt(COSName.FF) and (1 shl 18) != 0
                    }
                    is PDSignatureField -> m["signed"] = f.signature != null
                    else -> m["value"] = f.valueAsString
                }
                result.add(m)
            }
        }
        result
    }

    private fun ensureDefaultResources(form: PDAcroForm) {
        var dr = form.defaultResources
        if (dr == null) {
            dr = PDResources()
            form.defaultResources = dr
        }
        if (dr.getFont(COSName.getPDFName("Helv")) == null) dr.put(COSName.getPDFName("Helv"), PDType1Font.HELVETICA)
        if (dr.getFont(COSName.getPDFName("ZaDb")) == null) dr.put(COSName.getPDFName("ZaDb"), PDType1Font.ZAPF_DINGBATS)
        if (form.defaultAppearance.isNullOrEmpty()) form.defaultAppearance = "/Helv 0 Tf 0 g"
    }

    /** values: {fullName: String | Boolean | List<String>}. Optionally flattens the form afterwards. */
    fun fill(args: Map<String, Any?>) {
        PdfIO.edit(args.path, args.password, args.out) { od ->
            val doc = od.doc
            val form = doc.documentCatalog.acroForm ?: throw EngineException("NO_FORM", "This document has no form fields")
            ensureDefaultResources(form)
            form.needAppearances = false
            val values = args["values"] as Map<*, *>
            for ((k, v) in values) {
                val f = form.getField(k as String) ?: continue
                if (f.isReadOnly) continue
                try {
                    setValue(f, v)
                } catch (e: Exception) {
                    if (f is PDVariableText && v is String) {
                        // The field's font can't encode the text: switch to an embedded Unicode font.
                        val font = PDType0Font.load(doc, PdfIO.openAsset("assets/fonts/NotoSans-Regular.ttf"), false)
                        val name = form.defaultResources.add(font)
                        val da = f.defaultAppearance ?: "/Helv 0 Tf 0 g"
                        f.defaultAppearance = da.replace(Regex("/\\S+\\s+([0-9.]+)\\s+Tf"), "/${name.name} $1 Tf")
                            .let { if (it.contains("Tf")) it else "/${name.name} 0 Tf 0 g" }
                        f.setValue(v)
                    } else {
                        throw EngineException("FORM", "Cannot set ${f.fullyQualifiedName}: ${e.message}")
                    }
                }
            }
            if (args["flatten"] == true) {
                form.flatten()
            }
        }
    }

    private fun setValue(f: PDField, v: Any?) {
        when (f) {
            is PDCheckBox -> if (v == true || (v is String && v != "Off" && v.isNotEmpty())) f.check() else f.unCheck()
            is PDRadioButton -> f.setValue((v as String?)?.ifEmpty { "Off" } ?: "Off")
            is PDChoice -> when (v) {
                is List<*> -> f.setValue(v.map { it as String })
                is String -> f.setValue(v)
                else -> f.setValue(emptyList())
            }
            is PDButton -> {}
            is PDSignatureField -> {}
            else -> f.setValue(v?.toString() ?: "")
        }
    }
}
