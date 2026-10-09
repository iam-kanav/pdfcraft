<img src="assets/icon.svg" width="64" height="64" alt="">

# PDFCraft

An offline PDF reader, editor, scanner and converter for Android, built with Flutter.
Everything runs on the device: no backend, no accounts, no cloud or AI services.

See [FEATURES.md](FEATURES.md) for the full checklist and known limitations.

## How it's built

- **Viewing, search, text selection:** [pdfrx](https://pub.dev/packages/pdfrx) (PDFium), pinned to 2.4.8.
- **Editing engine:** Kotlin on top of [PdfBox-Android](https://github.com/TomRoush/PdfBox-Android), called through the `pdfcraft/engine` method channel (`android/app/src/main/kotlin/.../engine/`). It rewrites content streams for real text editing, vector-shape editing and true redaction.
- **OCR:** ML Kit text recognition with the bundled Latin model.
- **Scanner image processing:** pure Dart (edge detection, perspective correction, filters), run in isolates.
- **Office formats:** DOCX, XLSX and PPTX are read and written directly as OOXML (`lib/features/convert/engine/`).
- **Smart reading:** reflow analysis in `lib/features/reflow/`, using positioned text and styles extracted natively.

## Build

```sh
flutter pub get
flutter build apk --release --split-per-abi   # per-device APKs (~42–52 MB)
flutter build apk --release                   # universal APK (~124 MB)
```

Output goes to `build/app/outputs/flutter-apk/`. Most phones need `app-arm64-v8a-release.apk`.

Release builds are currently signed with the debug key. Add a signing config in `android/app/build.gradle.kts` before publishing.

## Test

```sh
flutter analyze
flutter test                                          # host unit and widget tests
flutter test integration_test -d <android-device-id>  # engine and UI flow on a device or emulator
```

Sample PDFs for manual testing: `dart run tool/make_samples.dart` and `dart run tool/make_formatted_sample.dart` (written to `build/samples/`).
