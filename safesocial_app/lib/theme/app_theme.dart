import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------------------------------------------------------------------------
// Spheres brand palette: the rose and violet of the logo's top two bands
// (drawn by scripts/make_logo.py)
// ---------------------------------------------------------------------------

// Light theme colors
const _lightPrimary = Color(0xFFC93D4E); // the logo's rose, deepened for text
const _lightOnPrimary = Colors.white;
const _lightSecondary = Color(0xFF7B3FE4); // the logo's violet
const _lightBackground = Color(0xFFF5F0EF); // Warm light gray
const _lightSurface = Colors.white;
const _lightOnSurface = Color(0xFF1C1E21);
const _lightOnSurfaceVariant = Color(0xFF65676B);
const _lightDivider = Color(0xFFDADDE1);
const _lightError = Color(0xFFE41E3F);

// Dark theme colors
const _darkPrimary = Color(0xFFE8556A); // Brighter coral for dark mode
const _darkOnPrimary = Colors.white;
const _darkSecondary = Color(0xFF9B6DFF); // Lighter purple for dark
const _darkBackground = Color(0xFF18191A);
const _darkSurface = Color(0xFF242526);
const _darkOnSurface = Color(0xFFE4E6EB);
const _darkOnSurfaceVariant = Color(0xFFB0B3B8);
const _darkDivider = Color(0xFF3E4042);
const _darkError = Color(0xFFFF4757);

// ---------------------------------------------------------------------------
// Light theme — Facebook / Instagram look
// ---------------------------------------------------------------------------

final ThemeData lightTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  scaffoldBackgroundColor: _lightBackground,
  // Seeded from the logo's coral, so containers, chips and badges get tonal
  // tints instead of the one solid brand red everywhere.
  colorScheme: ColorScheme.fromSeed(
    seedColor: _lightPrimary,
    brightness: Brightness.light,
    primary: _lightPrimary,
    onPrimary: _lightOnPrimary,
    secondary: _lightSecondary,
    surface: _lightSurface,
    onSurface: _lightOnSurface,
    onSurfaceVariant: _lightOnSurfaceVariant,
    error: _lightError,
    outline: _lightDivider,
  ),
  textTheme: GoogleFonts.interTextTheme(
    ThemeData.light().textTheme.copyWith(
          headlineLarge: const TextStyle(
            color: _lightOnSurface,
            fontWeight: FontWeight.bold,
          ),
          headlineMedium: const TextStyle(
            color: _lightOnSurface,
            fontWeight: FontWeight.w600,
          ),
          titleLarge: const TextStyle(
            color: _lightOnSurface,
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
          bodyLarge: const TextStyle(color: _lightOnSurface),
          bodyMedium: const TextStyle(color: _lightOnSurface),
          bodySmall: const TextStyle(color: _lightOnSurfaceVariant),
          labelLarge: const TextStyle(
            color: _lightOnSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
  ),
  cardTheme: CardThemeData(
    color: _lightSurface,
    elevation: 1,
    shadowColor: Colors.black.withValues(alpha: 0.35),
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: _lightBackground,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: _lightDivider),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: _lightPrimary, width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    hintStyle: const TextStyle(color: _lightOnSurfaceVariant),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: _lightSurface,
    elevation: 0,
    scrolledUnderElevation: 0.5,
    centerTitle: false,
    titleTextStyle: TextStyle(
      color: _lightOnSurface,
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    iconTheme: IconThemeData(color: _lightOnSurface),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: _lightSurface,
    elevation: 2,
    surfaceTintColor: Colors.transparent,
    indicatorColor: _lightPrimary.withValues(alpha: 0.12),
    labelTextStyle: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return const TextStyle(
          color: _lightPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        );
      }
      return const TextStyle(color: _lightOnSurfaceVariant, fontSize: 12);
    }),
    iconTheme: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return const IconThemeData(color: _lightPrimary);
      }
      return const IconThemeData(color: _lightOnSurfaceVariant);
    }),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: _lightPrimary,
    foregroundColor: Colors.white,
    elevation: 2,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: _lightPrimary,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      elevation: 0,
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: _lightOnSurface,
      side: const BorderSide(color: _lightDivider),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
    ),
  ),
  dividerTheme: const DividerThemeData(
    color: _lightDivider,
    thickness: 0.5,
    space: 0,
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: _lightSurface,
    showDragHandle: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: _lightSurface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: _lightBackground,
    selectedColor: _lightPrimary.withValues(alpha: 0.14),
    side: BorderSide.none,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    labelStyle: const TextStyle(color: _lightOnSurface, fontSize: 13, fontWeight: FontWeight.w500),
  ),
  iconTheme: const IconThemeData(color: _lightOnSurfaceVariant),
  listTileTheme: const ListTileThemeData(
    contentPadding: EdgeInsets.symmetric(horizontal: 16),
  ),
);

