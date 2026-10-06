import 'package:flutter/material.dart';

import '../config.dart';

/// Pantalla de soporte/ayuda (opción del menú hamburguesa).
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Soporte')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Icon(Icons.support_agent, size: 64, color: Color(0xFF007AFF)),
          const SizedBox(height: 12),
          const Text(
            '¿Necesitas ayuda?',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF333333)),
          ),
          const SizedBox(height: 4),
          const Text(
            'Contáctanos y te ayudaremos lo antes posible',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF888888)),
          ),
          const SizedBox(height: 24),
          _card(
            Icons.headset_mic_outlined,
            'Teléfono',
            '+53 59295207',
          ),
          const SizedBox(height: 12),
          _card(
            Icons.mail_outline,
            'Correo',
            'soporte@taxirapid.cu',
          ),
          const SizedBox(height: 12),
          _card(
            Icons.schedule,
            'Horario de atención',
            'Lunes a sábado · 8:00 am - 8:00 pm',
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'Servidor de datos: ${AppConfig.apiBase}',
              style: const TextStyle(
                  color: Color(0xFF888888), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(IconData icon, String label, String value) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: const Color(0xFF007AFF).withValues(alpha: 0.12),
          child: Icon(icon, color: const Color(0xFF007AFF)),
        ),
        title: Text(label, style: const TextStyle(color: Color(0xFF888888))),
        subtitle: Text(value,
            style: const TextStyle(
                color: Color(0xFF333333), fontWeight: FontWeight.w600)),
      ),
    );
  }
}