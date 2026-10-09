import 'package:flutter/material.dart';

/// Acrobat-inspired visual language (Spectrum-like): white surfaces, blue accents,
/// thin line icons, quiet dividers and Source Sans typography.
class Brand {
  /// Logo red (PDFCraft mark).
  static const red = Color(0xFFEB1000);

  /// Primary accent (selected tabs, FAB, links, toggles).
  static const blue = Color(0xFF1473E6);
  static const blueDark = Color(0xFF378EF0);

  static const ink = Color(0xFF222222);
  static const textSecondary = Color(0xFF6E6E6E);
  static const iconGrey = Color(0xFF4B4B4B);
  static const divider = Color(0xFFE6E6E6);
  static const viewerBackground = Color(0xFFEAEAEA);
  static const fontFamily = 'SourceSans';

  // Pastel tool tiles (Acrobat "More tools").
  static const edit = Color(0xFFD7373F); // pink/red
  static const comment = Color(0xFFDA7B11);
  static const sign = Color(0xFF6767EC);
  static const organize = Color(0xFF2D9D78);
  static const convert = Color(0xFF1473E6);
  static const protect = Color(0xFF5151D3);
  static const scan = Color(0xFFC0398A);
  static const compress = Color(0xFF268E6C);

  static Color tileBackground(Color c) => Color.alphaBlend(c.withValues(alpha: 0.10), Colors.white);
}

