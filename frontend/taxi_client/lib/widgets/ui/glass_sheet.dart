import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Contenedor reutilizable para hojas y paneles inferiores con efecto cristal.
///
/// Va sobre un [Stack] (o dentro de un `showModalBottomSheet` transparente) y
/// difumina lo que quede detras. Incluye el asa gris y las esquinas superiores
/// de 26 px que pide el sistema de diseno V2.
class GlassSheet extends StatelessWidget {
  /// Contenido de la hoja.
  final Widget child;

  /// Muestra el asa superior.
  final bool showHandle;

  /// Relleno del contenido. El asa ya lleva su propio margen.
  final EdgeInsetsGeometry padding;

  /// Radio de las esquinas superiores.
  final double radius;

  /// Intensidad del desenfoque, en pixeles sigma.
  final double blur;

  /// Opacidad del blanco del panel (0.85 - 0.9 recomendado).
  final double opacity;

  const GlassSheet({
    super.key,
    required this.child,
    this.showHandle = true,
    this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 20),
    this.radius = 26,
    this.blur = 18,
    this.opacity = 0.9,
  });

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.vertical(top: Radius.circular(radius));

    return DecoratedBox(
      // La sombra va FUERA del recorte: dentro la recortaria el ClipRRect.
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 28,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: opacity),
              borderRadius: shape,
              border: Border(
                top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.75),
                  width: 1,
                ),
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showHandle) ...[
                    const SizedBox(height: 9),
                    Center(
                      child: Container(
                        width: 42,
                        height: 4.5,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD2D6DB),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                  ],
                  Padding(
                    padding: padding,
                    child: child,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tarjeta blanca con sombra suave, para contenido fuera de las hojas.
class SoftCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  const SoftCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}
