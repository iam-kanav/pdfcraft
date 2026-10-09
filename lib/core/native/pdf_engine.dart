import 'package:flutter/services.dart';

import '../models/raw_page_content.dart';

/// Error raised by the native PDF engine.
class PdfEngineException implements Exception {
  PdfEngineException(this.code, this.message);

  final String code;
  final String message;

  bool get isPasswordError => code == 'PASSWORD';
  bool get isPermissionError => code == 'PERMISSION';

  @override
  String toString() => message;
}

List<double> rectToList(Rect r) => [r.left, r.top, r.right, r.bottom];

Rect listToRect(List<dynamic> l) => Rect.fromLTRB(
  (l[0] as num).toDouble(),
  (l[1] as num).toDouble(),
  (l[2] as num).toDouble(),
  (l[3] as num).toDouble(),
);

int colorToInt(Color c) => c.toARGB32();

/// Page specification for [PdfEngine.organize].
class PageSpec {
  const PageSpec.page(this.index, {this.rotate = 0})
    : file = null,
      password = null,
      blank = false,
      width = null,
      height = null;

  const PageSpec.fromFile(this.file, this.index, {this.password, this.rotate = 0})
    : blank = false,
      width = null,
      height = null;

  const PageSpec.blank({this.width = 595.28, this.height = 841.89})
    : index = 0,
      rotate = 0,
      file = null,
      password = null,
      blank = true;

  final int index;
  final int rotate;
  final String? file;
  final String? password;
  final bool blank;
  final double? width;
  final double? height;

  Map<String, Object?> toMap() => {
    if (blank) ...{
      'blank': true,
      'width': width,
      'height': height,
    } else ...{
      'index': index,
      'rotate': rotate,
      'file': ?file,
      'password': ?password,
    },
  };
}

class DocumentInfo {
  DocumentInfo(this.raw);

  final Map<dynamic, dynamic> raw;

  int get pageCount => raw['pageCount'] as int;
  bool get encrypted => raw['encrypted'] as bool;
  bool get isOwner => raw['isOwner'] as bool? ?? true;
  int get keyLength => raw['keyLength'] as int? ?? 0;
  String? get title => raw['title'] as String?;
  String? get author => raw['author'] as String?;
  String? get subject => raw['subject'] as String?;
  String? get keywords => raw['keywords'] as String?;
  String? get creator => raw['creator'] as String?;
  String? get producer => raw['producer'] as String?;
  double get version => (raw['version'] as num).toDouble();
  int get fieldCount => raw['fieldCount'] as int? ?? 0;
  int get fileSize => raw['fileSize'] as int? ?? 0;
  DateTime? get created => raw['created'] == null ? null : DateTime.fromMillisecondsSinceEpoch(raw['created'] as int);
  DateTime? get modified =>
      raw['modified'] == null ? null : DateTime.fromMillisecondsSinceEpoch(raw['modified'] as int);
  Map<String, bool> get permissions => (raw['permissions'] as Map).map((k, v) => MapEntry(k as String, v as bool));

  /// Display sizes (points) of each page with rotation applied.
  List<({double width, double height, int rotation})> get pages => [
    for (final p in raw['pages'] as List)
      (width: ((p as List)[0] as num).toDouble(), height: (p[1] as num).toDouble(), rotation: p[2] as int),
  ];
}

/// Typed facade over the Kotlin/PDFBox engine (`pdfcraft/engine` channel).
///
/// All coordinates are in "display space": PDF points, top-left origin, with the page
/// rotation applied — the same space as `PdfRect.toRect(page: page)` from pdfrx.
class PdfEngine {
  PdfEngine._();

  static final instance = PdfEngine._();
  static const _channel = MethodChannel('pdfcraft/engine');

