import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';

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
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Contacto',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.tinta,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Escríbenos y respondemos lo antes posible.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.secundario),
                ),
                const SizedBox(height: 12),
                _filaContacto(
                  icono: Icons.phone_rounded,
                  titulo: 'Teléfono',
                  subtitulo: _telefono,
                  onTap: _llamar,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _launchWhatsApp,
                    icon: const Icon(Icons.chat_outlined, size: 18),
                    label: const Text('Chat en vivo (WhatsApp)'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE9F6EE),
                      foregroundColor: const Color(0xFF1E7A3D),
                      minimumSize: const Size.fromHeight(44),
                      elevation: 0,
                      shape: const StadiumBorder(
                        side: BorderSide(color: Color(0xFFBFE3CD)),
                      ),
                      textStyle: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Preguntas frecuentes',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.tinta,
                  ),
                ),
                const SizedBox(height: 4),
                Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    iconColor: AppColors.ambar,
                    collapsedIconColor: AppColors.secundario,
                    childrenPadding: const EdgeInsets.only(bottom: 12),
                    title: const Text('¿Cómo solicitar un viaje?',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.tinta)),
                    children: const [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Selecciona tu ubicación de origen y destino, '
                          'elige el tipo de vehículo y confirma tu viaje.',
                          style: TextStyle(
                              fontSize: 13,
                              color: AppColors.secundario,
                              height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    iconColor: AppColors.ambar,
                    collapsedIconColor: AppColors.secundario,
                    childrenPadding: const EdgeInsets.only(bottom: 12),
                    title: const Text('¿Qué métodos de pago aceptan?',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.tinta)),
                    children: const [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Aceptamos efectivo y transferencias bancarias.',
                          style: TextStyle(
                              fontSize: 13,
                              color: AppColors.secundario,
                              height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    iconColor: AppColors.ambar,
                    collapsedIconColor: AppColors.secundario,
                    childrenPadding: const EdgeInsets.only(bottom: 12),
                    title: const Text('¿Cómo cancelo un viaje?',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.tinta)),
                    children: const [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Puedes cancelar desde la pantalla del viaje en curso '
                          'presionando el botón de cancelar.',
                          style: TextStyle(
                              fontSize: 13,
                              color: AppColors.secundario,
                              height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Fila de contacto con icono en burbuja ambar.
  Widget _filaContacto({
    required IconData icono,
    required String titulo,
    required String subtitulo,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppColors.campo,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: AppColors.acentoSuave,
                  shape: BoxShape.circle,
                ),
                child: Icon(icono, size: 18, color: AppColors.ambar),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titulo,
                        style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.tinta)),
                    Text(subtitulo,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppColors.secundario)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: AppColors.secundario),
            ],
          ),
        ),
      ),
    );
  }
}
