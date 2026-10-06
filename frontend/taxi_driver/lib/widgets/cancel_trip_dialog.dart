import 'package:flutter/material.dart';

import '../services/cancellation_service.dart';

/// Dialogo de confirmacion antes de cancelar un viaje ya aceptado.
///
/// Existe para que un toque accidental no se lleve por delante un viaje que el
/// chofer ya cogio. Cancelar descuenta una de las tres chances del dia, asi que
/// el boton no puedeir directo.
///
/// Los textos se pasan desde fuera para que este widget no dependa de la
/// pantalla ni del servicio, y se pueda probar con los valores que quiera.
class CancelTripDialog extends StatelessWidget {
  /// Cancelaciones que quedan hoy, para el texto del aviso.
  final int restantes;

  /// Maximo diario, para no repetir el numero en varios sitios.
  final int maximo;

  const CancelTripDialog({
    super.key,
    required this.restantes,
    this.maximo = CancellationService.maximoPorDia,
  });

  /// Muestra el dialogo y devuelve `true` solo si el chofer confirma.
  ///
  /// Devolver `false` es el valor por defecto: cerrar con el boton de atras o
  /// tocando fuera NO cancela.
  static Future<bool> mostrar(
    BuildContext context, {
    required int restantes,
    int maximo = CancellationService.maximoPorDia,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => CancelTripDialog(restantes: restantes, maximo: maximo),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final plural = restantes == 1 ? 'te queda' : 'te quedan';

    return AlertDialog(
      title: const Text('¿Cancelar este viaje?'),
      content: Text(
        'Esta acción no se puede deshacer. $plural $restantes '
        'cancelaciones disponibles hoy de $maximo.',
      ),
      actions: [
        // Accion principal a la izquierda: volver al viaje, que es lo que se
        // quiere en el 99 % de las veces que se abre esto.
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('No, continuar viaje'),
        ),
        // Texto rojo y separado del otro: cancelar es la accion destructiva.
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Sí, cancelar'),
        ),
      ],
    );
  }
}