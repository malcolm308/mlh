import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Arco semicircular del saldo, dibujado con [CustomPainter].
///
/// El arco inactivo siempre está completo; encima se pinta el activo según el
/// [progreso] (0..1). El extremo lleva un punto blanco con borde del color
/// activo, como en el diseño de referencia.
class ArcoSaldoPainter extends CustomPainter {
  const ArcoSaldoPainter({
    required this.progreso,
    required this.colorActivo,
    required this.colorInactivo,
    this.grosor = 14,
    this.colorPunto = Colors.white,
  });

  final double progreso;
  final Color colorActivo;
  final Color colorInactivo;
  final double grosor;
  final Color colorPunto;

  @override
  void paint(Canvas canvas, Size size) {
    final radio = (size.width - grosor) / 2;
    if (radio <= 0) return;
    final centro = Offset(size.width / 2, size.height - grosor / 2);
    final rect = Rect.fromCircle(center: centro, radius: radio);

    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = grosor
      ..strokeCap = StrokeCap.round
      ..color = colorInactivo;
    final activo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = grosor
      ..strokeCap = StrokeCap.round
      ..color = colorActivo;

    // π = izquierda, 3π/2 = arriba, 2π = derecha: media vuelta por encima.
    canvas.drawArc(rect, math.pi, math.pi, false, base);

    final p = progreso.clamp(0.0, 1.0);
    if (p > 0) {
      canvas.drawArc(rect, math.pi, math.pi * p, false, activo);
    }

    final angulo = math.pi + math.pi * p;
    final punto = Offset(
      centro.dx + radio * math.cos(angulo),
      centro.dy + radio * math.sin(angulo),
    );
    canvas.drawCircle(punto, grosor * 0.58, Paint()..color = colorPunto);
    canvas.drawCircle(
      punto,
      grosor * 0.58,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = colorActivo,
    );
  }

  @override
  bool shouldRepaint(covariant ArcoSaldoPainter old) =>
      old.progreso != progreso ||
      old.grosor != grosor ||
      old.colorActivo != colorActivo ||
      old.colorInactivo != colorInactivo;
}
