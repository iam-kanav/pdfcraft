# Architecture

This guide gives you a map of PDFCraft: what the main parts are, how they talk to each other, and where to look when you want to change something. It stays high-level on purpose. For details, read the code and its comments.

## The big picture

PDFCraft is a Flutter app for Android with two halves:

- **The Flutter side (Dart)** draws every screen and handles reading, smart reading, scanning, file management and Office file conversion.
- **The native engine (Kotlin)** changes PDF files: editing text, adding comments, filling forms, encrypting, redacting and so on. It's built on PdfBox-Android.

The two halves talk over Flutter method channels. Viewing doesn't touch the Kotlin engine at all; it uses pdfrx, which wraps Google's PDFium renderer.

```
┌──────────────────────── Flutter (Dart) ────────────────────────┐
│  Screens (lib/features/*)                                      │
│     │                                                          │
│     ├── pdfrx / PDFium ── render pages, search, select text    │
│     ├── DocumentSession ── undo/redo, safe file replacement    │
│     │        │                                                 │
│     │        └── PdfEngine ──── method channel "pdfcraft/engine"
│     ├── Scanner pipeline (pure Dart, background isolates)      │
│     └── Office readers and writers (DOCX, XLSX, PPTX)          │
└────────────────────────────────────────────────────────────────┘
                                │
┌──────────────────────── Android (Kotlin) ──────────────────────┐
│  MainActivity ── routes each call to an engine operation       │
│  engine/* ────── PdfBox-Android: read, change, save PDFs       │
│  PlatformBridge ─ sharing, printing, file intents, storage     │
└────────────────────────────────────────────────────────────────┘
```

## Where things live

### Dart (`lib/`)

| Path | What's there |
| --- | --- |
| `main.dart`, `app.dart` | Startup, theme, and handling files opened from other apps |
| `core/services.dart` | `AppServices`: one place that creates the file library, settings and caches |
| `core/session/` | `DocumentSession`: the open document, with undo, redo and safe saving |
| `core/native/` | `PdfEngine` (calls into Kotlin) and `PlatformBridge` (sharing, printing, intents) |
| `core/library/` | `FileService` (folders, import, rename, move) and `LibraryStore` (recents, stars, bookmarks) |
| `core/models/` | Data passed between the engine and smart reading: positioned text, document structure |
| `features/viewer/` | The PDF viewer and its modes. Each mode is a layer drawn over the page: comment, edit, fill & sign, redact |
| `features/reflow/` | Smart reading: turns positioned text into headings, paragraphs, lists and tables |
| `features/scanner/` | Camera screen, review screen, and `processing/` (edge detection, straightening, filters) |
| `features/convert/` | Create PDF, export, OCR, and `engine/` with the Office and HTML readers and writers |
| `features/organize/` | Organize pages, combine, split and crop |
| `features/tools/` | The tools list (`tool_registry.dart`), compress, watermark and page-number dialogs |
| `features/home/`, `files/`, `shell/` | Home, Files and Search tabs and the bottom navigation |
| `theme/` | Colors, typography and component styles |

### Kotlin (`android/app/src/main/kotlin/com/pdfcraft/pdfcraft/`)

| File | What's there |
| --- | --- |
| `MainActivity.kt` | Maps each method-channel call to an engine operation and runs it on a background thread |
| `PlatformBridge.kt` | Incoming files, sharing, printing, saving to Downloads, storage access |
| `engine/PdfIO.kt` | Opening and saving PDFs, including passwords and encryption |
| `engine/ContentScanner.kt` | Reads a page's drawing instructions and records where every glyph, image and shape is |
| `engine/ContentRewriter.kt` | Rewrites those instructions; used by text editing, redaction and shape editing |
| `engine/ContentOps.kt` | Text, image and shape editing, adding content, and redaction |
| `engine/AnnotOps.kt` | Adding, listing, updating and deleting comments |
| `engine/FormOps.kt` | Reading and filling form fields |
| `engine/DocOps.kt` | Page operations, metadata, encryption, compression, flattening |
| `engine/TextOps.kt` | Extracting styled text for smart reading, and adding OCR text layers |
| `engine/Stamps.kt` | Watermarks, page numbers, headers and footers |

## How an edit works

Every change to a document follows the same path:

1. A screen calls `DocumentSession.apply()` with a label (for example, "Redact") and an operation.
2. The session asks the engine to read the current file and write the result to a **new temporary file**. The engine never changes a file in place.
3. If that succeeds, the session keeps a snapshot of the old version for undo, then swaps the new file in.
4. The session's revision number goes up. The viewer sees this and reloads the document.

If anything fails, the original file is untouched.

## Rules the code follows

- **No network access.** Nothing in the app talks to the internet, and release builds remove the internet permission (`android/app/src/release/AndroidManifest.xml`). Don't add features that need it.
- **One coordinate system across the bridge.** Positions sent between Dart and Kotlin are in PDF points, measured from the top-left of the page as it appears on screen, with page rotation already applied. `engine/Geom.kt` converts to and from PDF's own coordinates.
- **Edits go through `DocumentSession`.** Screens shouldn't write to a document file directly. That's what keeps undo, redo and crash safety working.
- **Engine calls are stateless.** Each Kotlin operation opens the file, does its work, saves and closes. Nothing is cached between calls.
- **Errors carry a code.** The engine reports problems such as a wrong password (`PASSWORD`) or a restricted file (`PERMISSION`). The Dart side turns these into friendly messages.

## Threads

- Kotlin engine calls run on a small background thread pool, so the screen never freezes.
- Heavy Dart work (scanner image processing, edge detection) runs in background isolates.
- PDFium rendering is managed by pdfrx.

## Testing

| Folder | What it covers | Where it runs |
| --- | --- | --- |
| `test/core/` | File library, document sessions, formatting helpers | Your computer |
| `test/convert/` | Office, HTML, Markdown and PDF readers and writers | Your computer |
| `test/reflow/` | Smart reading analysis and rendering | Your computer |
| `test/scanner/` | Edge detection, straightening and filters on generated images | Your computer |
| `integration_test/engine_test.dart` | Every Kotlin engine operation, on real PDFs | Android device |
| `integration_test/app_flow_test.dart` | A full trip through the app's screens | Android device |
