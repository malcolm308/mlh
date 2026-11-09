import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';

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
      _trips = trips;
      _loading = false;
    } catch (e) {
      if (!mounted) return;
      _error = '$e';
      _loading = false;
    }
    setState(() {});
  }

  Color _statusColor(String status) => switch (status) {
        'completed' => const Color(0xFF1E7A3D),
        'in_progress' => AppColors.ambar,
        'accepted' || 'driver_arrived' => const Color(0xFF1A73E8),
        'requested' => AppColors.ambar,
        'cancelled' || 'expired' => const Color(0xFFD93840),
        _ => AppColors.secundario,
      };

  String _statusLabel(String status) => switch (status) {
        'completed' => 'Completado',
        'in_progress' => 'En curso',
        'accepted' => 'Chofer asignado',
        // Con el paso intermedio del chofer, `driver_arrived` ya no implica
        // que esta fisicamente en tu puerta: significa que empezo a ir por ti.
        'driver_arrived' => 'Chofer en recogida',
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

  /// ISO completo -> `07 nov 2026 · 01:34`: fecha legible, no el codigo
  /// crudo de Mongo que tapaba el historial.
  String _formatDate(String? iso) {
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

  /// Hoja de detalle con vidrio sobre el fondo oscurecido.
  ///
  /// Antes usaba un `showModalBottomSheet` "pelao": el tema global pinta la
  /// baseline transparente para las hojas de vidrio, y esta quedaba con su
  /// contenido flotando EN BLANCO sobre la pantalla, parecia que los datos
  /// "salian transparentes". Ahora siempre envuelve en [GlassSheet].
  void _showDetail(Map<String, dynamic> trip) {
    final status = trip['status']?.toString() ?? '';
    final colorEstado = _statusColor(status);
    final fecha =
        _formatDate(trip['completed_at'] ?? trip['requested_at']);
    final distanciaKm = trip['distance_km'] is num
        ? (trip['distance_km'] as num).toDouble()
        : null;
    final total = (trip['total_fare'] as num?)?.toDouble();
    final moneda = (trip['currency']?.toString().isNotEmpty == true)
        ? trip['currency'].toString()
        : 'CUP';
    final chofer = trip['driver_name']?.toString().trim();
    final vehiculo = '${trip['vehicle_brand'] ?? ''} ${trip['vehicle_model'] ?? ''}'
        .trim();

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
                    child: Text(
                      _statusLabel(status),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.tinta,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: ShapeDecoration(
                      color: colorEstado.withValues(alpha: 0.12),
                      shape: const StadiumBorder(
                        side: BorderSide(color: Colors.transparent),
                      ),
                    ),
                    child: Text(
                      fecha,
                      style: TextStyle(
                        color: colorEstado,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (trip['request_address'] != null &&
                  trip['request_address'].toString().isNotEmpty)
                _detailRow(Icons.location_on_outlined, 'Recogida',
                    trip['request_address']),
              if (trip['dropoff_address'] != null &&
                  trip['dropoff_address'].toString().isNotEmpty)
                _detailRow(Icons.flag_outlined, 'Destino',
                    trip['dropoff_address']),
              if (chofer != null && chofer.isNotEmpty)
                _detailRow(Icons.person_outline_rounded, 'Chofer', chofer),
              if (vehiculo.isNotEmpty)
                _detailRow(Icons.directions_car_outlined, 'Vehículo',
                    '${trip['vehicle_type'] ?? ''} · $vehiculo'),
              if (distanciaKm != null && distanciaKm > 0)
                _detailRow(Icons.straighten, 'Distancia',
                    '${distanciaKm.toStringAsFixed(2)} km'),
              _detailRow(Icons.timer_outlined, 'Duración',
                  _formatDuration(trip['duration_secs'] as int?)),
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
                      '${total?.toStringAsFixed(2) ?? '0.00'} $moneda',
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

  /// Fila etiqueta-valor de la hoja de detalle.
  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              color: AppColors.acentoSuave,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: AppColors.ambar),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: AppColors.secundario,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.tinta,
                    height: 1.3,
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
              : _trips.isEmpty
                  ? ListView(
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
                          'Cuando completes tu primer viaje lo verás aquí.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AppColors.secundario, height: 1.4),
                        ),
                      ],
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _trips.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final trip = _trips[index];
                          final status = trip['status']?.toString() ?? '';
                          final colorEstado = _statusColor(status);
                          return Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => _showDetail(trip),
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
                                        status == 'completed'
                                            ? Icons.check_rounded
                                            : status == 'cancelled' ||
                                                    status == 'expired'
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
                                                  _statusLabel(status),
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
                                                '${(trip['total_fare'] as num?)?.toStringAsFixed(2) ?? '0.00'} '
                                                '${trip['currency'] ?? 'CUP'}',
                                                style: const TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: AppColors.ambar,
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (trip['request_address']
                                                      ?.toString()
                                                      .isNotEmpty ==
                                                  true ||
                                              trip['dropoff_address']
                                                      ?.toString()
                                                      .isNotEmpty ==
                                                  true)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 2),
                                              child: Text(
                                                '${trip['request_address'] ?? ''}'
                                                '${trip['request_address']?.toString().isNotEmpty == true && trip['dropoff_address']?.toString().isNotEmpty == true ? '  →  ' : ''}'
                                                '${trip['dropoff_address'] ?? ''}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: AppColors.secundario,
                                                ),
                                              ),
                                            ),
                                          const SizedBox(height: 2),
                                          Text(
                                            _formatDate(trip['completed_at'] ??
                                                trip['requested_at']),
                                            style: const TextStyle(
                                              fontSize: 11,
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
