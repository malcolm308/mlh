import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';

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
        'completed' => const Color(0xFF1E7A3D),
        'in_progress' => AppColors.ambar,
        'accepted' || 'driver_on_the_way' || 'driver_arrived' =>
          const Color(0xFF1A73E8),
        'requested' => AppColors.ambar,
        'cancelled' || 'expired' => const Color(0xFFD93840),
        _ => AppColors.secundario,
      };

  String _statusLabel(String status) => switch (status) {
        'completed' => 'Completado',
        'in_progress' => 'En curso',
        'accepted' => 'Aceptado',
        'driver_on_the_way' => 'En camino',
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
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: GlassSheet(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(_statusLabel(t.status),
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.tinta)),
                  ),
                  _chip(_statusLabel(t.status), _statusColor(t.status)),
                ],
              ),
              const SizedBox(height: 8),
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
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8D6),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFF3E4A8)),
                ),
                child: Row(
                  children: [
                    const Text(
                      'TOTAL',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                        color: AppColors.ambar,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(t.totalFare ?? t.precioEstimado ?? 0).toStringAsFixed(2)} ${t.currency}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.tinta,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cerrar'),
              ),
            ],
          ),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi historial'),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const SizedBox(height: 30),
                    const Icon(Icons.error_outline,
                        size: 52, color: AppColors.error),
                    const SizedBox(height: 12),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.secundario)),
                    const SizedBox(height: 16),
                    Center(
                      child: OutlinedButton(
                        onPressed: _load,
                        child: const Text('Reintentar'),
                      ),
                    ),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _trips.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(24),
                          children: const [
                            SizedBox(height: 36),
                            Icon(Icons.receipt_long,
                                size: 56, color: AppColors.secundario),
                            SizedBox(height: 12),
                            Text(
                              'Aún no tienes viajes',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.tinta,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Aquí aparecerán los viajes que completes.',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: AppColors.secundario, height: 1.4),
                            ),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _trips.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final t = _trips[i];
                            final colorEstado = _statusColor(t.status);
                            return Material(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => _showDetail(t),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: AppColors.borde),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: colorEstado
                                              .withValues(alpha: 0.12),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          t.status == 'completed'
                                              ? Icons.check_rounded
                                              : t.status == 'cancelled' ||
                                                      t.status == 'expired'
                                                  ? Icons.close_rounded
                                                  : Icons.local_taxi_rounded,
                                          color: colorEstado,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    _statusLabel(t.status),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight: FontWeight.w700,
                                                      color: AppColors.tinta,
                                                    ),
                                                  ),
                                                ),
                                                Text(
                                                  '${(t.totalFare ?? t.precioEstimado ?? 0).toStringAsFixed(2)} ${t.currency}',
                                                  style: const TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.w800,
                                                    color: AppColors.ambar,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '${_fmtDate(t.requestedAt)} · ${t.vehicleType}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: AppColors.secundario,
                                              ),
                                            ),
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
                          },
                        ),
                ),
    );
  }
}