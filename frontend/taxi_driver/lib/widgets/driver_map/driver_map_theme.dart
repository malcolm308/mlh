import 'package:flutter/material.dart';

/// Paleta exclusiva de los layouts del mapa del chofer.
abstract final class DriverMapColors {
  static const Color amarillo = Color(0xFFFFD600);
  static const Color negro = Color(0xFF1A1A1A);
  static const Color bordeAmarillo = Color(0xFFFFE082);
  static const Color cremaArriba = Color(0xFFFFFBEA);
  static const Color cremaAbajo = Color(0xFFFFF7D6);
  static const Color blanco = Color(0xFFFFFFFF);
  static const Color texto = Color(0xFF1A1A1A);
  static const Color secundario = Color(0xFF999999);
  static const Color fondoChip = Color(0xFFF7F8FA);
  static const Color bordeGris = Color(0xFFE5E5E5);
}

abstract final class DriverMapTypography {
  static const String family = 'Inter';

  static TextStyle style({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    Color color = DriverMapColors.texto,
    double? height,
    TextDecoration? decoration,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      decoration: decoration,
    );
  }
}

/// Formatea un importe entero con separador de miles, sin inventar decimales.
String formatImporteEntero(num value) {
  final entero = value.round().abs();
  final texto = entero.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < texto.length; i++) {
    if (i > 0 && (texto.length - i) % 3 == 0) buffer.write(',');
    buffer.write(texto[i]);
  }
  return '${value < 0 ? '-' : ''}$buffer';
}

class LightningBolt extends StatelessWidget {
  const LightningBolt({
    super.key,
    this.size = 24,
    this.inverted = false,
    this.color = DriverMapColors.amarillo,
  });

  final double size;
  final bool inverted;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _LightningPainter(inverted: inverted, color: color),
      ),
    );
  }
}

class _LightningPainter extends CustomPainter {
  const _LightningPainter({required this.inverted, required this.color});

  final bool inverted;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24.0, size.height / 26.0);
    final path = Path();
    if (inverted) {
      path
        ..moveTo(10.5, 0)
        ..lineTo(22, 14)
        ..lineTo(14.5, 14)
        ..lineTo(16, 26)
        ..lineTo(4.5, 11)
        ..lineTo(12, 11)
        ..close();
    } else {
      path
        ..moveTo(13.5, 0)
        ..lineTo(2, 14)
        ..lineTo(9.5, 14)
        ..lineTo(8, 26)
        ..lineTo(19.5, 11)
        ..lineTo(12, 11)
        ..close();
    }
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LightningPainter oldDelegate) {
    return oldDelegate.inverted != inverted || oldDelegate.color != color;
  }
}

class LogoChip extends StatelessWidget {
  const LogoChip({super.key, this.onTap, this.size = 42});

  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final contenido = SizedBox(
      width: size,
      height: size,
      child: Center(child: LightningBolt(size: size * 0.52)),
    );
    return Semantics(
      button: onTap != null,
      label: onTap == null ? 'RapiTaxi' : 'Abrir menú',
      child: onTap == null
          ? Material(
              color: DriverMapColors.negro,
              borderRadius: BorderRadius.circular(13),
              clipBehavior: Clip.antiAlias,
              child: contenido,
            )
          : Tooltip(
              message: 'Abrir menú',
              child: Material(
                color: DriverMapColors.negro,
                borderRadius: BorderRadius.circular(13),
                clipBehavior: Clip.antiAlias,
                child: InkWell(onTap: onTap, child: contenido),
              ),
            ),
    );
  }
}
