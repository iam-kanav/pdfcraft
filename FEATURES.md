# Feature checklist

This page lists everything PDFCraft can do, what's still missing, and how each feature was tested.

**Status:** ✅ done · 🟡 partly done · ⛔ not supported yet

**How it was tested:**
- **Manual:** tried by hand on an Android emulator, using the release build
- **Device test:** covered by automated tests that run on an Android device (`integration_test/`)
- **Unit test:** covered by automated tests that run on a computer (`test/`)

## Reading

| Feature | Status | Tested by |
| --- | --- | --- |
| Smooth scrolling and pinch to zoom; zoom stays put when toolbars change | ✅ | Manual |
| Single-page and continuous layouts, page indicator, go to page | ✅ | Manual |
| Search with highlighted results, next and previous match | ✅ | Manual |
| Select, copy and share text | ✅ | Manual |
| Your own bookmarks and the document's table of contents | ✅ | Manual, device test |
| Page thumbnails | ✅ | Manual |
| Dark theme, plus inverted "night mode" pages | ✅ | Manual |
| Read aloud with the current sentence highlighted | ✅ | Manual |
| Open password-protected files (asks once per session) | ✅ | Manual, device test |
| Open PDFs shared from other apps | ✅ | Manual |

## Smart reading

| Feature | Status | Tested by |
| --- | --- | --- |
| Reflows headings, paragraphs, lists, tables and images to fit the screen | ✅ | Manual, unit test |
| Keeps colors, bold and italic, font style, underline, strikethrough, links and alignment | ✅ | Manual, device test, unit test |
| Adjustable text size, spacing, font and theme | ✅ | Manual |
| Search and read aloud inside smart reading | ✅ | Manual |
| Shows the values typed into form fields | ⛔ | — |

## Editing

| Feature | Status | Tested by |
| --- | --- | --- |
| Edit existing text, keeping its font, size and color | ✅ | Manual, device test |
| Add text boxes and images; move, resize, replace or delete images | ✅ | Manual, device test |
| Add shapes; move, resize, recolor or delete existing drawings | ✅ | Manual, device test |
| Add links to web pages or other pages | ✅ | Device test |
| Text or image watermarks | ✅ | Manual, device test |
| Page numbers, headers and footers | ✅ | Device test |
| Undo and redo for every change | ✅ | Manual, unit test |

## Comments

| Feature | Status | Tested by |
| --- | --- | --- |
| Highlight, underline, strike out and squiggly underline (snaps to whole words) | ✅ | Manual, device test |
| Freehand drawing, rectangles, ellipses, lines and arrows | ✅ | Manual, device test |
| Sticky notes and text boxes | ✅ | Manual, device test |
| List, edit and delete existing comments | ✅ | Manual, device test |

## Forms and signatures

| Feature | Status | Tested by |
| --- | --- | --- |
| Fill in text fields, checkboxes, radio buttons and lists | ✅ | Manual, device test |
| Fill in PDFs that have no form fields: text, ✓, ✗, dots | ✅ | Manual |
| Signatures and initials: draw, type or import a photo; saved for reuse | ✅ | Manual |
| Flatten forms and comments into the page | ✅ | Device test |
| Certificate-based digital signatures | ⛔ | — |

## Pages

| Feature | Status | Tested by |
| --- | --- | --- |
| Reorder, rotate, delete, duplicate and insert pages (blank or from another PDF) | ✅ | Manual, device test |
| Extract pages into a new PDF | ✅ | Device test |
| Combine several PDFs into one | ✅ | Manual, device test |
| Split by page count, by ranges, or into single pages | ✅ | Manual, device test |
| Crop margins (fits the content automatically, for one page or all) | ✅ | Manual, device test |
| Compress at three levels, with optional grayscale | ✅ | Manual, device test |

## Converting

| Feature | Status | Tested by |
| --- | --- | --- |
| Photos to PDF, with page size, orientation, margins and ordering | ✅ | Manual, unit test |
| Word, Excel, text and Markdown files to PDF | ✅ | Unit test |
| PDF to Word, keeping headings, lists, tables, images and text styles | ✅ | Manual, unit test |
| PDF to Excel: all text, plus one sheet per table | ✅ | Manual, unit test |
| PDF to PowerPoint: one slide per page with editable text | ✅ | Manual, unit test |
| PDF to HTML, Markdown, plain text, PNG or JPEG | ✅ | Unit test |
| Blank PDF | ✅ | Manual |

## Scanning and text recognition

| Feature | Status | Tested by |
| --- | --- | --- |
| Camera with live edge detection and auto-capture | ✅ | Manual, unit test |
| Import photos, adjust corners, straighten the page | ✅ | Manual, unit test |
| Filters: original, auto color, grayscale, black & white, whiteboard, photo | ✅ | Unit test |
| Asks before discarding scanned pages that haven't been saved | ✅ | Manual |
| Offline text recognition that makes scans searchable | ✅ | Manual, device test |
| Text recognition for Chinese, Japanese, Korean or Devanagari | ⛔ | — |

## Security

| Feature | Status | Tested by |
| --- | --- | --- |
| Password protection with AES-256 encryption | ✅ | Manual, device test |
| Permission password and restrictions (printing, copying, editing) | ✅ | Device test |
| Remove passwords and restrictions | ✅ | Device test |
| Edit document properties (title, author, subject, keywords) | ✅ | Device test |
| Permanent redaction that removes text, images and drawings underneath | ✅ | Manual, device test |
| Redact by area, by selected text, or by searching | ✅ | Manual |

## Files

| Feature | Status | Tested by |
| --- | --- | --- |
| Recent and starred files; create, rename, move and delete folders | ✅ | Manual, unit test |
| Sort by name, date or size; search the whole library | ✅ | Manual, unit test |
| Rename, duplicate, share, print and save a copy to Downloads | ✅ | Manual |
| Opening the same file again shows your edited copy instead of a duplicate | ✅ | Manual, unit test |
| Browse PDFs anywhere on the device (optional all-files access) | ✅ | Manual |

## Known limitations

- **Signatures are visual only.** Certificate-based digital signatures aren't supported.
- **Text recognition reads Latin-script languages only.** Other ML Kit models aren't bundled, to keep the app small.
- **The scanner was tuned mostly on test images.** It hasn't been tried on a wide range of real-world photos yet.
- **Smart reading doesn't show form field values.**
- **pdfrx is held at version 2.4.8.** Newer versions need a newer Dart release than this project uses.
- **Release builds are signed with the debug key.** Add a real signing key before publishing.
