import 'package:flutter/material.dart';

import '../design/aivy_ui.dart';

class AivyTheme {
  /// The app's one theme.
  ///
  /// Named `light()` still because every call site says so; the app itself is
  /// dark throughout now. Aivy — the screen the user lives in — was always
  /// near-black, and a shell that flipped to white on the next tab read as two
  /// apps stitched together.
  ///
  /// The values come from [AivyUi] so a Material widget nobody styled by hand
  /// still lands in the same palette as the ones that were.
  static ThemeData light() {
    final colorScheme = ColorScheme.dark(
      primary: AivyUi.brand,
      secondary: AivyUi.info,
      surface: AivyUi.surface,
      error: AivyUi.danger,
      onPrimary: Colors.white,
      onSurface: AivyUi.ink,
      onSurfaceVariant: AivyUi.inkSoft,
      outline: AivyUi.line,
      outlineVariant: AivyUi.line,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AivyUi.bg,
      canvasColor: AivyUi.bg,
      iconTheme: const IconThemeData(color: AivyUi.inkSoft),
      dividerTheme: const DividerThemeData(color: AivyUi.line, space: 1),
      appBarTheme: const AppBarTheme(
        backgroundColor: AivyUi.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: AivyUi.ink,
      ),
      listTileTheme: const ListTileThemeData(
        textColor: AivyUi.ink,
        iconColor: AivyUi.inkSoft,
        subtitleTextStyle: TextStyle(color: AivyUi.inkSoft, fontSize: 12.5),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AivyUi.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AivyUi.radius),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AivyUi.surfaceHigh,
        contentTextStyle: TextStyle(color: AivyUi.ink),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AivyUi.surface,
        hintStyle: const TextStyle(color: AivyUi.inkFaint),
        labelStyle: const TextStyle(color: AivyUi.inkSoft),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AivyUi.radiusSm),
          borderSide: const BorderSide(color: AivyUi.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AivyUi.radiusSm),
          borderSide: const BorderSide(color: AivyUi.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AivyUi.radiusSm),
          borderSide: const BorderSide(color: AivyUi.brand),
        ),
      ),
      cardTheme: CardThemeData(
        color: AivyUi.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AivyUi.radius),
          side: const BorderSide(color: AivyUi.line),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AivyUi.brand,
          foregroundColor: Colors.white,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AivyUi.brand),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AivyUi.ink,
          side: const BorderSide(color: AivyUi.line),
        ),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        textColor: AivyUi.ink,
        collapsedTextColor: AivyUi.ink,
        iconColor: AivyUi.inkFaint,
        collapsedIconColor: AivyUi.inkFaint,
      ),
    );
  }

  /// Dark Jarvis-style shell for the home dashboard only.
  static ThemeData darkDashboard() {
    const surface = Color(0xFF12121A);
    const neonPurple = Color(0xFF8B5CF6);
    const neonBlue = Color(0xFF3B82F6);
    final colorScheme = ColorScheme.dark(
      primary: neonPurple,
      secondary: neonBlue,
      surface: surface,
      onPrimary: Colors.white,
      onSurface: const Color(0xFFE2E8F0),
      onSurfaceVariant: const Color(0xFF94A3B8),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: Colors.transparent,
      iconTheme: const IconThemeData(color: Color(0xFFE2E8F0)),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Color(0xFFE2E8F0),
        centerTitle: false,
      ),
      dividerTheme: const DividerThemeData(color: Color(0xFF1E293B)),
    );
  }
}