  Future<T?> _call<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw PdfEngineException(e.code, e.message ?? 'PDF operation failed');
    }
  }

  Map<String, Object?> _base(String path, String? password, [String? out]) => {
    'path': path,
    'password': ?password,
    'out': ?out,
  };

  Future<DocumentInfo> info(String path, {String? password}) async =>
      DocumentInfo((await _call<Map>('info', _base(path, password)))!);

  Future<void> setMetadata(
    String path,
    String out,
    Map<String, String?> fields, {
    String? password,
    bool stripXmp = false,
  }) => _call('setMetadata', {..._base(path, password, out), 'fields': fields, 'stripXmp': stripXmp});

  Future<void> protect(
    String path,
    String out, {
    String? password,
    String userPassword = '',
    String? ownerPassword,
    Map<String, bool> permissions = const {},
    int keyLength = 256,
  }) => _call('protect', {
    ..._base(path, password, out),
    'userPassword': userPassword,
    'ownerPassword': ?ownerPassword,
    'permissions': permissions,
    'keyLength': keyLength,
  });

  Future<void> removeSecurity(String path, String out, {String? password}) =>
      _call('removeSecurity', _base(path, password, out));

  Future<int> organize(String path, String out, List<PageSpec> pages, {String? password}) async {
    final r = await _call<Map>('organize', {
      ..._base(path, password, out),
      'pages': [for (final p in pages) p.toMap()],
    });
    return r!['pageCount'] as int;
  }

  Future<List<String>> split(
    String path,
    String outDir,
    String baseName,
    List<(int, int)> ranges, {
    String? password,
  }) async {
    final r = await _call<List>('split', {
      ..._base(path, password),
      'outDir': outDir,
      'baseName': baseName,
      'ranges': [
        for (final r in ranges) [r.$1, r.$2],
      ],
    });
    return r!.cast<String>();
  }

  Future<void> crop(String path, String out, Map<int, Rect> crops, {String? password}) => _call('crop', {
    ..._base(path, password, out),
    'crops': [
      for (final e in crops.entries) {'page': e.key, 'rect': rectToList(e.value)},
    ],
  });

  Future<({int before, int after, int images})> compress(
    String path,
    String out, {
    String? password,
    double dpi = 150,
    double quality = 0.7,
    bool grayscale = false,
  }) async {
    final r = (await _call<Map>('compress', {
      ..._base(path, password, out),
      'dpi': dpi,
      'quality': quality,
      'grayscale': grayscale,
    }))!;
    return (before: r['before'] as int, after: r['after'] as int, images: r['images'] as int);
  }

  Future<void> flatten(String path, String out, {String? password, bool annotations = true}) =>
      _call('flatten', {..._base(path, password, out), 'annotations': annotations});

  Future<List<String>> addAnnotations(
    String path,
    String out,
    List<Map<String, Object?>> annotations, {
    String? password,
  }) async {
    final r = await _call<List>('addAnnotations', {..._base(path, password, out), 'annotations': annotations});
    return r!.cast<String>();
  }

  Future<List<Map<String, dynamic>>> listAnnotations(String path, {String? password, int? page}) async {
    final r = await _call<List>('listAnnotations', {..._base(path, password), 'page': ?page});
    return [for (final m in r!) (m as Map).cast<String, dynamic>()];
  }

  Future<int> deleteAnnotations(String path, String out, List<({int page, String id})> ids, {String? password}) async =>
      (await _call<int>('deleteAnnotations', {
        ..._base(path, password, out),
        'ids': [
          for (final i in ids) {'page': i.page, 'id': i.id},
        ],
      }))!;

  Future<void> updateAnnotation(
    String path,
    String out, {
    required int page,
    required String id,
    String? password,
    String? contents,
    Color? color,
    double? opacity,
    Rect? rect,
  }) => _call('updateAnnotation', {
    ..._base(path, password, out),
    'page': page,
    'id': id,
    'contents': ?contents,
    if (color != null) 'color': colorToInt(color),
    'opacity': ?opacity,
    if (rect != null) 'rect': rectToList(rect),
  });

  Future<List<Map<String, dynamic>>> listFields(String path, {String? password}) async {
    final r = await _call<List>('listFields', _base(path, password));
    return [for (final m in r!) (m as Map).cast<String, dynamic>()];
  }

  Future<void> fillForm(
    String path,
    String out,
    Map<String, Object?> values, {
    String? password,
    bool flatten = false,
  }) => _call('fillForm', {..._base(path, password, out), 'values': values, 'flatten': flatten});

  Future<List<Map<String, dynamic>>> getTextBlocks(String path, int page, {String? password}) async {
    final r = await _call<List>('getTextBlocks', {..._base(path, password), 'page': page});
    return [for (final m in r!) (m as Map).cast<String, dynamic>()];
  }

  Future<void> editTextBlocks(
    String path,
    String out,
    int page,
    List<Map<String, Object?>> edits, {
    String? password,
  }) => _call('editTextBlocks', {..._base(path, password, out), 'page': page, 'edits': edits});

  Future<List<Map<String, dynamic>>> getImageObjects(String path, int page, {String? password}) async {
    final r = await _call<List>('getImageObjects', {..._base(path, password), 'page': page});
    return [for (final m in r!) (m as Map).cast<String, dynamic>()];
  }

  Future<void> editImage(
    String path,
    String out, {
    required int page,
    required int id,
    required String action,
    Rect? rect,
    String? imagePath,
    String? password,
  }) => _call('editImage', {
    ..._base(path, password, out),
    'page': page,
    'id': id,
    'action': action,
    if (rect != null) 'rect': rectToList(rect),
    'imagePath': ?imagePath,
  });

  Future<List<Map<String, dynamic>>> getVectorObjects(String path, int page, {String? password}) async {
    final r = await _call<List>('getVectorObjects', {..._base(path, password), 'page': page});
    return [for (final m in r!) (m as Map).cast<String, dynamic>()];
  }

  /// [action]: 'delete', 'transform' (with [from]/[to] rects) or 'recolor' (with stroke/fill colors).
  Future<void> editVectors(
    String path,
    String out, {
    required int page,
    required List<int> ids,
    required String action,
    Rect? from,
    Rect? to,
    Color? strokeColor,
    Color? fillColor,
    String? password,
  }) => _call('editVectors', {
    ..._base(path, password, out),
    'page': page,
    'ids': ids,
    'action': action,
    if (from != null) 'from': rectToList(from),
    if (to != null) 'to': rectToList(to),
    if (strokeColor != null) 'strokeColor': colorToInt(strokeColor),
    if (fillColor != null) 'fillColor': colorToInt(fillColor),
  });

  Future<void> addContent(String path, String out, List<Map<String, Object?>> items, {String? password}) =>
      _call('addContent', {..._base(path, password, out), 'items': items});

  Future<Map<String, int>> redact(
    String path,
    String out,
    Map<int, List<Rect>> areas, {
    String? password,
    Color fill = const Color(0xFF000000),
    String? overlayText,
    bool removeMetadata = false,
  }) async {
    final r = await _call<Map>('redact', {
      ..._base(path, password, out),
      'areas': [
        for (final e in areas.entries) {'page': e.key, 'rects': e.value.map(rectToList).toList()},
      ],
      'fillColor': colorToInt(fill),
      'overlayText': ?overlayText,
      'removeMetadata': removeMetadata,
    });
    return r!.map((k, v) => MapEntry(k as String, v as int));
  }

  Future<void> watermark(
    String path,
    String out, {
    String? password,
    String? text,
    String? imagePath,
    double fontSize = 48,
    Color color = const Color(0xFFE11D48),
    double opacity = 0.3,
    double rotation = 45,
    String position = 'center',
    String layer = 'over',
    double imageScale = 0.5,
    List<int>? pages,
  }) => _call('watermark', {
    ..._base(path, password, out),
    'text': ?text,
    'imagePath': ?imagePath,
    'fontSize': fontSize,
    'color': colorToInt(color),
    'opacity': opacity,
    'rotation': rotation,
    'position': position,
    'layer': layer,
    'imageScale': imageScale,
    'pages': ?pages,
  });

  Future<void> pageNumbers(
    String path,
    String out, {
    String? password,
    String format = '{n}',
    String position = 'bottom-center',
    double fontSize = 10,
    Color color = const Color(0xFF000000),
    int startNumber = 1,
    double margin = 28,
    List<int>? pages,
  }) => _call('pageNumbers', {
    ..._base(path, password, out),
    'format': format,
    'position': position,
    'fontSize': fontSize,
    'color': colorToInt(color),
    'startNumber': startNumber,
    'margin': margin,
    'pages': ?pages,
  });

  Future<int> removeArtifacts(
    String path,
    String out, {
    String? password,
    List<String> kinds = const ['Watermark'],
  }) async => (await _call<int>('removeArtifacts', {..._base(path, password, out), 'kinds': kinds}))!;

  Future<List<RawPageContent>> extractPages(
    String path, {
    String? password,
    List<int>? pages,
    bool images = true,
  }) async {
    final r = await _call<List>('extractPages', {..._base(path, password), 'pages': ?pages, 'images': images});
    return [for (final m in r!) RawPageContent.fromMap(m as Map)];
  }

  Future<int> addOcrLayer(
    String path,
    String out,
    Map<int, List<({String text, Rect rect})>> pages, {
    String? password,
  }) async => (await _call<int>('addOcrLayer', {
    ..._base(path, password, out),
    'pages': [
      for (final e in pages.entries)
        {
          'page': e.key,
          'words': [
            for (final w in e.value) {'text': w.text, 'rect': rectToList(w.rect)},
          ],
        },
    ],
  }))!;
}
