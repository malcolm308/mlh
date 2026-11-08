import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';
import '../widgets/ui/warning_box.dart';

/// Promociones vigentes de RapiTaxi para el PASAJERO.
///
/// Se alimenta de `GET /admin/promociones/vigente`, el mismo estado que ve el
/// panel de administracion. Si no hay nada activo (o ya expiro) se dice tal
/// cual: sin promociones HYPOTECAS.
class PromocionesScreen extends StatefulWidget {
  final ApiService api;

  const PromocionesScreen({super.key, required this.api});

  @override
  State<PromocionesScreen> createState() => _PromocionesScreenState();
}

class _PromocionesScreenState extends State<PromocionesScreen> {
  Map<String, dynamic>? _promo;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.api.promocionVigente();
      if (!mounted) return;
      setState(() {
        _promo = p;
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

  bool get _descuentoVivo {
    final p = _promo;
    if (p == null) return false;
    return (p['descuento_aplicando'] ?? false) == true;
  }

  bool get _referidosVivos {
    final p = _promo;
    if (p == null) return false;
    return (p['referidos_activos'] ?? false) == true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Promociones')),
      body: RefreshIndicator(
        onRefresh: _cargar,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading && _promo == null)
              const SizedBox(
                height: 220,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              WarningBox(
                title: 'No se pudo consultar',
                message: '$_error. Reintenta en un momento.',
                icon: Icons.wifi_off_outlined,
              )
            else ...[
              if (_descuentoVivo)
                SoftCard(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const CircleAvatar(
                            radius: 22,
                            backgroundColor: AppColors.acentoSuave,
                            child: Icon(Icons.local_offer_rounded,
                                color: AppColors.ambar),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '${_promo!['descuento_cliente_porcentaje_texto']} '
                              'de descuento',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: AppColors.tinta,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Descuento directo en cada viaje que pides '
                        '(se aplica al cerrar, sin cupones).',
                        style: TextStyle(
                            color: AppColors.secundario, height: 1.35),
                      ),
                      if (_vigencia != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Vigente hasta $_vigencia',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ambar,
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              else
                const WarningBox(
                  title: 'Sin promociones activas',
                  message: 'No hay promociones disponibles en este momento. '
                      'Avisaremos aquí cuando la administración lance '
                      'una nueva.',
                  icon: Icons.local_offer_outlined,
                ),
              const SizedBox(height: 14),
              if (_referidosVivos)
                SoftCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 20,
                        backgroundColor: AppColors.acentoSuave,
                        child: Icon(Icons.card_giftcard_outlined,
                            color: AppColors.ambar),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Programa de invitados activo: invita amigos y '
                          'acumula descuentos desde "Mi perfil".',
                          style: TextStyle(
                              color: AppColors.secundario, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String? get _vigencia {
    final iso = (_promo!['fecha_expiracion'] ?? '').toString();
    final d = DateTime.tryParse(iso);
    if (d == null) return null;
    return '${d.day}/${d.month}/${d.year}';
  }
}
