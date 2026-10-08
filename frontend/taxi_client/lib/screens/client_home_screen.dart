import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../models/tariff.dart';
import '../services/address_service.dart';
import '../services/api_service.dart';
import '../services/geocode_service.dart';
import '../services/location_service.dart';
import '../services/osrm_service.dart';
import '../widgets/client_map_view.dart';
import 'history_screen.dart';
import 'trip_screen.dart';

class ClientHomeScreen extends StatefulWidget {
  final ApiService api;
  final ClientProfile profile;
  final String clientId;

  const ClientHomeScreen({
    super.key,
    required this.api,
    required this.profile,
    required this.clientId,
  });

  @override
  State<ClientHomeScreen> createState() => _ClientHomeScreenState();
}

enum _PinMode { pickup, dropoff }

class _ClientHomeScreenState extends State<ClientHomeScreen> {
  final ClientMapController _mapController = ClientMapController();

  LatLng _myLoc = ApiConfig.defaultClientLocation;
  LatLng? _pickup;
  LatLng? _dropoff;
  _PinMode _pinMode = _PinMode.pickup;
  String _vehicleType = '';
  bool _loading = false;
  String? _error;
  List<LatLng> _route = [];
  double? _routeKm;
  double? _routeMin;
  bool _routing = false;
  int _routeReq = 0;
  double? _backendFare;
  bool _estFareBusy = false;
  bool _estFareError = false;
  int _estReq = 0;
  String? _pickupAddr;
  String? _dropoffAddr;
  final TextEditingController _searchController = TextEditingController();
  final Map<String, String> _reverseCache = {};
  List<GeoPlace> _suggestions = const [];
  bool _searching = false;
  Timer? _searchDebounce;

  /// Tarifas del backend (GET /api/tariffs). Sin datos, el dropdown queda
  /// deshabilitado para no ofrecer un tipo de vehículo inexistente.
  List<Tariff> _tarifas = const [];
  bool _tarifasCargando = true;
  bool _tarifasError = false;

  /// Estado del GPS del dispositivo.
  LocationPermissionState? _gpsState;
  StreamSubscription<LatLng>? _gpsSub;

  /// El pasajero movio el pin o eligio un lugar: el GPS ya no pisa el
  /// punto de recogida hasta que pulse "mi ubicacion".
  bool _pickupTouched = false;

