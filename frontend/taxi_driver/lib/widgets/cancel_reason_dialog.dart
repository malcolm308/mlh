import 'package:flutter/material.dart';

/// Motivos por los que un chofer cancela un viaje.
///
/// Van como constante y no como texto suelto en el dialogo porque el backend
/// los acaba contando por separado para estadisticas. Si uno cambia aqui y no
/// alla, los conteos dejan de cuadrar.
enum MotivoCancelacion {
  noResponde('El cliente no responde / no contesta el teléfono'),
  noAparece('El cliente no aparece en el punto de recogida'),
  direccionIncorrecta('Dirección incorrecta o inaccesible'),
  otro('Otro motivo');

  const MotivoCancelacion(this.etiqueta);

  /// Texto que ve el chofer.
  final String etiqueta;
}

/// Dialogo de cancelacion del PASO INTERMEDIO ("van a buscar al cliente").
///
/// No es el mismo que el del panel del viaje en curso (ese participa en el
/// limite de 3 del dia): aqui quien falto fue el cliente, la cancelacion no
/// se cuenta y SOLO se puede elegir motivo en el propio dialogo. Devuelve el
/// motivo como texto o `null` si el chofer se arrepintio.
class CancelarRecogidaDialog extends StatefulWidget {
  const CancelarRecogidaDialog({super.key});

  static Future<String?> mostrar(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const CancelarRecogidaDialog(),
    );
  }

  @override
  State<CancelarRecogidaDialog> createState() => _CancelarRecogidaDialogState();
}

class _CancelarRecogidaDialogState extends State<CancelarRecogidaDialog> {
  MotivoCancelacion? _motivo;
  final TextEditingController _otro = TextEditingController();

  @override
  void dispose() {
    _otro.dispose();
    super.dispose();
  }

  bool get _puedeAceptar {
    if (_motivo == null) return false;
    if (_motivo == MotivoCancelacion.otro) return _otro.text.trim().isNotEmpty;
    return true;
  }

  String get _motivoTexto => _motivo == MotivoCancelacion.otro
      ? _otro.text.trim()
      : (_motivo?.etiqueta ?? '');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('¿Cancelar el viaje?'),
      content: SingleChildScrollView(
        child: RadioGroup<MotivoCancelacion>(
          groupValue: _motivo,
          onChanged: (v) => setState(() => _motivo = v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Eligen un motivo; el pasajero lo verá como aviso. No consume '
                'ninguna de tus cancelaciones del día.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              for (final motivo in MotivoCancelacion.values)
                RadioListTile<MotivoCancelacion>(
                  dense: true,
                  value: motivo,
                  title: Text(motivo.etiqueta, style: const TextStyle(fontSize: 13.5)),
                ),
              if (_motivo == MotivoCancelacion.otro) ...[
                TextField(
                  controller: _otro,
                  autofocus: true,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Cuéntanos el motivo',
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
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Volver'),
        ),
        FilledButton.icon(
          onPressed: _puedeAceptar
              ? () => Navigator.pop(context, _motivoTexto)
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.cancel_outlined, size: 18),
          label: const Text('Cancelar viaje'),
        ),
      ],
    );
  }
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