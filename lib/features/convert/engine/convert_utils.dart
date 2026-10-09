import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:pdfcraft/core/models/doc_structure.dart';

/// Shared helpers for the conversion engine.

/// Removes characters that are not allowed in XML 1.0 documents:
/// control characters other than TAB/LF/CR, lone surrogates, U+FFFE/U+FFFF.
String stripInvalidXmlChars(String input) {
  var clean = true;
  for (final r in input.runes) {
    if (!_isValidXmlRune(r)) {
      clean = false;
      break;
    }
  }
  if (clean) return input;
  final sb = StringBuffer();
  for (final r in input.runes) {
    if (_isValidXmlRune(r)) sb.writeCharCode(r);
  }
  return sb.toString();
}

bool _isValidXmlRune(int r) =>
    r == 0x9 ||
    r == 0xA ||
    r == 0xD ||
    (r >= 0x20 && r <= 0xD7FF) ||
    (r >= 0xE000 && r <= 0xFFFD) ||
    (r >= 0x10000 && r <= 0x10FFFF);

/// Escapes text for use in XML character data and attribute values, after
/// removing characters invalid in XML 1.0.
String xmlEscape(String input) {
  final s = stripInvalidXmlChars(input);
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    switch (c) {
      case 0x26:
        sb.write('&amp;');
      case 0x3C:
        sb.write('&lt;');
      case 0x3E:
        sb.write('&gt;');
      case 0x22:
        sb.write('&quot;');
      case 0x27:
        sb.write('&apos;');
      default:
        sb.writeCharCode(c);
    }
  }
  return sb.toString();
}

/// Detected raster image container format.
enum ImageKind { png, jpeg, gif, bmp, webp, tiff, unknown }

/// Detects the image format from its magic bytes.
ImageKind detectImageKind(List<int> b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return ImageKind.png;
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return ImageKind.jpeg;
  }
  if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
    return ImageKind.gif;
  }
  if (b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D) return ImageKind.bmp;
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return ImageKind.webp;
  }
  if (b.length >= 4 &&
      ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) ||
          (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A))) {
    return ImageKind.tiff;
  }
  return ImageKind.unknown;
}

/// Reads the pixel dimensions of an encoded image from its header without
/// decoding the pixel data. Returns null when the format is not recognised.
({int width, int height})? readImageSize(Uint8List bytes) {
  try {
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null) return null;
    final info = decoder.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return (width: info.width, height: info.height);
  } catch (_) {
    return null;
  }
}

/// Returns the image as PNG or JPEG bytes. PNG and JPEG input is returned
/// unchanged; other decodable formats (GIF, BMP, WebP, TIFF, ...) are
/// converted to PNG. Returns null if the data cannot be decoded.
Uint8List? normalizeToPngOrJpeg(Uint8List bytes) {
  final kind = detectImageKind(bytes);
  if (kind == ImageKind.png || kind == ImageKind.jpeg) return bytes;
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    return img.encodePng(decoded);
  } catch (_) {
    return null;
  }
}

/// Merges adjacent spans that have identical styling and drops empty spans.
List<TextSpanData> mergeSpans(Iterable<TextSpanData> spans) {
  final out = <TextSpanData>[];
  for (final s in spans) {
    if (s.text.isEmpty) continue;
    if (out.isNotEmpty && sameSpanStyle(out.last, s)) {
      out[out.length - 1] = out.last.copyWith(text: out.last.text + s.text);
    } else {
      out.add(s);
    }
  }
  return out;
}

bool sameSpanStyle(TextSpanData a, TextSpanData b) => a.sameStyleAs(b);

/// 'RRGGBB' hex for an ARGB color.
String hexRgb(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

TextSpanData spanWith(TextSpanData s, {String? text, bool? bold, bool? italic, bool? underline}) => TextSpanData(
  text ?? s.text,
  bold: bold ?? s.bold,
  italic: italic ?? s.italic,
  underline: underline ?? s.underline,
  strike: s.strike,
  link: s.link,
  color: s.color,
  fontFamily: s.fontFamily,
  sizeRatio: s.sizeRatio,
);

/// Number formats used for ordered lists by nesting level, shared by the
/// DOCX writer, PDF builder and text exporter so numbering looks the same in
/// every output.
enum ListNumberFormat { decimal, lowerLetter, lowerRoman, upperLetter, upperRoman }

ListNumberFormat orderedFormatForLevel(int level) =>
    const [ListNumberFormat.decimal, ListNumberFormat.lowerLetter, ListNumberFormat.lowerRoman][level % 3];

String formatListNumber(int n, ListNumberFormat format) {
  switch (format) {
    case ListNumberFormat.decimal:
      return '$n';
    case ListNumberFormat.lowerLetter:
      return toAlpha(n).toLowerCase();
    case ListNumberFormat.upperLetter:
      return toAlpha(n);
    case ListNumberFormat.lowerRoman:
      return toRoman(n).toLowerCase();
    case ListNumberFormat.upperRoman:
      return toRoman(n);
  }
}

/// 1 -> A, 26 -> Z, 27 -> AA (spreadsheet style).
String toAlpha(int n) {
  if (n <= 0) return '$n';
  final sb = <String>[];
  var v = n;
  while (v > 0) {
    v -= 1;
    sb.add(String.fromCharCode(0x41 + v % 26));
    v ~/= 26;
  }
  return sb.reversed.join();
}

String toRoman(int n) {
  if (n <= 0 || n >= 4000) return '$n';
  const values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  const symbols = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
  final sb = StringBuffer();
  var v = n;
  for (var i = 0; i < values.length; i++) {
    while (v >= values[i]) {
      sb.write(symbols[i]);
      v -= values[i];
    }
  }
  return sb.toString();
}

/// Tracks running numbers of (possibly nested) ordered lists while walking a
/// block sequence. Call [next] for every list item and [reset] for any
/// non-list block.
class ListCounter {
  final List<int> _counts = [];
  final List<bool> _ordered = [];

  void reset() {
    _counts.clear();
    _ordered.clear();
  }

  /// Returns the running number (1-based) of [item] within its list level.
  int next(ListItemBlock item) {
    final level = item.indent < 0 ? 0 : item.indent;
    if (_counts.length > level + 1) {
      _counts.removeRange(level + 1, _counts.length);
      _ordered.removeRange(level + 1, _ordered.length);
    }
    while (_counts.length < level + 1) {
      _counts.add(0);
      _ordered.add(item.ordered);
    }
    if (_ordered[level] != item.ordered) {
      _counts[level] = 0;
      _ordered[level] = item.ordered;
    }
    _counts[level]++;
    return _counts[level];
  }
}

/// Bullet glyphs per nesting level; all exist in Noto Sans.
const List<String> bulletGlyphs = ['•', '–', '‣'];

String bulletForLevel(int level) => bulletGlyphs[(level < 0 ? 0 : level) % bulletGlyphs.length];

/// Marker text ("3.", "b.", "•") for a list item at its running [number].
String listMarker(ListItemBlock item, int number) => item.ordered
    ? '${formatListNumber(number, orderedFormatForLevel(item.indent < 0 ? 0 : item.indent))}.'
    : bulletForLevel(item.indent);