  @override
  void initState() {
    super.initState();
    _pickup = _myLoc;
    _resolveDefaultAddress();
    _initGps();
    _loadTarifas();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ---------------- GPS ----------------

  /// Pide permiso y usa la posicion real del pasajero como punto de recogida
  /// inicial, manteniendola actualizada mientras se mueve.
  Future<void> _initGps() async {
    final state = await LocationService.ensurePermission();
    if (!mounted) return;
    if (state != LocationPermissionState.granted) {
      setState(() => _gpsState = state);
      return;
    }

    final last = await LocationService.lastKnown();
    if (last != null && mounted) _applyGpsPosition(last, moveMap: true);

    final fix = await LocationService.current();
    if (fix != null && mounted) _applyGpsPosition(fix, moveMap: true);
    if (mounted) setState(() => _gpsState = LocationPermissionState.granted);

    _gpsSub?.cancel();
    _gpsSub = LocationService.watch().listen((p) {
      if (!mounted) return;
      debugPrint('[GPS] pasajero en ${p.latitude},${p.longitude}');
      _applyGpsPosition(p, moveMap: false);
    });
  }

  void _applyGpsPosition(LatLng p, {required bool moveMap}) {
    final wasDefault = _samePoint(_myLoc, ApiConfig.defaultClientLocation);
    setState(() {
      _gpsState = LocationPermissionState.granted;
      _myLoc = p;
      // El punto de recogida sigue al GPS solo si el pasajero no lo movio a
      // mano ni eligio otro lugar por busqueda.
      if (!_pickupTouched && (wasDefault || _pickup == null)) {
        _pickup = p;
        _pickupAddr = null;
      }
    });
    if (moveMap) _mapController.move(p, 15);
    if (_pickup != null) _loadRoutePreview();
  }

  /// Vuelve a pedir el permiso y recentra en la posicion real.
  Future<void> _enableGps() async {
    final state = await LocationService.ensurePermission();
    if (!mounted) return;
    setState(() {
      _gpsState = state;
      if (state == LocationPermissionState.granted) _pickupTouched = false;
    });
    if (state == LocationPermissionState.granted) {
      final p = await LocationService.current();
      if (p != null && mounted) _applyGpsPosition(p, moveMap: true);
    }
  }

  /// Usa la ubicacion actual como punto de recogida.
  Future<void> _useMyLocation() async {
    final p = await LocationService.current() ?? await LocationService.lastKnown();
    if (p == null || !mounted) {
      _showError('No se pudo obtener la ubicacion. Revisa el GPS del telefono.');
      return;
    }
    setState(() => _pickupTouched = false);
    _applyGpsPosition(p, moveMap: true);
    _reverseToAddress(p);
  }

  bool _samePoint(LatLng a, LatLng b) =>
      (a.latitude - b.latitude).abs() < 1e-9 &&
      (a.longitude - b.longitude).abs() < 1e-9;

  Future<void> _resolveDefaultAddress() async {
    final addr = await AddressService.de(_myLoc);
    if (!mounted || _pickup == null || !_samePoint(_pickup!, _myLoc)) return;
    setState(() => _pickupAddr = addr.vacia ? null : addr.texto);
  }

  void _placePin(LatLng p) {
    setState(() {
      if (_pinMode == _PinMode.pickup) {
        _pickup = p;
        _myLoc = p;
        _pickupAddr = null;
        _pickupTouched = true;
      } else {
        _dropoff = p;
        _dropoffAddr = null;
      }
    });
    _loadRoutePreview();
    _reverseToAddress(p);
  }

  Future<void> _reverseToAddress(LatLng p) async {
    final key =
        '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}';
    final cached = _reverseCache[key];
    if (cached != null) {
      _applyReverseAddress(p, cached);
      return;
    }
    final dir = await AddressService.de(p);
    final addr = dir.vacia ? null : dir.texto;
    if (addr != null) _reverseCache[key] = addr;
    if (!mounted) return;
    _applyReverseAddress(p, addr);
  }

  void _applyReverseAddress(LatLng p, String? addr) {
    if (_pickup != null && _samePoint(p, _pickup!)) {
      if (_pickupAddr != addr) setState(() => _pickupAddr = addr);
    } else if (_dropoff != null && _samePoint(p, _dropoff!)) {
      if (_dropoffAddr != addr) setState(() => _dropoffAddr = addr);
    }
  }

  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    _searchController.text = text;
    final trimmed = text.trim();
    if (trimmed.length < 3) {
      setState(() {
        _suggestions = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 450), () async {
      final results = await GeocodeService.search(trimmed, near: _myLoc);
      if (!mounted || _searchController.text.trim() != trimmed) return;
      setState(() {
        _suggestions = results;
        _searching = false;
      });
    });
  }

  void _onSuggestionSelected(GeoPlace place) {
    _searchDebounce?.cancel();
    _searchController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _suggestions = const [];
      _searching = false;
      if (_pinMode == _PinMode.pickup) {
        _pickup = place.point;
        _myLoc = place.point;
        _pickupAddr = place.shortLabel ?? place.displayName;
        _pinMode = _PinMode.dropoff;
      } else {
        _dropoff = place.point;
        _dropoffAddr = place.shortLabel ?? place.displayName;
      }
    });
    _mapController.move(place.point, 15);
    _loadRoutePreview();
  }

  Future<void> _loadRoutePreview() async {
    final pickup = _pickup;
    final dropoff = _dropoff;
    if (pickup == null || dropoff == null || pickup == dropoff) {
      if (!mounted) return;
      setState(() {
        _route = const [];
        _routeKm = null;
        _routeMin = null;
        _routing = false;
      });
      return;
    }
    final req = ++_routeReq;
    setState(() => _routing = true);
    _loadEstimate();
    final r = await OsrmService.route(pickup, dropoff);
    if (!mounted || req != _routeReq) return;
    setState(() {
      _routing = false;
      if (r != null && r.points.length >= 2) {
        _route = r.points;
        _routeKm = r.distanceKm;
        _routeMin = r.durationMinutes;
      } else {
        _route = const [];
        _routeKm = null;
        _routeMin = null;
      }
    });
  }

  double? get _estimatedFare => _backendFare;

  Future<void> _loadEstimate() async {
    final pickup = _pickup;
    final dropoff = _dropoff;
    if (pickup == null || dropoff == null || pickup == dropoff) return;
    if (_vehicleType.isEmpty) return;
    final req = ++_estReq;
    setState(() => _estFareBusy = true);
    try {
      final res = await widget.api.estimateTrip(
        requestLat: pickup.latitude,
        requestLng: pickup.longitude,
        dropoffLat: dropoff.latitude,
        dropoffLng: dropoff.longitude,
        vehicleType: _vehicleType,
      );
      if (!mounted || req != _estReq) return;
      setState(() {
        _estFareBusy = false;
        _estFareError = false;
        _backendFare = (res['precio_estimado'] ?? 0).toDouble();
      });
    } catch (_) {
      if (!mounted || req != _estReq) return;
      setState(() {
        _estFareBusy = false;
        _estFareError = true;
      });
    }
  }

  Future<void> _requestTrip() async {
    final pickup = _pickup;
    final dropoff = _dropoff;
    if (pickup == null || dropoff == null) {
      _showError('Define recogida y destino en el mapa');
      return;
    }
    if (_vehicleType.isEmpty) {
      _showError('No se pudieron cargar las tarifas');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.createTrip(
        clientId: widget.clientId,
        requestLat: pickup.latitude,
        requestLng: pickup.longitude,
        dropoffLat: dropoff.latitude,
        dropoffLng: dropoff.longitude,
        vehicleType: _vehicleType,
        requestAddress: _pickupAddr,
        dropoffAddress: _dropoffAddr,
      );
      final tripId = (res['trip_id'] ?? '').toString();
      if (tripId.isEmpty) throw ApiException('No se recibió el trip_id');
      if (!mounted) return;
      setState(() => _loading = false);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TripScreen(
          api: widget.api,
          clientId: widget.clientId,
          tripId: tripId,
          initialEstimate: (res['precio_estimado'] ?? 0).toDouble(),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('$e');
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('client_token');
    await prefs.remove('client_id');
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Theme.of(context).colorScheme.error,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bothSet = _pickup != null && _dropoff != null;

    return Scaffold(
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          ClientMapView(
            controller: _mapController,
            initialCenter: _myLoc,
            initialZoom: ApiConfig.defaultZoom,
            minZoom: ApiConfig.minZoom.toDouble(),
            maxZoom: ApiConfig.maxZoom.toDouble(),
            route: _route,
            straightLine: bothSet ? [_pickup!, _dropoff!] : const [],
            routeColor: const Color(0xFF007AFF),
            routeHaloColor: const Color(0xE6FFFFFF),
            routeWidth: 4,
            straightColor: Colors.black45,
            pins: [
              // El halo y el punto azul van en un solo pin: antes eran dos
              // marcadores superpuestos y aqui basta con el radio del halo.
              MapPin(
                _myLoc,
                color: const Color(0xFF007AFF),
                radius: 20,
                haloRadius: 35,
                haloColor: const Color(0x2E007AFF),
              ),
              if (_pickup != null)
                MapPin(_pickup!, color: Colors.green, radius: 20),
              if (_dropoff != null)
                MapPin(_dropoff!, color: Colors.red, radius: 20),
            ],
            onTap: _placePin,
          ),
          if (_error != null)
            Positioned(
              top: 64,
              left: 8,
              right: 8,
              child: Material(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: () => setState(() => _error = null),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_error!,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 8,
            left: 8,
            child: _circularButton(
              Icons.menu,
              () => Scaffold.of(context).openDrawer(),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: _circularButton(
              _gpsState == LocationPermissionState.granted
                  ? Icons.my_location
                  : Icons.location_disabled,
              () {
                // Recentrar en la posicion real y usarla como punto de
                // recogida; si falta el permiso, se vuelve a pedir.
                if (_gpsState == LocationPermissionState.granted) {
                  _useMyLocation();
                } else {
                  _enableGps();
                }
              },
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _buildBottomPanel(),
          ),
        ],
      ),
    );
  }

  Widget _circularButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 3,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 22, color: const Color(0xFF333333)),
        ),
      ),
    );
  }

  /// Clave de SharedPreferences donde se guarda la última lista de tarifas.
  static const String _tarifasCacheKey = 'cache_tarifas';

  /// Carga las tarifas desde el backend y las cachea en disco.
  ///
  /// Si no hay red, usa la última lista cacheada para que el dropdown nunca se
  /// quede vacío (y nunca ofrezca un tipo de vehículo inexistente).
  Future<void> _loadTarifas() async {
    setState(() {
      _tarifasCargando = true;
      _tarifasError = false;
    });
    try {
      final tarifas = await widget.api.getTariffs();
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _tarifasCacheKey,
        jsonEncode(tarifas.map((t) => t.toJson()).toList()),
      );
      setState(() {
        _tarifas = tarifas;
        _tarifasCargando = false;
        _vehicleType = _vehicleTypeMarcado(tarifas);
      });
      _loadEstimate();
    } catch (_) {
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_tarifasCacheKey);
      List<Tariff>? tarifas;
      if (cached != null) {
        try {
          final list = (jsonDecode(cached) as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(Tariff.fromJson)
              .toList();
          if (list.isNotEmpty) tarifas = list;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        if (tarifas != null) {
          _tarifas = tarifas;
          _vehicleType = _vehicleTypeMarcado(tarifas);
        } else {
          _tarifasError = true;
        }
        _tarifasCargando = false;
      });
    }
  }

  /// Devuelve el tipo marcado si sigue existiendo en el backend; si no, el
  /// primero de la lista (o '' si la lista está vacía).
  String _vehicleTypeMarcado(List<Tariff> tarifas) {
    if (tarifas.isEmpty) return '';
    final conocidos = tarifas.map((t) => t.vehicleType).toSet();
    return conocidos.contains(_vehicleType)
        ? _vehicleType
        : tarifas.first.vehicleType;
  }

  /// Tipos de vehículo disponibles, tal y como los publica el backend.
  List<String> get _vehicleTypes =>
      _tarifas.map((t) => t.vehicleType).toList();

  Widget _buildRouteStats(ColorScheme scheme) {
    final fare = _estimatedFare;
    return Row(
      children: [
        Expanded(
          child: _statTile(
            scheme,
            Icons.route_outlined,
            'Distancia',
            _routing ? '...' : '${_routeKm?.toStringAsFixed(1) ?? '--'} km',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _statTile(
            scheme,
            Icons.timer_outlined,
            'Tiempo',
            _routing ? '...' : '${_routeMin?.ceil() ?? '--'} min',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _statTile(
            scheme,
            Icons.payments_outlined,
            'Tarifa est.',
            _estFareBusy
                ? '...'
                : (fare != null
                    ? '${fare.toStringAsFixed(0)} CUP'
                    : (_estFareError ? 'Error' : '--')),
          ),
        ),
      ],
    );
  }

  Widget _statTile(
      ColorScheme scheme, IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF007AFF)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Color(0xFF333333),
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Color(0xFF888888)),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomPanel() {
    final scheme = Theme.of(context).colorScheme;
    final bothSet = _pickup != null && _dropoff != null;

    return Material(
      color: Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      elevation: 12,
      shadowColor: Colors.black26,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFD0D0D0),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Hola, ${widget.profile.fullName.split(' ').first}",
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF888888))),
                          const SizedBox(height: 2),
                          const Text('¿Dónde quieres ir?',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF333333))),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<_PinMode>(
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: _PinMode.pickup,
                            label: Text('Recogida'),
                            icon: Icon(Icons.arrow_upward),
                          ),
                          ButtonSegment(
                            value: _PinMode.dropoff,
                            label: Text('Destino'),
                            icon: Icon(Icons.flag),
                          ),
                        ],
                        selected: {_pinMode},
                        onSelectionChanged: (s) =>
                            setState(() => _pinMode = s.first),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      color: const Color(0xFF007AFF),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
