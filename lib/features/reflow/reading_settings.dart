import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Colors used by the reading view for one theme.
@immutable
class ReadingThemeColors {
  const ReadingThemeColors({
    required this.background,
    required this.surface,
    required this.text,
    required this.secondaryText,
    required this.accent,
    required this.divider,
    required this.brightness,
  });

  final Color background;

  /// Slightly contrasting surface (table headers, code, cards).
  final Color surface;
  final Color text;
  final Color secondaryText;
  final Color accent;
  final Color divider;
  final Brightness brightness;
}

/// Reading color themes, each with its palette in [colors].
enum ReadingTheme {
  light(
    'Light',
    ReadingThemeColors(
      background: Color(0xFFFFFFFF),
      surface: Color(0xFFF2F4F7),
      text: Color(0xFF1C1E21),
      secondaryText: Color(0xFF5F6368),
      accent: Color(0xFF1565C0),
      divider: Color(0xFFDADCE0),
      brightness: Brightness.light,
    ),
  ),
  sepia(
    'Sepia',
    ReadingThemeColors(
      background: Color(0xFFF6EEDC),
      surface: Color(0xFFEDE1C6),
      text: Color(0xFF4A3B2A),
      secondaryText: Color(0xFF7A6650),
      accent: Color(0xFFA0522D),
      divider: Color(0xFFD9C8A6),
      brightness: Brightness.light,
    ),
  ),
  dark(
    'Dark',
    ReadingThemeColors(
      background: Color(0xFF1E1F22),
      surface: Color(0xFF2B2D31),
      text: Color(0xFFE3E3E6),
      secondaryText: Color(0xFFA0A3A8),
      accent: Color(0xFF8AB4F8),
      divider: Color(0xFF3C3F44),
      brightness: Brightness.dark,
    ),
  ),
  black(
    'Black',
    ReadingThemeColors(
      background: Color(0xFF000000),
      surface: Color(0xFF151515),
      text: Color(0xFFD6D6D6),
      secondaryText: Color(0xFF8E8E8E),
      accent: Color(0xFFFFB74D),
      divider: Color(0xFF2A2A2A),
      brightness: Brightness.dark,
    ),
  );

  const ReadingTheme(this.label, this.colors);

  final String label;
  final ReadingThemeColors colors;
}

/// Horizontal page margins of the reading view.
enum ReadingMargin {
  narrow('Narrow', 12),
  normal('Normal', 24),
  wide('Wide', 48);

  const ReadingMargin(this.label, this.padding);

  final String label;

  /// Horizontal padding in logical pixels.
  final double padding;
}

/// User preferences for Smart Reading Mode, persisted in SharedPreferences.
class ReadingSettings extends ChangeNotifier {
  ReadingSettings();

  static const double minFontScale = 0.8;
  static const double maxFontScale = 2.0;
  static const double minLineHeight = 1.2;
  static const double maxLineHeight = 2.2;
  static const List<String> fontFamilies = ['sans', 'serif', 'mono'];

  /// Base body text size before [fontScale] is applied.
  static const double baseFontSize = 16;

  static const _kFontScale = 'reflow.fontScale';
  static const _kLineHeight = 'reflow.lineHeight';
  static const _kFontFamily = 'reflow.fontFamily';
  static const _kJustify = 'reflow.justify';
  static const _kMargin = 'reflow.margin';
  static const _kTheme = 'reflow.theme';

  double _fontScale = 1.0;
  double _lineHeight = 1.6;
  String _fontFamily = 'sans';
  TextAlign _textAlign = TextAlign.left;
  ReadingMargin _margin = ReadingMargin.normal;
  ReadingTheme _theme = ReadingTheme.light;
  bool _loaded = false;

  double get fontScale => _fontScale;
  double get lineHeight => _lineHeight;

  /// One of [fontFamilies]: `'sans'`, `'serif'` or `'mono'`.
  String get fontFamily => _fontFamily;

