import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../widgets/client_map_view.dart';

class TripScreen extends StatefulWidget {
  final ApiService api;
  final String clientId;
  final String tripId;
  final double initialEstimate;

  const TripScreen({
    super.key,
    required this.api,
    required this.clientId,
    required this.tripId,
    this.initialEstimate = 0,
  });

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> {
  final ClientMapController _mapController = ClientMapController();
  ClientTrip? _trip;
  bool _cancelling = false;
  String? _error;
  Timer? _poll;
  List<LatLng> _route = [];
  LatLng? _driverPos;

  /// `true` cuando el mapa sigue al vehiculo.
  ///
  /// En cuanto el pasajero toca el mapa se pone en `false` y la camara pasa a
  /// suya: nadie quiere que el mapa le salte mientras esta mirando otra cosa.
  bool _siguiendo = true;

  /// Zoom de la ultima decision automatica.
  ///
  /// Se guarda para poder distinguir "el vehiculo se acerco y hay que acercar"
  /// de "el usuario ya habia movido el mapa", en cuyo caso no se toca nada.
  double? _zoomAuto;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final t = await widget.api.getTrip(widget.tripId);
      if (!mounted) return;
      setState(() {
        _trip = t;
        _error = null;
      });
      if (t.status == 'completed' || t.status == 'cancelled') {
        _poll?.cancel();
      }
      if (t.driverId != null && _inActive(t.status)) {
        await _loadRoute(t.tripId);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  bool _inActive(String status) =>
      status == 'accepted' ||
      status == 'driver_arrived' ||
      status == 'in_progress';

  Future<void> _loadRoute(String tripId) async {
    try {
      final pts = await widget.api.getTripRoute(tripId);
      if (!mounted) return;
      final antes = _driverPos;
      setState(() {
        _route = pts.map((p) => p.point).toList();
        if (pts.isNotEmpty) _driverPos = pts.last.point;
      });
      _seguirVehiculo(antes);
    } catch (_) {}
  }

  /// Encuadre automatico del cliente.
  ///
  /// Dos momentos distintos, porque el pasajero necesita cosas distintas:
  ///
  ///  1. Al aparecer el chofer, o el punto de recogida: `fitBounds` con los
  ///     tres puntos (origen, destino y vehiculo). Ahi encaja el trayecto
  ///     entero, que es lo que responde a "de donde salgo y a donde voy".
  ///  2. En cada refresh posterior: solo seguir al vehiculo, con el zoom que
  ///     toque por lo cerca que este. Reencuadrar el trayecto entero cada 3 s
  ///     haria que el mapa le temblase al pasajero.
  ///
  /// Cuando el pasajero ha tocado el mapa no se hace nada: manda el usuario.
  void _seguirVehiculo(LatLng? antes) {
    if (!_siguiendo) return;
    final vehiculo = _driverPos;
    final t = _trip;
    if (vehiculo == null || t == null) return;

    // El primer fix del vehiculo (o del viaje) reencuadra el conjunto.
    // `contains` es asincrono porque consulta la region visible al motor; se
    // resuelve sin bloquear el timer, y mientras tanto `_siguiendo` ya se ha
    // comprobado arriba.
    if (antes == null) {
      _encuadrarTrayecto();
    } else {
      unawaited(_reencuadrarSiElVehiculoSalio(vehiculo));
    }

    if (_trip?.status != 'in_progress') return;

    // Distancia al objetivo: destino durante el viaje, punto de partida si el
    // chofer aun esta yendo a buscar al pasajero.
    final objetivo = _objetivoDelPasajero();
    if (objetivo == null) return;

    final distancia = Distance().as(LengthUnit.Meter, vehiculo, objetivo);
    final zoom = distancia <= ApiConfig.distanciaZoomCerca
        ? ApiConfig.zoomVehiculoCerca
        : ApiConfig.zoomPorDistancia(distancia);

    // Solo se mueve si el nivel cambia de verdad: llamar a `move` en cada
    // refresh (cada 3 s) aun con el mismo zoom produce un salto visible.
    if (_zoomAuto == null || (_zoomAuto! - zoom).abs() > 0.01) {
      _zoomAuto = zoom;
      _mapController.move(vehiculo, zoom);
    } else if (_mapController.center != vehiculo) {
      _mapController.move(vehiculo, _mapController.zoom);
    }
  }

  /// Reencuadra el trayecto solo si el vehiculo se ha salido del encuadre.
  ///
  /// Se hace aparte porque con MapLibre la region visible se pide al motor de
  /// forma asincrona (`getVisibleRegion`). Si mientras llega la respuesta el
  /// pasajero ha tocado el mapa, se abandona: manda el usuario.
  Future<void> _reencuadrarSiElVehiculoSalio(LatLng vehiculo) async {
    if (!_siguiendo) return;
    if (await _mapController.contains(vehiculo)) return;
    if (!_siguiendo) return;
    _encuadrarTrayecto();
  }

  /// El punto que importa ahora mismo: destino si el viaje va en curso, y el
  /// lugar de partida si el chofer aun esta de camino.
  LatLng? _objetivoDelPasajero() {
    final t = _trip;
    if (t == null) return null;
    return t.status == 'in_progress' ? t.dropoffLocation : t.requestLocation;
  }

  /// Encuadra origen + destino + vehiculo a la vez.
  ///
  /// `padding` pequeno a proposito: con los tres puntos cerca no hace falta
  /// dejar aire, y con uno lejos se pierde precision. `maxZoom` evita que un
  /// trayecto muy corto se amplie hasta perder el contexto.
  void _encuadrarTrayecto() {
    final t = _trip;
    final vehiculo = _driverPos;
    if (t == null || vehiculo == null) return;

    final puntos = <LatLng>[vehiculo];
    if (t.requestLocation != null) puntos.add(t.requestLocation!);
    if (t.dropoffLocation != null) puntos.add(t.dropoffLocation!);
    if (puntos.length < 2) return;

    _mapController.fitPoints(
      puntos,
      padding: const EdgeInsets.fromLTRB(40, 80, 40, 140),
      maxZoom: ApiConfig.defaultZoom,
    );
    _zoomAuto = _mapController.zoom;
  }

  /// Vuelve a seguir al vehiculo tras un toque del pasajero.
  void _recentrarEnVehiculo() {
    setState(() => _siguiendo = true);
    _encuadrarTrayecto();
    _zoomAuto = null;
    _seguirVehiculo(_driverPos);
  }

  Future<void> _cancel() async {
    // Confirmación para evitar cancelación accidental
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Cancelar este viaje?'),
        content: const Text('Esta acción no se puede deshacer.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No, continuar viaje'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sí, cancelar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;

    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      await widget.api.cancelTrip(widget.tripId);
      if (!mounted) return;
      _poll?.cancel();
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancelling = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  int get _stepIndex {
    final status = _trip?.status ?? 'requested';
    switch (status) {
      case 'accepted':
        return 1;
      case 'driver_arrived':
        return 2;
      case 'in_progress':
        return 3;
      case 'completed':
        return 4;
      default:
        return 0;
    }
  }

  String get _stepLabel {
    final status = _trip?.status ?? 'requested';
    switch (status) {
      case 'requested':
        return 'Buscando chofer...';
      case 'accepted':
        return 'Chofer asignado, en camino';
      case 'driver_arrived':
        return 'El chofer llegó';
      case 'in_progress':
        return 'Viaje en curso';
      case 'completed':
        return 'Viaje completado';
      case 'cancelled':
        return 'Viaje cancelado';
      case 'expired':
        return 'Viaje expirado';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _trip;
    return Scaffold(
      appBar: AppBar(
        title: Text('Viaje ${t?.tripId.split('-').first ?? ''}'),
        automaticallyImplyLeading: _stepIndex == 0 || _stepIndex == 4,
        leading: (_stepIndex == 0 || _stepIndex == 4)
            ? null
            : IconButton(
                tooltip: 'Salir (el viaje continúa)',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
      ),
      body: t == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      ClientMapView(
                        controller: _mapController,
                        initialCenter:
                            t.requestLocation ?? ApiConfig.defaultClientLocation,
                        initialZoom: ApiConfig.defaultZoom,
                        minZoom: ApiConfig.minZoom.toDouble(),
                        maxZoom: ApiConfig.maxZoom.toDouble(),
                        route: _route,
                        straightLine: t.requestLocation != null &&
                                t.dropoffLocation != null
                            ? [t.requestLocation!, t.dropoffLocation!]
                            : const [],
                        // El cliente ve la escena en plano, con el norte arriba:
                        // no rota ni inclina.
                        routeColor: const Color(0xFF007AFF),
                        routeWidth: 4,
                        pins: [
                          if (_driverPos != null)
                            MapPin(
                              _driverPos!,
                              color: const Color(0xFF007AFF),
                              // Reducido un 25 % (era 19): tapaba la calle de
                              // al lado y no dejaba ver el trayecto util.
                              radius: 14,
                            ),
                          if (t.requestLocation != null)
                            MapPin(
                              t.requestLocation!,
                              color: Colors.green,
                              radius: 19,
                            ),
                          if (t.dropoffLocation != null)
                            MapPin(
                              t.dropoffLocation!,
                              color: Colors.red,
                              radius: 19,
                            ),
                        ],
                        // Al tocar o arrastrar el mapa deja de seguir al
                        // vehiculo, como en cualquier navegador.
                        onTap: (_) => setState(() => _siguiendo = false),
                        onGesture: () {
                          if (_siguiendo) setState(() => _siguiendo = false);
                        },
                      ),
                      if (_stepIndex < 4)
                        Positioned(
                          top: 12,
                          left: 12,
                          right: 12,
                          child: _statusBanner(),
                        ),
                      // Boton de recentrado del pasajero: mismo criterio que
                      // el chofer, pero sin rotacion ni tilt.
                      if (_siguiendo)
                        const SizedBox.shrink()
                      else
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: FloatingActionButton.small(
                            heroTag: 'recentrar',
                            tooltip: 'Seguir al vehiculo',
                            onPressed: _recentrarEnVehiculo,
                            child: const Icon(Icons.my_location),
                          ),
                        ),
                    ],
                  ),
                ),
                _buildDetailsPanel(),
              ],
            ),
    );
  }