onTap: () => setState(() {
  _pickup = _myLoc;
  _pinMode = _PinMode.dropoff;
  _pickupAddr = null;
  _reverseToAddress(_myLoc);
  _loadRoutePreview();
}),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(Icons.near_me,
                              color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: _pinMode == _PinMode.pickup
                        ? 'Buscar la calle de recogida...'
                        : 'Buscar la calle del destino...',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : (_searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchDebounce?.cancel();
                                  _searchController.clear();
                                  setState(() {
                                    _suggestions = const [];
                                    _searching = false;
                                  });
                                },
                              )
                            : null),
                  ),
                ),
                if (_suggestions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Material(
                    elevation: 2,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < _suggestions.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.place_outlined,
                                size: 18, color: Color(0xFF007AFF)),
                            title: Text(
                              _suggestions[i].shortLabel ??
                                  _suggestions[i].displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            onTap: () => _onSuggestionSelected(_suggestions[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  _pinMode == _PinMode.pickup
                      ? 'Toca el mapa o busca una calle para la RECOGIDA'
                      : 'Toca el mapa o busca una calle para el DESTINO',
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: scheme.primary),
                ),
                if (_pickupAddr != null || _dropoffAddr != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_pickupAddr != null)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.arrow_upward,
                                  size: 14, color: Colors.green),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(_pickupAddr!,
                                    style: const TextStyle(
                                        fontSize: 12, color: Color(0xFF1F2937))),
                              ),
                            ],
                          ),
                        if (_pickupAddr != null && _dropoffAddr != null)
                          const SizedBox(height: 2),
                        if (_dropoffAddr != null)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.flag,
                                  size: 14,
                                  color: Color(
                                      0xFFB91C1C)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(_dropoffAddr!,
                                    style: const TextStyle(
                                        fontSize: 12, color: Color(0xFF1F2937))),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
                if (bothSet) ...[
                  const SizedBox(height: 12),
                  _buildRouteStats(scheme),
                ],
                const SizedBox(height: 12),
                if (_tarifasCargando)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_tarifasError)
                  Row(
                    children: [
                      const Icon(Icons.error_outline,
                          size: 18, color: Color(0xFFB91C1C)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('No se pudieron cargar las tarifas.',
                            style: TextStyle(
                                fontSize: 13, color: const Color(0xFFB91C1C))),
                      ),
                      TextButton(
                        onPressed: _loadTarifas,
                        child: const Text('Reintentar'),
                      ),
                    ],
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: _vehicleType,
                    decoration: const InputDecoration(
                      labelText: 'Tipo de vehículo',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _vehicleTypes
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null && v != _vehicleType) {
                        setState(() => _vehicleType = v);
                        _loadEstimate();
                      }
                    },
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: (!bothSet || _loading) ? null : _requestTrip,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.local_taxi),
                  label: Text(_loading
                      ? 'Solicitando...'
                      : (bothSet ? 'Solicitar viaje' : 'Define el destino')),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF007AFF),
                    const Color(0xFF4DABFF),
                  ],
                ),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.white,
                    child: Icon(Icons.person, color: Color(0xFF007AFF), size: 30),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.profile.fullName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(widget.profile.email,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.history, color: Color(0xFF333333)),
              title: const Text('Historial de viajes'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => HistoryScreen(
                    api: widget.api,
                    clientId: widget.clientId,
                    fullName: widget.profile.fullName,
                  ),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline, color: Color(0xFF333333)),
              title: const Text('Servidor'),
              subtitle: Text(ApiConfig.baseUrl,
                  style: const TextStyle(color: Color(0xFF888888))),
              onTap: () => Navigator.of(context).pop(),
            ),
            const Divider(height: 16),
            ListTile(
              leading: const Icon(Icons.logout, color: Color(0xFF333333)),
              title: const Text('Cerrar sesión',
                  style: TextStyle(color: Color(0xFFB3261E))),
              onTap: _logout,
            ),
          ],
        ),
      ),
    );
  }
}