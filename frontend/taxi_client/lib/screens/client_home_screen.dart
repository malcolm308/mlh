import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../models/tariff.dart';
import '../services/address_service.dart';
import '../services/api_service.dart';
import '../services/geocode_service.dart';
import '../services/location_service.dart';
import '../services/osrm_service.dart';
import '../theme/app_theme.dart';
import '../widgets/client_map_view.dart';
import '../widgets/menu_lateral_cliente.dart';
import '../widgets/ui/glass_sheet.dart';
import '../widgets/ui/pill_button.dart';
import '../widgets/ui/pill_tabs.dart';
import '../widgets/vehicle_selector_sheet.dart';
import 'blocked_drivers_screen.dart';
import 'favorite_locations_screen.dart';
import 'history_screen.dart';
import 'support_screen.dart';
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

// Estados estrictos del flujo de solicitud de viaje
enum ClientState {
  selectingRoute,    // Paso 1: Mapa + buscadores + botón "Confirmar ruta"
  selectingVehicle,  // Paso 2: Panel de vehículos abierto (única forma de solicitar)
  waitingForDriver,  // Viaje solicitado, mostrando carga
}

class _ClientHomeScreenState extends State<ClientHomeScreen>
    with WidgetsBindingObserver {
  final ClientMapController _mapController = ClientMapController();

  /// Clave del Scaffold para abrir el menu desde el boton flotante.
  ///
  /// El boton vive en el `Stack` del propio `build`, o sea ENCIMA del
  /// `Scaffold`: `Scaffold.of(context)` con ese contexto no encuentra ningun
  /// Scaffold y la llamada explota en silencio (por eso el menu solo abria
  /// deslizando). Con la clave el drawer se abre igual que en la app del
  /// chofer.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  LatLng _myLoc = ApiConfig.defaultClientLocation;
  LatLng? _pickup;
  LatLng? _dropoff;
  _PinMode _pinMode = _PinMode.pickup;

  // Estado del flujo controlado por enum
  ClientState _currentState = ClientState.selectingRoute;

  // Variables de datos del viaje
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

  /// Desglose de la última estimación
  Map<String, dynamic>? _detalleFare;

  /// Si el desglose está abierto
  bool _verDetalle = false;

  /// Minutos de espera de cortesía
  int? _cortesiaMin;
  String? _pickupAddr;
  String? _dropoffAddr;
  final TextEditingController _searchController = TextEditingController();
  final Map<String, String> _reverseCache = {};
  List<GeoPlace> _suggestions = const [];
  String? _searchError;
  String? _searchHelp;
  bool _searching = false;
  Timer? _searchDebounce;

  /// Foco del buscador. Sirve para saber si el pasajero esta ESCRIBIENDO:
  /// mientras el campo tiene foco y texto, la geocodificacion inversa del pin
  /// no debe sobrescribir lo tecleado (era la otra via por la que el cursor
  /// saltaba a lo loco).
  final FocusNode _searchFocus = FocusNode();

  /// Ancla del desplegable de sugerencias: el campo es el "leader" y la
  /// ventana flotante lo sigue aunque el panel o el teclado se muevan.
  final LayerLink _searchLink = LayerLink();

  /// Ventana flotante de sugerencias. Vive en el Overlay (por encima de todo)
  /// para NO empujar el campo ni el resto del panel: se superpone.
  OverlayEntry? _suggestionsOverlay;

  /// Ancho real del campo, medido en el build, para que el desplegable tenga
  /// exactamente el mismo ancho.
  double _searchFieldWidth = 320;

  // Datos del panel de vehículos (solo existen cuando _currentState == selectingVehicle)
  List<VehicleOption> _vehicles = [];
  VehicleOption? _selectedVehicle;
  String? _etaText;
  String _paymentMethod = 'Efectivo';

  /// Datos del pasajero para esta solicitud: cuántos viajan, si llevan
  /// equipaje y si llevan mascota. Se envían al backend con el viaje.
  int _numPasajes = 1;
  bool _equipaje = false;
  bool _mascota = false;

  /// Resetea TODO el estado y vuelve a Paso 1 (selectingRoute)
  void _resetTripState() {
    setState(() {
      _currentState = ClientState.selectingRoute;
      
      // Coordenadas y direcciones
      _pickup = _myLoc;
      _dropoff = null;
      _pickupAddr = null;
      _dropoffAddr = null;
      _pickupTouched = false;
      _pinMode = _PinMode.pickup;

      // Vehículo
      _vehicleType = '';
      _selectedVehicle = null;
      _vehicles = const [];
      _etaText = null;
      _paymentMethod = 'Efectivo';

      // Pasajeros / equipaje / mascota
      _numPasajes = 1;
      _equipaje = false;
      _mascota = false;

      // Cotización
      _backendFare = null;
      _detalleFare = null;
      _estFareBusy = false;
      _estFareError = false;

      // Ruta
      _route = const [];
      _routeKm = null;
      _routeMin = null;
      _routing = false;

      // UI
      _verDetalle = false;
      _loading = false;

      // Errores
      _error = null;
      _searchError = null;
      _searchHelp = null;
      _suggestions = const [];
    });
  }

  /// Estado del GPS del dispositivo.
  LocationPermissionState? _gpsState;
  StreamSubscription<LatLng>? _gpsSub;

  /// Momento del ultimo fix recibido. El vigilante lo usa para detectar que el
  /// canal nativo dejo de emitir (pantalla bloqueada, GPS reiniciado, etc.).
  DateTime? _ultimoFixGps;
  Timer? _gpsWatchdog;

  /// El pasajero movio el pin o eligio un lugar: el GPS ya no pisa el
  /// punto de recogida hasta que pulse "mi ubicacion".
  bool _pickupTouched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pickup = _myLoc;
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus) _cerrarOverlaySugerencias();
    });
    _resolveDefaultAddress();
    _initGps();
    _loadTarifas();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gpsWatchdog?.cancel();
    _gpsSub?.cancel();
    _searchDebounce?.cancel();
    _cerrarOverlaySugerencias();
    _searchController.dispose();
    _searchFocus.dispose();
    _mapController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_reanudarGps());
    }
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

    _escucharGps();
  }

  /// Se suscribe al GPS continuo y arma un vigilante.
  ///
  /// El canal nativo puede dejar de emitir sin avisar (el sistema apaga el
  /// proveedor al bloquear la pantalla o al pasar la app a segundo plano), y
  /// antes no habia nada que lo volviera a arrancar: la flecha se quedaba
  /// congelada en la ultima posicion para siempre. El vigilante comprueba que
  /// sigan llegando fixes y, si no, reinicia el listener y pide uno nuevo.
  void _escucharGps() {
    _gpsSub?.cancel();
    _gpsSub = LocationService.watch(
      distanceFilter: 8,
      interval: const Duration(seconds: 5),
    ).listen((p) {
      if (!mounted) return;
      _ultimoFixGps = DateTime.now();
      debugPrint('[GPS] pasajero en ${p.latitude},${p.longitude}');
      _applyGpsPosition(p, moveMap: false);
    });
    _gpsWatchdog?.cancel();
    _gpsWatchdog = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_refrescarGpsSiHaceFalta()),
    );
  }

  /// Si no llega un fix en 25 s, reinicia el canal y pide la posicion actual.
  Future<void> _refrescarGpsSiHaceFalta() async {
    if (!mounted || _gpsState != LocationPermissionState.granted) return;
    final ultimo = _ultimoFixGps;
    if (ultimo != null &&
        DateTime.now().difference(ultimo) < const Duration(seconds: 25)) {
      return;
    }
    await LocationService.ensureWatching(
      distanceFilter: 8,
      interval: const Duration(seconds: 5),
    );
    final p = await LocationService.current(timeout: const Duration(seconds: 8));
    if (!mounted || p == null) return;
    _ultimoFixGps = DateTime.now();
    if (LocationService.distanceBetween(_myLoc, p) < 3) return;
    _applyGpsPosition(p, moveMap: false);
  }

  /// Al volver del segundo plano: reengancha el GPS y refresca la posicion.
  Future<void> _reanudarGps() async {
    if (_gpsState != LocationPermissionState.granted) {
      await _initGps();
      return;
    }
    final p = await LocationService.current(timeout: const Duration(seconds: 8));
    if (!mounted) return;
    if (p != null) {
      _ultimoFixGps = DateTime.now();
      _applyGpsPosition(p, moveMap: false);
    }
    _escucharGps();
  }

  void _applyGpsPosition(LatLng p, {required bool moveMap}) {
    final anterior = _myLoc;
    final movido = LocationService.distanceBetween(anterior, p);
    setState(() {
      _gpsState = LocationPermissionState.granted;
      _myLoc = p;
      // El punto de recogida sigue al GPS mientras el pasajero no lo haya
      // fijado a mano ni haya elegido otra direccion en el buscador.
      if (!_pickupTouched) {
        _pickup = p;
        _pickupAddr = null;
      }
    });
    if (moveMap) _mapController.move(p, 15);
    // Recalcular la ruta en cada tick de GPS seria una llamada a OSRM cada
    // 5 s: solo se hace cuando el pasajero se movio lo suficiente como para
    // que el trazado cambie de verdad.
    if (_pickup != null && _dropoff != null && (movido >= 25 || _route.isEmpty)) {
      _loadRoutePreview();
    }
  }

  /// Pide permiso si hace falta, toma la posicion real y la impone como punto
  /// de recogida.
  ///
  /// No reutiliza `_applyGpsPosition` a proposito: esa funcion respeta
  /// `_pickupTouched` y no mueve el punto si el pasajero toco el mapa antes.
  /// La flecha debe imponerse siempre: actualiza `_pickup`, mueve el mapa y
  /// escribe en el buscador la direccion inversa del nuevo punto.
  Future<void> _useMyLocation() async {
    var state = _gpsState ?? LocationPermissionState.denied;
    if (state != LocationPermissionState.granted) {
      state = await LocationService.ensurePermission();
      if (!mounted) return;
      setState(() => _gpsState = state);
    }
    if (state != LocationPermissionState.granted) {
      _showLocationError(state);
      return;
    }

    final p =
        await LocationService.current() ?? await LocationService.lastKnown();
    if (!mounted) return;
    if (p == null) {
      _showError('No se pudo obtener la ubicacion. Revisa el GPS del telefono.');
      return;
    }

    setState(() {
      _gpsState = LocationPermissionState.granted;
      _pickupTouched = false;
      _myLoc = p;
      _pickup = p;
      _pickupAddr = null;
    });
    _ultimoFixGps = DateTime.now();
    // Reengancha el flujo continuo: si el canal nativo se habia quedado
    // dormido, este es el punto donde vuelve a arrancar.
    _escucharGps();
    _moveMapTo(p);
    _loadRoutePreview();
    _reverseToAddress(p, updateSearch: true);
  }

  void _showLocationError(LocationPermissionState state) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(state == LocationPermissionState.serviceDisabled
          ? 'Activa la ubicacion (GPS) del telefono para usar tu posicion.'
          : 'Concede el permiso de ubicacion para usar tu posicion actual.'),
      backgroundColor: Theme.of(context).colorScheme.error,
      action: SnackBarAction(
        label: 'Ajustes',
        textColor: Colors.white,
        onPressed: LocationService.openSettings,
      ),
    ));
  }

  /// Centra el mapa en [p] aunque el controlador aun no este listo (primer
  /// arranque o estilo cargando): reintenta unas cuantas veces.
  void _moveMapTo(LatLng p, {double zoom = 16, int intento = 0}) {
    if (_mapController.listo) {
      _mapController.move(p, zoom);
      return;
    }
    if (intento >= 6) return;
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _moveMapTo(p, zoom: zoom, intento: intento + 1);
    });
  }

  bool _samePoint(LatLng a, LatLng b) =>
      (a.latitude - b.latitude).abs() < 1e-9 &&
      (a.longitude - b.longitude).abs() < 1e-9;

  String _coordLabel(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

  /// Garantiza que la direccion de un punto este en el estado ANTES de abrir
  /// el BottomSheet. Si el geocodificador inverso aun no respondio, se espera
  /// aqui; si falla, se usa la coordenada para que el destino nunca quede vacio.
  Future<void> _ensureAddress(LatLng point, {required bool pickup}) async {
    final actual = pickup ? _pickupAddr : _dropoffAddr;
    if (actual != null && actual.trim().isNotEmpty) return;

    final key = '${point.latitude.toStringAsFixed(5)},'
        '${point.longitude.toStringAsFixed(5)}';
    final cached = _reverseCache[key];
    String label;
    if (cached != null && cached.trim().isNotEmpty) {
      label = cached;
    } else {
      final dir = await AddressService.de(point);
      label = dir.vacia ? _coordLabel(point) : dir.texto;
      if (!dir.vacia) _reverseCache[key] = dir.texto;
    }
    if (!mounted) return;
    setState(() {
      if (pickup) {
        if (_pickup != null && _samePoint(_pickup!, point)) {
          _pickupAddr = label;
        }
      } else {
        if (_dropoff != null && _samePoint(_dropoff!, point)) {
          _dropoffAddr = label;
        }
      }
    });
  }

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

  Future<void> _reverseToAddress(LatLng p, {bool updateSearch = false}) async {
    final key =
        '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}';
    final cached = _reverseCache[key];
    if (cached != null) {
      _applyReverseAddress(p, cached, updateSearch: updateSearch);
      return;
    }
    final dir = await AddressService.de(p);
    final addr = dir.vacia ? null : dir.texto;
    if (addr != null) _reverseCache[key] = addr;
    if (!mounted) return;
    _applyReverseAddress(p, addr, updateSearch: updateSearch);
  }

  void _applyReverseAddress(LatLng p, String? addr,
      {bool updateSearch = false}) {
    final texto = (addr ?? '').trim();
    // El pasajero esta con el teclado abierto y contenido ya escrito:
    // NINGUNA geocodificacion puede tocar el controller. Es la via que
    // reescribia el texto y aplastaba el cursor al trabajar en el medio.
    final escribiendo =
        _searchFocus.hasFocus && _searchController.text.isNotEmpty;
    // Escrit segura para cuando no hay teclado: se conserva el hueco del
    // cursor (con clamp) en vez de dejarlo al final del texto nuevo.
    void escribirSeguro(String nuevo) {
      final sel = _searchController.selection;
      final largo = _searchController.text.length;
      _searchController.text = nuevo;
      if (sel.isValid && sel.baseOffset >= 0 && sel.baseOffset < largo &&
          largo > 0) {
        _searchController.selection = TextSelection.collapsed(
            offset: math.min(sel.baseOffset + nuevo.length - largo, nuevo.length));
      }
    }

    if (_pickup != null && _samePoint(p, _pickup!)) {
      final escribir =
          updateSearch && _pinMode == _PinMode.pickup && texto.isNotEmpty;
      if (escribir || _pickupAddr != addr) {
        setState(() {
          _pickupAddr = addr;
          if (escribir && !escribiendo) {
            escribirSeguro(texto);
            _suggestions = const [];
          }
        });
        if (escribir && !escribiendo) _cerrarOverlaySugerencias();
      }
    } else if (_dropoff != null && _samePoint(p, _dropoff!)) {
      final escribir =
          updateSearch && _pinMode == _PinMode.dropoff && texto.isNotEmpty;
      if (escribir || _dropoffAddr != addr) {
        setState(() {
          _dropoffAddr = addr;
          if (escribir && !escribiendo) {
            escribirSeguro(texto);
            _suggestions = const [];
          }
        });
        if (escribir && !escribiendo) _cerrarOverlaySugerencias();
      }
    }
  }

  /// Muestra/actualiza la ventana flotante de sugerencias debajo del campo.
  ///
  /// No forma parte del `Column` del panel: es una entrada del Overlay, asi
  /// que aparece ENCIMA del contenido y no empuja ni tapa el TextField.
  void _actualizarOverlaySugerencias() {
    if (!mounted) return;
    if (_suggestions.isEmpty || !_searchFocus.hasFocus) {
      _cerrarOverlaySugerencias();
      return;
    }
    if (_suggestionsOverlay == null) {
      final overlay = Overlay.of(context, rootOverlay: true);
      _suggestionsOverlay = OverlayEntry(builder: _buildOverlaySugerencias);
      overlay.insert(_suggestionsOverlay!);
    } else {
      _suggestionsOverlay!.markNeedsBuild();
    }
  }

  void _cerrarOverlaySugerencias() {
    _suggestionsOverlay?.remove();
    _suggestionsOverlay = null;
  }

  /// Contenido de la ventana flotante: fondo blanco, borde redondeado, sombra,
  /// maximo 300 px de alto y scroll interno.
  Widget _buildOverlaySugerencias(BuildContext context) {
    return CompositedTransformFollower(
      link: _searchLink,
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, 6),
      child: SizedBox(
        width: _searchFieldWidth,
        child: Material(
          color: Colors.white,
          elevation: 8,
          shadowColor: Colors.black26,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _suggestions.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final s = _suggestions[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.place_outlined,
                      size: 18, color: AppColors.ambar),
                  title: Text(
                    s.shortLabel ?? s.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  onTap: () => _onSuggestionSelected(s),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    // NO se reasigna `_searchController.text` aqui: el propio TextField ya
    // aplica el texto y su cursor. Reasignarlo colapsa la seleccion al final,
    // que es el bug del cursor al borrar en el medio.
    final trimmed = text.trim();

    // 1) Limpiar siempre: nada de sugerencias "fantasmas" de una busqueda previa.
    setState(() {
      _suggestions = const [];
      _searching = false;
      _searchError = null;
      _searchHelp = null;
    });
    _cerrarOverlaySugerencias();

    if (trimmed.length < 3) return;

    // 2) "entre" incompleto: no se llama al backend, se pide completar.
    if (_tieneEntreIncompleto(trimmed)) {
      setState(() {
        _searchHelp = 'Completa la dirección: calle A entre calle B y calle C';
      });
      return;
    }

    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final results = await GeocodeService.search(trimmed, near: _myLoc);
        if (!mounted || _searchController.text.trim() != trimmed) return;
        setState(() {
          _suggestions = results;
          _searching = false;
          _searchError = null;
          if (results.isEmpty) {
            _searchError = 'Dirección no encontrada';
          }
        });
        _actualizarOverlaySugerencias();
      } catch (_) {
        // 3) Fallo de red: mensaje rojo, el buscador no se queda congelado.
        if (!mounted || _searchController.text.trim() != trimmed) return;
        setState(() {
          _suggestions = const [];
          _searching = false;
          _searchError = 'Error de conexión. Intenta de nuevo';
        });
        _cerrarOverlaySugerencias();
      }
    });
  }

  /// True si la direccion usa "entre" pero todavia no trae las dos calles.
  bool _tieneEntreIncompleto(String texto) {
    final partes = texto.split(RegExp(r'\s+'));
    final idx = partes.indexWhere(
        (p) => p.toLowerCase().replaceAll('[^a-z]', '') == 'entre');
    if (idx == -1) return false;
    if (idx == 0) return true;
    final resto = partes.sublist(idx + 1).join(' ').trim();
    if (resto.isEmpty) return true;
    final tieneY = RegExp(r'\by\b', caseSensitive: false).hasMatch(resto) ||
        RegExp(r'\be\b', caseSensitive: false).hasMatch(resto);
    final palabras = resto.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    return !tieneY || palabras < 3;
  }

  void _onSuggestionSelected(GeoPlace place) {
    _searchDebounce?.cancel();
    _cerrarOverlaySugerencias();
    _searchController.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _suggestions = const [];
      _searching = false;
      _searchError = null;
      _searchHelp = null;
      if (_pinMode == _PinMode.pickup) {
        _pickup = place.point;
        _myLoc = place.point;
        _pickupAddr = place.shortLabel ?? place.displayName;
        // La direccion la eligio el pasajero: el GPS ya no debe pisarla.
        _pickupTouched = true;
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

  Future<void> _loadCortesia() async {
    final minutos = await widget.api.fetchCortesiaMinutos();
    if (!mounted || minutos == null) return;
    setState(() => _cortesiaMin = minutos);
  }

  Future<void> _loadEstimate() async {
    final pickup = _pickup;
    final dropoff = _dropoff;
    if (pickup == null || dropoff == null || pickup == dropoff) return;
    // Solo cargar estimación si estamos en Paso 1
    if (_currentState != ClientState.selectingRoute) return;

    // FIX: el destino debe estar escrito en el estado ANTES de abrir el panel.
    // Si el usuario tocó el mapa, el geocodificador inverso puede seguir en
    // vuelo; sin esta espera el BottomSheet recibía null y mostraba "Destino"
    // en blanco al cancelar y pedir un viaje nuevo.
    await _ensureAddress(pickup, pickup: true);
    await _ensureAddress(dropoff, pickup: false);
    if (!mounted || _currentState != ClientState.selectingRoute) return;

    final req = ++_estReq;
    setState(() => _estFareBusy = true);
    try {
      final res = await widget.api.estimateAll(
        requestLat: pickup.latitude,
        requestLng: pickup.longitude,
        dropoffLat: dropoff.latitude,
        dropoffLng: dropoff.longitude,
      );
      if (!mounted || req != _estReq) return;
      final vehiclesList = (res['vehicles'] as List)
          .map((v) => VehicleOption.fromApi(Map<String, dynamic>.from(v as Map)))
          .toList();
      if (vehiclesList.isEmpty) {
        setState(() {
          _estFareBusy = false;
          _estFareError = true;
        });
        return;
      }
      // Transición a Paso 2: cambiar estado Y abrir panel en un solo setState
      setState(() {
        _currentState = ClientState.selectingVehicle;
        _estFareBusy = false;
        _estFareError = false;
        _vehicles = vehiclesList;
        _etaText = res['eta_text'] as String? ?? '--';
        _paymentMethod = res['payment_method'] as String? ?? 'Efectivo';
        _selectedVehicle = vehiclesList.first;
      });
      // Abrir el panel DESPUÉS del setState (necesita _vehicles poblado)
      _showVehicleSelector();
    } catch (_) {
      if (!mounted || req != _estReq) return;
      setState(() {
        _estFareBusy = false;
        _estFareError = true;
      });
    }
  }

  void _showVehicleSelector() {
    // Solo abrir si estamos en el estado correcto y hay vehículos
    if (_currentState != ClientState.selectingVehicle) return;
    if (_vehicles.isEmpty || _selectedVehicle == null) return;

    final initialIndex = _vehicles.indexWhere(
        (v) => v.type == _selectedVehicle?.type);

    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _VehicleSelectorStateful(
        pickupAddress: (_pickupAddr ?? '').trim().isNotEmpty
            ? _pickupAddr!
            : _coordLabel(_pickup ?? _myLoc),
        dropoffAddress: (_dropoffAddr ?? '').trim().isNotEmpty
            ? _dropoffAddr!
            : _coordLabel(_dropoff ?? _myLoc),
        distanceKm: _routeKm ?? 0,
        etaText: _etaText ?? '--',
        paymentMethod: _paymentMethod,
        vehicles: _vehicles,
        initialSelectedIndex: initialIndex < 0 ? 0 : initialIndex,
        numPasajes: _numPasajes,
        equipaje: _equipaje,
        mascota: _mascota,
        onPasajerosChanged: (v) => setState(() => _numPasajes = v),
        onEquipajeChanged: (v) => setState(() => _equipaje = v),
        onMascotaChanged: (v) => setState(() => _mascota = v),
        onConfirm: (selectedIndex) {
          setState(() => _selectedVehicle = _vehicles[selectedIndex]);
          Navigator.of(ctx).pop(true);
          _requestTrip();
        },
        onBack: () {
          Navigator.of(ctx).pop(false);
        },
        isLoading: _loading,
        onOpen: () {},
        onClose: () {},
      ),
    ).then((confirmed) {
      if (!mounted) return;
      if (confirmed == true) return; // Confirmó → _requestTrip maneja el estado
      // El usuario cerró el panel sin confirmar → volver a Paso 1
      _resetTripState();
    });
  }

  Future<void> _requestTrip() async {
    final pickup = _pickup;
    final dropoff = _dropoff;
    if (pickup == null || dropoff == null) {
      _showError('Define recogida y destino en el mapa');
      _resetTripState();
      return;
    }
    if (_selectedVehicle == null) {
      _showError('Selecciona un tipo de vehículo');
      _resetTripState();
      return;
    }
    // Transición a estado de carga
    setState(() {
      _currentState = ClientState.waitingForDriver;
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
        vehicleType: _selectedVehicle!.type,
        numPasajes: _numPasajes,
        equipaje: _equipaje,
        mascota: _mascota,
        requestAddress: _pickupAddr ?? _coordLabel(pickup),
        dropoffAddress: _dropoffAddr ?? _coordLabel(dropoff),
      );
      final tripId = (res['trip_id'] ?? '').toString();
      if (tripId.isEmpty) throw ApiException('No se recibió el trip_id');
      if (!mounted) return;
      // Navegar a TripScreen
      final result = await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TripScreen(
          api: widget.api,
          clientId: widget.clientId,
          tripId: tripId,
          initialEstimate: (res['precio_estimado'] ?? 0).toDouble(),
        ),
      ));
      // Si el pasajero cerro el recibo (o el viaje fue cancelado), volver al
      // paso 1. En `completed` el reset ocurre SOLO aqui: la pantalla del
      // recibo se queda abierta hasta que el usuario pulse "Finalizar".
      if ((result == 'cancelled' || result == 'completed') && mounted) {
        _resetTripState();
      }
    } catch (e) {
      if (!mounted) return;
      _showError('$e');
      _resetTripState();
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('client_token');
    await prefs.remove('client_id');
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar cuenta?'),
        content: const Text(
          'Esta acción eliminará permanentemente tu cuenta y todos tus datos. '
          'Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Borrar cuenta'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await widget.api.deleteAccount();
        if (!mounted) return;
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cuenta eliminada')),
        );
        Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
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
    // Los botones flotantes NO pueden arrancar en el borde fisico: la app
    // dibuja edge-to-edge y la barra de estado se come el primer centimetro.
    // Con el inset real quedan debajo de la hora/bateria y clickeables (asi
    // lo hace la app del chofer).
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(),
      // El scrim casi transparente: el vidrio del menu ya difumina el mapa y
      // el resto de la pantalla debe seguir viendose, como en el diseno.
      drawerScrimColor: Colors.transparent,
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
            // Rayo 3D sobre los puntos ya confirmados. La punta del PNG cae
            // en el centro-abajo, asi que `iconAnchor: bottom` lo clava en la
            // coordenada exacta.
            rayoPins: [?_pickup, ?_dropoff],
            onTap: _placePin,
          ),
          // Rayo flotante mientras se elige el punto: la punta marca el
          // centro del mapa. El desplazamiento de -32.5 px (mitad de los
          // 65 px) deja la punta justo en `Alignment.center`.
          if (_currentState == ClientState.selectingRoute)
            IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: Transform.translate(
                  offset: const Offset(0, -32.5),
                  child: Image.asset(
                    'assets/icons/rayo_3d.png',
                    width: 65,
                    height: 65,
                    cacheWidth: 150,
                  ),
                ),
              ),
            ),
          if (_error != null)
            Positioned(
              top: topPad + 64,
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
            top: topPad + 8,
            left: 8,
            child: RoundIconButton(
              icon: Icons.menu_rounded,
              tooltip: 'Menú',
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          ),
          Positioned(
            top: topPad + 8,
            right: 8,
            child: Row(
              children: [
                RoundIconButton(
                  icon: Icons.notifications_none_rounded,
                  tooltip: 'Notificaciones',
                  onTap: _showNotifications,
                ),
                const SizedBox(width: 8),
                RoundIconButton(
                  icon: _gpsState == LocationPermissionState.granted
                      ? Icons.my_location_rounded
                      : Icons.location_disabled_rounded,
                  tooltip: _gpsState == LocationPermissionState.granted
                      ? 'Mi ubicación'
                      : 'Activar GPS',
                  // Recentra en la posicion real y la usa como recogida. La
                  // funcion pide el permiso si falta, asi que siempre responde.
                  onTap: _useMyLocation,
                ),
              ],
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

  void _showNotifications() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('No tienes notificaciones por el momento'),
      ));
  }

  /// Clave de SharedPreferences donde se guarda la última lista de tarifas.
  static const String _tarifasCacheKey = 'cache_tarifas';

  /// Carga las tarifas desde el backend y las cachea en disco.
  ///
  /// Si no hay red, usa la última lista cacheada para que el dropdown nunca se
  /// quede vacío (y nunca ofrezca un tipo de vehículo inexistente).
  //
  // el campo `_tarifas` se elimino: se asignaba y nunca se leia; las tarifas
  // fluyen por el parametro de `_vehicleTypeMarcado`. Si algun dia se necesita
  // en pantalla, se re-deriva del cache `_tarifasCacheKey`.
  Future<void> _loadTarifas() async {
    try {
      final tarifas = await widget.api.getTariffs();
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _tarifasCacheKey,
        jsonEncode(tarifas.map((t) => t.toJson()).toList()),
      );
      setState(() {
        _vehicleType = _vehicleTypeMarcado(tarifas);
      });
      _loadEstimate();
      unawaited(_loadCortesia());
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
      if (tarifas != null) {
        // variables locales para que el analyzer promocione el null dentro
        // del closure de `setState` (una variable mutable no se promueve).
        final lista = tarifas;
        setState(() {
          _vehicleType = _vehicleTypeMarcado(lista);
        });
      }
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
  Widget _buildRouteStats(ColorScheme scheme) {
    final fare = _estimatedFare;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
      Row(
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
      ),
      _botonDetalle,
      _panelDetalle,
      ],
    );
  }

  /// El botón de desglose. Va aparte porque solo tiene sentido cuando hay
  /// desglose que enseñar.
  Widget get _botonDetalle {
    if (_detalleFare == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () =>
            setState(() => _verDetalle = !_verDetalle),
        icon: Icon(_verDetalle ? Icons.expand_less : Icons.expand_more,
            size: 18),
        label: Text(_verDetalle ? 'Ocultar desglose' : 'Ver desglose',
            style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  /// Detalle de la tarifa, si el botón lo tiene abierto.
  Widget get _panelDetalle =>
      _verDetalle ? _detalleTarifa() : const SizedBox.shrink();

  /// Explica por que la tarifa estimada es la que es.
  ///
  /// Con el coeficiente por distancia el precio ya no es "base + km + tiempo" a
  /// ojos del pasajero, y un número que no se explica parece un error. Se
  /// despieza en las tres partes de verdad, sin inventar nada: los datos salen
  /// del backend en el breakdown de la estimación.
  Widget _detalleTarifa() {
    if (_detalleFare == null) return const SizedBox.shrink();
    final d = _detalleFare!;
    final base = (d['base_fare'] as num?)?.toDouble();
    final coef = (d['coeficiente'] as num?)?.toDouble();
    final km = (d['distance_fare'] as num?)?.toDouble();
    final tiempo = (d['time_fare'] as num?)?.toDouble();
    final ahorro = (d['ahorro_por_coeficiente'] as num?)?.toDouble();
    if (base == null || coef == null || km == null || tiempo == null) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _lineaDetalle('Tarifa base', '${base.toStringAsFixed(0)} CUP'),
          _lineaDetalle(
              'Kilometraje (x${coef.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')})',
              '${km.toStringAsFixed(0)} CUP'),
          _lineaDetalle('Tiempo estimado', '${tiempo.toStringAsFixed(0)} CUP'),
          if ((ahorro ?? 0) > 0)
            _lineaDetalle('Ahorro por carrera corta',
                '-${ahorro!.toStringAsFixed(0)} CUP', color: const Color(0xFF15803D)),
          if (_cortesiaMin != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _cortesiaMin == 0
                    ? 'La espera del chofer se cobra completa.'
                    : 'Espera del chofer: $_cortesiaMin min gratis. '
                        'Lo que pase de ahí se paga.',
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _lineaDetalle(String texto, String valor, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(texto,
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
          Text(valor,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color ?? const Color(0xFF111827))),
        ],
      ),
    );
  }

  Widget _statTile(
      ColorScheme scheme, IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borde),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: AppColors.ambar),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.tinta,
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppColors.secundario),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomPanel() {
    final bothSet = _pickup != null && _dropoff != null;
    final nombre = widget.profile.fullName.trim().split(RegExp(r'\s+')).first;
    final direccion =
        (_pinMode == _PinMode.pickup ? _pickupAddr : _dropoffAddr)?.trim();

    return GlassSheet(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Hola, $nombre',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.secundario,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            '¿Dónde quieres ir?',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: AppColors.tinta,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 12),
          PillTabs<_PinMode>(
            value: _pinMode,
            onChanged: (modo) {
              setState(() => _pinMode = modo);
              _cerrarOverlaySugerencias();
              FocusScope.of(context).unfocus();
            },
            items: const [
              PillTabItem(
                value: _PinMode.pickup,
                label: 'Recogida',
                icon: Icons.arrow_upward_rounded,
              ),
              PillTabItem(
                value: _PinMode.dropoff,
                label: 'Destino',
                icon: Icons.flag_rounded,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _searchFieldWidth = constraints.maxWidth;
                    return CompositedTransformTarget(
                      link: _searchLink,
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        onChanged: _onSearchChanged,
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.tinta,
                        ),
                        decoration: InputDecoration(
                          prefixIcon:
                              const Icon(Icons.search_rounded, size: 20),
                          hintText: _pinMode == _PinMode.pickup
                              ? 'Buscar la calle de recogida...'
                              : 'Buscar la calle del destino...',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          suffixIcon: _searching
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                )
                              : (_searchController.text.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear_rounded,
                                          size: 18),
                                      onPressed: () {
                                        _searchDebounce?.cancel();
                                        _cerrarOverlaySugerencias();
                                        _searchController.clear();
                                        setState(() {
                                          _suggestions = const [];
                                          _searching = false;
                                          _searchError = null;
                                          _searchHelp = null;
                                        });
                                      },
                                    )
                                  : null),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              // Flecha "mi ubicacion": boton redondo amarillo a la derecha
              // del buscador, como en el diseno.
              Material(
                color: AppColors.acento,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    setState(() => _pinMode = _PinMode.pickup);
                    _useMyLocation();
                  },
                  child: const SizedBox(
                    width: 46,
                    height: 46,
                    child: Icon(
                      Icons.near_me_rounded,
                      color: AppColors.tinta,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // Las sugerencias NO van en este Column: se pintan en una ventana
          // flotante del Overlay (ver `_buildOverlaySugerencias`) para que no
          // empujen el campo ni el resto del panel.
          if (_searchHelp != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
              child: Text(
                _searchHelp!,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.ambar,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
              child: Text(
                _searchError!,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.secundario,
                height: 1.3,
              ),
              children: [
                const TextSpan(text: 'Toca el mapa o busca una calle'),
                TextSpan(
                  text: (direccion != null && direccion.isNotEmpty)
                      ? ' · $direccion'
                      : ' para la ${_pinMode == _PinMode.pickup ? 'RECOGIDA' : 'DESTINO'}',
                  style: const TextStyle(
                    color: AppColors.ambar,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (_pickupAddr != null || _dropoffAddr != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.campo,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_pickupAddr != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.arrow_upward_rounded,
                            size: 14, color: AppColors.exito),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _pickupAddr!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.tinta,
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (_pickupAddr != null && _dropoffAddr != null)
                    const SizedBox(height: 2),
                  if (_dropoffAddr != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.flag_rounded,
                            size: 14, color: AppColors.error),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _dropoffAddr!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.tinta,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
          if (bothSet) ...[
            const SizedBox(height: 12),
            _buildRouteStats(Theme.of(context).colorScheme),
          ],
          const SizedBox(height: 12),
          // Boton de accion: solo "Confirmar ruta" en Paso 1. En otros
          // estados (selectingVehicle, waitingForDriver) no se muestra.
          if (_currentState == ClientState.selectingRoute)
            PillButton(
              label: _estFareBusy ? 'Calculando...' : 'Confirmar ruta',
              loading: _estFareBusy,
              loadingLabel: 'Calculando...',
              icon: Icons.route_rounded,
              onPressed: bothSet ? _loadEstimate : null,
            ),
          // Indicador de carga cuando el viaje esta siendo solicitado.
          if (_currentState == ClientState.waitingForDriver)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text(
                    'Solicitando viaje...',
                    style: TextStyle(
                        fontSize: 14, color: AppColors.secundario),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _shareApp() async {
    // El código viene en el perfil que se cargó al iniciar sesión. Si la
    // sesión se restauró con un perfil antiguo (sin código), se pide al
    // backend: `/referidos/mi-codigo` también lo crea y lo guarda si la
    // cuenta es anterior al sistema de referidos.
    var codigo = widget.profile.codigoReferido;
    if (codigo == null || codigo.isEmpty) {
      try {
        final j = await widget.api.getMyReferralCode();
        codigo = (j['codigo'] ?? '').toString().trim();
      } catch (_) {
        codigo = null;
      }
    }
    if (!mounted) return;
    if (codigo == null || codigo.isEmpty) {
      _showError('No se pudo obtener tu código de invitación. Inténtalo de nuevo.');
      return;
    }
    final mensaje = '¡Descarga RapiTaxi, la mejor forma de moverte por La '
        'Habana! Usa mi código de invitación $codigo al registrarte y obtén un '
        '10% de descuento en tu primer viaje. Descarga aquí: '
        '${ApiConfig.appDownloadUrl}';
    // ignore: deprecated_member_use
    await Share.share(mensaje, subject: 'RapiTaxi');
  }

  Widget _buildDrawer() {
    return MenuLateralCliente(
      profile: widget.profile,
      onHistorial: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => HistoryScreen(
            api: widget.api,
            clientId: widget.clientId,
          ),
        ));
      },
      onFavoritas: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => FavoriteLocationsScreen(
            api: widget.api,
            clientId: widget.clientId,
          ),
        ));
      },
      onBloqueados: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BlockedDriversScreen(api: widget.api),
        ));
      },
      onCompartir: () {
        _shareApp();
      },
      onAyuda: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SupportScreen(api: widget.api),
        ));
      },
      onCerrarSesion: _logout,
      onBorrarCuenta: () {
        // La confirmacion vive en el propio dialogo del home.
        Navigator.of(context).pop();
        _confirmDeleteAccount();
      },
    );
  }
}

