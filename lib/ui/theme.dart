import 'package:flutter/material.dart';

abstract final class AppColors {
  // 页面、面板、控件分别分层；交互边界与装饰分隔线使用不同颜色。
  static const background = Color(0xff101415),
      surface = Color(0xff1c2224),
      card = Color(0xff2b3335),
      inset = Color(0xff14191b),
      selected = Color(0xff243e36);
  static const accent = Color(0xff82efc5),
      onAccent = Color(0xff10241c),
      text = Color(0xffedf3f3),
      muted = Color(0xffb1bebf),
      border = Color(0xff414e50),
      controlBorder = Color(0xff839596),
      disabled = Color(0xff899697),
      track = Color(0xff839596);
  static const green = accent,
      red = Color(0xffffa1a8),
      amber = Color(0xffffd191);

  static const panelGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [card, surface, inset],
    stops: [0, 0.45, 1],
  );
  static const knobLight = Color(0xff566164);
  static const knobDark = Color(0xff080c0d);

  static ThemeData get theme {
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: controlBorder),
    );
    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: background,
      disabledColor: disabled,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        onPrimary: onAccent,
        primaryContainer: selected,
        onPrimaryContainer: text,
        surface: surface,
        onSurface: text,
        onSurfaceVariant: muted,
        surfaceContainerLowest: background,
        surfaceContainerLow: inset,
        surfaceContainer: surface,
        surfaceContainerHigh: card,
        surfaceContainerHighest: card,
        outline: controlBorder,
        outlineVariant: border,
        secondary: green,
        onSecondary: onAccent,
        secondaryContainer: selected,
        onSecondaryContainer: text,
        error: red,
        onError: onAccent,
        surfaceTint: Colors.transparent,
      ),
      fontFamily: 'Microsoft YaHei',
      fontFamilyFallback: const [
        'PingFang SC',
        'Noto Sans CJK SC',
        'sans-serif',
      ],
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: text),
        bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: text),
        bodySmall: TextStyle(fontSize: 12, height: 1.5, color: muted),
        labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: rounded.copyWith(side: const BorderSide(color: border)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inset,
        labelStyle: const TextStyle(color: muted),
        hintStyle: const TextStyle(color: muted),
        contentPadding: const EdgeInsets.all(16),
        border: outline,
        enabledBorder: outline,
        disabledBorder: outline.copyWith(
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: outline.copyWith(
          borderSide: const BorderSide(color: accent, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: card,
          disabledForegroundColor: disabled,
          shape: rounded,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: inset,
          foregroundColor: text,
          disabledForegroundColor: disabled,
          side: const BorderSide(color: controlBorder),
          shape: rounded,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: accent,
          disabledForegroundColor: disabled,
          shape: rounded,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: text,
          disabledForegroundColor: disabled,
          shape: rounded,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabled
              : states.contains(WidgetState.selected)
              ? onAccent
              : text,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? card
              : states.contains(WidgetState.selected)
              ? accent
              : inset,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? accent : controlBorder,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: inset,
        selectedColor: selected,
        disabledColor: card,
        labelStyle: const TextStyle(
          color: text,
          fontSize: 14,
          fontFamily: 'Microsoft YaHei',
          fontFamilyFallback: ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
        ),
        secondaryLabelStyle: const TextStyle(
          color: text,
          fontSize: 14,
          fontFamily: 'Microsoft YaHei',
          fontFamilyFallback: ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
        ),
        checkmarkColor: accent,
        side: const BorderSide(color: controlBorder),
        shape: rounded,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: muted,
        textColor: text,
        selectedColor: accent,
        selectedTileColor: selected,
        minVerticalPadding: 12,
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      sliderTheme: const SliderThemeData(
        trackHeight: 5,
        activeTrackColor: accent,
        inactiveTrackColor: track,
        thumbColor: text,
        overlayColor: Color(0x3382efc5),
        disabledActiveTrackColor: disabled,
        disabledInactiveTrackColor: border,
        disabledThumbColor: disabled,
        activeTickMarkColor: Colors.transparent,
        inactiveTickMarkColor: Colors.transparent,
        disabledActiveTickMarkColor: Colors.transparent,
        disabledInactiveTickMarkColor: Colors.transparent,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
        valueIndicatorColor: accent,
        valueIndicatorTextStyle: TextStyle(color: onAccent),
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: inset,
        indicatorColor: selected,
        surfaceTintColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? accent : muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            color: states.contains(WidgetState.selected) ? text : muted,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w400,
          ),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: rounded.copyWith(side: const BorderSide(color: controlBorder)),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 350),
        textStyle: TextStyle(color: onAccent, fontSize: 12),
        decoration: BoxDecoration(
          color: text,
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
    );
  }
}
