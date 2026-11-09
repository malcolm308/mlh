import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';

/// Configuración general del conductor (opción del menú hamburguesa).
class DriverSettingsScreen extends StatefulWidget {
  final ApiService api;
  final String driverId;

  const DriverSettingsScreen({
    super.key,
    required this.api,
    required this.driverId,
  });

  @override
  State<DriverSettingsScreen> createState() => _DriverSettingsScreenState();
}

class _DriverSettingsScreenState extends State<DriverSettingsScreen> {
  bool _notifications = true;
  bool _sonido = true;

  /// El borrado de cuenta esta en vuelo: el boton no se manda dos veces.
  bool _eliminando = false;

  Future<void> _confirmarEliminarCuenta() async {
    if (_eliminando) return;
    final confirmado = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _DialogoEliminarCuenta(),
    );
    if (confirmado != true) return;
    setState(() => _eliminando = true);
    try {
      await widget.api.deleteAccount();
      if (!mounted) return;
      // La pantalla principal limpia servicios, wakelock y token (cerrar la
      // sesion) y regresa al login: la cuenta ya no existe.
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _eliminando = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('No se pudo eliminar: '
            '$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), '')),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuración')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            'Preferencias',
            [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Notificaciones',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Recibir alertas de solicitudes',
                    style: TextStyle(color: AppColors.secundario)),
                value: _notifications,
                activeTrackColor: AppColors.acento,
                onChanged: (v) => setState(() => _notifications = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sonido',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Reproducir sonido en nuevas solicitudes',
                    style: TextStyle(color: AppColors.secundario)),
                value: _sonido,
                activeTrackColor: AppColors.acento,
                onChanged: (v) => setState(() => _sonido = v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _card(
            'Aplicación',
            [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline, color: AppColors.tinta),
                title: const Text('Acerca de'),
                subtitle: const Text('RapiTaxi Chofer 1.0.0',
                    style: TextStyle(color: AppColors.secundario)),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Probar conexión',
                  onPressed: () async {
                    try {
                      await widget.api.getChofer(widget.driverId);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Conexión correcta')),
                      );
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _card(
            'Cuenta',
            [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Eliminar cuenta',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, color: Colors.red)),
                subtitle: _eliminando
                    ? const Text('Eliminando tu cuenta...')
                    : const Text(
                        'Borra tu cuenta y tus vehículos. No se puede deshacer.',
                        style: TextStyle(color: AppColors.secundario)),
                trailing: _eliminando
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                enabled: !_eliminando,
                onTap: _confirmarEliminarCuenta,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card(String title, List<Widget> children) {
    return SoftCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: AppColors.ambar,
                    fontWeight: FontWeight.w800,
                    fontSize: 13)),
            const Divider(height: 18),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Doble confirmacion del borrado: hay que escribir ELIMINAR tal cual.
///
/// Un tap accidental no tiene que poder borrar una cuenta: el dialogo explica
/// lo que se pierde y exige la palabra completa para habilitar el boton.
class _DialogoEliminarCuenta extends StatefulWidget {
  const _DialogoEliminarCuenta();

  @override
  State<_DialogoEliminarCuenta> createState() => _DialogoEliminarCuentaState();
}

class _DialogoEliminarCuentaState extends State<_DialogoEliminarCuenta> {
  final TextEditingController _texto = TextEditingController();

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  bool get _coincide => _texto.text.trim().toUpperCase() == 'ELIMINAR';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('¿Eliminar tu cuenta?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Se borrarán tu cuenta, tus vehículos y tus fotos. No podrás '
            'volver a entrar con este número. Esta acción no se puede '
            'deshacer.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _texto,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Escribe "ELIMINAR" para confirmar',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_coincide) Navigator.of(context).pop(true);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _coincide ? () => Navigator.of(context).pop(true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: const Text('Eliminar cuenta'),
        ),
      ],
    );
  }
}