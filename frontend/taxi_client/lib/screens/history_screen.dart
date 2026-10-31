import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// Historial de viajes enriquecido con datos del chofer y vehículo.
class HistoryScreen extends StatefulWidget {
  final ApiService api;
  final String clientId;

  const HistoryScreen({
    super.key,
    required this.api,
    required this.clientId,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _trips = [];
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
      final trips = await widget.api.getTripHistory(widget.clientId);
      if (!mounted) return;
      setState(() {
        _trips = trips;
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
        'accepted' => 'Chofer asignado',
        'driver_arrived' => 'Chofer llegó',
        'requested' => 'Solicitado',
        'cancelled' => 'Cancelado',
        'expired' => 'Expirado',
        _ => status,
      };

  String _formatDuration(int? secs) {
    if (secs == null || secs == 0) return '—';
    final mins = secs ~/ 60;
    final remainingSecs = secs % 60;
    if (mins >= 60) {
      final hours = mins ~/ 60;
      final remainingMins = mins % 60;
      return '${hours}h ${remainingMins}m';
    }
    return '${mins}m ${remainingSecs}s';
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  void _showDetail(Map<String, dynamic> trip) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Viaje ${trip['trip_id'] ?? '—'}',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor(trip['status'] ?? '').withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _statusColor(trip['status'] ?? ''), width: 1),
                  ),
                  child: Text(
                    _statusLabel(trip['status'] ?? ''),
                    style: TextStyle(
                      color: _statusColor(trip['status'] ?? ''),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            if (trip['request_address'] != null && trip['request_address'].toString().isNotEmpty)
              _detailRow(Icons.location_on_outlined, 'Origen', trip['request_address']),
            if (trip['dropoff_address'] != null && trip['dropoff_address'].toString().isNotEmpty)
              _detailRow(Icons.flag_outlined, 'Destino', trip['dropoff_address']),
            const SizedBox(height: 8),
            _detailRow(Icons.directions_car, 'Vehículo', '${trip['vehicle_type'] ?? '—'}'),
            if (trip['driver_name'] != null)
              _detailRow(Icons.person, 'Chofer', trip['driver_name']),
            if (trip['vehicle_brand'] != null || trip['vehicle_model'] != null)
              _detailRow(
                Icons.car_rental,
                'Automóvil',
                '${trip['vehicle_brand'] ?? ''} ${trip['vehicle_model'] ?? ''}'.trim(),
              ),
            const Divider(height: 16),
            _detailRow(Icons.calendar_today, 'Fecha', _formatDate(trip['completed_at'] ?? trip['requested_at'])),
            if (trip['distance_km'] != null)
              _detailRow(Icons.straighten, 'Distancia', '${(trip['distance_km'] as num).toStringAsFixed(2)} km'),
            if (trip['duration_secs'] != null)
              _detailRow(Icons.timer, 'Duración', _formatDuration(trip['duration_secs'])),
            const Divider(height: 16),
            _detailRow(
              Icons.attach_money,
              'Total',
              '${(trip['total_fare'] as num?)?.toStringAsFixed(2) ?? '0.00'} ${trip['currency'] ?? 'CUP'}',
              bold: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey[600]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi historial'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.red),
                      const SizedBox(height: 16),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _load, child: const Text('Reintentar')),
                    ],
                  ),
                )
              : _trips.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.receipt_long, size: 64, color: Colors.grey[400]),
                          const SizedBox(height: 16),
                          Text(
                            'Aún no tienes viajes',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _trips.length,
                        itemBuilder: (context, index) {
                          final trip = _trips[index];
                          final status = trip['status']?.toString() ?? '';
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              onTap: () => _showDetail(trip),
                              leading: CircleAvatar(
                                backgroundColor: _statusColor(status).withValues(alpha: 0.18),
                                child: Icon(
                                  status == 'completed'
                                      ? Icons.check
                                      : status == 'cancelled' || status == 'expired'
                                          ? Icons.close
                                          : Icons.local_taxi,
                                  color: _statusColor(status),
                                  size: 20,
                                ),
                              ),
                              title: Text(
                                trip['request_address']?.toString().isNotEmpty == true
                                    ? trip['request_address']!
                                    : 'Viaje ${trip['trip_id']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (trip['dropoff_address']?.toString().isNotEmpty == true)
                                    Text(
                                      trip['dropoff_address']!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Text(
                                        _formatDate(trip['completed_at'] ?? trip['requested_at']),
                                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                      ),
                                      const Spacer(),
                                      Text(
                                        '${(trip['total_fare'] as num?)?.toStringAsFixed(2) ?? '0.00'} ${trip['currency'] ?? 'CUP'}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context).colorScheme.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              trailing: Icon(
                                Icons.chevron_right,
                                color: Colors.grey[400],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
