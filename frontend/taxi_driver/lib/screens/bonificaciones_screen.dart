import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';
import '../widgets/ui/warning_box.dart';

/// Bonificaciones vigentes para el CHOFER.
///
/// Sale de la misma fila del panel de administracion (`promociones` id=1):
/// bono por viajes del dia (monto + viajes requeridos) y descuento que se
/// esta dandole a los clientes para que pidan mas viajes. Si no hay nada
/// activo, se dice tal cual.
class BonificacionesScreen extends StatefulWidget {
  final ApiService api;

  const BonificacionesScreen({super.key, required this.api});

  @override
  State<BonificacionesScreen> createState() => _BonificacionesScreenState();
}

class _BonificacionesScreenState extends State<BonificacionesScreen> {
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

  bool get _bonoVivo {
    final p = _promo;
    if (p == null) return false;
    return (p['bono_chofer_activo'] ?? false) == true && !_expirada;
  }

  bool get _expirada => (_promo?['expirada'] ?? false) == true;

  bool get _descuentoVivo =>
      (_promo?['descuento_aplicando'] ?? false) == true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bonificaciones')),
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
            else if (_bonoVivo) ...[
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
                          child: Icon(Icons.emoji_events_outlined,
                              color: AppColors.ambar),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '${_money(_promo!['bono_chofer_monto'])} CUP de bono',
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
                    Text(
                      'Bono diario por completar '
                      '${_promo!['bono_chofer_viajes_requeridos']} viajes en '
                      'un mismo dia. El saldo entra a tu Fondo al cumplirlo.',
                      style: const TextStyle(
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
              ),
              const SizedBox(height: 14),
            ] else
              const WarningBox(
                title: 'Sin bonificaciones activas',
                message:
                    'No hay bonificaciones disponibles en este momento. '
                    'Cuando la administración active una, se muestra aquí.',
                icon: Icons.emoji_events_outlined,
              ),
            // Contexto util: si a los CLIENTES les estan dando descuento, el
            // chofer esta ganando viajes. Se muestra aunque no haya bono.
            if (!_loading && _error == null && _descuentoVivo)
              SoftCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 20,
                      backgroundColor: AppColors.acentoSuave,
                      child: Icon(Icons.local_offer_rounded,
                          color: AppColors.ambar),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Además, tus pasajeros llevan '
                        '${_promo!['descuento_cliente_porcentaje_texto']} de '
                        'descuento en cada viaje: muchos más pedidos.',
                        style: const TextStyle(
                            color: AppColors.secundario, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
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

  /// Los montos pueden venir con decimales "1230.0": se pintan sin la cola.
  String _money(dynamic valor) {
    final v = (valor is num) ? valor : double.tryParse('$valor') ?? 0.0;
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  }
}
