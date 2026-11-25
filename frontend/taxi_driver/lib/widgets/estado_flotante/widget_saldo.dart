import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'arco_saldo_painter.dart';

/// Tarjeta flotante con el saldo disponible y su arco de progreso.
///
/// El arco representa lo que queda de la última recarga conocida. El botón de
/// refrescar vuelve a consultar `/drivers/{id}/fondo`.
///
/// Tamaño compacto: ocupa poco más de una pulgada y media de alto para no
/// quitarle mapa al conductor, pero el monto sigue siendo lo más grande de la
/// tarjeta.
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
      width: 128,
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: AppColors.acento,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  size: 11,
                  color: AppColors.tinta,
                ),
              ),
              const SizedBox(width: 5),
              const Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'SALDO DISPONIBLE',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: AppColors.secundario,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 22,
                height: 22,
                child: actualizando
                    ? const Padding(
                        padding: EdgeInsets.all(6),
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Refrescar saldo',
                        onPressed: onRefrescar,
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 15,
                          color: AppColors.secundario,
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 1),
          SizedBox(
            width: 108,
            height: 56,
            child: CustomPaint(
              painter: ArcoSaldoPainter(
                progreso: progreso,
                colorActivo: AppColors.acento,
                colorInactivo: const Color(0xFFEDE8DA),
                grosor: 9,
              ),
            ),
          ),
          const SizedBox(height: 1),
          // Un saldo de cinco cifras con decimales no cabe a 19 px. El
          // `FittedBox` lo reduce lo justo para que «$155371.65 CUP» siga en
          // una sola línea dentro de la tarjeta, sin desbordar ni partir el
          // sufijo «CUP» a un renglón aparte.
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: RichText(
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: monto,
                      style: const TextStyle(
                        fontSize: 19,
                        height: 1.0,
                        fontWeight: FontWeight.w900,
                        color: AppColors.tinta,
                      ),
                    ),
                    const TextSpan(
                      text: ' CUP',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        color: AppColors.secundario,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
