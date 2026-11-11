import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Historial de transferencias y pagos del pasajero (vista embebible).
///
/// Muestra, con el MONTO TOTAL que pagó el cliente, los viajes pagados con
/// billetera o transferencia y las transferencias de billetera a billetera.
/// Todas las contrapartes se identifican por teléfono, nunca por correo.
class ClientTransferHistoryView extends StatefulWidget {
  final ApiService api;
  final String clientId;
  final String fullName;

  /// `true` cuando se incrusta dentro de un scroll (sin ListView propio).
  final bool embebido;

  const ClientTransferHistoryView({
    super.key,
    required this.api,
    required this.clientId,
    required this.fullName,
    this.embebido = false,
  });

  @override
  State<ClientTransferHistoryView> createState() =>
      _ClientTransferHistoryViewState();
}

class _ClientTransferHistoryViewState extends State<ClientTransferHistoryView> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  String? _telefono;
  double _totalPagado = 0;
  double _totalViajes = 0;
  double _totalTransferido = 0;

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
      final j = await widget.api.getClientTransferHistory(widget.clientId);
      if (!mounted) return;
      setState(() {
        _telefono = j['telefono']?.toString();
        _items = ((j['items'] ?? const []) as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _totalPagado = (j['total_pagado'] as num?)?.toDouble() ?? 0;
        _totalViajes = (j['total_viajes'] as num?)?.toDouble() ?? 0;
        _totalTransferido = (j['total_transferido'] as num?)?.toDouble() ?? 0;
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 36),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _mensajeError();
    }

    final contenido = <Widget>[
      _cabecera(),
      const SizedBox(height: 14),
      if (_items.isEmpty) _vacio() else ..._items.map(_fila),
    ];

    if (widget.embebido) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: contenido,
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: contenido,
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
          const Text('Monto total pagado',
              style: TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 3),
          Text(
            '${_totalPagado.toStringAsFixed(2)} CUP',
            style: const TextStyle(
                color: Color(0xFFFFD100),
                fontSize: 26,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _total('En viajes', _totalViajes, Colors.white),
              ),
              Container(width: 1, height: 32, color: Colors.white24),
              Expanded(
                child: _total(
                    'Transferido', _totalTransferido, const Color(0xFF7CE3A8)),
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
            style: const TextStyle(color: Colors.white60, fontSize: 11)),
        const SizedBox(height: 2),
        Text(
          '${monto.toStringAsFixed(2)} CUP',
          style: TextStyle(
              color: color, fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _fila(Map<String, dynamic> item) {
    final metodo = (item['metodo'] ?? 'Billetera').toString();
    final monto = (item['monto'] as num?)?.toDouble() ?? 0;
    final recargo = (item['recargo_transferencia'] as num?)?.toDouble() ?? 0;
    final contraparte = (item['contraparte_telefono'] ?? '').toString();
    final nombre = (item['contraparte_nombre'] ?? '').toString();
    final esViaje = (item['tipo'] ?? '') == 'viaje';
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(esViaje ? Icons.local_taxi_rounded : Icons.swap_horiz,
                        size: 12, color: color),
                    const SizedBox(width: 4),
                    Text(
                      metodo,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: color),
                    ),
                  ],
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
              Expanded(
                child: Text(
                  (item['concepto'] ??
                          (esViaje ? 'Pago de viaje' : 'Transferencia'))
                      .toString(),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.tinta,
                      fontSize: 13.5),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${monto.toStringAsFixed(2)} CUP',
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.tinta,
                    fontSize: 14.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.phone_outlined,
                  size: 13, color: AppColors.secundario),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  contraparte.isEmpty ? 'Sin teléfono' : contraparte,
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.secundario,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (nombre.isNotEmpty)
                Flexible(
                  child: Text(
                    nombre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.secundario),
                  ),
                ),
            ],
          ),
          if (recargo > 0) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.ambarFondo,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.ambarBorde),
              ),
              child: Text(
                'Incluye ${recargo.toStringAsFixed(2)} CUP de recargo por '
                'transferencia',
                style:
                    const TextStyle(fontSize: 11, color: AppColors.ambar),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _vacio() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: const [
          Icon(Icons.receipt_long_rounded,
              size: 54, color: AppColors.secundario),
          SizedBox(height: 10),
          Text(
            'Aún no hay transferencias',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.tinta),
          ),
          SizedBox(height: 4),
          Text(
            'Aquí verás los viajes pagados con billetera o transferencia y '
            'las transferencias que hagas a otros pasajeros.',
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

/// Pantalla completa del historial de transferencias (entrada del menú).
class ClientTransferHistoryScreen extends StatelessWidget {
  final ApiService api;
  final String clientId;
  final String fullName;

  const ClientTransferHistoryScreen({
    super.key,
    required this.api,
    required this.clientId,
    required this.fullName,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historial de transferencias')),
      body: ClientTransferHistoryView(
        api: api,
        clientId: clientId,
        fullName: fullName,
      ),
    );
  }
}