// ---------------------------------------------------------------------------
// Dark theme — FB dark mode aesthetic
// ---------------------------------------------------------------------------

final ThemeData darkTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: _darkBackground,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _darkPrimary,
    brightness: Brightness.dark,
    primary: _darkPrimary,
    onPrimary: _darkOnPrimary,
    secondary: _darkSecondary,
    surface: _darkSurface,
    onSurface: _darkOnSurface,
    onSurfaceVariant: _darkOnSurfaceVariant,
    error: _darkError,
    outline: _darkDivider,
  ),
  textTheme: GoogleFonts.interTextTheme(
    ThemeData.dark().textTheme.copyWith(
          headlineLarge: const TextStyle(
            color: _darkOnSurface,
            fontWeight: FontWeight.bold,
          ),
          headlineMedium: const TextStyle(
            color: _darkOnSurface,
            fontWeight: FontWeight.w600,
          ),
          titleLarge: const TextStyle(
            color: _darkOnSurface,
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
          bodyLarge: const TextStyle(color: _darkOnSurface),
          bodyMedium: const TextStyle(color: _darkOnSurface),
          bodySmall: const TextStyle(color: _darkOnSurfaceVariant),
          labelLarge: const TextStyle(
            color: _darkOnSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
  ),
  cardTheme: CardThemeData(
    color: _darkSurface,
    elevation: 0,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFF3A3B3C),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: _darkDivider),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: _darkPrimary, width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    hintStyle: const TextStyle(color: _darkOnSurfaceVariant),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: _darkSurface,
    elevation: 0,
    scrolledUnderElevation: 0.5,
    centerTitle: false,
    titleTextStyle: TextStyle(
      color: _darkOnSurface,
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    iconTheme: IconThemeData(color: _darkOnSurface),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: _darkSurface,
    elevation: 2,
    surfaceTintColor: Colors.transparent,
    indicatorColor: _darkPrimary.withValues(alpha: 0.15),
    labelTextStyle: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return const TextStyle(
          color: _darkPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        );
      }
      return const TextStyle(color: _darkOnSurfaceVariant, fontSize: 12);
    }),
    iconTheme: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return const IconThemeData(color: _darkPrimary);
      }
      return const IconThemeData(color: _darkOnSurfaceVariant);
    }),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: _darkPrimary,
    foregroundColor: Colors.white,
    elevation: 2,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: _darkPrimary,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      elevation: 0,
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: _darkOnSurface,
      side: const BorderSide(color: _darkDivider),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
    ),
  ),
  dividerTheme: const DividerThemeData(
    color: _darkDivider,
    thickness: 0.5,
    space: 0,
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: _darkSurface,
    showDragHandle: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: _darkSurface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: const Color(0xFF3A3B3C),
    selectedColor: _darkPrimary.withValues(alpha: 0.18),
    side: BorderSide.none,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    labelStyle: const TextStyle(color: _darkOnSurface, fontSize: 13, fontWeight: FontWeight.w500),
  ),
  iconTheme: const IconThemeData(color: _darkOnSurfaceVariant),
  listTileTheme: const ListTileThemeData(
    contentPadding: EdgeInsets.symmetric(horizontal: 16),
  ),
);
