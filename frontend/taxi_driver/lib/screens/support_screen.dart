import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';

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
          const SizedBox(height: 10),
          const Icon(Icons.support_agent, size: 54, color: AppColors.ambar),
          const SizedBox(height: 10),
          const Text(
            '¿Necesitas ayuda?',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.tinta),
          ),
          const SizedBox(height: 4),
          const Text(
            'Contáctanos y te ayudaremos lo antes posible',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.secundario, height: 1.4),
          ),
          const SizedBox(height: 22),
          SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _fila(Icons.headset_mic_outlined, 'Teléfono', '+53 59295207'),
                const Divider(height: 1, indent: 16, endIndent: 16),
                _fila(Icons.mail_outline_rounded, 'Correo',
                    'rapitaxicuba@gmail.com'),
                const Divider(height: 1, indent: 16, endIndent: 16),
                _fila(Icons.schedule_rounded, 'Horario de atención',
                    'Lunes a sábado · 8:00 am - 8:00 pm'),
                const Divider(height: 1, indent: 16, endIndent: 16),
                _fila(Icons.send_outlined, 'Bot de Telegram',
                    '@RapiTaxiSoporte_bot'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fila(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: AppColors.acentoSuave,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: AppColors.ambar),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.secundario)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.tinta)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
