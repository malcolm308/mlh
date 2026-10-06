import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_service.dart';

/// Registro de viajes del chofer: GET /trips/driver/{id}.
class HistoryScreen extends StatefulWidget {
  final ApiService api;
  final String driverId;
  final String fullName;

  const HistoryScreen({
    super.key,
    required this.api,
    required this.driverId,
    required this.fullName,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<TripOffer> _trips = [];
  bool _loading = true;
  String? _error;

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
      final trips = await widget.api.getTripsByDriver(widget.driverId);
      if (!mounted) return;
      setState(() {
        _trips = trips.reversed.toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Color _statusColor(String status) => switch (status) {
        'completed' => Colors.green.shade600,
        'in_progress' => Colors.amber.shade700,
        'accepted' || 'driver_arrived' => Colors.lightBlue.shade700,
        'requested' => Colors.orange.shade700,
        'cancelled' || 'expired' => Colors.red.shade600,
        _ => Colors.grey.shade600,
      };

  String _statusLabel(String status) => switch (status) {
        'completed' => 'Completado',
        'in_progress' => 'En curso',
        'accepted' => 'Aceptado',
        'driver_arrived' => 'En recogida',
        'requested' => 'Solicitado',
        'cancelled' => 'Cancelado',
        'expired' => 'Expirado',
        _ => status,
      };

  String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} · ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  void _showDetail(TripOffer t) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Viaje ${t.tripId}',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const Spacer(),
                _chip(_statusLabel(t.status), _statusColor(t.status)),
              ],
            ),
            const Divider(height: 20),
            _row('Chofer', widget.fullName),
            _row('Vehículo', t.vehicleType),
            _row('Fecha', _fmtDate(t.requestedAt)),
            _row('Pasajeros', '${t.numPasajes}'),
            if (t.pickup != null)
              _row('Recogida',
                  '${t.pickup!.latitude.toStringAsFixed(5)}, ${t.pickup!.longitude.toStringAsFixed(5)}'),
            if (t.dropoff != null)
              _row('Destino',
                  '${t.dropoff!.latitude.toStringAsFixed(5)}, ${t.dropoff!.longitude.toStringAsFixed(5)}'),
            if (t.distanceKm != null)
              _row('Distancia', '${t.distanceKm!.toStringAsFixed(2)} km'),
            const Divider(height: 16),
            _row(
              'Precio',
              '${(t.totalFare ?? t.precioEstimado ?? 0).toStringAsFixed(2)} ${t.currency}',
              bold: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color, width: 1),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      );

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(value,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.bold : FontWeight.w500)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi historial'),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('Reintentar')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _trips.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 120),
                            Icon(Icons.receipt_long,
                                size: 64, color: scheme.outlineVariant),
                            const SizedBox(height: 12),
                            Text('Aún no tienes viajes',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant)),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _trips.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final t = _trips[i];
                            return Card(
                              clipBehavior: Clip.antiAlias,
                              child: ListTile(
                                onTap: () => _showDetail(t),
                                leading: CircleAvatar(
                                  backgroundColor:
                                      _statusColor(t.status).withValues(alpha: 0.18),
                                  child: Icon(
                                      t.status == 'completed'
                                          ? Icons.check
                                          : t.status == 'cancelled' ||
                                                  t.status == 'expired'
                                              ? Icons.close
                                              : Icons.local_taxi,
                                      color: _statusColor(t.status), size: 20),
                                ),
                                title: Text(
                                    'Viaje ${t.tripId} · ${_statusLabel(t.status)}'),
                                subtitle: Text(
                                    '${_fmtDate(t.requestedAt)} · ${t.vehicleType}'),
                                trailing: Text(
                                  '${(t.totalFare ?? t.precioEstimado ?? 0).toStringAsFixed(2)} ${t.currency}',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: scheme.primary),
                                ),
                              ),
                            );
                          },
                        ),
                ),
    );
  }
}