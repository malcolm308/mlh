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
  static const String _telefono = '+53 59295207';
  static const String _whatsappUrl =
      'https://wa.me/5359295207?text=Hola,%20necesito%20ayuda%20con%20mi%20viaje.';

  Future<void> _launchWhatsApp() async {
    final uri = Uri.parse(_whatsappUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp')),
      );
    }
  }

  Future<void> _llamar() async {
    final uri = Uri(scheme: 'tel', path: '+5359295207');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el marcador')),
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
                    subtitle: const Text(_telefono),
                    onTap: _llamar,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _launchWhatsApp,
                      icon: const Icon(Icons.chat),
                      label: const Text('Chat en vivo (WhatsApp)'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
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
