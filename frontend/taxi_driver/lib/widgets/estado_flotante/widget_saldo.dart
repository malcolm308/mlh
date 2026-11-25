import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'arco_saldo_painter.dart';

/// Tarjeta flotante con el saldo disponible y su arco de progreso.
///
/// El arco representa lo que queda de la última recarga conocida. El botón de
/// refrescar vuelve a consultar `/drivers/{id}/fondo`.
class WidgetSaldo extends StatelessWidget {
  const WidgetSaldo({
    super.key,
    required this.saldo,
    required this.progreso,
    required this.actualizando,
    required this.onRefrescar,
  });

  final double? saldo;
  final double progreso;
  final bool actualizando;
  final VoidCallback onRefrescar;

  @override
  Widget build(BuildContext context) {
    final monto = saldo == null ? '--' : '\$${saldo!.toStringAsFixed(2)}';
    return Container(
      width: 204,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(
                  color: AppColors.acento,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  size: 16,
                  color: AppColors.tinta,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'SALDO DISPONIBLE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                    color: AppColors.secundario,
                  ),
                ),
              ),
              SizedBox(
                width: 30,
                height: 30,
                child: actualizando
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Refrescar saldo',
                        onPressed: onRefrescar,
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 20,
                          color: AppColors.secundario,
                        ),
                      ),
              ),
            ],
          ),
          SizedBox(
            width: 172,
            height: 88,
            child: CustomPaint(
              painter: ArcoSaldoPainter(
                progreso: progreso,
                colorActivo: AppColors.acento,
                colorInactivo: const Color(0xFFEDE8DA),
                grosor: 14,
              ),
            ),
          ),
          const SizedBox(height: 2),
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              children: [
                TextSpan(
                  text: monto,
                  style: const TextStyle(
                    fontSize: 30,
                    height: 1.0,
                    fontWeight: FontWeight.w900,
                    color: AppColors.tinta,
                  ),
                ),
                const TextSpan(
                  text: ' CUP',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.secundario,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