/// Widget stateful que maneja la selección de vehículo internamente.
/// Evita reconstruir el padre y apilar múltiples layouts.
class _VehicleSelectorStateful extends StatefulWidget {
  final String pickupAddress;
  final String dropoffAddress;
  final double distanceKm;
  final String etaText;
  final String paymentMethod;
  final List<VehicleOption> vehicles;
  final int initialSelectedIndex;
  final int numPasajes;
  final bool equipaje;
  final bool mascota;
  final ValueChanged<int> onPasajerosChanged;
  final ValueChanged<bool> onEquipajeChanged;
  final ValueChanged<bool> onMascotaChanged;
  final ValueChanged<int> onConfirm;
  final VoidCallback onBack;
  final bool isLoading;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  const _VehicleSelectorStateful({
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.distanceKm,
    required this.etaText,
    required this.paymentMethod,
    required this.vehicles,
    required this.initialSelectedIndex,
    required this.numPasajes,
    required this.equipaje,
    required this.mascota,
    required this.onPasajerosChanged,
    required this.onEquipajeChanged,
    required this.onMascotaChanged,
    required this.onConfirm,
    required this.onBack,
    required this.isLoading,
    required this.onOpen,
    required this.onClose,
  });

  @override
  State<_VehicleSelectorStateful> createState() => _VehicleSelectorStatefulState();
}

class _VehicleSelectorStatefulState extends State<_VehicleSelectorStateful> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialSelectedIndex;
    widget.onOpen();
  }

  @override
  void dispose() {
    widget.onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VehicleSelectorSheet(
      pickupAddress: widget.pickupAddress,
      dropoffAddress: widget.dropoffAddress,
      distanceKm: widget.distanceKm,
      etaText: widget.etaText,
      paymentMethod: widget.paymentMethod,
      vehicles: widget.vehicles,
      selectedIndex: _selectedIndex,
      numPasajes: widget.numPasajes,
      equipaje: widget.equipaje,
      mascota: widget.mascota,
      onPasajerosChanged: widget.onPasajerosChanged,
      onEquipajeChanged: widget.onEquipajeChanged,
      onMascotaChanged: widget.onMascotaChanged,
      onVehicleSelected: (index) {
        setState(() {
          _selectedIndex = index;
        });
      },
      onConfirmTrip: () {
        widget.onConfirm(_selectedIndex);
      },
      onBack: widget.onBack,
      isLoading: widget.isLoading,
    );
  }
}
