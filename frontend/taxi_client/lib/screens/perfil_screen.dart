import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';
import 'referral_screen.dart';

/// Perfil del pasajero: datos personales y numeros de su actividad.
///
/// Nunca se muestra el id interno: solo lo que la cuenta de verdad (nombre,
/// telefono, correo y su codigo de referido).
class PerfilScreen extends StatefulWidget {
  final ApiService api;
  final ClientProfile profile;
  final String clientId;

  const PerfilScreen({
    super.key,
    required this.api,
    required this.profile,
    required this.clientId,
  });

  @override
  State<PerfilScreen> createState() => _PerfilScreenState();
}

class _PerfilScreenState extends State<PerfilScreen> {
  Map<String, dynamic>? _resumen;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargarResumen();
  }

  Future<void> _cargarResumen() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.api.resumenViajes(widget.clientId);
      if (!mounted) return;
      setState(() {
        _resumen = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Mi perfil')),
      body: RefreshIndicator(
        onRefresh: _cargarResumen,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _tarjetaDatos(scheme),
            const SizedBox(height: 14),
            _tarjetaEstadisticas(scheme),
            const SizedBox(height: 14),
            _tarjetaReferidos(scheme),
          ],
        ),
      ),
    );
  }

  Widget _tarjetaDatos(ColorScheme scheme) {
    final p = widget.profile;
    final nombreCompleto = p.fullName;
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: AppColors.acentoSuave,
            child: Text(
              _iniciales(nombreCompleto),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: AppColors.tinta,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            nombreCompleto.isEmpty ? 'Pasajero RapiTaxi' : nombreCompleto,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppColors.tinta,
            ),
          ),
          const SizedBox(height: 8),
          _filaDatos(Icons.phone_outlined, p.telefono),
          _filaDatos(Icons.alternate_email_outlined, p.email),
          if (p.codigoReferido?.isNotEmpty ?? false)
            _filaDatos(Icons.card_giftcard_outlined,
                'Código de invitación: ${p.codigoReferido}'),
        ],
      ),
    );
  }

  Widget _filaDatos(IconData icono, String? texto) {
    if (texto == null || texto.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icono, size: 18, color: AppColors.secundario),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              texto,
              style: const TextStyle(color: AppColors.secundario, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tarjetaEstadisticas(ColorScheme scheme) {
    final r = _resumen;
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tus viajes',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: AppColors.tinta,
            ),
          ),
          const SizedBox(height: 12),
          if (_loading && r == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: AppColors.error)),
            TextButton(onPressed: _cargarResumen, child: const Text('Reintentar')),
          ] else ...[
            Row(
              children: [
                _stat(
                  valor: '${r!['pedidos'] ?? 0}',
                  etiqueta: 'Pedidos',
                  icono: Icons.receipt_long_outlined,
                ),
                _stat(
                  valor: '${r['realizados'] ?? 0}',
                  etiqueta: 'Realizados',
                  icono: Icons.check_circle_outline,
                ),
                _stat(
                  valor: '${r['cancelados'] ?? 0}',
                  etiqueta: 'Cancelados',
                  icono: Icons.cancel_outlined,
                ),
              ],
            ),
            const Divider(height: 24),
            _filaStat(Icons.route_outlined,
                '${(r['kilometros'] ?? 0).toStringAsFixed(1)} km recorridos'),
            if ((r['total_gastado'] ?? 0) > 0)
              _filaStat(
                  Icons.payments_outlined,
                  'Total gastado: '
                      '${(r['total_gastado'] ?? 0).toStringAsFixed(2)} CUP'),
          ],
        ],
      ),
    );
  }

  Widget _stat({required String valor, required String etiqueta, required IconData icono}) {
    return Expanded(
      child: Column(
        children: [
          Icon(icono, size: 22, color: AppColors.secundario),
          const SizedBox(height: 4),
          Text(
            valor,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.tinta,
            ),
          ),
          Text(
            etiqueta,
            style: const TextStyle(fontSize: 12, color: AppColors.secundario),
          ),
        ],
      ),
    );
  }

  Widget _filaStat(IconData icono, String texto) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icono, size: 18, color: AppColors.secundario),
            const SizedBox(width: 10),
            Text(
              texto,
              style: const TextStyle(color: AppColors.secundario, fontSize: 13.5),
            ),
          ],
        ),
      );

  Widget _tarjetaReferidos(ColorScheme scheme) {
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Invita y gana',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: AppColors.tinta,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Cada amigo que se registre con tu código te da un descuento '
            'para tus próximos viajes.',
            style: TextStyle(fontSize: 13, color: AppColors.secundario, height: 1.35),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ReferralScreen(
                    api: widget.api,
                    clientId: widget.clientId,
                    fullName: widget.profile.fullName,
                  ),
                ));
              },
              child: const Text('Ver código y referidos'),
            ),
          ),
        ],
      ),
    );
  }

  String _iniciales(String nombre) {
    final partes =
        nombre.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (partes.isEmpty) return 'R';
    return partes.take(2).map((s) => s[0].toUpperCase()).join();
  }
}
