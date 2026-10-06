import 'package:flutter/material.dart';

/// Motivos por los que un chofer cancela un viaje.
///
/// Van como constante y no como texto suelto en el dialogo porque el backend
/// los acaba contando por separado para estadisticas. Si uno cambia aqui y no
/// alla, los conteos dejan de cuadrar.
enum MotivoCancelacion {
  pasajeroNoAparece('Pasajero no aparece'),
  direccionIncorrecta('Dirección incorrecta'),
  emergenciaPersonal('Emergencia personal'),
  problemaVehiculo('Problema con el vehículo'),
  otro('Otro');

  const MotivoCancelacion(this.etiqueta);

  /// Texto que ve el chofer.
  final String etiqueta;
}

/// Dialogo para elegir el motivo de la cancelacion.
///
/// Es opcional a proposito: el chofer puede cancelar sin dar reason. Por eso
/// tiene una salida clara de "sin motivo" y el boton de cancelar queda
/// deshabilitado mientras el motivo sea "Otro" y no haya texto.
///
/// La razon viaja como texto libre al backend; el enum solo sirve para pintarla.
class CancelReasonDialog extends StatefulWidget {
  const CancelReasonDialog({super.key});

  /// Muestra el dialogo y devuelve el motivo, o `null` si el chofer no quiere
  /// dar ninguno.
  static Future<String?> mostrar(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => const CancelReasonDialog(),
    );
  }

  @override
  State<CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<CancelReasonDialog> {
  MotivoCancelacion? _motivo;
  final TextEditingController _otro = TextEditingController();

  @override
  void dispose() {
    _otro.dispose();
    super.dispose();
  }

  /// `true` cuando se puede aceptar: hay motivo, y si es "Otro" hay texto.
  bool get _puedeAceptar {
    if (_motivo == null) return false;
    if (_motivo == MotivoCancelacion.otro) return _otro.text.trim().isNotEmpty;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('¿Por qué cancelas?'),
      content: SingleChildScrollView(
        // `RadioGroup` es el patron actual desde Flutter 3.32; el
        // `groupValue` de `RadioListTile` quedo obsoleto.
        child: RadioGroup<MotivoCancelacion>(
          groupValue: _motivo,
          onChanged: (v) => setState(() => _motivo = v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Es opcional. Nos ayuda a mejorar.',
                style:
                    TextStyle(color: Theme.of(context).hintColor, fontSize: 13),
              ),
              const SizedBox(height: 12),
              for (final m in MotivoCancelacion.values)
                RadioListTile<MotivoCancelacion>(
                  value: m,
                  // `dense` + `contentPadding` para que quepan los cinco sin
                  // que el dialogo se salga de la pantalla en moviles pequenos.
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(m.etiqueta),
                ),
              if (_motivo == MotivoCancelacion.otro) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _otro,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Cuéntanos qué pasó',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        // Salida sin motivo: el cancelador es valido asi.
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar sin motivo'),
        ),
        FilledButton(
          onPressed:
              _puedeAceptar ? () => Navigator.of(context).pop(_motivo!.etiqueta) : null,
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}