  Widget _statusBanner() {
    final scheme = Theme.of(context).colorScheme;
    final isError = _stepIndex == 4
        ? false
        : (_trip?.status == 'cancelled' || _trip?.status == 'expired');
    final color = isError
        ? scheme.error
        : (_stepIndex == 4 ? Colors.green.shade700 : scheme.primaryContainer);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(12),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              isError
                  ? Icons.cancel
                  : (_stepIndex == 4 ? Icons.check_circle : Icons.local_taxi),
              color: isError ? scheme.onError : Colors.white,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _stepLabel,
                style: TextStyle(
                  color: isError ? scheme.onError : Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsPanel() {
    final t = _trip!;
    final scheme = Theme.of(context).colorScheme;
    final steps = ['Solicitado', 'Chofer', 'Recogida', 'En curso', 'Completado'];
    final cancelled = t.status == 'cancelled' || t.status == 'expired';

    return Material(
      color: scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 44,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: steps.length,
                  itemBuilder: (ctx, i) {
                    final active = i <= _stepIndex && !cancelled;
                    final current = i == _stepIndex && !cancelled;
                    return Row(
                      children: [
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor: current
                                  ? scheme.primary
                                  : (active
                                      ? Colors.green.shade600
                                      : scheme.surfaceContainerHighest),
                              child: current
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white))
                                  : Icon(
                                      active
                                          ? Icons.check
                                          : Icons.circle_outlined,
                                      size: 14,
                                      color: active
                                          ? Colors.white
                                          : scheme.onSurfaceVariant,
                                    ),
                            ),
                            const SizedBox(height: 4),
                            Text(steps[i],
                                style: TextStyle(
                                    fontSize: 10,
                                    color: active
                                        ? scheme.onSurface
                                        : scheme.onSurfaceVariant)),
                          ],
                        ),
                        if (i < steps.length - 1)
                          SizedBox(
                            width: 26,
                            child: Divider(
                                color: active ? Colors.green : scheme.outlineVariant),
                          ),
                      ],
                    );
                  },
                ),
              ),
              const Divider(),
              if (t.driverId != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.person_pin_circle),
                  title: const Text('Chofer asignado'),
                  subtitle: Text(t.driverId!),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.route),
                title: Text(
                    '${t.vehicleType} · ${t.currency} · ${t.requestedAt ?? ''}'),
                subtitle: Text(
                    'Precio estimado: ${t.precioEstimado?.toStringAsFixed(2) ?? '---'} CUP'),
              ),
              if (t.status == 'completed') _buildSummary(t),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!,
                      style: TextStyle(color: scheme.error, fontSize: 12)),
                ),
              if (!cancelled && _stepIndex < 4)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _cancelling ? null : _cancel,
                    icon: _cancelling
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.close),
                    label: const Text('Cancelar viaje'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                )
              else if (_stepIndex == 4 || cancelled)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.check),
                    label: const Text('Listo'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(44)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummary(ClientTrip t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('Detalles del viaje',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        _row('Distancia', '${t.distanciaKm?.toStringAsFixed(2) ?? '-'} km'),
        _row('Base', '${t.baseFare?.toStringAsFixed(2) ?? '-'} CUP'),
        _row('Distancia', '${t.distanceFare?.toStringAsFixed(2) ?? '-'} CUP'),
        _row('Tiempo', '${t.timeFare?.toStringAsFixed(2) ?? '-'} CUP'),
        // El pasajero solo ve el precio final. La comision es interna y se
        // descuenta del Fondo del chofer, nunca del precio del viaje.
        const Divider(height: 12),
        _row('TOTAL', '${t.totalFare?.toStringAsFixed(2) ?? '-'} CUP',
            bold: true),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
            Text(value,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      );
}