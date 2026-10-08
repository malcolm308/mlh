import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/cancellation_service.dart';
import '../services/address_service.dart';
import '../services/nav_camera.dart';
import '../services/vehicle_types_service.dart';
import '../services/location_service.dart';
import '../services/navigation_mode_service.dart';
import '../services/osrm_service.dart';
import '../models/geo_fix.dart';
import '../services/route_recalculation_service.dart';
import '../services/trip_notification_service.dart';
import '../services/whatsapp_service.dart';
import '../widgets/navigation_map_view.dart';
import '../widgets/cancel_reason_dialog.dart';
import '../widgets/cancel_trip_dialog.dart';
import '../widgets/trip_info_panel.dart';
import 'driver_profile_screen.dart';
import 'driver_settings_screen.dart';
import 'driver_fondo_screen.dart';
import 'history_screen.dart';
import 'support_screen.dart';

class DriverHomeScreen extends StatefulWidget {
  final ApiService api;
  final DriverProfile profile;
  final String driverId;

  const DriverHomeScreen({
    super.key,
    required this.api,
    required this.profile,
    required this.driverId,
  });

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen>
    with SingleTickerProviderStateMixin {
  static const int _offerLimitSecs = 20;
  static const int _lostCloseSecs = 5;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Controlador del mapa, que entrega NavigationMapView al crearse.
  ///
  /// Lo usan los movimientos puntuales de camara (cambio de fase, encuadrar
  /// el trayecto). No se puede crear aqui: el constructor de
  /// MapLibreMapController exige maplibrePlatform, que es interno del
  /// paquete. El seguimiento continuo NO lo usa: de eso se encarga el widget.
  MapLibreMapController? _controlador;
  final WhatsAppService _whatsappService = WhatsAppService();
  final Map<String, String> _addrCache = {};

  /// Ruta que se dibuja en el mapa segun la fase del viaje.
  ///
  /// Antes cada polilinea se insertaba en el `PolylineLayer` por separado. Con
  /// maplibre hay una sola capa de linea, asi que se elige aqui cual se pinta:
  /// la del trayecto en curso durante el viaje, y la de ir a recoger el
  /// pasajero mientras se va a por el.
  ///
  /// Si no hay trazado de OSRM se cae a una recta entre los extremos, que es lo
  /// que hacia el `Polyline` de reserva. Se descarta si coincide con la
  /// posicion actual, que daria una linea de longitud cero.
  List<LatLng> get _rutaVisible {
    if (_tripPhase && _route.length >= 2) return _route;
    if (_pickupPhase && _routeToPickup.length >= 2) return _routeToPickup;

    final destino = _tripPhase ? _activeTrip?.dropoff : _activeTrip?.pickup;
    if (destino == null) return const [];
    if (destino.latitude == _driverPos.latitude &&
        destino.longitude == _driverPos.longitude) {
      return const [];
    }
    return [_driverPos, destino];
  }

  /// Camara de navegacion: sigue al vehiculo, rota con su rumbo y aplica el
  /// tilt. Necesita el `TickerProvider` del State, asi que no se puede
  /// inicializar en la declaracion (aun no existe `this`): se crea en
  /// `initState` y se deja `late`.
  /// Tipos de vehiculo del backend, para pintar las etiquetas correctas.
  ///
  /// Comparte la misma fuente que el registro: la tabla `tariffs` de
  /// PostgreSQL. Si el backend no responde, el servicio deja una lista de
  /// respaldo para que los viajes existentes se sigan mostrando bien.
  final VehicleTypesService _tiposVehiculo = VehicleTypesService();

  /// Limite de cancelaciones del dia.
  ///
  /// Solo cuenta lo que el chofer cancela DESPUES de aceptar. Rechazar una
  /// oferta no pasa por aqui, asi que se puede rechazar todas las veces que
  /// haga falta.
  final CancellationService _cancelacion = CancellationService();

  late final NavigationModeService _nav;

  /// Detecta desvios y pide ruta nueva al backend.
  ///
  /// Se crea aqui y no en la declaracion porque es `ChangeNotifier` y
  /// necesita el `addListener` montado. Lo consume el servicio de navegacion
  /// a traves de la posicion suavizada, nunca con la del GPS crudo.
  late final RouteRecalculationService _recalc;

  /// Suscripcion a las rutas nuevas que devuelve el recalculo.
  StreamSubscription<OsrmRoute>? _subRecalc;

  /// Bandera para no encadenar SnackBars mientras dura una peticion.
  bool _avisandoRecalculo = false;


  LatLng _driverPos = ApiConfig.defaultDriverLocation;
  bool _online = false;
  bool _busy = false;
  bool _loading = false;
  String? _error;

  /// Estado del GPS del dispositivo.
  LocationPermissionState? _gpsState;

  /// El chofer movio el pin a mano: el GPS deja de sobrescribir la posicion.
  bool _manualPos = false;
  StreamSubscription<GeoFix>? _gpsSub;

  Timer? _ticker;
  Timer? _tripPoller;
  Timer? _offerTimer;
  int _offerCountdown = 0;
  DateTime? _offerDeadlineAt;
  Timer? _lostTimer;
  TripOffer? _lostOffer;
  int _lostCountdown = 0;
  TripOffer? _selectedOffer;
  TripOffer? _activeTrip;

  /// Aviso de oferta en el panel de notificaciones, con su sonido y su
  /// contador en el icono.
  ///
  /// No decide el flujo de la oferta ni llama al backend: eso sigue siendo de
  /// la tarjeta de aqui mismo. El servicio solo hace que el telefono suene y
  /// que quede constancia en el panel.
  final TripNotificationService _notif = TripNotificationService.create();

  StreamSubscription<TripNoticeEvent>? _subNotif;

  /// Ofertas que el sondeo ya entrego, por `trip_id`.
  ///
  /// Se guarda para dos cosas: avisar en el panel solo mientras la oferta siga
  /// viva, y poder abrir la tarjeta correcta si el conductor toca el aviso del
  /// panel con la app en segundo plano.
  final Map<String, TripOffer> _ofertaCache = <String, TripOffer>{};

  final Set<String> _declinedTripIds = <String>{};
  List<LatLng> _route = [];
  List<LatLng> _routeToPickup = [];
  double? _toPickupKm;
  double? _toPickupMin;
  double? _tripKm;
  double? _tripMin;
int _routeReq = 0;
  double _todayEarnings = 0;

  /// Fase del viaje usada en el ultimo encuadre de camara, para no repetir
  /// el zoom en cada tick del GPS.
  String? _faseEncuadre;

  /// Firma del trayecto ya encuadrado (destino + fase + puntos de la ruta).
  /// Si no cambia, no se vuelve a mover la camara.
  String? _trayectoEncuadre;

  /// Rumbo con el que se dibuja la flecha de ubicacion.
  ///
  /// Al arrancar un viaje manda el primer tramo de la ruta, no el sensor: con
  /// el coche parado apuntando a otro lado, el sensor dice otra cosa y la
  /// flecha saldria girada hacia una calle en la que no se va a entrar. El
  /// primer tramo de OSRM es por donde se sale de verdad.
  ///
  /// En cuanto el vehiculo se mueve, manda el sensor, que es mas fino. El corte
  /// esta en [ApiConfig.desvioVelocidadCarreteraMps] porque por debajo el GPS
  /// no da rumbo fiable y el filtro lo habria retardado.
  double? _rumboParaFlecha() {
    final vel = _nav.velocidadMps;
    if (vel >= 2.0) {
      final sensor = _nav.rumbo;
      if (sensor != null) return sensor;
    }

    final trazados = _tripPhase ? _route : _routeToPickup;
    if (trazados.length < 2) return null;

    // Primer tramo con dos puntos de verdad consecutivos: la ruta puede venir
    // con puntos repetidos en el origen.
    for (var i = 0; i < trazados.length - 1; i++) {
      final a = trazados[i];
      final b = trazados[i + 1];
      if (a.latitude == b.latitude && a.longitude == b.longitude) continue;
      return NavigationMapView.bearingEntre(
        _nav.debeSeguir ? _nav.posicion : _driverPos,
        b,
      );
    }
    return null;
  }

  /// Estado del viaje en castellano, para el titulo del panel.
  ///
  /// Antes se pintaba `trip.status.toUpperCase()`, o sea el literal interno de la
  /// base de datos en ingles dentro de una interfaz que es toda en espanol.
  /// Un estado desconocido cae al propio valor para no dejar el titulo vacio.
  static String estadoViaje(String status) => switch (status) {
        'accepted' => 'ACEPTADO',
        'driver_arrived' => 'EN EL PUNTO',
        'in_progress' => 'EN CURSO',
        'completed' => 'COMPLETADO',
        'cancelled' => 'CANCELADO',
        'expired' => 'EXPIRADO',
        _ => status.toUpperCase(),
      };

  /// Fase de recogida: el chofer aún va hacia el punto de recogida.
  bool get _pickupPhase =>
      _activeTrip != null &&
      (_activeTrip!.status == 'accepted' ||
          _activeTrip!.status == 'driver_arrived');

  /// Fase de traslado: el chofer va hacia el destino final.
  bool get _tripPhase =>
      _activeTrip != null && _activeTrip!.status == 'in_progress';

  @override
  void initState() {
    super.initState();

    // Se crea aqui porque necesita el `TickerProvider` del State.
    _nav = NavigationModeService(vsync: this);

    // Recalculo de ruta por desvio. El `postJson` por defecto va al backend.
    _recalc = RouteRecalculationService();
    _recalc.addListener(_alCambiarEstadoRecalc);
    _subRecalc = _recalc.onRouteChanged.listen(_alRecibirRutaRecalculada);

    // Tipos de vehiculo: se piden una vez para poder pintar las etiquetas de
    // las ofertas y del viaje. Si falla, el servicio usa la lista de respaldo.
    _tiposVehiculo.cargar();

    _loadTodayEarnings();
    _initGps();
    _initNotificaciones();

    // El servicio de navegacion arranca antes que el mapa: cuando llegue el
    // primer fix ya tiene el GPS a 1 Hz y el sensor de rumbo activos.
    _nav.iniciar();
    // Cada vez que el servicio recalcula la camara hay que repintar el mapa.
    // Se conecta aqui y no dentro del servicio, porque quien compone el
    // `CameraPosition` es el widget, no la logica.
    _nav.alCambiar(_alCambiarCamara);
    // Unico punto donde el tilt se anima: entrar y salir del modo.
    _nav.alCambiarTilt(_alCambiarTilt);
    // Aviso unico de degradacion por rendimiento.
    _nav.alDegradar(_alDegradarTilt);
  }

  /// El servicio ha recalculado la camara: repinta la pantalla.
  ///
  /// No se mueve el mapa aqui. `NavigationMapView` lee los valores del servicio
  /// y compone un unico `CameraPosition` con target, zoom, tilt y bearing, y lo
  /// aplica con `moveCamera` solo cuando algo ha cambiado de verdad.
  ///
  /// Antes esta pantalla llamaba a `_mapController.move(...)` con el offset del
  /// 25 % y luego a `rotate(...)` por separado, porque `flutter_map` no permitia
  /// las dos cosas en una llamada. Con maplibre el offset deja de hacer falta:
  /// el `tilt` nativo hace que el motor situe el punto focal en el tercio
  /// inferior, sin desplazar la camara a mano.
  void _alCambiarCamara() {
    // Se alimenta el detector de desvios con la posicion y velocidad YA
    // filtradas del servicio de navegacion, no con las del GPS crudo. Medir la
    // distancia contra un fix con 30 m de error daria desvios falsos en cada
    // esquina, que es justo lo que el detector debe evitar.
    if (_nav.debeSeguir) {
      _recalc.informarPosicion(_nav.posicion, _nav.velocidadMps);
    }
    if (mounted) setState(() {});
  }

  // ---------------- RECALCULO DE RUTA ----------------

  /// El recalculo ha cambiado de estado: se avisa o se retira el aviso.
  ///
  /// El aviso es un SnackBar corto porque es lo unico que hay: un banner
  /// propio taparia el mapa, que es justo lo que el conductor necesita para
  /// seguir avanzando mientras el backend piensa.
  void _alCambiarEstadoRecalc() {
    if (!mounted) return;
    final estado = _recalc.estado;

    switch (estado) {
      case RouteRecalcState.calculating:
        if (_avisandoRecalculo) return;
        _avisandoRecalculo = true;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('Recalculando ruta…'),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ));

      case RouteRecalcState.error:
      case RouteRecalcState.agotado:
        if (!_avisandoRecalculo) return;
        _avisandoRecalculo = false;
        final agotado = estado == RouteRecalcState.agotado;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(agotado
                ? 'Sin conexión. Se mantiene la ruta anterior.'
                : 'Sin conexión, ruta no actualizada. Reintentando…'),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ));

      case RouteRecalcState.idle:
      case RouteRecalcState.success:
        // El aviso se retira solo: la peticion dura 1-3 s, que es lo que dura
        // el SnackBar.
        _avisandoRecalculo = false;
    }
  }

  /// Llego una ruta nueva del backend.
  ///
  /// Solo se sustituye la geometria que se dibuja. Ni se recrea la capa ni se
  /// toca la camara: la lleva `NavigationMapView` en su siguiente repintado, y
  /// moverla aqui pelearia con el servicio de navegacion.
  void _alRecibirRutaRecalculada(OsrmRoute ruta) {
    if (!mounted) return;
    setState(() {
      if (_tripPhase) {
        _route = ruta.points;
        _tripKm = ruta.distanceKm;
        _tripMin = ruta.durationMinutes;
      } else {
        _routeToPickup = ruta.points;
        _toPickupKm = ruta.distanceKm;
        _toPickupMin = ruta.durationMinutes;
      }
    });
    // El servicio ya tiene la ruta nueva, asi que no vuelve a pedirla.
  }

  void _alCambiarTilt(double objetivo) {
    if (!mounted) return;

    // Al salir del modo, la rotacion se vuelve a cero ANTES de que el tilt
    // empiece a bajar. Bajar el tilt no resetea la rotacion por si sola, y
    // bajarlo antes dejaria el mapa girado mientras se va aplastando.
    if (objetivo <= 0.5) {
      NavCamera.reset();
    }
    setState(() {});
  }

  /// Aviso de degradacion por rendimiento, UNA sola vez por cambio.
  ///
  /// El servicio ya garantiza que no repite: avisa solo al cruzar el umbral, no
  /// en cada frame por debajo de 30 fps.
  void _alDegradarTilt(bool degradado) {
    if (!mounted) return;
    setState(() {});
    if (!degradado) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Vista 3D desactivada para ahorrar batería'),
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _loadTodayEarnings() async {
    try {
      final e = await widget.api.getTodayEarnings(widget.driverId);
      if (!mounted) return;
      setState(() => _todayEarnings = e.totalEarnings);
    } catch (_) {}
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _ticker?.cancel();
    _tripPoller?.cancel();
    _offerTimer?.cancel();
      _lostTimer?.cancel();
      _subNotif?.cancel();
      _notif.dispose();
      _nav.dispose();

    _tiposVehiculo.dispose();
    _subRecalc?.cancel();
    _recalc.removeListener(_alCambiarEstadoRecalc);
    _recalc.dispose();
    super.dispose();
  }

  // ---------------- SERVIDOR ----------------

  Future<void> _toggleOnline() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_online) {
        await widget.api.setDriverStatus(widget.driverId, 'offline');
        _ticker?.cancel();
        _offerTimer?.cancel();
        // Al dejar de aceptar viajes no puede quedar ningun aviso de oferta
        // en el panel: el conductor ya dijo que no las quiere.
        await _notif.shutdown();
        if (!mounted) return;
        setState(() {
          _online = false;
      _selectedOffer = null;
      _lostOffer = null;
      _lostCountdown = 0;
      _declinedTripIds.clear();
    });
        _refreshRoutes();
      } else {
        await widget.api.setDriverStatus(widget.driverId, 'available');
        await widget.api.setDriverLocation(
            widget.driverId, _driverPos.latitude, _driverPos.longitude);
        if (!mounted) return;
        setState(() => _online = true);
        _startTicker();
        await _tick();
      }
    } catch (e) {
      if (!mounted) return;
      _showError('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------- AVISOS DE OFERTA ----------------

  /// Levanta el servicio de avisos y pide permiso para notificar.
  ///
  /// Va en `initState` porque el sondeo arranca enseguida y la oferta tiene que
  /// estar avisada desde la primera, no desde la segunda.
  Future<void> _initNotificaciones() async {
    // Tocar el aviso del panel abre la app y, si la oferta sigue viva, su
    // tarjeta. El servicio solo avisa: la decision es de aqui.
    PlatformNotificationPort.onTap = (tripId) {
      _notif.notifyOpened(tripId);
      _abrirOfertaNotificada(tripId);
    };

    _notif
      ..onExpired = _alExpirarOferta
      ..onTakenByOther = _alTomarOtroOferta;

    // Si el panel no acepta el aviso, la tarjeta de la app sigue siendo la que
    // manda. Solo se informa en el log, no se rompe nada.
    _subNotif = _notif.events.listen((e) {
      if (e.kind == TripNoticeKind.showFailed) {
        debugPrint('[NOTIF] ${e.message}: ${e.offer.tripId}');
      }
    });

    try {
      await _notif.init();
      await _notif.requestPermission();
    } catch (e) {
      debugPrint('[NOTIF] no se pudo inicializar los avisos: $e');
    }
    if (mounted) setState(() {});
  }

  /// El conductor abrio la oferta desde el panel. Se abre su tarjeta si sigue
  /// viva y no hay otra en pantalla.
  void _abrirOfertaNotificada(String tripId) {
    if (!mounted) return;
    if (_selectedOffer != null || _lostOffer != null) return;
    final offer = _ofertaCache[tripId];
    if (offer == null) {
      _showError('Esa oferta ya no esta disponible');
      return;
    }
    _selectOffer(offer);
  }

  /// La oferta se agoto sin respuesta. La tarjeta ya se retira sola por su
  /// cuenta atras; aqui solo se limpia el aviso del panel y se explica.
  void _alExpirarOferta(TripOffer offer) {
    if (!mounted) return;
    _mostrarAviso('La oferta a ${_destino(offer)} expiro sin respuesta');
  }

  /// Otro conductor se llevo el viaje. Para este chofer ya no existe.
  void _alTomarOtroOferta(TripOffer offer) {
    if (!mounted) return;
    _markOfferLost(offer);
    _mostrarAviso('Otro conductor aceptó el viaje a ${_destino(offer)}');
  }

  /// Una oferta dejo de venir en el sondeo. Se consulta su estado para no
  /// confundir una toma de otro conductor con una cancelacion.
  ///
  /// Si el estado no se puede leer, se retira el aviso en silencio: dar un
  /// veredicto que no se puede sostener seria peor que no decir nada.
  Future<void> _retirarAvisoSiDesaparecio(String tripId) async {
    TripOffer? offer;
    try {
      offer = await widget.api.getTrip(tripId);
    } catch (_) {
      offer = null;
    }

    final status = offer?.status ?? '';
    if (status == 'accepted' ||
        status == 'in_progress' ||
        status == 'driver_assigned') {
      await _notif.handleTripTakenByOther(tripId);
      return;
    }
    if (status == 'cancelled' || status == 'rejected') {
      await _notif.handleTripCancelled(tripId);
      return;
    }
    await _notif.handleTripExpired(tripId);
  }

  /// Destino legible de una oferta, para los avisos.
  String _destino(TripOffer offer) {
    final d = offer.dropoffAddress;
    if (d != null && d.trim().isNotEmpty) return d.trim();
    return 'otro destino';
  }

  /// Aviso efimero en la parte de abajo. Se usa en lugar de los avisos de
  /// error porque no son fallos: son el desenlace normal de una oferta.
  void _mostrarAviso(String texto) {
    if (!mounted) return;
    final mq = ScaffoldMessenger.maybeOf(context);
    if (mq == null) return;
    mq.hideCurrentSnackBar();
    mq.showSnackBar(SnackBar(content: Text(texto)));
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 4), (_) => _tick());
  }

  Future<void> _tick() async {
    if (_online && _activeTrip != null) return;
    try {
      final list = await widget.api.getNearbyRequestedTrips(
        _driverPos.latitude,
        _driverPos.longitude,
        driverId: widget.driverId,
      );
      if (!mounted) return;
      final now = DateTime.now().toUtc();
      for (final o in list) {
        final dl = _offerDeadlineRaw(o);
        debugPrint('[OFERTA] trip=${o.tripId} pickup=${o.pickup} '
            'deadline=${dl?.toIso8601String()} ahora=${now.toIso8601String()} '
            'vence=${dl == null ? "sin-plazo" : dl.isAfter(now)}');
      }
      debugPrint('[OFERTA] recibidas=${list.length} online=$_online '
          'activeTrip=${_activeTrip?.tripId} lost=${_lostOffer?.tripId} '
          'selected=${_selectedOffer?.tripId}');
      final offers = list
          .where((o) =>
              o.pickup != null &&
              !_declinedTripIds.contains(o.tripId) &&
              (_offerDeadlineRaw(o) == null ||
                  _offerDeadlineRaw(o)!.isAfter(now)))
          .toList();
      debugPrint('[OFERTA] filtradas=${offers.length} '
          'ids=${offers.map((o) => o.tripId).toList()}');

      // Una oferta que el backend ya no devuelve puede estar tomada por otro
      // conductor, cancelada o simplemente vencida. El sondeo no dice cual, y
      // avisar "otro conductor Daily" de un viaje cancelado seria una falta de
      // respeto, asi que se consulta el estado real antes de acusar a nadie.
      final desaparecidas = _ofertaCache.keys
          .where((id) => !offers.any((o) => o.tripId == id))
          .toList();
      for (final id in desaparecidas) {
        _ofertaCache.remove(id);
        await _retirarAvisoSiDesaparecio(id);
      }

      final selected = _selectedOffer;
      final stillThere =
          selected != null && offers.any((o) => o.tripId == selected.tripId);
      if (_lostOffer == null && selected != null && !stillThere) {
        _markOfferLost(selected);
      } else {
        setState(() {
          if (selected != null && !stillThere) _selectedOffer = null;
        });
      }

      // La tarjeta interna es la interfaz principal de la oferta: se abre en
      // cuanto el sondeo la ve. El aviso del panel es solo el complemento que
      // hace que el telefono suene y quede constancia si no esta mirando.
      for (final o in offers) {
        _ofertaCache[o.tripId] = o;
      }
      _ofertaCache.removeWhere((id, _) => !offers.any((o) => o.tripId == id));

      for (final o in offers) {
        await _notif.showTripRequest(o);
      }

      if (_selectedOffer == null && _lostOffer == null && offers.isNotEmpty) {
        _selectOffer(offers.first);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _setDriverPos(LatLng p) {
    setState(() => _driverPos = p);
    if (_online) {
      widget.api
          .setDriverLocation(widget.driverId, p.latitude, p.longitude)
          .catchError((_) {});
    }
    _refreshRoutes();
  }

  // ---------------- GPS ----------------

  /// Pide permiso, muestra la posicion real y la mantiene actualizada.
  Future<void> _initGps() async {
    final state = await LocationService.ensurePermission();
    if (!mounted) return;

    if (state != LocationPermissionState.granted) {
      setState(() => _gpsState = state);
      // Sin GPS se puede seguir usando la app, pero avisamos de que la
      // posicion no sera la real.
      return;
    }

    // Posicion guardada por el sistema: aparece al instante y luego se
    // sustituye por la del GPS cuando este responde.
    final last = await LocationService.lastKnown();
    if (last != null && mounted) {
      setState(() => _gpsState = LocationPermissionState.granted);
      _setDriverPos(last);
      // El zoom alto de aqui ya no se aplica: con la camara gestionada por
      // `NavigationMapView`, la unica forma de fijarlo seria un
      // `CameraUpdate` suelto, que se pelearia con el siguiente tic del GPS.
      // La vista arranca con el zoom de la fase, que ya es de calle.
    }

    final first = await LocationService.current();
    if (first != null && mounted) {
      setState(() => _gpsState = LocationPermissionState.granted);
        _setDriverPos(first);
        _activarCamaraDeFase();
      } else if (mounted) {
        setState(() => _gpsState = LocationPermissionState.granted);
      }

    _gpsSub?.cancel();

    // Dos flujos con ritmos distintos y papeles distintos:
    //
    //  * `watch()` es el modo FLOTA (10 s / 20 m). Solo actualiza la posicion
    //    que se dibuja y la que ve el backend. Es el que manda cuando el
    //    vehiculo esta parado o sin viaje.
    //  * `watchNavegacion()` (1 Hz + sensor de rumbo) lo consume el servicio de
    //    navegacion, que es quien mueve la camara.
    //
    // Se escuchan los dos porque el modo flota no se puede dejar de usar: al
    // cerrarse la app es el que mantiene la posicion al dia.
    _gpsSub = LocationService.watch().listen((fix) {
      if (!mounted) return;
      // La posicion movida a mano tiene prioridad sobre el GPS.
      if (_manualPos) return;
      setState(() => _gpsState = LocationPermissionState.granted);
      _setDriverPos(fix.position);
    });
  }

  /// Pone la camara en el modo que toca segun la fase del viaje.
  ///
  /// Sin viaje: norte arriba, sin tilt (comportamiento de siempre). Con viaje:
  /// el servicio de navegacion toma el relevo con heading-up y tilt. La
  /// excepcion es el movimiento en idle: si el chofer se desplaza sin carrera,
  /// el modo de conduccion ya esta activo por [NavigationModeService.idleEnMovimiento]
  /// y no se apaga aqui; se apaga solo cuando el vehiculo se queda parado
  /// mas de 5 s.
  void _activarCamaraDeFase() {
    final fase = _faseCamara;
    if (fase == null) {
      if (!_nav.idleEnMovimiento) {
        _nav.apagar();
        final ctl = _controlador;
        if (ctl != null) NavCamera.aplicarFase(ctl, _driverPos, status: null);
      }
      _recalc.detener();
      return;
    }
    // Se pasa la posicion real del GPS: el servicio la usa como punto de partida
    // en vez del punto fijo por defecto, que hacia que el mapa y la flecha
    // aparecieran en el centro de La Habana al arrancar un viaje.
    _nav.activar(fase, posicionConocida: _driverPos);
  }

  /// Vuelve a pedir el permiso y recentra el mapa en la posicion real.
  Future<void> _enableGps() async {
    final state = await LocationService.ensurePermission();
    if (!mounted) return;
    setState(() {
      _gpsState = state;
    });
    if (state == LocationPermissionState.granted) {
      _manualPos = false;
      final p = await LocationService.current();
      if (p != null && mounted) {
        setState(() => _driverPos = p);
        NavCamera.reset();
        final ctl = _controlador;
        if (ctl != null) NavCamera.centrar(ctl, p);
        _setDriverPos(p);
        // Si hay viaje, el modo navegacion recupera el control de la camara.
        if (_faseCamara != null) {
          // `recentrar` ademas fija zoom 18 y tilt 55 mientras siga parado, que
          // es lo que quiere quien pulsa esto: ver la calle de cerca, inclinada.
          _nav.recentrar();
        }
      }
    }
  }

  /// Vuelve a seguir el GPS despues de haber movido el pin a mano.
  void _followGpsAgain() {
    setState(() {
      _manualPos = false;
      _gpsState = LocationPermissionState.granted;
    });
    _centrarEnMi();
  }

  /// Centra el mapa en la posicion del chofer, inclinado.
  ///
  /// Es lo que hace el boton de "mi ubicacion". Tres cosas a la vez:
  ///
  ///  * Vuelve a la posicion real del GPS, deshaciendo cualquier pin movido a
  ///    mano.
  ///  * Recupera el modo navegacion si habia un viaje, que es lo que devuelve
  ///    el seguimiento con rumbo y velocidad.
  ///  * Aplica la inclinacion, que es lo que se le pide al boton.
  ///
  /// El tilt se aplica con `NavCamera.centrar`, no con el del servicio, porque
  /// el servicio solo inclina si [ApiConfig.velocidadMinimaTilt] se supera y
  /// uno va a pulsar esto parado en casi todos los casos. Sin esto, el boton
  /// devolvia la vista a 2D.
  void _centrarEnMi() async {
    final p = await LocationService.current();
    if (!mounted) return;

    setState(() {
      _manualPos = false;
      _gpsState = LocationPermissionState.granted;
      if (p != null) {
      _driverPos = p;
    }
    });
    if (p == null) {
      return;
    }

    NavCamera.reset();
    final ctl = _controlador;
    if (ctl != null) {
      NavCamera.centrar(
        ctl,
        p,
        // `seguir: true` conserva el rumbo en vez de volver al norte arriba:
        // recentrar no significa desorientarse.
        seguir: true,
        tilt: _tiltAlRecentrar,
      );
    }

    // Si hay viaje, el servicio recupera el control y su tilt adaptativo pasa
    // a mandar por encima de este.
    if (_faseCamara != null) {
      _nav.recentrar();
    } else if (mounted) {
      setState(() {});
    }
  }

  /// Inclinacion que aplica el boton de recentrar, en grados.
  ///
  /// El mismo valor con el que entra el mapa al activarse la navegacion, para
  /// que el boton no cambie el aspecto de la vista.
  double get _tiltAlRecentrar => ApiConfig.tiltEntradaNavegacion;


  /// Calcula con OSRM la ruta por carretera conductor->recogida y
  /// recogida->destino, tanto para la oferta seleccionada como para el
  /// viaje activo.
  Future<void> _refreshRoutes() async {
    final req = ++_routeReq;

    LatLng? pickup;
    LatLng? dropoff;
    final active = _activeTrip;
    if (active != null && active.pickup != null) {
      pickup = active.pickup;
      dropoff = active.dropoff;
    } else {
      final offer = _selectedOffer;
      if (offer != null && offer.pickup != null) {
        pickup = offer.pickup;
        dropoff = offer.dropoff;
      }
    }

    if (pickup == null) {
      if (!mounted || req != _routeReq) return;
      setState(() {
        _routeToPickup = const [];
          _toPickupKm = null;
        _toPickupMin = null;
        _tripKm = null;
        _tripMin = null;
      });
      return;
    }

// Con una oferta seleccionada se calculan las dos rutas (resumen del
    // modal); durante la carrera activa solo la correspondiente al tramo en
    // curso:
    //   - fase de recogida ('accepted'/'driver_arrived') ? ruta de recogida.
    //   - fase de traslado ('in_progress') ? ruta hacia el destino.
    final inTripPhase = active != null && active.status == 'in_progress';
    final OsrmRoute? toPickup;
    final OsrmRoute? toDropoff;
    if (inTripPhase) {
      toPickup = null;
      toDropoff = dropoff != null
          ? await OsrmService.route(pickup, dropoff)
          : null;
    } else {
      toPickup = await OsrmService.route(_driverPos, pickup);
      toDropoff = null;
    }
    if (!mounted || req != _routeReq) return;
    setState(() {
      _routeToPickup = toPickup?.points ?? const [];
      _toPickupKm = toPickup?.distanceKm;
      _toPickupMin = toPickup?.durationMinutes;
      _tripKm = toDropoff?.distanceKm;
      _tripMin = toDropoff?.durationMinutes;
    });
    // Si OSRM fallo, `_rutaVisible` se cae a la linea recta entre extremos:
    // se deja constancia para no confundir un fallo de calculo con una ruta
    // rara dibujada. El detalle del error ya lo logueo `OsrmService.route`.
    if (inTripPhase && toDropoff == null && dropoff != null) {
      debugPrint('[OSRM] FALLA - usando fallback en linea recta al destino');
    } else if (!inTripPhase && toPickup == null) {
      debugPrint('[OSRM] FALLA - usando fallback en linea recta a la recogida');
    }
    _encuadrarTrayecto(pickup: pickup, dropoff: inTripPhase ? dropoff : null);

    // El recalculo de desvio solo tiene sentido con una ruta que seguir y un
    // destino. Se arranca DESPUES de fijar `_route`, porque el servicio toma la
    // polilinea tal cual para medir la distancia perpendicular.
    _arrancarRecalc(inTripPhase ? dropoff : pickup, inTripPhase);
  }

  /// Arranca (o reinicia) la deteccion de desvio para el tramo en curso.
  void _arrancarRecalc(LatLng? destino, bool enTraslado) {
    final trazado = enTraslado ? _route : _routeToPickup;
    if (destino == null || trazado.length < 2) {
      _recalc.detener();
      return;
    }
    _recalc.iniciar(ruta: trazado, destino: destino);
  }

  /// Fase del viaje para la que se esta encuadrando el mapa.
  String? get _faseCamara {
    final t = _activeTrip;
    if (t == null) return null;
    if (t.status == 'in_progress') return 'in_progress';
    if (t.status == 'driver_arrived') return 'driver_arrived';
    if (t.status == 'accepted') return 'accepted';
    return 'otra';
  }

  /// Encuadre del trayecto: chofer + destino + ruta, con el zoom de la fase.
  ///
  /// Solo reencuadra cuando cambia la fase o el trayecto. El GPS refresca cada
  /// pocos segundos y, si se reencuadrara en cada tick, el mapa se moveria solo
  /// y el chofer no podria mirarlo ni apartarlo.
  ///
  /// Durante la navegacion esto NO hace nada: del seguimiento continuo se
  /// encarga `_nav`, que mueve la camara cada frame. Aqui solo se.actua en los
  /// saltos discretos de fase, que si exigen reencuadre, y al volver del modo
  /// navegacion.
  void _encuadrarTrayecto({LatLng? pickup, LatLng? dropoff}) {
    final fase = _faseCamara;
    if (fase != _faseEncuadre) {
      _faseEncuadre = fase;
      _trayectoEncuadre = null;
      NavCamera.reset();
      if (fase == null) {
        // Sin viaje: se queda el zoom general, norte arriba y sin tilt.
        _nav.apagar();
        return;
      }
      // Cambio de fase: el servicio de navegacion toma el relevo. Se le pasa la
      // posicion real por el mismo motivo que en [_activarCamaraDeFase].
      _nav.activar(fase, posicionConocida: _driverPos);
    }
    final objetivo = dropoff ?? pickup;
    if (objetivo == null) return;

    // la ruta da la forma real del trayecto; si no hay, con los extremos basta
    final puntos = <LatLng>[_driverPos];
    if (objetivo != _driverPos) puntos.add(objetivo);
    List<LatLng> trazado;
    if (_tripPhase && _route.length >= 2) {
      trazado = _route;
    } else if (_pickupPhase && _routeToPickup.length >= 2) {
      trazado = _routeToPickup;
    } else {
      trazado = const [];
    }
    if (trazado.isNotEmpty) puntos.addAll(trazado);
    if (puntos.length < 2) return;

    final firma = '${objetivo.latitude.toStringAsFixed(5)},'
        '${objetivo.longitude.toStringAsFixed(5)}|$fase|${trazado.length}';
    if (firma == _trayectoEncuadre) return;   // nada nuevo que encuadrar
    _trayectoEncuadre = firma;

    // Mientras la camara sigue al vehiculo no se reencuadra: si se hiciera, el
    // mapa saltaria al trayecto completo y perderia el heading-up. El
    // encuadre completo queda para el boton "ver trayecto".
    if (_nav.debeSeguir) return;

    final ctl = _controlador;
    if (ctl != null) NavCamera.encuadrar(ctl, puntos);
  }

  // ---------------- OFERTA SELECCIONADA ----------------

  void _selectOffer(TripOffer offer) {
    _offerTimer?.cancel();
    _lostTimer?.cancel();
    final now = DateTime.now().toUtc();
    final maxSecs = offer.offerExpiresInSecs ?? _offerLimitSecs;
    final deadline = _offerDeadlineRaw(offer) ??
        now.add(Duration(seconds: maxSecs));
    setState(() {
      _selectedOffer = offer;
      _error = null;
      _lostOffer = null;
      _lostCountdown = 0;
      _offerDeadlineAt = deadline;
      _offerCountdown = deadline
          .difference(now)
          .inSeconds
          .clamp(0, maxSecs);
    });
    _startOfferCountdown();
    _refreshRoutes();
  }

  DateTime? _offerDeadlineRaw(TripOffer o) {
    // El servidor envia los segundos que le quedan al viaje. Es la unica
    // fuente fiable: si el reloj del dispositivo va adelantado, comparar
    // `requested_at` contra DateTime.now() daria la oferta por vencida
    // nada mas recibirla.
    final secs = o.offerExpiresInSecs;
    if (secs != null) {
      return DateTime.now().toUtc().add(Duration(seconds: secs));
    }
    final raw = o.requestedAt;
    if (raw == null || raw.isEmpty) return null;
    final d = DateTime.tryParse(raw);
    if (d == null) return null;
    final utc = (raw.endsWith('Z') || raw.contains('+'))
        ? d.toUtc()
        : DateTime.utc(
            d.year, d.month, d.day, d.hour, d.minute, d.second,
            d.millisecond);
    return utc.add(const Duration(seconds: _offerLimitSecs));
  }

  void _startOfferCountdown() {
    _offerTimer?.cancel();
    _offerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final deadline = _offerDeadlineAt;
      if (deadline == null) return;
      final left = deadline.difference(DateTime.now().toUtc()).inSeconds;
      if (left <= 0) {
        _offerTimer?.cancel();
        final offer = _selectedOffer;
        if (offer != null) {
          _markOfferLost(offer);
        } else if (mounted) {
          setState(() => _offerCountdown = 0);
        }
      } else if (mounted) {
        setState(() => _offerCountdown = left);
      }
    });
  }

  void _markOfferLost(TripOffer offer) {
    _offerTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _selectedOffer = null;
      if (_lostOffer == null) {
        _lostOffer = offer;
        _lostCountdown = _lostCloseSecs;
      }
    });
    _lostTimer?.cancel();
    _lostTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final left = _lostCountdown - 1;
      if (left <= 0) {
        t.cancel();
        setState(() {
          _lostOffer = null;
          _lostCountdown = 0;
        });
        _refreshRoutes();
      } else {
        setState(() => _lostCountdown = left);
      }
    });
  }

  void _dismissOffer() {
    _offerTimer?.cancel();
    _lostTimer?.cancel();
    setState(() {
      _selectedOffer = null;
      _lostOffer = null;
      _lostCountdown = 0;
    });
    _refreshRoutes();
  }

  // ---------------- VIAJE ----------------

  Future<void> _acceptOffer(TripOffer offer) async {
    _offerTimer?.cancel();
    setState(() {
      _loading = true;
      _selectedOffer = null;
      _error = null;
    });
    try {
      await widget.api.acceptTrip(offer.tripId, widget.driverId);
      await widget.api.setDriverStatus(widget.driverId, 'busy');
      final trip = await widget.api.getTrip(offer.tripId);
      if (!mounted) return;
      setState(() {
        _activeTrip = trip;
        _loading = false;
        _route = [];
      });
      _startTripPoller();
      // El limite de cancelaciones se consulta al empezar un viaje: es
      // cuando empieza a contar, y asi el boton llega con el numero correcto
      // desde el primer segundo.
      _cancelacion.cargar(driverId: widget.driverId);
      _refreshRoutes();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('$e');
      await _tick();
    }
  }

  Future<void> _declineOffer(TripOffer offer) async {
    _offerTimer?.cancel();
    // Se marca aqui y no solo en el servidor: el sondeo ocurre cada 4 s y sin
    // esto la tarjeta reapareceria antes de que el backend registre el rechazo.
    _declinedTripIds.add(offer.tripId);
    setState(() {
      _loading = true;
      _selectedOffer = null;
    });
    try {
      await widget.api.declineTrip(offer.tripId, widget.driverId);
      if (!mounted) return;
      setState(() => _loading = false);
      _refreshRoutes();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('$e');
    }
    // Sondeo inmediato para mostrar la siguiente oferta sin esperar al ticker.
    await _tick();
  }

  Future<void> _advanceTrip() async {
    final trip = _activeTrip;
    if (trip == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      switch (trip.status) {
        case 'accepted':
          // Marca la ubicación real de recogida: desde aquí se cuentan los kilómetros.
          await widget.api.setPickup(trip.tripId, _driverPos.latitude,
              _driverPos.longitude);
          await widget.api.updateTripStatus(trip.tripId, 'driver_arrived');
        case 'driver_arrived':
          await widget.api.updateTripStatus(trip.tripId, 'in_progress');
        default:
          break;
      }
final updated = await widget.api.getTrip(trip.tripId);
      if (!mounted) return;
      setState(() {
        _activeTrip = updated;
        _loading = false;
        if (updated.pickup != null) {
        // el chofer acaba de aceptar: encuadra el trayecto con el zoom de
        // esta fase en vez de un zoom fijo
        _encuadrarTrayecto(pickup: updated.pickup);
      }
      });
      // Al pasar a 'in_progress' la ruta de recogida se borra al instante y
      // aparece la ruta hacia el destino.
      await _refreshRoutes();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('$e');
    }
  }

  /// El viaje ya no esta vivo: lo perdimos, lo cancelamos o lo completo otro.
  ///
  /// Es el unico sitio por el que se limpia un viaje en curso, y lo comparten
  /// los tres finales posibles:
  ///
  ///  * El chofer lo cancela desde el boton.
  ///  * El pasajero lo cancela y el backend avisa.
  ///  * El viaje se completa.
  ///
  /// Que sea uno solo importa: cada uno que se le olvide una pieza deja al
  /// chofer con el layout de viaje en curso y sin poder trabajar, que es el peor
  /// fallo que puede tener esto.
  ///
  /// [mostrarAviso] pinta un SnackBar con el motivo. Se puede pasar null para
  /// no molestar, como en la completacion normal.
  Future<void> _alPerderElViaje(String motivo, {bool mostrarAviso = true}) async {
    if (_activeTrip == null) return;

    _tripPoller?.cancel();
    _tripPoller = null;
    _recalc.detener();
    // El modo navegacion se apaga: sin viaje no hay rumbo que seguir ni tilt
    // que mantener. `NavCamera.reset()` olvida la fase y el zoom cacheados; el
    // bearing y el tilt a cero los aplica el siguiente tic del widget, que ya
    // lee el objetivo en 0 al estar apagado el modo.
    _nav.finalizar();
    NavCamera.reset();

    if (!mounted) return;
    setState(() {
      _activeTrip = null;
      _loading = false;
      // La ruta se vacia para que el mapa no siga pintando el trayecto de un
      // viaje que ya no existe.
      _route = [];
      _routeToPickup = [];
      _tripKm = null;
      _tripMin = null;
      _toPickupKm = null;
      _toPickupMin = null;
    });

    // El chofer vuelve a estar disponible para recibir ofertas. Si esto fallara
    // no se interrumpe la limpieza: es peor quedar con un viaje fantasma que no
    // poder trabajar, y el siguiente `setDriverStatus` lo corrige.
    try {
      await widget.api.setDriverStatus(widget.driverId, 'available');
    } catch (_) {
      // Silencioso a proposito, ver arriba.
    }

    if (mostrarAviso && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(motivo),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ));
    }
  }

  Future<void> _completeTrip() async {
    final trip = _activeTrip;
    if (trip == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final done = await widget.api.completeTrip(
        trip.tripId,
        dropoffLat: _driverPos.latitude,
        dropoffLng: _driverPos.longitude,
      );
      await widget.api.setDriverStatus(widget.driverId, 'available');
      await widget.api.setDriverLocation(
          widget.driverId, _driverPos.latitude, _driverPos.longitude);

      // La limpieza pasa por [_alPerderElViaje], el mismo camino que usa la
      // cancelacion. Que sea uno solo evita que a uno se le olvide una pieza y el
      // chofer se quede con el layout de viaje en curso sin poder trabajar.
      await _alPerderElViaje('', mostrarAviso: false);
      if (!mounted) return;
      await _showCompleted(done);
      await _tick();
      await _refreshRoutes();
      await _loadTodayEarnings();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError('$e');
    }
  }