  /// Either [TextAlign.left] or [TextAlign.justify].
  TextAlign get textAlign => _textAlign;
  ReadingMargin get margin => _margin;
  ReadingTheme get theme => _theme;
  ReadingThemeColors get colors => _theme.colors;
  bool get isLoaded => _loaded;

  /// Body font size in logical pixels.
  double get fontSize => baseFontSize * _fontScale;

  /// Flutter font family for [fontFamily] (null = platform default/Roboto).
  String? get flutterFontFamily => switch (_fontFamily) {
        'serif' => 'serif',
        'mono' => 'monospace',
        _ => null,
      };

  /// Loads persisted values. Safe to call more than once.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _fontScale = (prefs.getDouble(_kFontScale) ?? _fontScale).clamp(minFontScale, maxFontScale).toDouble();
    _lineHeight = (prefs.getDouble(_kLineHeight) ?? _lineHeight).clamp(minLineHeight, maxLineHeight).toDouble();
    final family = prefs.getString(_kFontFamily);
    if (family != null && fontFamilies.contains(family)) _fontFamily = family;
    final justify = prefs.getBool(_kJustify);
    if (justify != null) _textAlign = justify ? TextAlign.justify : TextAlign.left;
    _margin = _byName(ReadingMargin.values, prefs.getString(_kMargin)) ?? _margin;
    _theme = _byName(ReadingTheme.values, prefs.getString(_kTheme)) ?? _theme;
    _loaded = true;
    notifyListeners();
  }

  static T? _byName<T extends Enum>(List<T> values, String? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble(_kFontScale, _fontScale),
      prefs.setDouble(_kLineHeight, _lineHeight),
      prefs.setString(_kFontFamily, _fontFamily),
      prefs.setBool(_kJustify, _textAlign == TextAlign.justify),
      prefs.setString(_kMargin, _margin.name),
      prefs.setString(_kTheme, _theme.name),
    ]);
  }

  Future<void> _changed() {
    notifyListeners();
    return _save();
  }

  Future<void> setFontScale(double value) {
    final v = (value * 100).roundToDouble() / 100;
    final clamped = v.clamp(minFontScale, maxFontScale).toDouble();
    if (clamped == _fontScale) return Future.value();
    _fontScale = clamped;
    return _changed();
  }

  /// Steps the font scale by [delta] (e.g. ±0.1).
  Future<void> adjustFontScale(double delta) => setFontScale(_fontScale + delta);

  Future<void> setLineHeight(double value) {
    final v = ((value * 100).roundToDouble() / 100).clamp(minLineHeight, maxLineHeight).toDouble();
    if (v == _lineHeight) return Future.value();
    _lineHeight = v;
    return _changed();
  }

  Future<void> setFontFamily(String family) {
    if (!fontFamilies.contains(family)) {
      throw ArgumentError.value(family, 'family', 'must be one of $fontFamilies');
    }
    if (family == _fontFamily) return Future.value();
    _fontFamily = family;
    return _changed();
  }

  Future<void> setTextAlign(TextAlign align) {
    final a = align == TextAlign.justify ? TextAlign.justify : TextAlign.left;
    if (a == _textAlign) return Future.value();
    _textAlign = a;
    return _changed();
  }

  Future<void> setMargin(ReadingMargin margin) {
    if (margin == _margin) return Future.value();
    _margin = margin;
    return _changed();
  }

  Future<void> setTheme(ReadingTheme theme) {
    if (theme == _theme) return Future.value();
    _theme = theme;
    return _changed();
  }

  /// Restores all defaults.
  Future<void> reset() {
    _fontScale = 1.0;
    _lineHeight = 1.6;
    _fontFamily = 'sans';
    _textAlign = TextAlign.left;
    _margin = ReadingMargin.normal;
    _theme = ReadingTheme.light;
    return _changed();
  }
}
