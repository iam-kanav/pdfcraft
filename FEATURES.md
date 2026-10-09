# PDFCraft feature checklist

Offline Android PDF app. Everything runs on the device: no backend, no accounts, no cloud or AI services.

Legend: ✅ done · 🟡 partial · ⛔ blocked / not planned

How each item was checked:
- **UI**: exercised by hand on the Android emulator (release build)
- **E2E**: covered by `integration_test/` on the emulator
- **Unit**: covered by `test/` on the host

## Reader

| Feature | Status | Checked |
| --- | --- | --- |
| Continuous scroll, pinch zoom, fit-width, zoom kept across toolbar changes | ✅ | UI |
| Single-page mode, page indicator, go to page | ✅ | UI |
| Search with match case / whole words, next/previous, highlighted hits | ✅ | UI |
| Text selection, copy, share selection | ✅ | UI |
| Bookmarks (user) and document outline (table of contents) | ✅ | UI, E2E |
| Page thumbnails / pages grid | ✅ | UI |
| App dark theme and inverted "dark pages" | ✅ | UI |
| Read aloud (device TTS) with sentence highlight, skip, pause | ✅ | UI |
| Password-protected files (prompt, reuse on reload) | ✅ | UI, E2E |
| Open from other apps (VIEW / SEND intents) | ✅ | UI |

## Smart reading (Liquid Mode alternative)

| Feature | Status | Checked |
| --- | --- | --- |
| Reflowed headings, paragraphs, lists, tables, images, collapsible sections | ✅ | UI, Unit |
| Keeps original formatting: colors, bold/italic, serif/sans/mono, underline, strike, links, alignment | ✅ | UI, E2E, Unit |
| Font size, spacing, theme, font family ("Original" by default) | ✅ | UI |
| Search and read aloud inside smart reading | ✅ | UI |
| Form field values shown in reflow | ⛔ | Not implemented |

## Editing

| Feature | Status | Checked |
| --- | --- | --- |
| Edit existing text (font, size, color detected and kept) | ✅ | UI, E2E |
| Add text boxes and images; move, resize, replace, delete images | ✅ | UI, E2E |
| Add shapes; move, resize, recolor, delete existing vector shapes | ✅ | UI, E2E |
| Add links (web / page) | ✅ | E2E |
| Watermarks (text or image, opacity, rotation, behind content) | ✅ | UI, E2E |
| Headers, footers, page numbers | ✅ | E2E |
| Undo / redo for every edit | ✅ | UI, Unit |

## Comments and annotations

| Feature | Status | Checked |
| --- | --- | --- |
| Highlight, underline, strikethrough, squiggly (word-snapped) | ✅ | UI, E2E |
| Freehand drawing, rectangles, ellipses, lines, arrows | ✅ | UI, E2E |
| Sticky notes and text boxes | ✅ | UI, E2E |
| Comment list, edit and delete existing annotations | ✅ | UI, E2E |
| Signatures: draw, type or image; saved for reuse | ✅ | UI |

## Fill & Sign / forms

| Feature | Status | Checked |
| --- | --- | --- |
| Fill AcroForm text fields, checkboxes, radio buttons, choice lists | ✅ | UI, E2E |
| Fill non-form PDFs: text, ✓, ✗, dot, signature, initials | ✅ | UI |
| Flatten forms and annotations | ✅ | E2E |
| Cryptographic (certificate) digital signatures | ⛔ | Not implemented |

## Pages

| Feature | Status | Checked |
| --- | --- | --- |
| Reorder, rotate, delete, duplicate, insert blank, insert from another PDF | ✅ | UI, E2E |
| Extract pages to a new PDF | ✅ | E2E |
| Combine (merge) PDFs | ✅ | UI, E2E |
| Split by every N pages, ranges, one file per page | ✅ | UI, E2E |
| Crop (auto-fits content margins; one page or all) | ✅ | UI, E2E |
| Compress (3 levels, optional grayscale) | ✅ | UI, E2E |

## Convert

| Feature | Status | Checked |
| --- | --- | --- |
| Images → PDF (page size, orientation, margins, reorder) | ✅ | UI, Unit |
| Word (.docx), Excel (.xlsx), text, Markdown → PDF | ✅ | Unit |
| PDF → Word (.docx) with headings, lists, tables, images, formatting | ✅ | UI, Unit |
| PDF → Excel (.xlsx): text plus one sheet per table | ✅ | UI, Unit |
| PDF → PowerPoint (.pptx): one slide per page, editable text boxes | ✅ | UI, Unit |
| PDF → HTML, Markdown, plain text, PNG, JPEG | ✅ | Unit |
| Blank PDF | ✅ | UI |

## Scanner and OCR

| Feature | Status | Checked |
| --- | --- | --- |
| Camera capture with live edge detection and auto-capture | ✅ | UI, Unit |
| Import photos; manual corner crop; perspective correction | ✅ | UI, Unit |
| Filters: original, auto color, grayscale, black & white, whiteboard, photo | ✅ | Unit |
| Offline OCR (ML Kit, bundled) → invisible, searchable text layer | ✅ | UI, E2E |
| OCR for non-Latin scripts (Chinese, Japanese, Korean, Devanagari) | ⛔ | Only the Latin model is bundled |

## Security

| Feature | Status | Checked |
| --- | --- | --- |
| Open password, AES-256 encryption (edits keep a file's existing encryption) | ✅ | UI, E2E |
| Permissions password and restrictions (print, copy, edit…) | ✅ | E2E |
| Remove security | ✅ | E2E |
| Edit metadata (title, author, subject, keywords) | ✅ | E2E |
| True redaction: removes glyphs, image pixels, vector paths and annotations underneath | ✅ | UI, E2E |
| Redaction by area, text selection, or find-and-mark | ✅ | UI |

## Files

| Feature | Status | Checked |
| --- | --- | --- |
| Recents, starred, folders (create, rename, move, delete) | ✅ | UI, Unit |
| Sort by name / date / size; search across the library | ✅ | UI, Unit |
| Rename, duplicate, share, save a copy to Downloads, print | ✅ | UI |
| Reopening the same external file returns your edited copy (no duplicates) | ✅ | Unit |
| Browse device storage (all-files access on Android 11+) | ✅ | UI |

## Known limitations

- **pdfrx pinned to 2.4.8.** Newer versions need Dart 3.13.
- **No certificate-based digital signatures.** Signatures are visual only.
- **OCR is Latin-script only.** Other ML Kit models are not bundled, to keep the APK small.
- **Scanner tuning used synthetic and emulator-camera images.** It hasn't been tried on many real-world photos.
- **Smart reading doesn't show form field values.**
- **Release APKs are signed with the debug key.** Add a real signing config before publishing.
