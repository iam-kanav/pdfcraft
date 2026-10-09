import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/native/pdf_engine.dart';

enum ViewerMode { read, comment, edit, fillSign, redact }

enum CommentTool { select, note, highlight, underline, strikeout, squiggly, freeText, ink, rect, ellipse, line, arrow }

enum EditTool { select, addText, addImage, rect, ellipse, line, arrow, link }

enum FillTool { select, text, check, cross, dot, signature, initials }

extension CommentToolX on CommentTool {
  String get label => switch (this) {
    CommentTool.select => 'Select',
    CommentTool.note => 'Sticky note',
    CommentTool.highlight => 'Highlight',
    CommentTool.underline => 'Underline',
    CommentTool.strikeout => 'Strikethrough',
    CommentTool.squiggly => 'Squiggly',
    CommentTool.freeText => 'Text',
    CommentTool.ink => 'Draw',
    CommentTool.rect => 'Rectangle',
    CommentTool.ellipse => 'Oval',
    CommentTool.line => 'Line',
    CommentTool.arrow => 'Arrow',
  };

  IconData get icon => switch (this) {
    CommentTool.select => Icons.near_me_outlined,
    CommentTool.note => Icons.sticky_note_2_outlined,
    CommentTool.highlight => Icons.border_color_outlined,
    CommentTool.underline => Icons.format_underline,
    CommentTool.strikeout => Icons.format_strikethrough,
    CommentTool.squiggly => Icons.waves,
    CommentTool.freeText => Icons.text_fields,
    CommentTool.ink => Icons.gesture,
    CommentTool.rect => Icons.crop_square,
    CommentTool.ellipse => Icons.circle_outlined,
    CommentTool.line => Icons.horizontal_rule,
    CommentTool.arrow => Icons.arrow_right_alt,
  };

  bool get isTextMarkup =>
      this == CommentTool.highlight || this == CommentTool.underline || this == CommentTool.strikeout || this == CommentTool.squiggly;

  bool get isDrag => this == CommentTool.ink || this == CommentTool.rect || this == CommentTool.ellipse || this == CommentTool.line || this == CommentTool.arrow;

  String get annotationType => switch (this) {
    CommentTool.highlight => 'highlight',
    CommentTool.underline => 'underline',
    CommentTool.strikeout => 'strikeout',
    CommentTool.squiggly => 'squiggly',
    CommentTool.rect => 'square',
    CommentTool.ellipse => 'circle',
    CommentTool.line => 'line',
    CommentTool.arrow => 'arrow',
    CommentTool.ink => 'ink',
    CommentTool.freeText => 'freetext',
    CommentTool.note => 'note',
    CommentTool.select => '',
  };
}

/// An annotation as reported by the engine (display-space rect).
class AnnotInfo {
  AnnotInfo(this.raw);

  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  int get page => raw['page'] as int;
  String get type => raw['type'] as String? ?? 'Unknown';
  Rect get rect => listToRect(raw['rect'] as List);
  String? get contents => raw['contents'] as String?;
  String? get author => raw['author'] as String?;
  Color? get color => raw['color'] == null ? null : Color(raw['color'] as int);
  String? get url => raw['url'] as String?;
  int? get targetPage => raw['targetPage'] as int?;
  String? get modified => raw['modified'] as String?;

  bool get isLink => type == 'Link';

  String get typeLabel => switch (type) {
    'Text' => 'Note',
    'Highlight' => 'Highlight',
    'Underline' => 'Underline',
    'StrikeOut' => 'Strikethrough',
    'Squiggly' => 'Squiggly',
    'FreeText' => 'Text box',
    'Ink' => 'Drawing',
    'Square' => 'Rectangle',
    'Circle' => 'Oval',
    'Line' => 'Line',
    'Stamp' => 'Stamp',
    'Link' => 'Link',
    _ => type,
  };

