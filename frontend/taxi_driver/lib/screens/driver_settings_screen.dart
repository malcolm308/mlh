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