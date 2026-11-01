import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

class SupportScreen extends StatefulWidget {
  final ApiService api;

  const SupportScreen({super.key, required this.api});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  Future<void> _launchWhatsApp() async {
    final uri = Uri.parse('https://wa.me/5359295207');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp')),
      );
    }
  }

  Future<void> _launchEmail() async {
    final uri = Uri.parse('mailto:malcolmlamar308@gmail.com');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el correo')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayuda y soporte'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Contacto',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const Icon(Icons.phone, color: Colors.green),
                    title: const Text('Teléfono'),
                    subtitle: const Text('+53 5 5551234'),
                    onTap: () {
                      final uri = Uri.parse('tel:+5355551234');
                      launchUrl(uri);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.email, color: Colors.blue),
                    title: const Text('Email'),
                    subtitle: const Text('malcolmlamar308@gmail.com'),
                    onTap: _launchEmail,
                  ),
                  ListTile(
                    leading: const Icon(Icons.chat, color: Colors.purple),
                    title: const Text('WhatsApp'),
                    subtitle: const Text('Chat en vivo'),
                    onTap: _launchWhatsApp,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Preguntas frecuentes',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ExpansionTile(
                    title: const Text('¿Cómo solicitar un viaje?'),
                    children: const [
                      Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Selecciona tu ubicación de origen y destino, '
                          'elige el tipo de vehículo y confirma tu viaje.',
                        ),
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('¿Qué métodos de pago aceptan?'),
                    children: const [
                      Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Aceptamos efectivo y transferencias bancarias.',
                        ),
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('¿Cómo cancelo un viaje?'),
                    children: const [
                      Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Puedes cancelar desde la pantalla del viaje en curso '
                          'presionando el botón de cancelar.',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