  IconData get icon => switch (type) {
    'Text' => Icons.sticky_note_2_outlined,
    'Highlight' => Icons.border_color_outlined,
    'Underline' => Icons.format_underline,
    'StrikeOut' => Icons.format_strikethrough,
    'FreeText' => Icons.text_fields,
    'Ink' => Icons.gesture,
    'Square' => Icons.crop_square,
    'Circle' => Icons.circle_outlined,
    'Line' => Icons.horizontal_rule,
    'Stamp' => Icons.approval_outlined,
    'Link' => Icons.link,
    _ => Icons.comment_outlined,
  };
}

/// A stroke being drawn (page display coordinates).
class InkStroke {
  InkStroke(this.page, this.color, this.width, this.opacity);

  final int page;
  final Color color;
  final double width;
  final double opacity;
  final List<Offset> points = [];
}

/// Mutable UI state shared by the viewer and its mode layers.
class ViewerState extends ChangeNotifier {
  ViewerMode _mode = ViewerMode.read;
  CommentTool _commentTool = CommentTool.select;
  EditTool _editTool = EditTool.select;
  FillTool _fillTool = FillTool.select;
  Color color;
  Color inkColor;
  double strokeWidth;
  double opacity = 1;
  double fontSize = 14;
  bool panLocked = false;

  /// Redact mode: mark areas by dragging (true) or by selecting text (false).
  bool redactByArea = true;

  /// Strokes drawn but not yet saved.
  final List<InkStroke> pendingStrokes = [];

  /// Areas marked for redaction (page index → rects).
  final Map<int, List<Rect>> redactions = {};

  AnnotInfo? selectedAnnotation;

  ViewerState({required this.color, required this.inkColor, required this.strokeWidth});

  ViewerMode get mode => _mode;
  CommentTool get commentTool => _commentTool;
  EditTool get editTool => _editTool;
  FillTool get fillTool => _fillTool;

  set mode(ViewerMode m) {
    _mode = m;
    _commentTool = CommentTool.select;
    _editTool = EditTool.select;
    _fillTool = FillTool.select;
    selectedAnnotation = null;
    panLocked = m == ViewerMode.redact && redactByArea;
    notifyListeners();
  }

  void setRedactByArea(bool v) {
    redactByArea = v;
    panLocked = v;
    notifyListeners();
  }

  set commentTool(CommentTool t) {
    _commentTool = t;
    selectedAnnotation = null;
    panLocked = t.isDrag;
    notifyListeners();
  }

  set editTool(EditTool t) {
    _editTool = t;
    panLocked = t == EditTool.rect || t == EditTool.ellipse || t == EditTool.line || t == EditTool.arrow || t == EditTool.link;
    notifyListeners();
  }

  set fillTool(FillTool t) {
    _fillTool = t;
    selectedAnnotation = null;
    notifyListeners();
  }

  void select(AnnotInfo? a) {
    selectedAnnotation = a;
    notifyListeners();
  }

  void togglePanLock() {
    panLocked = !panLocked;
    notifyListeners();
  }

  void changed() => notifyListeners();

  int get redactionCount => redactions.values.fold(0, (a, l) => a + l.length);
}

/// Groups the characters of a selected text range into one rect per line (display space).
List<Rect> lineRectsForRange(PdfPageTextRange range, PdfPage page) {
  final rects = <Rect>[];
  Rect? current;
  final chars = range.pageText.charRects;
  for (var i = range.start; i < range.end && i < chars.length; i++) {
    final ch = range.pageText.fullText[i];
    if (ch == '\n' || ch == '\r') continue;
    final r = chars[i].toRect(page: page);
    if (r.width <= 0 || r.height <= 0) continue;
    if (current != null &&
        (r.center.dy - current.center.dy).abs() < current.height * 0.5 &&
        r.left <= current.right + current.height * 1.5 &&
        r.right >= current.left - current.height) {
      current = current.expandToInclude(r);
    } else {
      if (current != null) rects.add(current);
      current = r;
    }
  }
  if (current != null) rects.add(current);
  return rects;
}
