import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../models/tariff.dart';
import '../services/address_service.dart';
import '../services/api_client.dart';
import '../services/api_service.dart';
import '../services/geocode_service.dart';
import '../services/location_service.dart';
import '../services/osrm_service.dart';
import '../services/token_store.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/client_map_view.dart';
import '../widgets/menu_lateral_cliente.dart';
import '../widgets/ui/glass_sheet.dart';
import '../widgets/ui/pill_button.dart';
import '../widgets/vehicle_selector_sheet.dart';
import 'blocked_drivers_screen.dart';
import 'client_fondo_screen.dart';
import 'favorite_locations_screen.dart';
import 'history_screen.dart';
import 'perfil_screen.dart';
import 'promociones_screen.dart';
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

// Estados estrictos del flujo de solicitud de viaje
enum ClientState {
  selectingRoute,    // Paso 1: Mapa + buscadores + botón "Confirmar ruta"
  selectingVehicle,  // Paso 2: Panel de vehículos abierto (única forma de solicitar)
  waitingForDriver,  // Viaje solicitado, mostrando carga
}

class _ClientHomeScreenState extends State<ClientHomeScreen>
    with WidgetsBindingObserver {
  final ClientMapController _mapController = ClientMapController();

  /// Permite disparar el pulso del rayo flotante cuando el mapa se detiene.
  final GlobalKey<_RayoFlotanteState> _rayoKey = GlobalKey<_RayoFlotanteState>();

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

  // Estado del flujo controlado por enum
  ClientState _currentState = ClientState.selectingRoute;

  /// Hay una pantalla de viaje (TripScreen) abierta. Mientras sea true el
  /// aviso de actualizacion obligatoria NO puede tapar la pantalla.
  bool _viajeEnPantalla = false;

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

  // ---- Flujo de selección por centro del mapa (rayo fijo) ----
  //
  // El pasajero NO toca pines: mueve el mapa bajo el rayo. Tras 2 s quieto se
  // geocodifica el centro y el panel muestra la dirección. Primero se confirma
  // la recogida y después el destino; hasta confirmar el destino no se traza
  // ninguna ruta.
  bool _pickupConfirmado = false;

  /// Centro geocodificado y su dirección. `null` mientras no hay respuesta.
  LatLng? _centroMapa;
  String? _centroAddr;

  /// La geocodificación inversa del centro está en vuelo.
  bool _buscandoCentro = false;

  /// No se pudo resolver una dirección de calle: se usará la coordenada.
  String? _centroError;

  /// Token de la última petición de geocodificación del centro.
  int _centroReq = 0;

  /// Espera de 2 s sin mover la cámara antes de pedir la dirección.
  Timer? _centroTimer;

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

  /// Saldo vigente del Fondo del pasajero, consultado al cotizar el viaje.
  double _walletBalance = 0;

  /// Recargo por pago con transferencia externa (0.10 = 10%, lo fija el
  /// panel). El backend es quien calcula el monto final.
  double _transferSurchargeRate = 0.10;

  /// Datos del pasajero para esta solicitud: cuántos viajan, si llevan
  /// equipaje y si llevan mascota. Se envían al backend con el viaje.
  int _numPasajes = 1;
  bool _equipaje = false;
  bool _mascota = false;

  /// Resetea TODO el estado y vuelve a Paso 1 (selectingRoute)
  void _resetTripState() {
    // Se toma antes del `setState` porque este limpia `_centroMapa`.
    final centro = _centroActual();
    // Invalida respuestas en vuelo (ruta / tarifa) de la seleccion anterior.
    _routeReq++;
    _estReq++;
    setState(() {
      _currentState = ClientState.selectingRoute;
      
      // Coordenadas y direcciones
      _pickup = centro;
      _dropoff = null;
      _pickupAddr = null;
      _dropoffAddr = null;
      _pickupTouched = false;

      // Flujo por centro del mapa
      _pickupConfirmado = false;
      _centroMapa = null;
      _centroAddr = null;
      _centroError = null;
      _buscandoCentro = false;

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
    _centroTimer?.cancel();
    // Vuelta al paso 1: el rayo vuelve a apuntar a lo que haya en el centro.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_geocodificarCentro());
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
    // Si el refresh token caduca, ApiClient limpia la sesion y avisa aqui.
    ApiClient.alExpirarSesion = _sesionExpirada;
    WidgetsBinding.instance.addObserver(this);
    _pickup = _myLoc;
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus) _cerrarOverlaySugerencias();
    });
    _resolveDefaultAddress();
    _initGps();
    _loadTarifas();
    // OTA: al abrir (o al recuperar la sesion y llegar aqui) se consulta la
    // version. Un parche se descarga solo; un APK obligatorio abre el dialogo.
    unawaited(_revisarActualizacion());
    // Dirección del centro nada más abrir, sin esperar a que el pasajero mueva.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_geocodificarCentro());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gpsWatchdog?.cancel();
    _gpsSub?.cancel();
    _searchDebounce?.cancel();
    _centroTimer?.cancel();
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
      // Al volver del segundo plano pudo publicarse una version nueva.
      unawaited(_revisarActualizacion());
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
    setState(() {
      _gpsState = LocationPermissionState.granted;
      _myLoc = p;
      // El punto de recogida sigue al GPS mientras el pasajero no lo haya
      // fijado a mano, haya elegido otra direccion en el buscador o ya lo
      // haya confirmado. Tras confirmar queda CONGELADO.
      if (!_pickupTouched && !_pickupConfirmado) {
        _pickup = p;
        _pickupAddr = null;
      }
    });
    if (moveMap) _mapController.move(p, 15);
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
      _myLoc = p;
      // Antes de confirmar, la recogida sigue al GPS (aunque quien manda es
      // el centro del mapa). Después de confirmar no se toca.
      if (!_pickupConfirmado) _pickup = p;
      _centroMapa = p;
      _centroError = null;
    });
    _ultimoFixGps = DateTime.now();
    // Reengancha el flujo continuo: si el canal nativo se habia quedado
    // dormido, este es el punto donde vuelve a arrancar.
    _escucharGps();
    _moveMapTo(p);
    // Si el mapa ya estaba en ese punto no habrá `onCameraIdle`: la espera de
    // 2 s cubre ese caso.
    _onMapaMovido();
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

  static const String _sinDireccion = 'Ubicación seleccionada en el mapa';

  bool _coordValida(LatLng p) =>
      p.latitude.isFinite &&
      p.longitude.isFinite &&
      p.latitude.abs() <= 90 &&
      p.longitude.abs() <= 180;

  /// Punto que marca el rayo: la camara REAL del mapa.
  ///
  /// `_mapController.center` se actualiza con cada `onCameraMove` (por eso el
  /// mapa lleva `trackCameraPosition: true`). Los otros dos son solo respaldo
  /// para el primer frame, antes de que exista el controlador nativo.
  LatLng _centroActual() => _mapController.center ?? _centroMapa ?? _myLoc;

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
      label = dir.vacia ? 'Ubicación seleccionada en el mapa' : dir.texto;
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
    // Si mientras se resolvia el pasajero ya confirmo la recogida (o movio el
    // punto), esta respuesta es vieja: no puede pisar la direccion fijada.
    if (!mounted ||
        _pickupConfirmado ||
        _pickupTouched ||
        _pickup == null ||
        !_samePoint(_pickup!, _myLoc)) {
      return;
    }
    setState(() => _pickupAddr = addr.vacia ? null : addr.texto);
  }

  // ---------------- Selección por centro del mapa ----------------

  /// El mapa se ha movido: se reinicia la espera de 2 s.
  ///
  /// No se hace `setState` aquí: `onCameraMove` dispara decenas de veces por
  /// segundo y reconstruir el panel en cada fotograma arruinaría la fluidez.
  /// El panel se actualiza una sola vez, cuando llega la dirección.
  void _onMapaMovido() {
    if (_currentState != ClientState.selectingRoute) return;
    _centroTimer?.cancel();
    // Invalida cualquier geocodificación en vuelo: si el rayo se movió, la
    // respuesta de la posición anterior ya no vale y no debe cambiar el texto.
    _centroReq++;
    _centroTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) unawaited(_geocodificarCentro());
    });
  }

  /// La cámara se detuvo: solo pulso del rayo.
  ///
  /// Aquí NO se geocodifica. `onCameraIdle` llega en cuanto termina el gesto,
  /// así que pedir la dirección aquí cambiaría el texto aunque el pasajero
  /// acabe de moverse. La dirección se pide cuando de verdad han pasado 2 s
  /// sin mover (lo controla `_onMapaMovido`).
  void _onMapaQuieto() {
    _rayoKey.currentState?.pulso();
  }

  /// Geocodifica el centro actual del mapa (donde apunta el rayo).
  Future<void> _geocodificarCentro() async {
    if (_currentState != ClientState.selectingRoute) return;
    final centro = _centroActual();
    final req = ++_centroReq;
    if (!_buscandoCentro) setState(() => _buscandoCentro = true);
    final dir = await AddressService.de(centro);
    if (!mounted ||
        req != _centroReq ||
        _currentState != ClientState.selectingRoute) {
      return;
    }
    final texto = dir.vacia ? null : dir.texto;
    setState(() {
      _buscandoCentro = false;
      _centroMapa = centro;
      _centroAddr = texto ?? _sinDireccion;
      _centroError =
          texto == null ? 'No se pudo obtener la dirección exacta.' : null;
    });
  }

  /// Confirma el centro actual como punto de recogida y pasa a ubicar destino.
  ///
  /// La direccion se CONGELA aqui en `_pickupAddr`: el panel de destino, la
  /// solicitud del viaje y el selector de vehiculo leen siempre ese valor.
  Future<void> _confirmarRecogida() async {
    if (_currentState != ClientState.selectingRoute || _pickupConfirmado) {
      return;
    }
    _centroTimer?.cancel();
    final centro = _centroActual();

    // Si el panel ya muestra la direccion de ESTE centro, se congela tal cual:
    // no se vuelve a geocodificar (una respuesta nueva podria devolver otra
    // variante del nombre y parecer que la recogida "cambio sola").
    final mostrada = (_centroAddr ?? '').trim();
    final coincide = _centroMapa != null && _samePoint(_centroMapa!, centro);
    String texto;
    if (mostrada.isNotEmpty && coincide) {
      texto = mostrada;
    } else {
      setState(() {
        _buscandoCentro = true;
        _centroError = null;
      });
      final dir = await AddressService.de(centro);
      if (!mounted ||
          _currentState != ClientState.selectingRoute ||
          _pickupConfirmado) {
        return;
      }
      texto = dir.vacia ? _sinDireccion : dir.texto;
    }

    setState(() {
      _buscandoCentro = false;
      _centroMapa = centro;
      _centroAddr = texto;
      _pickup = centro;
      _pickupAddr = texto; // CONGELADA: ya nadie la sobrescribe
      _pickupTouched = true;
      _pickupConfirmado = true;
      // El destino se elige desde cero, con el mismo centro como punto de
      // partida. No hay ruta ni pines que conservar.
      _dropoff = null;
      _dropoffAddr = null;
      _route = const [];
      _routeKm = null;
      _routeMin = null;
    });
  }

  /// Confirma el destino, traza la ruta por calles y abre el selector de
  /// vehículo. Solo se dibuja la línea: nunca pines de inicio/fin.
  Future<void> _confirmarDestino() async {
    if (_currentState != ClientState.selectingRoute || !_pickupConfirmado) {
      return;
    }
    final pickup = _pickup;
    if (pickup == null) return;
    _centroTimer?.cancel();
    final centro = _centroActual();

    // Nunca mandar a OSRM coordenadas invalidas ni el mismo punto dos veces:
    // eso devolvia 0.0 km y una ruta inexistente.
    if (!_coordValida(pickup) || !_coordValida(centro)) {
      _showError('Las coordenadas del viaje no son válidas.');
      return;
    }
    if (const Distance().as(LengthUnit.Meter, pickup, centro) < 10) {
      _showError(
          'El destino está demasiado cerca de la recogida. Mueve el mapa.');
      return;
    }

    setState(() {
      _buscandoCentro = true;
      _centroError = null;
      _routing = true;
      _route = const [];
      _routeKm = null;
      _routeMin = null;
    });
    final dir = await AddressService.de(centro);
    if (!mounted ||
        _currentState != ClientState.selectingRoute ||
        !_pickupConfirmado) {
      return;
    }
    final texto = dir.vacia ? _sinDireccion : dir.texto;

    final req = ++_routeReq;
    final r = await OsrmService.route(pickup, centro);
    if (!mounted || req != _routeReq) return;

    // Sin geometria o con distancia 0 no hay viaje: se avisa y se queda en el
    // mapa para reintentar, en vez de abrir el selector con "0.0 km".
    if (r == null || r.points.length < 2 || r.distanceMeters <= 0) {
      setState(() {
        _buscandoCentro = false;
        _routing = false;
        _route = const [];
        _routeKm = null;
        _routeMin = null;
      });
      _showError(
          'No se pudo calcular la ruta. Revisa tu conexión e inténtalo de nuevo.');
      return;
    }

    setState(() {
      _buscandoCentro = false;
      _routing = false;
      _centroMapa = centro;
      _centroAddr = texto;
      _dropoff = centro;
      _dropoffAddr = texto; // CONGELADA para el panel y el selector
      _route = r.points;
      _routeKm = r.distanceKm;
      _routeMin = r.durationMinutes;
    });

    await _loadEstimate();
  }

  /// Boton "atras" de la fase de destino: deshace la recogida confirmada y
  /// vuelve al paso 1 con el rayo donde este el mapa, listo para reubicarla.
  ///
  /// Lo que se dejo atras (destino elegido, ruta trazada, direcciones) se
  /// limpia de una vez; en la fase de recogida el pan del panel vuelve a leer
  /// `_centroAddr`, que se regeocodifica enseguida (la cache responde al
  /// instante si el punto no cambio).
  void _volverARecogida() {
    if (_currentState != ClientState.selectingRoute || !_pickupConfirmado) {
      return;
    }
    _centroTimer?.cancel();
    _routeReq++; // invalida rutas/estimaciones en vuelo
    setState(() {
      _pickupConfirmado = false;
      // La recogida vuelve a vivir en el centro del rayo: lo que el usuario
      // vera al volver atras es exactamente ese punto.
      _pickup = _centroActual();
      _pickupAddr = null;
      _dropoff = null;
      _dropoffAddr = null;
      _route = const [];
      _routeKm = null;
      _routeMin = null;
      _routing = false;
      _buscandoCentro = false;
      _centroError = null;
      // NO se pone `_pickupTouched = false`: el GPS no debe pisar el punto
      // del rayo ni por accidente.
      _pickupTouched = true;
    });
    unawaited(_geocodificarCentro());
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
      // El rayo geocodificará este punto en cuanto el mapa se detenga.
      _centroMapa = place.point;
      _centroAddr = place.shortLabel ?? place.displayName;
      _centroError = null;
    });
    _moveMapTo(place.point, zoom: 16);
    _onMapaMovido();
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
    if (pickup == null || dropoff == null) return;
    // Solo cargar estimación si estamos en Paso 1
    if (_currentState != ClientState.selectingRoute) return;
    if (!_coordValida(pickup) || !_coordValida(dropoff)) {
      _showError('Las coordenadas del viaje no son válidas.');
      return;
    }
    // Origen y destino deben ser puntos distintos: con el mismo punto el
    // backend devuelve una tarifa minima y el mapa una ruta de 0.0 km.
    if (const Distance().as(LengthUnit.Meter, pickup, dropoff) < 10) {
      _showError('El destino está demasiado cerca de la recogida.');
      return;
    }

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
        _showError('No hay vehículos disponibles en este momento.');
        return;
      }
      // Saldo real de la billetera y recargo vigente: el selector de pago los
      // necesita para avisar antes de pedir el viaje.
      final tasaRecargo =
          (res['recargo_transferencia'] as num?)?.toDouble() ?? 0.10;
      double saldo = _walletBalance;
      try {
        final fondo = await widget.api.getClientFondo(widget.clientId);
        saldo = (fondo['fondo'] as num?)?.toDouble() ?? saldo;
      } catch (_) {
        // Sin conexion se conserva el ultimo saldo conocido; el backend
        // vuelve a validar al crear el viaje.
      }
      if (!mounted || req != _estReq) return;

      // Transición a Paso 2: cambiar estado Y abrir panel en un solo setState
      setState(() {
        _currentState = ClientState.selectingVehicle;
        _estFareBusy = false;
        _estFareError = false;
        _vehicles = vehiclesList;
        _etaText = res['eta_text'] as String? ?? '--';
        _paymentMethod = res['payment_method'] as String? ?? 'Efectivo';
        _transferSurchargeRate = tasaRecargo;
        _walletBalance = saldo;
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
      _showError('No se pudo calcular la tarifa. Inténtalo de nuevo.');
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
            : _sinDireccion,
        dropoffAddress: (_dropoffAddr ?? '').trim().isNotEmpty
            ? _dropoffAddr!
            : _sinDireccion,
        distanceKm: _routeKm ?? 0,
        durationMin: _routeMin ?? 0,
        etaText: _etaText ?? '--',
        paymentMethod: _paymentMethod,
        walletBalance: _walletBalance,
        transferSurchargeRate: _transferSurchargeRate,
        vehicles: _vehicles,
        initialSelectedIndex: initialIndex < 0 ? 0 : initialIndex,
        numPasajes: _numPasajes,
        equipaje: _equipaje,
        mascota: _mascota,
        onPasajerosChanged: (v) => setState(() => _numPasajes = v),
        onEquipajeChanged: (v) => setState(() => _equipaje = v),
        onMascotaChanged: (v) => setState(() => _mascota = v),
        onConfirm: (selectedIndex, paymentMethod) {
          setState(() {
            _selectedVehicle = _vehicles[selectedIndex];
            _paymentMethod = paymentMethod;
          });
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

  Future<void> _requestTrip({bool isRetry = false}) async {
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
        requestAddress: _pickupAddr ?? _sinDireccion,
        dropoffAddress: _dropoffAddr ?? _sinDireccion,
        paymentMethod: _paymentMethod,
        isRetry: isRetry,
      );
      final tripId = (res['trip_id'] ?? '').toString();
      if (tripId.isEmpty) throw ApiException('No se recibió el trip_id');
      if (!mounted) return;
      // Mientras TripScreen este abierta hay viaje activo: la actualizacion
      // obligatoria no puede interrumpirlo.
      _viajeEnPantalla = true;
      UpdateService.instance.viajeActivo = true;
      // Navegar a TripScreen
      final result = await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TripScreen(
          api: widget.api,
          clientId: widget.clientId,
          tripId: tripId,
          initialEstimate: (res['precio_estimado'] ?? 0).toDouble(),
        ),
      ));
      _viajeEnPantalla = false;
      UpdateService.instance.viajeActivo = false;
      if (result == 'retry' && mounted) {
        // El viaje expiro sin chofer y el pasajero pulso "Volver a pedir
        // viaje". NO se resetea el estado: _requestTrip reutiliza _pickup,
        // _dropoff, _selectedVehicle y el resto de preferencias, crea un
        // viaje nuevo en `requested` y vuelve a abrir el radar. Se manda
        // `is_retry: true` para que el backend aplique el recargo del 10 %.
        await _requestTrip(isRetry: true);
        return;
      }
      // Si el pasajero cerro el recibo (o el viaje fue cancelado), volver al
      // paso 1. En `completed` el reset ocurre SOLO aqui: la pantalla del
      // recibo se queda abierta hasta que el usuario pulse "Finalizar".
      if ((result == 'cancelled' || result == 'completed') && mounted) {
        _resetTripState();
      }
      // El viaje termino: si habia un APK obligatorio pendiente, se avisa
      // ahora (nunca durante el viaje).
      if (mounted) unawaited(_revisarActualizacion());
    } catch (e) {
      _viajeEnPantalla = false;
      UpdateService.instance.viajeActivo = false;
      if (!mounted) return;
      _showError('$e');
      _resetTripState();
      unawaited(_revisarActualizacion());
    }
  }

  /// Consulta la version al backend y, si toca, muestra el aviso bloqueante.
  ///
  /// Un parche se descarga en segundo plano. El dialogo de APK solo aparece
  /// si NO hay viaje activo; si lo hay, queda pendiente para el final.
  Future<void> _revisarActualizacion() async {
    final update = UpdateService.instance;
    update.viajeActivo = _viajeEnPantalla;
    await update.revisar();
    if (!mounted) return;
    await update.mostrarSiHaceFalta(context);
  }

  /// El access y el refresh ya no sirven: se vuelve al Login sin dialogo.
  ///
  /// Los tokens los borra `ApiClient` antes de llamar aqui.
  void _sesionExpirada() {
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await TokenStore.instance.limpiar();
    await prefs.remove('client_id');
    widget.api.token = null;
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
        // Cerrar la sesion COMPLETA: el access/refresh viven en el almacen
        // seguro (flutter_secure_storage), no en SharedPreferences. Si no se
        // limpian, al abrir la app el auto-login intentaba renovar la sesion
        // de la cuenta ya borrada y parecia que no se borro nada.
        await TokenStore.instance.limpiar();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('client_id');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cuenta eliminada')),
        );
        Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            // Legible: el backend responde "Tienes un viaje en curso..." y
            // demas; sin el sufijo tecnico "(HTTP 409)".
            content: Text('No se pudo eliminar: '
                '$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), '')),
          ),
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
            // Sin pines de origen/destino ni recta provisional: durante la
            // selección solo existe el rayo central, y tras confirmar el
            // destino solo la línea azul de la ruta.
            routeColor: const Color(0xFF007AFF),
            routeHaloColor: const Color(0xE6FFFFFF),
            routeWidth: 4,
            pins: [
              // Punto azul de "mi ubicacion" (GPS). Es pequeno a proposito:
              // antes media 40 px + halo de 70 px y se confundia con un
              // circulo de carga atascado en el centro del mapa.
              MapPin(
                _myLoc,
                color: const Color(0xFF007AFF),
                radius: 7,
                haloRadius: 16,
                haloColor: const Color(0x2E007AFF),
              ),
            ],
            // Cada movimiento reinicia la espera de 2 s; al detenerse, el rayo
            // hace un pulso (ver `_onMapaMovido` / `_onMapaQuieto`).
            onCameraMove: _onMapaMovido,
            onCameraIdle: _onMapaQuieto,
          ),
          // Rayo flotante mientras se elige el punto: la punta marca el
          // centro del mapa y flota suavemente (ver `_RayoFlotante`).
          if (_currentState == ClientState.selectingRoute)
            _RayoFlotante(key: _rayoKey),
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
    final nombre = widget.profile.fullName.trim().split(RegExp(r'\s+')).first;
    final enRecogida = !_pickupConfirmado;
    // El boton atras solo existe mientras se esta ubicando el destino en el
    // mapa (Paso 1). Con el panel de vehiculos abierto o esperando chofer la
    // vuelta atras la maneja cada pantalla propia.
    final enDestinoActivo =
        _currentState == ClientState.selectingRoute && !enRecogida;
    final direccion = (_centroAddr ?? '').trim();
    final recogida = (_pickupAddr ?? '').trim();

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Boton atras: solo en la fase de DESTINO. Permite volver a la
              // recogida y reubicarla sin empezar todo el viaje de cero
              // (en el selector de vehiculo ya existe "Cambiar ruta").
              if (enDestinoActivo) ...[
                RoundIconButton(
                  icon: Icons.arrow_back_rounded,
                  size: 38,
                  tooltip: 'Cambiar la recogida',
                  onTap: _volverARecogida,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  enRecogida ? 'Ubica tu recogida' : 'Ubica tu destino',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.tinta,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Mueve el mapa: el rayo marca el punto exacto.',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.secundario,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 12),
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
                          hintText: enRecogida
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
              // Flecha "mi ubicacion": centra el mapa en la posicion real.
              Material(
                color: AppColors.acento,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _useMyLocation,
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
          const SizedBox(height: 10),

          // Dirección del punto al que apunta el rayo. Mientras se resuelve se
          // muestra "Buscando dirección...".
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.campo,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                if (_buscandoCentro)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    enRecogida
                        ? Icons.trip_origin_rounded
                        : Icons.flag_rounded,
                    size: 18,
                    color: _centroError != null
                        ? AppColors.error
                        : (enRecogida ? AppColors.exito : AppColors.ambar),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _buscandoCentro
                        ? 'Buscando dirección...'
                        : (direccion.isNotEmpty
                            ? direccion
                            : 'Mueve el mapa para elegir el punto'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: _centroError != null
                          ? AppColors.error
                          : AppColors.tinta,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Recogida ya confirmada: se mantiene a la vista mientras se elige
          // el destino.
          if (!enRecogida && recogida.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.arrow_upward_rounded,
                    size: 14, color: AppColors.exito),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Recogida: $recogida',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.secundario,
                    ),
                  ),
                ),
              ],
            ),
          ],

          // Métricas reales de la ruta mientras OSRM responde (después el
          // panel de vehículos ocupa la pantalla).
          if (_dropoff != null) ...[
            const SizedBox(height: 12),
            _buildRouteStats(Theme.of(context).colorScheme),
          ],
          const SizedBox(height: 12),

          // Botón grande amarillo: confirma la fase actual del flujo.
          if (_currentState == ClientState.selectingRoute)
            PillButton(
              label: enRecogida ? 'Confirmar recogida' : 'Confirmar destino',
              loading: !enRecogida && (_routing || _estFareBusy),
              loadingLabel: enRecogida ? 'Confirmando...' : 'Trazando ruta...',
              icon: enRecogida
                  ? Icons.check_circle_outline_rounded
                  : Icons.route_rounded,
              height: 56,
              onPressed: _buscandoCentro
                  ? null
                  : (enRecogida ? _confirmarRecogida : _confirmarDestino),
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
      onPerfil: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PerfilScreen(
            api: widget.api,
            profile: widget.profile,
            clientId: widget.clientId,
          ),
        ));
      },
      onPromociones: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PromocionesScreen(api: widget.api),
        ));
      },
      onHistorial: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => HistoryScreen(
            api: widget.api,
            clientId: widget.clientId,
          ),
        ));
      },
      onFondo: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ClientFondoScreen(
            api: widget.api,
            clientId: widget.clientId,
            fullName: widget.profile.fullName,
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
  final double durationMin;
  final String etaText;
  final String paymentMethod;
  final double walletBalance;
  final double transferSurchargeRate;
  final List<VehicleOption> vehicles;
  final int initialSelectedIndex;
  final int numPasajes;
  final bool equipaje;
  final bool mascota;
  final ValueChanged<int> onPasajerosChanged;
  final ValueChanged<bool> onEquipajeChanged;
  final ValueChanged<bool> onMascotaChanged;
  final void Function(int selectedIndex, String paymentMethod) onConfirm;
  final VoidCallback onBack;
  final bool isLoading;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  const _VehicleSelectorStateful({
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.distanceKm,
    this.durationMin = 0,
    required this.etaText,
    required this.paymentMethod,
    required this.walletBalance,
    required this.transferSurchargeRate,
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

  // Estado local de la hoja: el modal vive en su propia ruta, asi que el
  // `setState` de la pantalla de fondo no la reconstruye. Sin estos campos los
  // botones de pasajeros/equipaje/mascota se pulsaban pero la UI no cambiaba.
  late int _numPasajes;
  late bool _equipaje;
  late bool _mascota;

  /// Metodo de pago elegido dentro de la hoja. Vive aqui porque el modal es
  /// su propia ruta y el `setState` del home no lo reconstruye.
  late String _paymentMethod;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialSelectedIndex;
    _numPasajes = widget.numPasajes;
    _equipaje = widget.equipaje;
    _mascota = widget.mascota;
    _paymentMethod = widget.paymentMethod;
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
      durationMin: widget.durationMin,
      etaText: widget.etaText,
      paymentMethod: _paymentMethod,
      walletBalance: widget.walletBalance,
      transferSurchargeRate: widget.transferSurchargeRate,
      onPaymentMethodChanged: (metodo) {
        setState(() => _paymentMethod = metodo);
      },
      vehicles: widget.vehicles,
      selectedIndex: _selectedIndex,
      numPasajes: _numPasajes,
      equipaje: _equipaje,
      mascota: _mascota,
      onPasajerosChanged: (v) {
        setState(() => _numPasajes = v);
        widget.onPasajerosChanged(v);
      },
      onEquipajeChanged: (v) {
        setState(() => _equipaje = v);
        widget.onEquipajeChanged(v);
      },
      onMascotaChanged: (v) {
        setState(() => _mascota = v);
        widget.onMascotaChanged(v);
      },
      onVehicleSelected: (index) {
        setState(() {
          _selectedIndex = index;
        });
      },
      onConfirmTrip: () {
        widget.onConfirm(_selectedIndex, _paymentMethod);
      },
      onBack: widget.onBack,
      isLoading: widget.isLoading,
    );
  }
}

