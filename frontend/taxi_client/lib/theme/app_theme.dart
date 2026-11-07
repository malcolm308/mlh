import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Paleta del sistema de diseno V2 de RapiTaxi.
///
/// Todo el color de la app vive aqui: cambiar una constante cambia el tema
/// entero. El mapa (MapLibre) NO usa estos colores a proposito: conserva su
/// agua azul, sus calles claras y su ruta amarilla original.
abstract final class AppColors {
  /// Acento de marca (amarillo RapiTaxi).
  static const Color acento = Color(0xFFFFD100);

  /// Variante muy suave del acento para fondos y chips.
  static const Color acentoSuave = Color(0xFFFFF7DC);

  /// Texto principal.
  static const Color tinta = Color(0xFF1C1E21);

  /// Texto secundario.
  static const Color secundario = Color(0xFF6B6A70);

  /// Texto de alertas / ambar oscuro.
  static const Color ambar = Color(0xFFA16207);

  /// Fondo de las cajas de advertencia.
  static const Color ambarFondo = Color(0xFFFFF8E6);

  /// Borde sutil de las cajas de advertencia.
  static const Color ambarBorde = Color(0xFFF1DFAE);

  /// Fondo de controles deshabilitados.
  static const Color deshabilitado = Color(0xFFECEEF1);

  /// Texto sobre fondo deshabilitado.
  static const Color deshabilitadoTexto = Color(0xFF9AA0A6);

  /// Fondo de campos de texto y segmentos inactivos.
  static const Color campo = Color(0xFFF1F2F4);

  /// Borde estandar de tarjetas y campos.
  static const Color borde = Color(0xFFE7E9EC);

  /// Blanco translucido de los paneles de vidrio.
  static const Color panel = Color(0xF2FFFFFF);

  /// Fondo general de las pantallas (fuera del mapa).
  static const Color fondo = Color(0xFFF6F7F9);

  /// Rojo de error / acciones destructivas.
  static const Color error = Color(0xFFB3261E);

  /// Verde de confirmacion.
  static const Color exito = Color(0xFF15803D);
}

/// Tema global V2: Light Theme con acento amarillo.
abstract final class AppTheme {
  static ThemeData light() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.acento,
      onPrimary: AppColors.tinta,
      primaryContainer: AppColors.acentoSuave,
      onPrimaryContainer: AppColors.tinta,
      secondary: AppColors.ambar,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.ambarFondo,
      onSecondaryContainer: AppColors.ambar,
      error: AppColors.error,
      onError: Colors.white,
      errorContainer: Color(0xFFF9DEDC),
      onErrorContainer: Color(0xFF410E0B),
      surface: Colors.white,
      onSurface: AppColors.tinta,
      onSurfaceVariant: AppColors.secundario,
      surfaceContainerHighest: AppColors.campo,
      outline: AppColors.borde,
      outlineVariant: AppColors.borde,
      shadow: Color(0x33000000),
      scrim: Color(0x80000000),
      inverseSurface: AppColors.tinta,
      onInverseSurface: Colors.white,
      inversePrimary: AppColors.acento,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.fondo,
      canvasColor: Colors.white,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.tinta,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.tinta,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: IconThemeData(color: AppColors.tinta),
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.all(0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.borde),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.acento,
          foregroundColor: AppColors.tinta,
          disabledBackgroundColor: AppColors.deshabilitado,
          disabledForegroundColor: AppColors.deshabilitadoTexto,
          elevation: 0,
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.acento,
          foregroundColor: AppColors.tinta,
          disabledBackgroundColor: AppColors.deshabilitado,
          disabledForegroundColor: AppColors.deshabilitadoTexto,
          elevation: 0,
          minimumSize: const Size(0, 52),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.tinta,
          side: const BorderSide(color: AppColors.borde),
          minimumSize: const Size(0, 46),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.ambar,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      iconTheme: const IconThemeData(color: AppColors.tinta),
      dividerTheme: const DividerThemeData(
        color: AppColors.borde,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.campo,
        hintStyle: const TextStyle(
          color: AppColors.secundario,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        labelStyle: const TextStyle(color: AppColors.secundario),
        prefixIconColor: AppColors.secundario,
        suffixIconColor: AppColors.secundario,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.acento, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.error, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.error, width: 1.6),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => Colors.white,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.acento
              : const Color(0xFFDDE1E6),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.acentoSuave,
        selectedColor: AppColors.acento,
        labelStyle: const TextStyle(
          color: AppColors.tinta,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: const TextStyle(color: AppColors.tinta),
        side: BorderSide.none,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        modalBarrierColor: Color(0x2E000000),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        titleTextStyle: const TextStyle(
          color: AppColors.tinta,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: const TextStyle(
          color: AppColors.secundario,
          fontSize: 14,
          height: 1.4,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.tinta,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.secundario,
        textColor: AppColors.tinta,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.ambar,
        linearTrackColor: AppColors.deshabilitado,
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.tinta,
        displayColor: AppColors.tinta,
      ),
    );
  }
}
