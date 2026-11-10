import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_service.dart';

/// Pantalla que se muestra cuando el chofer tiene estado "needs_correction".
/// Lista los campos que el administrador marcó como faltantes/incorrectos
/// (en rojo) y permite reenviar la solicitud.
class CorrectionScreen extends StatefulWidget {
  const CorrectionScreen({
    super.key,
    required this.api,
    required this.profile,
    required this.driverId,
  });

  final ApiService api;
  final DriverProfile profile;
  final String driverId;

  @override
  State<CorrectionScreen> createState() => _CorrectionScreenState();
}

class _CorrectionScreenState extends State<CorrectionScreen> {
  bool _sending = false;
  String? _error;
  String? _ok;

  Future<void> _reenviar() async {
    setState(() {
      _sending = true;
      _error = null;
      _ok = null;
    });
    try {
      await widget.api.reenviarSolicitud(widget.driverId);
      if (!mounted) return;
      setState(() {
        _ok = 'Solicitud reenviada. En revisión.';
        _sending = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _sending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final missing = widget.profile.missingFields;
    return Scaffold(
      appBar: AppBar(title: const Text('Corrige tu registro')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'El administrador rechazó tu solicitud. Corrige los datos '
              'marcados en rojo y reenvía.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            if (missing.isEmpty)
              const Text('No se indicaron campos específicos. Revisa todos '
                  'los datos.'),
            ...missing.map((campo) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.red, width: 2),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.red.shade50,
                    ),
                    child: Text(
                      'Falta o es incorrecto: $campo',
                      style: const TextStyle(
                          color: Colors.red, fontWeight: FontWeight.w600),
                    ),
                  ),
                )),
            const SizedBox(height: 16),
            Text('Datos actuales: ${widget.profile.fullName} · '
                '${widget.profile.email} · ${widget.profile.telefono}'),
            const SizedBox(height: 24),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_ok != null)
              Text(_ok!, style: const TextStyle(color: Colors.green)),
            const Spacer(),
            ElevatedButton(
              onPressed: _sending ? null : _reenviar,
              child: _sending
                  ? const CircularProgressIndicator()
                  : const Text('Reenviar solicitud'),
            ),
          ],
        ),
      ),
    );
  }
}