/// Marcador 3D del centro del mapa, con dos animaciones independientes:
///
///  * **Flotar**: sube y baja ±5 px en bucle (1 s por tramo) para que el rayo
///    respire sobre el mapa en vez de quedarse clavado.
///  * **Pulso**: al soltar el mapa (`onCameraIdle`) escala 1.0 → 1.2 → 1.0 en
///    medio segundo, como confirmación de que la vista se detuvo.
///
/// La escala se ancla en `bottomCenter` para que la punta siga marcando el
/// centro exacto del mapa mientras el rayo crece.
class _RayoFlotante extends StatefulWidget {
  const _RayoFlotante({super.key});

  @override
  State<_RayoFlotante> createState() => _RayoFlotanteState();
}

class _RayoFlotanteState extends State<_RayoFlotante>
    with SingleTickerProviderStateMixin {
  static const double _tamano = 32.5;
  static const double _anclaje = -16.25; // mitad del tamaño: punta al centro

  late final AnimationController _flotar;
  late final AnimationController _pulso;
  late final Animation<double> _escala;

  @override
  void initState() {
    super.initState();
    _flotar = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _pulso = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _escala = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.2)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.2, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_pulso);
  }

  /// Rebote de confirmación al detenerse la cámara.
  void pulso() {
    if (mounted) _pulso.forward(from: 0);
  }

  @override
  void dispose() {
    _flotar.dispose();
    _pulso.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.center,
        child: AnimatedBuilder(
          animation: Listenable.merge([_flotar, _pulso]),
          builder: (context, child) {
            return Transform.translate(
              // -5 a +5 px alrededor del anclaje original.
              offset: Offset(0, _anclaje + (_flotar.value * 10 - 5)),
              child: Transform.scale(
                scale: _escala.value,
                alignment: Alignment.bottomCenter,
                child: child,
              ),
            );
          },
          child: Image.asset(
            'assets/icons/rayo_3d.png',
            width: _tamano,
            height: _tamano,
            cacheWidth: 150,
          ),
        ),
      ),
    );
  }
}