ThemeData buildTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final primary = light ? Brand.blue : Brand.blueDark;
  final surface = light ? Colors.white : const Color(0xFF1E1E1E);
  final onSurface = light ? Brand.ink : const Color(0xFFEBEBEB);
  final secondaryText = light ? Brand.textSecondary : const Color(0xFFA8A8A8);
  final divider = light ? Brand.divider : const Color(0xFF3A3A3A);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: Colors.white,
    primaryContainer: light ? const Color(0xFFE5F0FD) : const Color(0xFF0D3A6E),
    onPrimaryContainer: light ? const Color(0xFF0D66D0) : Colors.white,
    secondary: primary,
    onSecondary: Colors.white,
    tertiary: Brand.red,
    onTertiary: Colors.white,
    error: const Color(0xFFD7373F),
    onError: Colors.white,
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: secondaryText,
    surfaceContainerHighest: light ? const Color(0xFFF3F3F3) : const Color(0xFF2C2C2C),
    surfaceContainerHigh: light ? const Color(0xFFF5F5F5) : const Color(0xFF282828),
    surfaceContainer: light ? const Color(0xFFF8F8F8) : const Color(0xFF242424),
    surfaceContainerLow: light ? const Color(0xFFFAFAFA) : const Color(0xFF212121),
    outline: light ? const Color(0xFFB3B3B3) : const Color(0xFF6E6E6E),
    outlineVariant: divider,
    shadow: Colors.black,
    inverseSurface: light ? const Color(0xFF323232) : Colors.white,
    onInverseSurface: light ? Colors.white : Brand.ink,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: Brand.fontFamily,
    splashFactory: InkRipple.splashFactory,
  );
  final t = base.textTheme;
  final text = t.copyWith(
    headlineSmall: t.headlineSmall?.copyWith(fontSize: 24, fontWeight: FontWeight.w700, color: onSurface, letterSpacing: -0.2),
    titleLarge: t.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w700, color: onSurface),
    titleMedium: t.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: onSurface),
    titleSmall: t.titleSmall?.copyWith(fontSize: 15, fontWeight: FontWeight.w600, color: onSurface),
    bodyLarge: t.bodyLarge?.copyWith(fontSize: 17, color: onSurface),
    bodyMedium: t.bodyMedium?.copyWith(fontSize: 15, color: onSurface),
    bodySmall: t.bodySmall?.copyWith(fontSize: 13, color: secondaryText),
    labelLarge: t.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
    labelSmall: t.labelSmall?.copyWith(fontSize: 12, color: secondaryText),
  );
  final iconTheme = IconThemeData(color: light ? Brand.iconGrey : const Color(0xFFD0D0D0), size: 24, weight: 300, opticalSize: 24);
  return base.copyWith(
    textTheme: text,
    iconTheme: iconTheme,
    scaffoldBackgroundColor: surface,
    dividerColor: divider,
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      shadowColor: divider,
      centerTitle: false,
      iconTheme: iconTheme,
      actionsIconTheme: iconTheme,
      titleTextStyle: TextStyle(fontFamily: Brand.fontFamily, fontSize: 18, fontWeight: FontWeight.w600, color: onSurface),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: surface,
      selectedItemColor: primary,
      unselectedItemColor: light ? const Color(0xFF6E6E6E) : const Color(0xFFA8A8A8),
      type: BottomNavigationBarType.fixed,
      elevation: 0,
      selectedLabelStyle: const TextStyle(fontFamily: Brand.fontFamily, fontSize: 12, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontFamily: Brand.fontFamily, fontSize: 12),
      selectedIconTheme: IconThemeData(color: primary, fill: 1, weight: 400),
      unselectedIconTheme: IconThemeData(weight: 300, color: light ? const Color(0xFF6E6E6E) : const Color(0xFFA8A8A8)),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: onSurface,
      unselectedLabelColor: secondaryText,
      indicatorColor: onSurface,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelStyle: const TextStyle(fontFamily: Brand.fontFamily, fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontFamily: Brand.fontFamily, fontSize: 15),
      tabAlignment: TabAlignment.start,
      labelPadding: const EdgeInsets.only(right: 24),
      indicator: UnderlineTabIndicator(borderSide: BorderSide(color: onSurface, width: 2)),
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: divider)),
      margin: EdgeInsets.zero,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: Colors.white,
      shape: const CircleBorder(),
      elevation: 4,
      iconSize: 28,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: light ? const Color(0xFFCACACA) : const Color(0xFF5A5A5A),
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    ),
    dialogTheme: DialogThemeData(
      surfaceTintColor: Colors.transparent,
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      titleTextStyle: TextStyle(fontFamily: Brand.fontFamily, fontSize: 20, fontWeight: FontWeight.w700, color: onSurface),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(fontFamily: Brand.fontFamily, fontSize: 15, color: onSurface),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: light ? const Color(0xFFB3B3B3) : const Color(0xFF5A5A5A))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: light ? const Color(0xFFB3B3B3) : const Color(0xFF5A5A5A))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: primary, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelStyle: TextStyle(color: secondaryText),
      hintStyle: TextStyle(color: secondaryText),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontFamily: Brand.fontFamily, fontSize: 15, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: onSurface,
        shape: const StadiumBorder(),
        side: BorderSide(color: light ? const Color(0xFF8E8E8E) : const Color(0xFF8E8E8E), width: 1.5),
        textStyle: const TextStyle(fontFamily: Brand.fontFamily, fontSize: 15, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        textStyle: const TextStyle(fontFamily: Brand.fontFamily, fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? primary : (light ? const Color(0xFFB3B3B3) : const Color(0xFF5A5A5A))),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? primary : Colors.transparent),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? primary : secondaryText)),
    sliderTheme: SliderThemeData(activeTrackColor: primary, thumbColor: primary, inactiveTrackColor: divider),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: primary, linearTrackColor: divider),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      selectedColor: scheme.primaryContainer,
      side: BorderSide(color: light ? const Color(0xFFCACACA) : const Color(0xFF5A5A5A)),
      shape: const StadiumBorder(),
      labelStyle: TextStyle(fontFamily: Brand.fontFamily, fontSize: 14, color: onSurface),
      showCheckmark: false,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        side: BorderSide(color: light ? const Color(0xFFCACACA) : const Color(0xFF5A5A5A)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: iconTheme.color,
      titleTextStyle: TextStyle(fontFamily: Brand.fontFamily, fontSize: 16, color: onSurface),
      subtitleTextStyle: TextStyle(fontFamily: Brand.fontFamily, fontSize: 13, color: secondaryText),
      minLeadingWidth: 24,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF323232),
      contentTextStyle: const TextStyle(fontFamily: Brand.fontFamily, fontSize: 15, color: Colors.white),
      actionTextColor: Brand.blueDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    dividerTheme: DividerThemeData(color: divider, space: 1, thickness: 1),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
  );
}