void _startTripPoller() {
    _tripPoller?.cancel();
    _tripPoller = Timer.periodic(
        const Duration(seconds: 4), (_) => _pollActiveTrip());
  }

  // ---------------- COMUNICACI?N CON EL PASAJERO ----------------

  /// Texto predefinido del mensaje de WhatsApp al aceptar la carrera.
  String _mensajeAlPasajero(String? nombre) {
    final saludo = (nombre != null && nombre.isNotEmpty) ? ' $nombre' : '';
    return 'Hola$saludo, soy tu conductor. He aceptado tu viaje. '
        'Estoy en camino.';
  }

  Future<void> _enviarWhatsApp() async {
    final trip = _activeTrip;
    final numero = trip?.clientPhone;
    if (numero == null || numero.trim().isEmpty) {
      _showError('No hay un número de teléfono del pasajero para este viaje.');
      return;
    }
    try {
      await _whatsappService.enviarMensaje(
        numero: numero,
        mensaje: _mensajeAlPasajero(trip?.clientName),
      );
    } on WhatsAppException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _llamarPorWhatsApp() async {
    final trip = _activeTrip;
    final numero = trip?.clientPhone;
    if (numero == null || numero.trim().isEmpty) {
      _showError('No hay un número de teléfono del pasajero para este viaje.');
      return;
    }
    try {
      await _whatsappService.abrirChatParaLlamada(numero: numero);
    } on WhatsAppException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _pollActiveTrip() async {
    final trip = _activeTrip;
    if (trip == null) return;
    try {
      // Reporta la posición al backend (que la reenvía a Traccar) mientras el viaje está activo.
      await widget.api.setDriverLocation(
          widget.driverId, _driverPos.latitude, _driverPos.longitude);

      // Antes de tocar la ruta se consulta el estado del viaje. El sondeo cada
      // 4 s es lo que hace que cuando el PASAJERO cancela desde su app, el
      // chofer se entere y se le quite el layout de viaje en curso, sin tener que
      // reiniciar la suya.
      final actual = await widget.api.getTrip(trip.tripId);
      if (!mounted) return;

      if (!estadosViajeVivos.contains(actual.status)) {
        await _alPerderElViaje(
          actual.status == 'cancelled'
              ? 'El pasajero canceló el viaje'
              : 'El viaje ya no está activo',
        );
        return;
      }

      final pts = await widget.api.getTripRoute(trip.tripId);
      if (!mounted) return;
      setState(() {
        _route = pts.map((p) => p.point).toList();
      });
      await _refreshRoutes();
    } catch (_) {
      // Silencioso: la ruta sigue disponible en el próximo tick.
    }
  }

  // ---------------- DIÁLOGOS ----------------

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  Future<void> _showCompleted(CompletedTrip t) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Viaje completado'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _row('Distancia', '${t.distanceKm} km'),
            _row('Duración', _fmtDuration(t.durationSecs)),
            _row('Base', '${t.baseFare.toStringAsFixed(2)} ${t.currency}'),
            _row('Distancia', '${t.distanceFare.toStringAsFixed(2)} ${t.currency}'),
            _row('Tiempo', '${t.timeFare.toStringAsFixed(2)} ${t.currency}'),
            _row('Comisión ${t.commissionLabel}',
                '-${t.commission.toStringAsFixed(2)} ${t.currency}'),
            if (t.commissionDiscount)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Descuento aplicado: 3er viaje del día con comisión reducida.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
            const Divider(),
            // El total es el precio final del viaje. La comisión ya se
            // desconto del Fondo del chofer, no se resta de aqui.
            _row('Total del viaje',
                '${t.totalFare.toStringAsFixed(2)} ${t.currency}',
                bold: true),
            if (t.appliedRule != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Tarifa horaria: ${t.appliedRule}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('driver_token');
    await prefs.remove('driver_id');
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  String _fmtDuration(int secs) {
    final m = (secs / 60).floor();
    final s = secs % 60;
    return '${m}m ${s}s';
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
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

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          // El mapa ocupa todo el hueco del Stack. La inclinacion y la rotacion las
          // pone `NavigationMapView` con el `tilt` y el `bearing` nativos de
          // MapLibre: no hay `Transform` ni `Matrix4` por en medio, asi que el
          // layout es el natural y la UI no se inclina.
          //
          // Toda la UI flotante de este Stack (menu, GPS, banners, panel
          // inferior) queda como hermana FUERA del mapa.
          Positioned.fill(
            child: NavigationMapView(
              tilt: _nav.tiltActual,
              bearing: _nav.rotacionActual ?? 0.0,
              center: _nav.centroActual ?? _driverPos,
              zoom: _nav.zoomActual ?? ApiConfig.defaultZoom,
              posicionVehiculo: _nav.debeSeguir ? _nav.posicion : _driverPos,
              rumboVehiculo: _rumboParaFlecha(),
              ruta: _rutaVisible,
              onControlador: (c) => _controlador = c,
            ),
          ),
          if (_error != null)
            Positioned(
              top: 64,
              left: 8,
              right: 8,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
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
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: Text(
                    'CN',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                      shadows: [
                        Shadow(color: Colors.black45, blurRadius: 4),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _circularButton(
                  Icons.menu,
                  tooltip: 'Menú',
                  onTap: () => _scaffoldKey.currentState?.openDrawer(),
                ),
              ],
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 24,
            right: 8,
            child: Column(
              children: [
                _circularButton(
                  Icons.notifications_none,
                  tooltip: 'Notificaciones',
                  onTap: _showNotifications,
                ),
                const SizedBox(height: 8),
                _circularButton(
                  _gpsState == LocationPermissionState.granted
                      ? (Icons.gps_fixed)
                      : (Icons.gps_off),
                  tooltip: _gpsState == LocationPermissionState.granted
                      ? 'Recentrar en mi posición'
                      : 'Activar GPS',
                  onTap: _gpsState == LocationPermissionState.granted
                      ? _followGpsAgain
                      : _enableGps,
                ),
              ],
            ),
          ),
          if (_selectedOffer != null || _lostOffer != null)
            _buildOfferOverlay(),
          if (_selectedOffer == null && _lostOffer == null) _buildPanelInferior(),
        ],
      ),
    );
  }

  Widget _circularButton(IconData icon,
      {required VoidCallback onTap, String? tooltip}) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip ?? '',
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: const Color(0xFF333333), size: 22),
          ),
        ),
      ),
    );
  }

  void _showNotifications() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('No tienes notificaciones por el momento'),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Widget _buildOfferOverlay() {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _lostOffer != null ? _dismissOffer : () {},
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Material(
                  color: const Color(0xFFFFFFFF),
                  borderRadius: BorderRadius.circular(22),
                  elevation: 14,
                  shadowColor: Colors.black38,
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                    child: _lostOffer != null
                        ? _buildLostOfferCard(_lostOffer!)
                        : _buildOfferCard(_selectedOffer!),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOfferCard(TripOffer o) {
    const text = Color(0xFF1F2937);
    const muted = Color(0xFF6B7280);
    const cardBg = Color(0xFFF3F4F6);
    final km = _tripKm ?? o.distanceKm;
    final min = _tripMin;
    final toPickupKm = _toPickupKm ?? o.distanciaChoferKm;
    final toPickupTxt = toPickupKm != null
        ? '${toPickupKm.toStringAsFixed(1)} km'
            '${_toPickupMin != null ? ' · ${_toPickupMin!.ceil()} min' : ''}'
        : '-';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Solicitud de viaje',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: text, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF007AFF).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.timer_outlined,
                    size: 14, color: Color(0xFF007AFF)),
                const SizedBox(width: 4),
                Text(
                  'Acepta en: $_offerCountdown s',
                  style: const TextStyle(
                      color: Color(0xFF007AFF),
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _vehicleTypeLabel(o.vehicleType).toUpperCase(),
                    style: const TextStyle(
                        color: text,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: const [
                      Icon(Icons.payments_outlined, size: 16, color: muted),
                      SizedBox(width: 4),
                      Text('Efectivo',
                          style: TextStyle(color: muted, fontSize: 13)),
                    ],
                  ),
                ],
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('PRECIO ESTIMADO',
                      style: TextStyle(color: muted, fontSize: 10)),
                  const SizedBox(height: 2),
                  Text(
                    '${o.precioEstimado?.toStringAsFixed(0) ?? '-'} CUP',
                    style: const TextStyle(
                        color: text, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metricCard('Distancia',
                km != null ? '${km.toStringAsFixed(1)} km' : '-'),
            _metricCard('Tiempo',
                min != null ? '${min.toStringAsFixed(1)} min' : '-'),
            _metricCard('Pasajeros', '${o.numPasajes}'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Al cliente',
                style: TextStyle(
                    color: text, fontSize: 14, fontWeight: FontWeight.w600)),
            Text(
              toPickupTxt,
              style: const TextStyle(color: muted, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _buildRouteCard(o),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _declineOffer(o),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: const Color(0xFFF3F4F6),
                  foregroundColor: const Color(0xFF1F2937),
                  side: const BorderSide(color: Color(0xFFF3F4F6)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.close),
                label: const Text('Rechazar'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : () => _acceptOffer(o),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: const Color(0xFF111827),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.check),
                label: const Text('Aceptar'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _metricCard(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(
                  color: Color(0xFF1F2937),
                  fontSize: 16,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF6B7280), fontSize: 11)),
          ],
        ),
      ),
    );
  }

Widget _buildRouteCard(TripOffer o) {
    const muted = Color(0xFF6B7280);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 24,
              child: Column(
children: [
                  const Icon(Icons.person,
                      size: 18, color: Color(0xFF007AFF)),
                  Expanded(
                    child: Container(
                        width: 2, color: const Color(0xFFD1D5DB)),
                  ),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CheckeredFlag(
                        color: Colors.black, checks: Colors.white),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
if (o.pickup != null) ...[
                    const Text('Recogida',
                        style: TextStyle(color: muted, fontSize: 11)),
                    const SizedBox(height: 2),
                    _addressLine(o, pickup: true),
                  ],
                  const SizedBox(height: 12),
                  if (o.dropoff != null) ...[
                    const Text('Destino',
                        style: TextStyle(color: muted, fontSize: 11)),
                    const SizedBox(height: 2),
                    _addressLine(o, pickup: false),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Línea con la dirección en calles del punto, con coordenadas como
  /// referencia secundaria (o como texto principal si no hay dirección).
  Widget _addressLine(TripOffer o, {required bool pickup}) {
    const muted = Color(0xFF6B7280);
    const text = Color(0xFF1F2937);
    final p = pickup ? o.pickup : o.dropoff;
    if (p == null) return const SizedBox.shrink();
    final addr = _addressOf(o, pickup: pickup);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          addr ?? _fmtCoord(p),
          style: const TextStyle(color: text, fontSize: 13),
        ),
        if (addr != null)
          Text(
            _fmtCoord(p),
            style: const TextStyle(color: muted, fontSize: 10),
          ),
      ],
    );
  }

String _fmtCoord(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

  String _addrKey(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}';

  /// Dirección legible (nombres de calle) de la recogida o del destino.
  ///
  /// Prioriza la dirección que envió el pasajero al crear el viaje; si el
  /// viaje se creó con un pin en el mapa (sin dirección), geocodifica en
  /// segundo plano y actualiza la pantalla cuando responde.
  String? _addressOf(TripOffer o, {required bool pickup}) {
    final provided = pickup ? o.requestAddress : o.dropoffAddress;
    if (provided != null && provided.trim().isNotEmpty) {
      return provided.trim();
    }
    final p = pickup ? o.pickup : o.dropoff;
    if (p == null) return null;
    final key = _addrKey(p);
    final cached = _addrCache[key];
    if (cached != null) return cached.isEmpty ? null : cached;
    unawaited(_loadAddress(p));
    return null;
  }

  Future<void> _loadAddress(LatLng p) async {
    final key = _addrKey(p);
    if (_addrCache.containsKey(key)) return;
    final dir = await AddressService.de(p);
    if (!mounted) return;
    setState(() => _addrCache[key] = dir.texto);
  }

  Widget _buildLostOfferCard(TripOffer o) {
    const text = Color(0xFF1F2937);
    const muted = Color(0xFF6B7280);
    const alert = Color(0xFFDC2626);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFFEE2E2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: alert, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Aceptado por otro chofer',
                      style: TextStyle(
                          color: alert,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Se borrará en: $_lostCountdown s',
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _vehicleTypeLabel(o.vehicleType).toUpperCase(),
                  style: const TextStyle(
                      color: text, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text('${o.numPasajes} pasajero(s) · Efectivo',
                    style: const TextStyle(color: muted, fontSize: 12)),
              ],
            ),
            Text(
              '${o.precioEstimado?.toStringAsFixed(0) ?? '-'} cup',
              style: const TextStyle(
                  color: text, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _dismissOffer,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: const Color(0xFFF3F4F6),
                  foregroundColor: const Color(0xFF1F2937),
                  side: const BorderSide(color: Color(0xFFF3F4F6)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.close),
                label: const Text('Cerrar'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: const Color(0xFFE5E7EB),
                  foregroundColor: const Color(0xFF9CA3AF),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.check),
                label: const Text('Aceptar'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPanelInferior() {
    if (_loading) {
      return const Positioned(
        left: 8,
        right: 8,
        bottom: 8,
        child: _PanelCard(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }
    final trip = _activeTrip;
    if (trip != null) {
      // Panel del viaje en curso: una hoja arrastrable que se abre COLAPSADA
      // (solo destino + precio) y deja el mapa y la flecha de navegacion a la
      // vista. Se despliega con el asa o arrastrando.
      return Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: CollapsibleTripPanel(
          tripId: trip.tripId,
          collapsed: _buildTripResumen(trip),
          expanded: _buildActiveTripPanel(),
        ),
      );
    }
    return Positioned(
      left: 8,
      right: 8,
      bottom: 8,
      child: _buildControlPanel(),
    );
  }

  /// Resumen compacto del viaje para el panel COLAPSADO.
  ///
  /// Solo destino y precio, como se pide: lo que el chofer necesita de un
  /// vistazo sin que el panel le tape la flecha de navegacion del mapa.
  Widget _buildTripResumen(TripOffer t) {
    const text = Color(0xFF1F2937);
    const muted = Color(0xFF6B7280);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CheckeredFlag(color: Colors.black, checks: Colors.white),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Destino',
                  style: TextStyle(fontSize: 10, color: muted)),
              _addressLine(t, pickup: false),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text('Precio',
                style: TextStyle(fontSize: 10, color: muted)),
            Text(
              '${t.precioEstimado?.toStringAsFixed(2) ?? '---'} CUP',
              style: const TextStyle(
                  color: text, fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildControlPanel() {
    const mainText = Color(0xFF333333);
    const secondaryText = Color(0xFF888888);
    final vehicleLabel = widget.profile.vehicleModel.isNotEmpty
        ? widget.profile.vehicleModel
        : (widget.profile.vehicleType ?? 'Vehículo');
    return _PanelCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Mi vehículo',
                        style: TextStyle(color: secondaryText, fontSize: 13)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.directions_car,
                            color: Colors.black87, size: 22),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _vehicleTypeLabel(widget.profile.vehicleType),
                            style: const TextStyle(
                              color: mainText,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Ganancias de hoy',
                        style: TextStyle(color: secondaryText, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(
                      '${_todayEarnings.toStringAsFixed(0)} CUP',
                      style: const TextStyle(
                        color: mainText,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE0E0E0)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _online ? 'Aceptando viajes' : 'Viajes pausados',
                        style: const TextStyle(
                          color: mainText,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _online
                            ? 'Listo para recibir solicitudes'
                            : 'No recibirás nuevas solicitudes',
                        style: const TextStyle(
                            color: secondaryText, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _online,
                  activeTrackColor: const Color(0xFF007AFF),
                  onChanged: _busy ? null : (_) => _toggleOnline(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.info_outline,
                    size: 16, color: secondaryText),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vehicleLabel,
                      style: const TextStyle(
                          color: secondaryText, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Al activar esta opción se te mostrarán en pantalla las solicitudes de viajes.',
                      style: TextStyle(color: secondaryText, fontSize: 12, height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Etiqueta del tipo de vehiculo, desde la configuracion del backend.
  ///
  /// Antes era un `switch` con los cuatro tipos escritos a mano, repetido en
  /// varias pantallas. Si el administrador anadia un tipo nuevo en la tabla
  /// `tariffs` de PostgreSQL, aqui salia el identificador en crudo en vez de la
  /// etiqueta. Ahora delega en [VehicleTypesService], que es la unica fuente.
  String _vehicleTypeLabel(String? type) => _tiposVehiculo.etiquetaDe(type);

  Widget _buildActiveTripPanel() {
    final trip = _activeTrip!;
    final pickup = trip.pickup;
    final nextStep = switch (trip.status) {
      'accepted' => 'Llegué al punto de recogida',
      'driver_arrived' => 'Iniciar viaje',
      'in_progress' => 'Completar viaje',
      _ => null,
    };
    // Sin `_PanelCard`: el asa y el material los pone `CollapsibleTripPanel`,
    // que es el contenedor de este contenido cuando hay viaje en curso.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
            children: [
              const Icon(Icons.route, color: Colors.orangeAccent),
              const SizedBox(width: 8),
              Text('VIAJE EN CURSO · ${estadoViaje(trip.status)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
            ],
          ),
          const SizedBox(height: 10),
if (pickup != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.person, size: 16, color: Color(0xFF1E88E5)),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Recogida',
                          style: TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
                      _addressLine(trip, pickup: true),
                    ],
                  ),
                ),
              ],
            ),
          if (trip.dropoff != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CheckeredFlag(color: Colors.black, checks: Colors.white),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Destino',
                          style: TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
                      _addressLine(trip, pickup: false),
                    ],
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Text('Precio estimado: ${trip.precioEstimado?.toStringAsFixed(2) ?? '---'} CUP'),
          if (trip.clientName != null) Text('Cliente: ${trip.clientName}'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _enviarWhatsApp,
                  icon: const Icon(Icons.chat, size: 20),
                  label: const Text('Mensaje por WhatsApp'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _llamarPorWhatsApp,
                  icon: const Icon(Icons.call, size: 20),
                  label: const Text('Llamar por WhatsApp'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (nextStep != null)
            FilledButton.icon(
              onPressed: trip.status == 'in_progress'
                  ? _completeTrip
                  : _advanceTrip,
              icon: Icon(trip.status == 'in_progress'
                  ? Icons.done_all
                  : Icons.directions_car),
              label: Text(nextStep),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            )
          else
            Text(
              'Estado: ${trip.status}',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),

          // Cancelar viaje.
          //
          // Va DEBAJO de la accion principal y en segundo plano, a proposito:
          // cancelar descuenta una de las tres chances del dia, asi que un toque
          // accidental no puede costar una. El dialogo de confirmacion es lo que
          // protege de verdad, pero un boton que parece secundario tampoco
          // convida a pulsarlo sin querer.
          const SizedBox(height: 8),
          _buildBotonCancelar(trip),
        ],
    );
  }

  /// Boton de cancelar el viaje en curso.
  ///
  /// Se oculta entero cuando el limite diario esta alcanzado: un boton gris que
  /// no hace nada confunde mas que no tenerlo, y el chofer ya ve el aviso en el
  /// panel.
  Widget _buildBotonCancelar(TripOffer t) {
    if (!_cancelacion.limiteAlcanzado) {
      return TextButton.icon(
        onPressed: _cancelacion.cancelando ? null : () => _cancelarViaje(t),
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
          minimumSize: const Size.fromHeight(40),
        ),
        icon: _cancelacion.cancelando
            // El spinner va dentro del boton para que no cambie el alto del
            // panel mientras se espera al backend.
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.cancel_outlined, size: 18),
        label: Text(_cancelacion.etiquetaBoton),
      );
    }

    // Limite alcanzado: se explica, no se ofrece una accion imposible.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.info_outline,
            size: 16, color: Theme.of(context).hintColor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'No puedes cancelar: límite diario alcanzado '
            '(${CancellationService.maximoPorDia}/${CancellationService.maximoPorDia})',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).hintColor,
            ),
          ),
        ),
      ],
    );
  }

  /// Flujo completo de cancelar: confirmar, pedir motivo, llamar al backend.
  ///
  /// El orden importa. Primero la confirmacion, porque cancelar sin想问 no debe
  /// pasar; despues el motivo, que es opcional; y solo entonces se gasta una de
  /// las tres oportunidades del dia.
  Future<void> _cancelarViaje(TripOffer t) async {
    final confirmar = await CancelTripDialog.mostrar(
      context,
      restantes: _cancelacion.restantes,
    );
    if (!confirmar || !mounted) return;

    final motivo = await CancelReasonDialog.mostrar(context);
    if (!mounted) return;

    final resultado = await _cancelacion.cancelarViajeAceptado(
      tripId: t.tripId,
      driverId: widget.driverId,
      motivo: motivo,
    );
    if (!mounted) return;

    switch (resultado) {
      case ResultadoCancelacion.ok:
        // El backend ya cancelo. Se limpia todo por el camino normal de viaje
        // terminado: ruta, modo navegacion y disponibilidad.
        _alPerderElViaje('Viaje cancelado');
      case ResultadoCancelacion.limiteAlcanzado:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Llegaste al límite de 3 cancelaciones de hoy'),
        ));
      case ResultadoCancelacion.viajeNoCancelable:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ese viaje ya no se puede cancelar'),
        ));
      case ResultadoCancelacion.error:
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            _cancelacion.motivoDelError ?? 'No se pudo cancelar',
          ),
        ));
    }
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
                    child: Icon(Icons.directions_car,
                        color: Color(0xFF007AFF), size: 30),
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
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.star,
                                color: Color(0xFFFFD700), size: 16),
                            const SizedBox(width: 4),
                            Text(
                              widget.profile.raiting.toStringAsFixed(1),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline, color: Color(0xFF333333)),
              title: const Text('Perfil del conductor'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DriverProfileScreen(
                    api: widget.api,
                    driverId: widget.driverId,
                    initialProfile: widget.profile,
                  ),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.history, color: Color(0xFF333333)),
              title: const Text('Historial de viajes'),
              onTap: () {
                Navigator.of(context).pop();
                // El conductor va a ver sus solicitudes: lo que hubiera sin
                // revisar ya lo tiene delante, asi que el icono puede quedar
                // en cero.
                _notif.resetBadge();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => HistoryScreen(
                    api: widget.api,
                    driverId: widget.driverId,
                    fullName: widget.profile.fullName,
                  ),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined,
                  color: Color(0xFF333333)),
              title: const Text('Fondo y transferencias'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DriverFondoScreen(
                    api: widget.api,
                    driverId: widget.driverId,
                    fullName: widget.profile.fullName,
                  ),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined, color: Color(0xFF333333)),
              title: const Text('Configuración'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DriverSettingsScreen(
                    api: widget.api,
                    driverId: widget.driverId,
                  ),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.support_agent, color: Color(0xFF333333)),
              title: const Text('Soporte'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SupportScreen(),
                ));
              },
            ),
            const Divider(height: 16),
            ListTile(
              leading: const Icon(Icons.logout, color: Color(0xFF333333)),
              title: const Text(
                'Cerrar sesión',
                style: TextStyle(color: Color(0xFFB3261E)),
              ),
              onTap: _logout,
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  final Widget child;
  const _PanelCard({required this.child});

  @override
  Widget build(BuildContext context) {
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
            child: child,
          ),
        ],
      ),
    );
  }
}

class CheckeredFlag extends StatelessWidget {
  const CheckeredFlag({super.key, required this.color, required this.checks});

  final Color color;
  final Color checks;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _CheckeredFlagPainter(color, checks));
  }
}

class _CheckeredFlagPainter extends CustomPainter {
  const _CheckeredFlagPainter(this.color, this.checks);

  final Color color;
  final Color checks;

@override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cell = w * 0.16;
    final poleX = w * 0.5;
    final flagW = cell * 4;
    final left = poleX - flagW / 2;
    final top = h * 0.10;
    final pole = Paint()
      ..color = color
      ..strokeWidth = w * 0.08
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
        Offset(poleX, h * 0.06), Offset(poleX, h * 0.96), pole);
    for (var r = 0; r < 3; r++) {
      for (var c = 0; c < 4; c++) {
        final black = (r + c).isEven;
        final rect = Rect.fromLTWH(
          left + c * cell,
          top + r * cell,
          cell,
          cell,
        );
        canvas.drawRect(rect, Paint()..color = black ? checks : color);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckeredFlagPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.checks != checks;
}

