import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/models/doc_structure.dart';

/// Bump when extraction or analysis changes what Smart reading produces, so
/// documents analyzed by an older version are analyzed again.
const reflowCacheVersion = 1;

/// Saved Smart reading results, so a document reopens instantly. Entries are
/// keyed by the file's path, size and modification time, so an edited file
/// is analyzed again. Lives in the cache directory ("Clear cache" removes it).
///
/// Never used for password-protected files: that would store their text
/// unencrypted.
class ReflowCache {
  ReflowCache(this.dir);

  final Directory dir;

  /// Most entries kept; the least recently opened go first.
  static const maxEntries = 30;
  static const maxBytes = 200 * 1024 * 1024;

  static Future<ReflowCache> open() async =>
      ReflowCache(Directory(p.join((await getTemporaryDirectory()).path, 'reflow')));

  Future<File?> _entry(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final key = '$reflowCacheVersion|${file.absolute.path}|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    return File(p.join(dir.path, '${sha1.convert(utf8.encode(key))}.bin'));
  }

  /// The saved result for [path], or null when there is none (or it is
  /// unreadable).
  Future<DocStructure?> read(String path) async {
    try {
      final entry = await _entry(path);
      if (entry == null || !await entry.exists()) return null;
      final file = entry.path;
      final doc = await Isolate.run(() => decodeDocStructure(File(file).readAsBytesSync()));
      // Recently opened entries are kept longest.
      await entry.setLastModified(DateTime.now());
      return doc;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String path, DocStructure doc) async {
    try {
      final entry = await _entry(path);
      if (entry == null) return;
      await dir.create(recursive: true);
      final bytes = await Isolate.run(() => encodeDocStructure(doc));
      final tmp = File('${entry.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(entry.path);
      await _prune();
    } catch (_) {
      // A cache that can't be written just means a slower next open.
    }
  }

  Future<void> _prune() async {
    final files = [
      await for (final e in dir.list())
        if (e is File && e.path.endsWith('.bin')) e,
    ];
    final stats = {for (final f in files) f: await f.stat()};
    files.sort((a, b) => stats[b]!.modified.compareTo(stats[a]!.modified));
    var total = 0;
    for (var i = 0; i < files.length; i++) {
      total += stats[files[i]]!.size;
      if (i >= maxEntries || total > maxBytes) await files[i].delete();
    }
  }
}

// ---------------------------------------------------------------------------
// Format: 4-byte big-endian JSON length, the JSON, then the image bytes the
// JSON refers to by offset and length.
// ---------------------------------------------------------------------------

Uint8List encodeDocStructure(DocStructure doc) {
  final images = BytesBuilder(copy: false);
  List<Object?> spans(List<TextSpanData> spans) => [
    for (final s in spans)
      [
        s.text,
        (s.bold ? 1 : 0) | (s.italic ? 2 : 0) | (s.underline ? 4 : 0) | (s.strike ? 8 : 0),
        s.link,
        s.color,
        s.fontFamily,
        s.sizeRatio,
      ],
  ];
  Map<String, Object?> block(DocBlock b) => {
    'p': b.pageNumber,
    ...switch (b) {
      HeadingBlock h => {'t': 'h', 'l': h.level, 's': spans(h.spans), 'a': h.align.index},
      ParagraphBlock x => {'t': 'p', 's': spans(x.spans), 'a': x.align.index},
      ListItemBlock l => {'t': 'li', 's': spans(l.spans), 'o': l.ordered, 'm': l.marker, 'i': l.indent},
      QuoteBlock q => {'t': 'q', 's': spans(q.spans)},
      TableBlock t => {'t': 'tb', 'r': t.rows, 'hh': t.hasHeader},
      PageBreakBlock() => {'t': 'br'},
      ImageBlock im => () {
        final offset = images.length;
        images.add(im.bytes);
        return {'t': 'img', 'w': im.width, 'h': im.height, 'c': im.caption, 'o': offset, 'n': im.bytes.length};
      }(),
    },
  };
  final json = utf8.encode(
    jsonEncode({
      'title': doc.title,
      'blocks': [for (final b in doc.blocks) block(b)],
    }),
  );
  final out = BytesBuilder(copy: false)
    ..add((ByteData(4)..setUint32(0, json.length)).buffer.asUint8List())
    ..add(json)
    ..add(images.takeBytes());
  return out.takeBytes();
}

DocStructure decodeDocStructure(Uint8List bytes) {
  final length = ByteData.sublistView(bytes, 0, 4).getUint32(0);
  final data = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 4, 4 + length))) as Map<String, dynamic>;
  final imageStart = 4 + length;
  List<TextSpanData> spans(Object? list) => [
    for (final s in list! as List)
      TextSpanData(
        s[0] as String,
        bold: (s[1] as int) & 1 != 0,
        italic: (s[1] as int) & 2 != 0,
        underline: (s[1] as int) & 4 != 0,
        strike: (s[1] as int) & 8 != 0,
        link: s[2] as String?,
        color: s[3] as int?,
        fontFamily: s[4] as String?,
        sizeRatio: (s[5] as num).toDouble(),
      ),
  ];
  DocBlock block(Map<String, dynamic> m) {
    final page = m['p'] as int?;
    return switch (m['t']) {
      'h' => HeadingBlock(
        level: m['l'] as int,
        spans: spans(m['s']),
        align: BlockAlign.values[m['a'] as int],
        pageNumber: page,
      ),
      'p' => ParagraphBlock(spans: spans(m['s']), align: BlockAlign.values[m['a'] as int], pageNumber: page),
      'li' => ListItemBlock(
        spans: spans(m['s']),
        ordered: m['o'] as bool,
        marker: m['m'] as String?,
        indent: m['i'] as int,
        pageNumber: page,
      ),
      'q' => QuoteBlock(spans: spans(m['s']), pageNumber: page),
      'tb' => TableBlock(
        rows: [
          for (final r in m['r'] as List) [for (final c in r as List) c as String],
        ],
        hasHeader: m['hh'] as bool,
        pageNumber: page,
      ),
      'br' => PageBreakBlock(pageNumber: page),
      'img' => ImageBlock(
        // A copy, not a view: views are sent between isolates with their whole buffer.
        bytes: bytes.sublist(imageStart + (m['o'] as int), imageStart + (m['o'] as int) + (m['n'] as int)),
        width: m['w'] as int,
        height: m['h'] as int,
        caption: m['c'] as String?,
        pageNumber: page,
      ),
      final t => throw FormatException('Unknown block type $t'),
    };
  }

  return DocStructure(
    title: data['title'] as String?,
    blocks: [for (final b in data['blocks'] as List) block(b as Map<String, dynamic>)],
  );
}
