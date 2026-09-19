import 'package:flutter/material.dart';

abstract final class AppColors {
  static const navy = Color(0xFF071B4B);
  static const blue = Color(0xFF0878F9);
  static const paleBlue = Color(0xFFEAF4FF);
  static const canvas = Color(0xFFF4F9FF);
  static const muted = Color(0xFF6E7E9C);
  static const line = Color(0xFFE5EDF7);
  static const green = Color(0xFF00BF63);
  static const red = Color(0xFFFF5147);
  static const orange = Color(0xFFFF9D18);
}

ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.blue,
    brightness: Brightness.light,
    primary: AppColors.blue,
    surface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.canvas,
    fontFamilyFallback: const [
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
    ],
    textTheme: ThemeData.light().textTheme.apply(
      bodyColor: AppColors.navy,
      displayColor: AppColors.navy,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      height: 68,
      backgroundColor: Colors.white,
      indicatorColor: AppColors.paleBlue,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 7,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.line,
      thickness: 1,
      space: 1,
    ),
  );
}
