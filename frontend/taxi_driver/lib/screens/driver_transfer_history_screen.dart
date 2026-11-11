import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Historial de transferencias INTERNAS del Fondo del chofer.
///
/// Son los movimientos de billetera de la plataforma (transferencias entre
/// choferes y pagos de viajes con billetera). No tiene nada que ver con el
/// método de pago "Transferencia", que es un pago externo.
///
/// La contraparte se identifica SIEMPRE por teléfono, nunca por correo.
class DriverTransferHistoryView extends StatefulWidget {
  final ApiService api;
  final String driverId;
  final String fullName;

  /// `true` cuando se incrusta dentro de un scroll (sin ListView propio).
  final bool embebido;

  const DriverTransferHistoryView({
    super.key,
    required this.api,
    required this.driverId,
    required this.fullName,
    this.embebido = false,
  });

  @override
  State<DriverTransferHistoryView> createState() =>
      _DriverTransferHistoryViewState();
}

class _DriverTransferHistoryViewState extends State<DriverTransferHistoryView> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  String? _telefono;
  double _recibido = 0;
  double _enviado = 0;

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
      final j = await widget.api.getTransferHistory(widget.driverId);
      if (!mounted) return;
      setState(() {
        _telefono = j['telefono']?.toString();
        _items = ((j['items'] ?? const []) as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _recibido = (j['total_recibido'] as num?)?.toDouble() ?? 0;
        _enviado = (j['total_enviado'] as num?)?.toDouble() ?? 0;
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
                child: _total('Recibido', _recibido, const Color(0xFF7CE3A8)),
              ),
              Container(width: 1, height: 38, color: Colors.white24),
              Expanded(
                child: _total('Enviado', _enviado, const Color(0xFFFFB4AB)),
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
    final monto = (item['monto'] as num?)?.toDouble() ?? 0;
    final positivo = monto >= 0;
    final color = positivo ? AppColors.exito : AppColors.error;
    final contraparte = (item['contraparte_telefono'] ?? '').toString();
    final nombre = (item['contraparte_nombre'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borde),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              positivo ? Icons.south_west_rounded : Icons.north_east_rounded,
              color: color,
              size: 19,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (item['concepto'] ?? 'Transferencia').toString(),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.tinta,
                      fontSize: 13.5),
                ),
                if (nombre.isNotEmpty)
                  Text(
                    nombre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.secundario),
                  ),
                Row(
                  children: [
                    const Icon(Icons.phone_outlined,
                        size: 13, color: AppColors.secundario),
                    const SizedBox(width: 4),
                    Text(
                      contraparte.isEmpty ? 'Sin teléfono' : contraparte,
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.secundario,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  _fecha(item['fecha']?.toString()),
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.secundario),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${positivo ? '+' : ''}${monto.toStringAsFixed(2)}',
            style: TextStyle(
                fontWeight: FontWeight.w800, color: color, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _vacio() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: const [
          Icon(Icons.swap_horiz_rounded, size: 54, color: AppColors.secundario),
          SizedBox(height: 10),
          Text(
            'Aún no hay movimientos',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.tinta),
          ),
          SizedBox(height: 4),
          Text(
            'Aquí verás las transferencias internas entre choferes y los pagos '
            'de viajes con billetera.',
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
