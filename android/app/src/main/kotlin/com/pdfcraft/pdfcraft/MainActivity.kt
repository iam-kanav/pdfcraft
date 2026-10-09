package com.pdfcraft.pdfcraft

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.pdfcraft.pdfcraft.engine.AnnotOps
import com.pdfcraft.pdfcraft.engine.ContentOps
import com.pdfcraft.pdfcraft.engine.DocOps
import com.pdfcraft.pdfcraft.engine.EngineException
import com.pdfcraft.pdfcraft.engine.FormOps
import com.pdfcraft.pdfcraft.engine.PdfIO
import com.pdfcraft.pdfcraft.engine.Stamps
import com.pdfcraft.pdfcraft.engine.TextOps
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val executor = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private lateinit var platform: PlatformBridge

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PDFBoxResourceLoader.init(applicationContext)
        PdfIO.context = applicationContext
        platform = PlatformBridge(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pdfcraft/engine").setMethodCallHandler { call, result ->
            @Suppress("UNCHECKED_CAST")
            val args = (call.arguments as? Map<String, Any?>) ?: emptyMap()
            val op: ((Map<String, Any?>) -> Any?)? = when (call.method) {
                "info" -> DocOps::info
                "setMetadata" -> DocOps::setMetadata
                "protect" -> DocOps::protect
                "removeSecurity" -> DocOps::removeSecurity
                "organize" -> DocOps::organize
                "split" -> DocOps::split
                "crop" -> DocOps::crop
                "compress" -> DocOps::compress
                "flatten" -> DocOps::flatten
                "addAnnotations" -> AnnotOps::add
                "listAnnotations" -> AnnotOps::list
                "deleteAnnotations" -> AnnotOps::delete
                "updateAnnotation" -> AnnotOps::update
                "listFields" -> FormOps::list
                "fillForm" -> FormOps::fill
                "getTextBlocks" -> ContentOps::getTextBlocks
                "editTextBlocks" -> ContentOps::editTextBlocks
                "getImageObjects" -> ContentOps::getImageObjects
                "editImage" -> ContentOps::editImage
                "addContent" -> ContentOps::addContent
                "redact" -> ContentOps::redact
                "watermark" -> Stamps::watermark
                "pageNumbers" -> Stamps::pageNumbers
                "removeArtifacts" -> Stamps::removeArtifacts
                "extractPages" -> TextOps::extractPages
                "addOcrLayer" -> TextOps::addOcrLayer
                else -> null
            }
            if (op == null) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val r = op(args)
                    main.post { result.success(if (r is Unit) null else r) }
                } catch (e: EngineException) {
                    main.post { result.error(e.code, e.message, null) }
                } catch (e: OutOfMemoryError) {
                    main.post { result.error("OOM", "Not enough memory to process this document", null) }
                } catch (e: Throwable) {
                    android.util.Log.e("PDFCraft", "engine ${call.method} failed", e)
                    main.post { result.error("PDF_ERROR", e.message ?: e.javaClass.simpleName, null) }
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pdfcraft/platform").setMethodCallHandler(platform)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "pdfcraft/intents").setStreamHandler(platform)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        platform.handleIntent(intent, live = true)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        platform.onActivityResult(requestCode)
    }
}
