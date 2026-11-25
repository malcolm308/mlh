import 'package:flutter/material.dart';

import '../../services/estado_flotante_controller.dart';
import 'widget_red.dart';
import 'widget_saldo.dart';

/// Los dos widgets flotantes del chofer sobre el mapa.
///
/// Se coloca como hijo de un [Stack] a pantalla completa; el propio overlay se
/// encarga del Safe Area, así que ningún aviso choca con la barra de estado de
/// Android ni con el notch.
///
/// Reparto pensado para no tapar al conductor:
///  * **saldo**: arriba y centrado, por debajo de la barra de estado y entre el
///    menú y la campana/GPS, que viven en las esquinas;
///  * **red**: a media altura, pegado al borde derecho y en formato compacto.
///    El marcador del vehículo se dibuja en el centro del mapa, así que este
///    aviso queda a su derecha sin cubrirlo.
///
/// La visibilidad de cada tarjeta la decide [EstadoFlotanteController] por
/// separado:
///  * saldo: solo si el chofer está disponible (sin viaje activo);
///  * red: solo si no hay señal o es débil. Con señal buena desaparece.
///
/// «Sin señal» y «señal débil» son estados excluyentes del mismo enum: nunca
/// se pintan los dos a la vez.
class EstadoFlotanteOverlay extends StatelessWidget {
  const EstadoFlotanteOverlay({
    super.key,
    required this.controller,
    required this.onRefrescarSaldo,
    required this.onReintentarRed,
    this.desplazamientoSuperior = 8,
  });

  final EstadoFlotanteController controller;
  final VoidCallback onRefrescarSaldo;
  final VoidCallback onReintentarRed;

  /// Separación bajo el Safe Area para la tarjeta de saldo.
  final double desplazamientoSuperior;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final mostrarRed = controller.redVisible;
        final mostrarSaldo = controller.saldoVisible;
        if (!mostrarRed && !mostrarSaldo) return const SizedBox.shrink();

        return SafeArea(
          child: Stack(
            children: [
              if (mostrarSaldo)
                Positioned(
                  top: desplazamientoSuperior,
                  left: 12,
                  right: 12,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: WidgetSaldo(
                      saldo: controller.saldo,
                      progreso: controller.progresoSaldo,
                      actualizando: controller.actualizandoSaldo,
                      onRefrescar: onRefrescarSaldo,
                    ),
                  ),
                ),
              if (mostrarRed)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 10,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: WidgetRed(
                      estado: controller.red,
                      onReintentar: onReintentarRed,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
