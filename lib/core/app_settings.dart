import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PageScrollMode { continuous, singlePage }

/// App-wide preferences persisted with SharedPreferences.
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  final SharedPreferences _prefs;

  ThemeMode get themeMode => ThemeMode.values[_prefs.getInt('themeMode') ?? ThemeMode.system.index];
  set themeMode(ThemeMode m) => _set(() => _prefs.setInt('themeMode', m.index));

  PageScrollMode get scrollMode => PageScrollMode.values[_prefs.getInt('scrollMode') ?? 0];
  set scrollMode(PageScrollMode m) => _set(() => _prefs.setInt('scrollMode', m.index));

  /// Inverts page colors in the viewer (night reading).
  bool get nightPages => _prefs.getBool('nightPages') ?? false;
  set nightPages(bool v) => _set(() => _prefs.setBool('nightPages', v));

  bool get keepScreenOn => _prefs.getBool('keepScreenOn') ?? false;
  set keepScreenOn(bool v) => _set(() => _prefs.setBool('keepScreenOn', v));

  String get authorName => _prefs.getString('authorName') ?? 'PDFCraft user';
  set authorName(String v) => _set(() => _prefs.setString('authorName', v));

  double get ttsRate => _prefs.getDouble('ttsRate') ?? 0.5;
  set ttsRate(double v) => _set(() => _prefs.setDouble('ttsRate', v));

  double get ttsPitch => _prefs.getDouble('ttsPitch') ?? 1.0;
  set ttsPitch(double v) => _set(() => _prefs.setDouble('ttsPitch', v));

  int get annotationColor => _prefs.getInt('annotColor') ?? 0xFFFFE94D;
  set annotationColor(int v) => _set(() => _prefs.setInt('annotColor', v));

  int get inkColor => _prefs.getInt('inkColor') ?? 0xFFE11D48;
  set inkColor(int v) => _set(() => _prefs.setInt('inkColor', v));

  double get inkWidth => _prefs.getDouble('inkWidth') ?? 2.5;
  set inkWidth(double v) => _set(() => _prefs.setDouble('inkWidth', v));

  bool get showOnboarding => _prefs.getBool('onboarded') != true;
  void completeOnboarding() => _set(() => _prefs.setBool('onboarded', true));

  /// Most recently used tools (ids) for the Home quick tools row.
  List<String> get recentTools => _prefs.getStringList('recentTools') ?? const [];
  void useTool(String id) {
    final list = [id, ...recentTools.where((t) => t != id)].take(8).toList();
    _set(() => _prefs.setStringList('recentTools', list));
  }

  void _set(Future<bool> Function() write) {
    write();
    notifyListeners();
  }
}
