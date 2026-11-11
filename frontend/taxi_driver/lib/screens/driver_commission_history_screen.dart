import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Historial de comisiones del chofer, con el desglose de cada carrera.
///
/// Cada carrera se identifica por el teléfono del pasajero (nunca por el
/// correo). El monto es lo que pagó el pasajero y la comisión es lo que retuvo
/// la plataforma: efectivo, billetera o transferencia externa.
class DriverCommissionHistoryView extends StatefulWidget {
  final ApiService api;
  final String driverId;
  final String fullName;

  /// `true` cuando se incrusta dentro de un scroll (sin ListView propio).
  final bool embebido;

  const DriverCommissionHistoryView({
    super.key,
    required this.api,
    required this.driverId,
    required this.fullName,
    this.embebido = false,
  });

  @override
  State<DriverCommissionHistoryView> createState() =>
      _DriverCommissionHistoryViewState();
}

class _DriverCommissionHistoryViewState
    extends State<DriverCommissionHistoryView> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  String? _telefono;
  double _facturado = 0;
  double _comision = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final j = await widget.api.getCommissionHistory(widget.driverId);
      if (!mounted) return;
      setState(() {
        _telefono = j['telefono']?.toString();
        _items = ((j['items'] ?? const []) as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _facturado = (j['total_facturado'] as num?)?.toDouble() ?? 0;
        _comision = (j['total_comision'] as num?)?.toDouble() ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _fecha(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const meses = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    final mes = (d.month >= 1 && d.month <= 12) ? meses[d.month - 1] : '?';
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day.toString().padLeft(2, '0')} $mes ${d.year} · $hh:$mm';
  }

  Color _colorMetodo(String metodo) => switch (metodo) {
        'Billetera' => const Color(0xFF1A73E8),
        'Transferencia' => const Color(0xFF7B1FA2),
        _ => AppColors.ambar,
      };

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _mensajeError();
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: widget.embebido
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        shrinkWrap: widget.embebido,
        padding: const EdgeInsets.all(16),
        children: [
          _cabecera(),
          const SizedBox(height: 14),
          if (_items.isEmpty) _vacio() else ..._items.map(_fila),
        ],
      ),
    );
  }

  Widget _cabecera() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF23262B), Color(0xFF45484F)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.fullName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          if ((_telefono ?? '').isNotEmpty) ...[
            const SizedBox(height: 3),
            Row(
              children: [
                const Icon(Icons.phone_outlined,
                    color: Colors.white70, size: 15),
                const SizedBox(width: 5),
                Text(
                  _telefono!,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _total('Facturado', _facturado, Colors.white),
              ),
              Container(width: 1, height: 38, color: Colors.white24),
              Expanded(
                child: _total(
                    'Comisión retenida', _comision, const Color(0xFFFFD100)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _total(String etiqueta, double monto, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(etiqueta,
            style: const TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 3),
        Text(
          '${monto.toStringAsFixed(2)} CUP',
          style: TextStyle(
              color: color, fontSize: 19, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _fila(Map<String, dynamic> item) {
    final metodo = (item['metodo_pago'] ?? 'Efectivo').toString();
    final monto = (item['monto_total'] as num?)?.toDouble() ?? 0;
    final comision = (item['comision'] as num?)?.toDouble() ?? 0;
    final contraparte = (item['cliente_telefono'] ?? '').toString();
    final nombre = (item['cliente_nombre'] ?? '').toString();
    final color = _colorMetodo(metodo);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borde),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  metodo,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: color),
                ),
              ),
              const Spacer(),
              Text(
                _fecha(item['fecha']?.toString()),
                style: const TextStyle(
                    fontSize: 11, color: AppColors.secundario),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.phone_outlined,
                  size: 14, color: AppColors.secundario),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  contraparte.isEmpty ? 'Sin teléfono' : contraparte,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.tinta),
                ),
              ),
              if (nombre.isNotEmpty)
                Flexible(
                  child: Text(
                    nombre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.secundario),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _dato('Monto total',
                    '${monto.toStringAsFixed(2)} CUP', AppColors.tinta),
              ),
              Expanded(
                child: _dato(
                    'Comisión',
                    '${comision.toStringAsFixed(2)} CUP',
                    comision > 0 ? AppColors.ambar : AppColors.exito),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dato(String etiqueta, String valor, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(etiqueta,
            style: const TextStyle(fontSize: 10.5, color: AppColors.secundario)),
        const SizedBox(height: 2),
        Text(
          valor,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w800, color: color),
        ),
      ],
    );
  }

  Widget _vacio() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: const [
          Icon(Icons.percent_rounded, size: 54, color: AppColors.secundario),
          SizedBox(height: 10),
          Text(
            'Aún no hay comisiones',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.tinta),
          ),
          SizedBox(height: 4),
          Text(
            'Cuando completes tu primera carrera verás aquí el desglose.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.secundario, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _mensajeError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 52, color: AppColors.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: _load, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}
