import 'package:flutter/material.dart';

/// PDFCraft brand palette.
class Brand {
  static const red = Color(0xFFE11D48);
  static const redDark = Color(0xFFBE123C);
  static const ink = Color(0xFF1F2328);
  static const surfaceLight = Color(0xFFF7F7F8);

  /// Category colors for tool tiles (Acrobat uses color-coded tool icons).
  static const edit = Color(0xFF7C3AED);
  static const comment = Color(0xFFF59E0B);
  static const sign = Color(0xFF0EA5E9);
  static const organize = Color(0xFF10B981);
  static const convert = Color(0xFF2563EB);
  static const protect = Color(0xFF64748B);
  static const scan = Color(0xFFDB2777);
  static const compress = Color(0xFF0D9488);
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.red,
    brightness: brightness,
    primary: brightness == Brightness.light ? Brand.red : const Color(0xFFFB7185),
    surface: brightness == Brightness.light ? Colors.white : const Color(0xFF16171A),
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  final isLight = brightness == Brightness.light;
  return base.copyWith(
    scaffoldBackgroundColor: isLight ? Brand.surfaceLight : const Color(0xFF0E0F11),
    appBarTheme: AppBarTheme(
      backgroundColor: isLight ? Colors.white : const Color(0xFF16171A),
      foregroundColor: isLight ? Brand.ink : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: isLight ? Brand.ink : Colors.white),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isLight ? Colors.white : const Color(0xFF16171A),
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(fontSize: 12, fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500),
      ),
    ),
    cardTheme: CardThemeData(
      color: isLight ? Colors.white : const Color(0xFF1C1D21),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: isLight ? const Color(0xFFE6E6EA) : const Color(0xFF2A2B30)),
      ),
      margin: EdgeInsets.zero,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: Colors.white,
      shape: const CircleBorder(),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isLight ? Colors.white : const Color(0xFF1C1D21),
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(surfaceTintColor: Colors.transparent, backgroundColor: isLight ? Colors.white : const Color(0xFF1C1D21)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isLight ? const Color(0xFFF1F1F4) : const Color(0xFF24252A),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: isLight ? const Color(0xFFEDEDF0) : const Color(0xFF2A2B30), space: 1),
  );
}
