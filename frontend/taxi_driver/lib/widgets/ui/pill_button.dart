import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Boton principal en forma de pildora.
///
/// Fondo amarillo solido, texto oscuro y `StadiumBorder`. Cuando
/// [onPressed] es `null` (o [loading] es `true`) se pinta con el gris
/// deshabilitado del sistema de diseno.
class PillButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final String? loadingLabel;
  final bool expand;
  final double height;

  const PillButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.loadingLabel,
    this.expand = true,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: AppColors.tinta,
            ),
          )
        else if (icon != null)
          Icon(icon, size: 20, color: enabled ? AppColors.tinta : AppColors.deshabilitadoTexto),
        if (loading || icon != null) const SizedBox(width: 9),
        Flexible(
          child: Text(
            loading ? (loadingLabel ?? label) : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: enabled ? AppColors.tinta : AppColors.deshabilitadoTexto,
            ),
          ),
        ),
      ],
    );

    return SizedBox(
      height: height,
      width: expand ? double.infinity : null,
      child: FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.acento,
          foregroundColor: AppColors.tinta,
          disabledBackgroundColor: AppColors.deshabilitado,
          disabledForegroundColor: AppColors.deshabilitadoTexto,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: const StadiumBorder(),
        ),
        child: child,
      ),
    );
  }
}

/// Boton circular blanco con sombra e icono oscuro (FABs del mapa).
class RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;

  const RoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.22),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: AppColors.tinta, size: size * 0.5),
        ),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
