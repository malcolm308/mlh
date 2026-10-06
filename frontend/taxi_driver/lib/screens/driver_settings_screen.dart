import 'package:flutter/material.dart';

import '../config.dart';
import '../services/api_service.dart';

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
                    style: TextStyle(color: Color(0xFF888888))),
                value: _notifications,
                activeTrackColor: const Color(0xFF007AFF),
                onChanged: (v) => setState(() => _notifications = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sonido',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Reproducir sonido en nuevas solicitudes',
                    style: TextStyle(color: Color(0xFF888888))),
                value: _sonido,
                activeTrackColor: const Color(0xFF007AFF),
                onChanged: (v) => setState(() => _sonido = v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _card(
            'Servidor',
            [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.storage, color: Color(0xFF333333)),
                title: Text('Backend'),
                subtitle: Text(AppConfig.apiBase,
                    style: TextStyle(color: Color(0xFF888888))),
              ),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.map_outlined, color: Color(0xFF333333)),
                title: Text('Mapa (tiles)'),
                subtitle: Text(AppConfig.mapStyleUrl,
                    style: TextStyle(color: Color(0xFF888888))),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline,
                    color: Color(0xFF333333)),
                title: const Text('Acerca de'),
                subtitle: const Text('RapiTaxi Chofer v2.0',
                    style: TextStyle(color: Color(0xFF888888))),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Probar conexión',
                  onPressed: () async {
                    try {
                      await widget.api.getChofer(widget.driverId);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Conexión correcta con el backend')),
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
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Color(0xFF007AFF),
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            const Divider(height: 18),
            ...children,
          ],
        ),
      ),
    );
  }
}