# Contributing to PDFCraft

Thanks for helping out! This guide covers how to set up the project, the conventions the code follows, and how to send a change.

## Set up

1. Install [Flutter](https://docs.flutter.dev/get-started/install) 3.44 (it includes Dart 3.12), the Android SDK and JDK 17.
2. Clone the repository and fetch dependencies:

   ```sh
   git clone https://github.com/iam-kanav/pdfcraft.git
   cd pdfcraft
   flutter pub get
   ```

3. Start an Android emulator (Android 8.0 or newer) or connect a phone, then run `flutter run`.

Want some PDFs to play with? Run `dart run tool/make_samples.dart` and `dart run tool/make_formatted_sample.dart`. The files are written to `build/samples/`.

Before you dive in, skim [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). It explains how the app is organized.

## Before you send a change

Run all three checks and make sure they pass:

```sh
flutter analyze                               # must report "No issues found"
flutter test                                  # unit and widget tests
flutter test integration_test -d <device-id>  # engine and UI tests on a device
```

The device tests reinstall the app, which clears its data on that device.

If your change affects what you see on screen, try it on a device and include a screenshot in your pull request.

## Code style

- **Format with `dart format`.** The line width is 120 (set in `analysis_options.yaml`).
- **Use single quotes** for Dart strings.
- **Keep the analyzer at zero issues.** Don't silence a warning without a comment explaining why.
- **Match the surrounding code.** Follow the naming, comment density and structure of nearby files.
- **Write comments that explain why**, not what. The code already says what it does.

## Rules that keep the app working

- **No network access.** PDFCraft is offline-only. Don't add dependencies or features that need the internet.
- **Change documents through `DocumentSession.apply()`.** This keeps undo, redo and safe saving working.
- **Never change a file in place.** Engine operations read the input file and write a new output file.
- **Use the shared coordinate system.** Positions between Dart and Kotlin are in PDF points, measured from the top-left of the page as displayed. See `engine/Geom.kt`.

## Adding a new PDF operation

Most new features need a new engine operation. Here's how to wire one up, using `stripText` as an example:

1. **Write the Kotlin function** in the matching file under `android/app/src/main/kotlin/com/pdfcraft/pdfcraft/engine/`. It takes a `Map<String, Any?>` of arguments. Use `PdfIO.edit` to open the input and save the output:

   ```kotlin
   fun stripText(args: Map<String, Any?>) {
       PdfIO.edit(args.path, args.password, args.out) { od ->
           // change od.doc here
       }
   }
   ```

2. **Register it** in the `when` block in `MainActivity.kt`:

   ```kotlin
   "stripText" -> ContentOps::stripText
   ```

3. **Add a Dart method** to `PdfEngine` in `lib/core/native/pdf_engine.dart`:

   ```dart
   Future<void> stripText(String path, String out, {String? password}) =>
       _call('stripText', _base(path, password, out));
   ```

4. **Call it from a screen** through the session, so undo works:

   ```dart
   await session.apply('Remove text', (input, out) => PdfEngine.instance.stripText(input, out, password: session.password));
   ```

5. **Add a test** to `integration_test/engine_test.dart` that runs the operation on a sample PDF and checks the result.

## Reporting bugs

Please open an issue and include:

- What you did, what you expected, and what happened instead
- Your Android version and phone model
- A sample PDF that shows the problem, if you can share one (remove anything private first)

## Commit messages

Write a short summary line in the imperative mood, such as "Fix crash when opening an empty PDF". If it helps, add a blank line and a few sentences explaining why the change was needed.
