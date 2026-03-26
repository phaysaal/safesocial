import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Spheres dark theme matching SeeSelf's aesthetic.
final ThemeData darkTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF0D0D0D),
  colorScheme: const ColorScheme.dark(
    surface: Color(0xFF1A1A2E),
    primary: Color(0xFF00D4AA),
    secondary: Color(0xFF7B2FBE),
    error: Color(0xFFFF4757),
    onPrimary: Color(0xFF0D0D0D),
    onSecondary: Color(0xFFE8E8E8),
    onSurface: Color(0xFFE8E8E8),
    onError: Color(0xFFE8E8E8),
  ),
  textTheme: GoogleFonts.interTextTheme(
    ThemeData.dark().textTheme.copyWith(
          headlineLarge: const TextStyle(
            color: Color(0xFFE8E8E8),
            fontWeight: FontWeight.bold,
          ),
          headlineMedium: const TextStyle(
            color: Color(0xFFE8E8E8),
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: const TextStyle(color: Color(0xFFE8E8E8)),
          bodyMedium: const TextStyle(color: Color(0xFFE8E8E8)),
          bodySmall: const TextStyle(color: Color(0xFFB0B0B0)),
          labelLarge: const TextStyle(
            color: Color(0xFFE8E8E8),
            fontWeight: FontWeight.w600,
          ),
        ),
  ),
  cardTheme: CardThemeData(
    color: const Color(0xFF1A1A2E),
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFF1A1A2E),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFF2A2A3E)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFF00D4AA), width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    hintStyle: const TextStyle(color: Color(0xFF666680)),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    elevation: 0,
    centerTitle: false,
    titleTextStyle: TextStyle(
      color: Color(0xFFE8E8E8),
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
    iconTheme: IconThemeData(color: Color(0xFFE8E8E8)),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: const Color(0xFF1A1A2E),
    indicatorColor: const Color(0xFF00D4AA).withOpacity(0.15),
    labelTextStyle: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return const TextStyle(
          color: Color(0xFF00D4AA),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        );
      }
      return const TextStyle(color: Color(0xFF888888), fontSize: 12);
    }),
    iconTheme: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return const IconThemeData(color: Color(0xFF00D4AA));
      }
      return const IconThemeData(color: Color(0xFF888888));
    }),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Color(0xFF00D4AA),
    foregroundColor: Color(0xFF0D0D0D),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF00D4AA),
      foregroundColor: const Color(0xFF0D0D0D),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      textStyle: const TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 16,
      ),
    ),
  ),
  dividerTheme: const DividerThemeData(
    color: Color(0xFF2A2A3E),
    thickness: 0.5,
  ),
);
