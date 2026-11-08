import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/navegacion_geo.dart';
import '../services/osrm_service.dart';
import '../services/ws_cliente.dart';
import '../theme/app_theme.dart';
import '../widgets/client_map_view.dart';
import '../widgets/ui/glass_sheet.dart';
import '../widgets/ui/pill_button.dart';
import '../widgets/ui/warning_box.dart';

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
  bool _popped = false;  // Flag to prevent double pop
  String? _error;
  Timer? _poll;
  List<LatLng> _route = [];
  LatLng? _driverPos;

  /// Ultimo rumbo CONOCIDO del vehiculo.
  ///
  /// El chófer solo envia bearing cuando anda (por debajo de 3 km/h ninguno
  /// es fiable). Con el conservado, la vista 3D sigue apuntando hacia
  /// adelante aunque el GPS del chofer no envie uno nuevo (luz roja, rotonda,
  /// GPS sin fix momentáneo).
  double? _ultimoRumboVehiculo;

  /// Filtro de posicion (media movil + rechazo de puntos fantasma) y seguidor
  /// de la ruta para calcular el bearing por geometria, no por brujula.
  final FiltroGps _filtroGps = FiltroGps();
  final SeguidorRuta _seguidorRuta = SeguidorRuta();

  /// Ultima velocidad conocida del chofer (km/h), para el zoom dinamico.
  double? _velocidadKmh;

  /// Instante del ultimo push de posicion. Evita que un sondeo con datos mas
  /// viejos pise un fix recien llegado por WebSocket.
  DateTime? _ultimoPushPos;

  /// Primer encuadre del trayecto pendiente (origen + destino + vehiculo).
  bool _encuadreInicialPendiente = true;

  /// `true` mientras la ruta dibujada es la que comparte el chofer (dueño de
  /// la ruta). Evita que el sondeo la pise con la ruta planificada propia.
  bool _rutaDelChofer = false;

  /// WebSocket del cliente: push del viaje activo (posiciones del chofer y
  /// cambios de estado) por encima del sondeo de 3 s, que queda de respaldo.
  final WsCliente _ws = WsCliente();

  /// `true` cuando el mapa sigue al vehiculo.
  ///
  /// En cuanto el pasajero toca el mapa se pone en `false` y la camara pasa a
  /// suya: nadie quiere que el mapa le salte mientras esta mirando otra cosa.
  bool _siguiendo = true;

  /// Hay una peticion `_refresh()` en vuelo.
  ///
  /// El sondeo de 3 s y los eventos del WebSocket pueden solaparse. Sin este
  /// cerrojo dos respuestas competian por pintar el estado y provocaban
  /// rebuilds encadenados (y redimensionados del PlatformView del mapa justo
  /// mientras la camara animaba), que es el escenario del crash nativo.
  bool _refrescando = false;

  /// Llego otra peticion mientras `_refresh()` estaba ocupado: se repite al
  /// terminar para no perder el evento (por ejemplo `driver_arrived`).
  bool _refrescoPendiente = false;

  /// La camara no se mueve hasta este instante.
  ///
  /// Al cambiar de estado el panel inferior cambia de contenido y el mapa se
  /// redimensiona; animar la camara en ese mismo frame es lo que tumbaba la
  /// app en algunos dispositivos. Se deja que el layout se asiente.
  DateTime _pausaCamaraHasta = DateTime.fromMillisecondsSinceEpoch(0);

  /// Zoom de la ultima decision automatica.
  ///
  /// Se guarda para poder distinguir "el vehiculo se acerco y hay que acercar"
  /// de "el usuario ya habia movido el mapa", en cuyo caso no se toca nada.
  double? _zoomAuto;

  /// `true` mientras se envia un bloqueo de chofer al backend.
  bool _bloqueando = false;

  /// Motivos rapidos que ofrece el dialogo de bloqueo.
  static const List<String> _motivosBloqueo = [
    'Conducción peligrosa',
    'Cobro indebido',
    'Falta de respeto',
    'Vehículo en mal estado',
    'Otro motivo',
  ];

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    // Push del viaje: posiciones del chofer y cambios de estado al instante.
    _ws.onDatos = (canal, datos) {
      if (!mounted) return;
      final evento = (datos['event'] ?? '').toString();
      if (evento == 'driver_position') {
        final lat = (datos['lat'] as num?)?.toDouble();
        final lng = (datos['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) return;
        // Push inmediato: filtra el GPS, calcula el bearing sobre la ruta y
        // mueve la camara 3D en el acto (el sondeo tarda 3 s mas).
        _actualizarPosicionChofer(
          lat,
          lng,
          speed: (datos['speed'] as num?)?.toDouble(),
          esPush: true,
        );
        return;
      }
      switch (evento) {
        // `driver_arrived` ("he llegado") tambien cambia el panel y la copia
        // de la pantalla: antes se ignoraba y el cliente no se enteraba hasta
        // el siguiente sondeo de 3 s.
        case 'driver_arrived' ||
              'trip_accepted' ||
              'trip_started' ||
              'trip_cancelled' ||
              'trip_expired' ||
              'trip_completed':
          unawaited(_refresh());
        case 'trip_route' || 'trip_route_updated':
          // El chofer es el DUEÑO de la ruta: replica SU geometria (mismas
          // calles, mismo asistente) en vez de pedir la propia. El evento
          // llega tanto en la ruta inicial como en cada recalculo por desvio.
          final geo = (datos['geometry'] ?? const {}) as Map;
          final coords = geo['coordinates'] as List<dynamic>? ?? const [];
          final pts = <LatLng>[
            for (final c in coords)
              if (c is List && c.length >= 2)
                LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          ];
          if (pts.length >= 2 && mounted) {
            setState(() {
              _route = pts;
              _rutaDelChofer = true;
            });
            _seguidorRuta.reiniciar();
            _aplicarVista3D();
          }
      }
    };
    // arranca el socket (token del usuario sesionado) y suscribe el viaje
    _ws.iniciar(
      clienteId: widget.clientId,
      token: widget.api.token ?? '',
    );
    _ws.suscribirViaje(widget.tripId);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ws.detener();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_popped) return;
    // Un solo refresh a la vez: el sondeo y el WebSocket se solapaban y dos
    // respuestas viejas competian por pintar el estado. Si llega otra
    // peticion mientras tanto, se recuerda y se repite al terminar.
    if (_refrescando) {
      _refrescoPendiente = true;
      return;
    }
    _refrescando = true;
    try {
      final t = await widget.api.getTrip(widget.tripId);
      if (!mounted || _popped) return;
      final estadoAnterior = _trip?.status;
      setState(() {
        _trip = t;
        _error = null;
      });
      if (estadoAnterior != t.status) {
        // Nueva fase: la ruta del chofer de la fase anterior ya no sirve.
        _rutaDelChofer = false;
        _seguidorRuta.reiniciar();
        // El panel cambia de alto al cambiar de fase: se le da un respiro al
        // PlatformView antes de volver a mover la camara.
        _pausaCamaraHasta =
            DateTime.now().add(const Duration(milliseconds: 450));
      }
      if (t.status == 'completed' || t.status == 'cancelled' || t.status == 'expired') {
        _poll?.cancel();
      }
      // IMPORTANTE: al completarse NO se limpia `_trip` ni se hace pop aqui.
      // La pantalla sigue viva y cambia al recibo (`_buildCompletedScreen`).
      // El estado solo se abandona cuando el pasajero pulsa "Finalizar".
      //
      // Si el viaje fue cancelado por el chofer o expiró, notificar al home
      if ((t.status == 'cancelled' || t.status == 'expired') && mounted && !_popped) {
        _popped = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t.status == 'cancelled' 
                ? 'El conductor ha cancelado el viaje' 
                : 'El viaje ha expirado'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        Navigator.of(context).pop('cancelled');
        return;
      }
      // Respaldo del push: el backend cachea posicion/rumbo/velocidad del
      // chofer y el sondeo los entrega. Si el WebSocket cae, la camara 3D
      // sigue moviendose en vez de quedarse congelada.
      if (t.driverLat != null && t.driverLng != null) {
        _actualizarPosicionChofer(
          t.driverLat!,
          t.driverLng!,
          speed: t.driverSpeed,
          esPush: false,
        );
      }
      // La ruta se dibuja en TODOS los estados del viaje, incluyendo
      // `requested` (en espera): el pasajero debe ver el recorrido aunque
      // nadie haya aceptado todavia.
      if (t.driverId != null || t.status == 'requested') {
        await _loadRoute(t.tripId);
      }
    } catch (e) {
      if (mounted && !_popped) setState(() => _error = '$e');
    } finally {
      _refrescando = false;
      if (_refrescoPendiente) {
        _refrescoPendiente = false;
        if (mounted && !_popped) unawaited(_refresh());
      }
    }
  }

  /// Llenado de la ruta segun el estado del viaje:
  ///
  ///  * `requested` / `accepted` / `driver_arrived`: ruta PLANEADA por calles
  ///    entre recogida y destino (OSRM). En `requested` tambien: el pasajero
  ///    ya contenido la ruta real mientras espera, no una recta inventada.
  ///  * `in_progress`: NO se usa el Traccar suelto ni rectas: se recarga la
  ///    ruta planeada recogida->destino. Cada estado hace UNA peticion (la
  ///    cache de [OsrmService] paga el resto del sondeo).
  ///
  /// El fallback en linea recta ya no se dibuja aqui: se pasa un
  /// `straightLine` vacio a proposito (la unica recta SUTIL/punteada existe,
  /// pero solo si OSRM devil ni ni siquiera se toca).
  Future<void> _loadRoute(String tripId) async {
    final t = _trip;
    if (t == null) return;
    // La ruta del chofer manda durante toda la fase. Sin este guard el sondeo
    // de 3 s sustituiria la geometria del chofer (la que dibuja su asistente)
    // por la planificada propia. Se invalida al cambiar de estado y cuando el
    // chofer publica un recalculo nuevo.
    if (_rutaDelChofer) {
      _seguirVehiculo(_driverPos);
      return;
    }
    // RESPALDO del `trip_route_updated`: el evento WS solo llega a quien
    // estaba suscrito en ese instante. Si se perdio el paquete (o el socket
    // cerro), aqui se recupera el trazado VIGENTE del chofer en vez de caerle
    // encima con la ruta planificada vieja. Como maximo 1 intento cada 10 s.
    final delChofer = await _intentarRutaDelChofer(tripId);
    if (delChofer != null && mounted) {
      setState(() {
        _route = delChofer;
        _rutaDelChofer = true;
      });
      _seguidorRuta.reiniciar();
      _seguirVehiculo(_driverPos);
      return;
    }
    final antes = _driverPos;
    try {
      if (t.driverId != null || t.status == 'requested') {
        // Ruta PLANEADA por calles, tanto esperando como en curso.
        final pickup = t.pickupLocation ?? t.requestLocation;
        if (pickup != null && t.dropoffLocation != null) {
          final planificada = await OsrmService.route(pickup, t.dropoffLocation!);
          if (!mounted) return;
          setState(() => _route = planificada?.points ?? const []);
        }
      }
      _seguirVehiculo(antes);
    } catch (_) {}
  }

  /// Ultima vez que se pregunto la ruta del chofer por HTTP.
  ///
  /// El sondeo corre cada 3 s; preguntar la ruta entera a ese ritmo gastaria
  /// data a lo tonto. Con el tope de 10 s basta: es solo el respaldo del WS.
  DateTime? _ultimoIntentoRutaChofer;

  /// Pregunta el trazado compartido por el chofer. Devuelve `null` si no toca
  /// preguntar todavia (throttle) o si el chofer no ha compartido ruta.
  Future<List<LatLng>?> _intentarRutaDelChofer(String tripId) async {
    final ahora = DateTime.now();
    final ultimo = _ultimoIntentoRutaChofer;
    if (ultimo != null && ahora.difference(ultimo).inSeconds < 10) {
      return null;
    }
    _ultimoIntentoRutaChofer = ahora;
    try {
      final pts = await widget.api.getDriverRoute(tripId);
      return pts.length >= 2 ? pts : null;
    } catch (_) {
      // Sin red o sin ruta publicada: no es error para el usuario. La ruta
      // planificada propia sigue siendo el respaldo.
      return null;
    }
  }

  /// Anima la camara 3D (pitch 50 + bearing de la ruta + zoom por velocidad).
  void _aplicarVista3D() {
    if (!_siguiendo || !mounted) return;
    // Cambio de fase reciente: el panel se esta redimensionando y animar la
    // camara ahora mismo es lo que hacia saltar el PlatformView.
    if (DateTime.now().isBefore(_pausaCamaraHasta)) return;
    final t = _trip;
    final vehiculo = _driverPos;
    if (t == null ||
        vehiculo == null ||
        (t.status != 'accepted' && t.status != 'in_progress')) {
      return;
    }
    final rumbo = _rumboParaCamara();
    if (rumbo == null) return;
    unawaited(_mapController.animar3D(
      vehiculo,
      rumbo,
      zoom: ApiConfig.zoomNavegacion(velocidadKmh: _velocidadKmh),
    ));
  }

  /// Rumbo de la camara, SIEMPRE calculado sobre la ruta dibujada.
  ///
  /// No se usa la brujula ni el bearing crudo del GPS del chofer: se hace
  /// route snapping con la posicion suavizada y se toma el angulo hacia el
  /// siguiente punto de la polilinea. Si el coche se para (o el GPS deja de
  /// dar fixes) se conserva el ULTIMO rumbo de ruta, que sigue siendo valido
  /// porque la ruta no cambia de direccion en un semaforo.
  ///
  /// En `accepted` solo se usa cuando la ruta dibujada es la del chofer
  /// (`_rutaDelChofer`), porque la ruta planificada del cliente va de la
  /// recogida al destino y no de donde esta el coche a la recogida.
  double? _rumboParaCamara() {
    final t = _trip;
    final pos = _driverPos;
    if (t != null && pos != null) {
      final usarRuta = t.status == 'in_progress' || _rutaDelChofer;
      if (usarRuta) {
        final deRuta = _seguidorRuta.rumbo(pos, _route);
        if (deRuta != null) {
          _ultimoRumboVehiculo = deRuta;
          return deRuta;
        }
      }
    }
    return _ultimoRumboVehiculo;
  }

  /// Punto unico de entrada de las posiciones del chofer (push y sondeo).
  ///
  /// Filtra el GPS para eliminar saltos, calcula la velocidad implicita si el
  /// backend no la manda y conserva el ultimo rumbo valido. [esPush] decide si
  /// mueve la camara en el acto; en el sondeo lo hace el encuadre posterior,
  /// para no lanzar dos animaciones seguidas sobre el mismo frame.
  void _actualizarPosicionChofer(
    double lat,
    double lng, {
    double? speed,
    required bool esPush,
  }) {
    final ahora = DateTime.now();
    if (!esPush &&
        _ultimoPushPos != null &&
        ahora.difference(_ultimoPushPos!).inSeconds < 5) {
      // Un push reciente es mas fresco que este sondeo.
      return;
    }
    if (esPush) _ultimoPushPos = ahora;

    final suave = _filtroGps.filtrar(LatLng(lat, lng), ahora: ahora);
    final velocidad = speed ?? _filtroGps.velocidadKmh;

    setState(() {
      _driverPos = suave;
      _velocidadKmh = velocidad;
    });

    if (esPush) _aplicarVista3D();
  }

  /// Encuadre automatico del cliente.
  ///
  /// Dos momentos distintos, porque el pasajero necesita cosas distintas:
  ///
  ///  1. Al aparecer el chofer, o el punto de recogida: `fitBounds` con los
  ///     tres puntos (origen, destino y vehiculo). Ahi encaja el trayecto
  ///     entero, que es lo que responde a "de donde salgo y a donde voy".
  ///  2. En cada refresh posterior con viaje ACTIVO y rumbo del chofer: la
  ///     camara 3D ([_aplicarVista3D]) sigue al vehiculo y se adelanta. Sin
  ///     rumbo (chofer parado, viaje sin vehiculo) se mantiene el acompanamien-
  ///     to plano con el norte arriba, con el zoom que toque segun distancia.
  ///
  /// Cuando el pasajero ha tocado el mapa no se hace nada: manda el usuario.
  void _seguirVehiculo(LatLng? antes) {
    if (!_siguiendo) return;
    if (DateTime.now().isBefore(_pausaCamaraHasta)) return;
    final vehiculo = _driverPos;
    final t = _trip;
    if (vehiculo == null || t == null) return;

    // El primer fix del vehiculo (o del viaje) reencuadra el conjunto.
    // `contains` es asincrono porque consulta la region visible al motor; se
    // resuelve sin bloquear el timer, y mientras tanto `_siguiendo` ya se ha
    // comprobado arriba.
    if (antes == null || _encuadreInicialPendiente) {
      _encuadreInicialPendiente = false;
      _encuadrarTrayecto();
    } else {
      unawaited(_reencuadrarSiElVehiculoSalio(vehiculo));
    }

    final rumbo = _rumboParaCamara();
    final activo = t.status == 'accepted' || t.status == 'in_progress';

    // Mientras el chofer rueda: vista 3D, que es la emulacion pedida. La
    // direccion (bearing) la manda él y el motor cancela la animacion previa.
    if (activo && rumbo != null) {
      _aplicarVista3D();
      return;
    }

    // Chofer parado (driver_arrived) o sin rumbo todavia: acompanamiento
    // plano, con el zoom que toque por lo cerca que este. Reencuadrar todo el
    // trayecto cada 3 s haria que el mapa le temblase al pasajero.
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
    // Accion explicita del usuario: no espera al asentamiento del panel.
    _pausaCamaraHasta = DateTime.fromMillisecondsSinceEpoch(0);
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
      if (!mounted || _popped) return;
      _poll?.cancel();
      
      // Marcar como popped para evitar double pop
      _popped = true;
      
      // NO llamar a _refresh() aquí - causaría double pop
      // Pop directamente con resultado 'cancelled'
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Viaje cancelado'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
      Navigator.of(context).pop('cancelled');
    } catch (e) {
      if (!mounted || _popped) return;
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

  @override
  Widget build(BuildContext context) {
    final t = _trip;
    // El viaje terminado tiene pantalla propia: NO se vuelve al inicio solo.
    // El recibo se queda en pantalla hasta que el pasajero pulse "Finalizar",
    // que es el unico boton que limpia el estado y hace el pop.
    if (t != null && t.status == 'completed') {
      return _buildCompletedScreen(t);
    }
    return Scaffold(
      // Sin AppBar: el mapa ocupa tambien la franja superior. La X de salida
      // flota sobre el mapa para no robarle ancho a la vista ni dejar una
      // barra con el codigo del viaje (dato tecnico que no aporta nada).
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
                        // Fase 1: SIN recta de dos puntos en el viaje. Si
                        // OSRM falla, no se dibuja nada: la app re-pide en
                        // el siguiente sondeo de 3 s.
                        straightLine: const [],
                        // Ruta real por calles: AZUL OSCURO, grosor 5 (Fase 1).
                        // La recta de dos puntos SOLO queda como respaldo si
                        // OSRM fallo, y sale PUNTEADA y sutil (ver wrapper).
                        routeColor: const Color(0xFF0047B3),
                        routeWidth: 5,
                        // Fallback punteado, azul muy tenue: visible pero no
                        // confundible con la ruta real.
                        straightColor: const Color(0x33007AFF),
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
                      // Salir del seguimiento sin ocupar una barra entera: la
                      // X flota arriba a la izquierda sobre el mapa. El estado
                      // ya se ve en el stepper del panel inferior.
                      Positioned(
                        top: 0,
                        left: 0,
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: FloatingActionButton.small(
                              heroTag: 'salirViaje',
                              tooltip: 'Salir (el viaje continúa)',
                              backgroundColor: Colors.white,
                              foregroundColor: AppColors.tinta,
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Icon(Icons.close),
                            ),
                          ),
                        ),
                      ),
                      // Boton flotante "Centrar": SIEMPRE visible, para que el
                      // pasajero pueda volver a la vista 3D del vehiculo en
                      // cualquier momento. Si ya va siguiendo, el toque
                      // re-aplica el encuadre; la proxima indicacion del
                      // sondeo (3 s) re-anima la camara con bearing + tilt.
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          heroTag: 'recentrar',
                          tooltip: 'Volver a seguir al vehiculo (vista 3D)',
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

  Widget _buildDetailsPanel() {
    final t = _trip!;
    final scheme = Theme.of(context).colorScheme;
    final steps = ['Solicitado', 'Chofer', 'Recogida', 'En curso', 'Completado'];
    const stepIcons = [
      Icons.access_time_rounded,
      Icons.directions_car_outlined,
      Icons.location_on_outlined,
      Icons.navigation_outlined,
      Icons.check_rounded,
    ];
    final cancelled = t.status == 'cancelled' || t.status == 'expired';
    final expirado = t.status == 'expired';
    final buscando = t.status == 'requested' || t.driverId == null;

    // Hoja con tope de altura: el contenido completo puede crecer (radar,
    // chofer, fichas y tarifa) y sin tope desbordaria en pantallas chicas.
    final maxAlto = MediaQuery.of(context).size.height * 0.62;

    return Material(
      color: Colors.white,
      elevation: 0,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      clipBehavior: Clip.antiAlias,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxAlto),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Asa de la hoja.
                Center(
                  child: Container(
                    width: 42,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD2D6DB),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // ---------------- STEPPER HORIZONTAL ----------------
                Row(
                  children: [
                    for (var i = 0; i < steps.length; i++) ...[
                      if (i > 0) const SizedBox(width: 2),
                      Expanded(
                        child: Column(
                          children: [
                            Icon(
                              stepIcons[i],
                              size: 20,
                              color: _stepColor(i, cancelled),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              steps[i],
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: (i == _stepIndex && !cancelled)
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: (i == _stepIndex && !cancelled)
                                    ? AppColors.tinta
                                    : AppColors.secundario,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (i < steps.length - 1)
                        Container(
                          height: 2,
                          width: 10,
                          margin: const EdgeInsets.only(bottom: 18),
                          decoration: BoxDecoration(
                            color: (!cancelled && i < _stepIndex)
                                ? AppColors.acento
                                : AppColors.borde,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                    ],
                  ],
                ),
                const SizedBox(height: 14),

                // ---------------- ESTADO / CHOFER ----------------
                if (buscando && !cancelled)
                  _cardBuscando()
                else if (t.driverId != null)
                  _tarjetaChofer(t),
                if (cancelled) ...[
                  if (expirado)
                    const WarningBox(
                      title: 'No encontramos chóferes disponibles',
                      message:
                          'Ningún chófer tomó el viaje a tiempo. Vuelve a '
                          'pedirlo: estás a un toque.',
                      icon: Icons.search_off_rounded,
                    )
                  else
                    const WarningBox(
                      title: 'Viaje cancelado',
                      message:
                          'Este viaje terminó sin completarse. Si lo cancelaste '
                          'por error, solicita uno nuevo.',
                      icon: Icons.info_outline_rounded,
                    ),
                  const SizedBox(height: 10),
                ],

                // ---------------- FICHAS DE DATOS ----------------
                Row(
                  children: [
                    Expanded(
                      child: _ficha(
                        'CATEGORÍA',
                        t.vehicleType,
                        Icons.local_taxi_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ficha(
                        'SOLICITADO',
                        (t.requestedAtLocal ?? t.requestedAt ?? '—')
                            .split(',')
                            .join(' · '),
                        Icons.schedule_rounded,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // ---------------- TARIFA ESTIMADA ----------------
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF8D6),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFF3E4A8)),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TARIFA ESTIMADA',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: AppColors.ambar,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Al final se cobra lo recorrido, no lo estimado.',
                              style: TextStyle(
                                  fontSize: 11, color: AppColors.secundario),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        _precio(t),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.tinta,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!,
                        style: TextStyle(color: scheme.error, fontSize: 12)),
                  ),

                // ---------------- CANCELAR / LISTO ----------------
                if (!cancelled && _stepIndex < 4)
                  _botonCancelar()
                else if (_stepIndex == 4 || cancelled)
                  PillButton(
                    label: cancelled ? 'Volver a pedir viaje' : 'Listo',
                    icon: cancelled
                        ? Icons.refresh_rounded
                        : Icons.check_rounded,
                    onPressed: () {
                      if (_popped) return; // Prevent double pop
                      _popped = true;
                      // Si fue cancelado, indicar al home que resetee el estado
                      final result = cancelled ? 'cancelled' : null;
                      Navigator.of(context).pop(result);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Nombre completo del precio con la moneda del viaje.
  String _precio(ClientTrip t) {
    final m = t.currency.isNotEmpty ? t.currency : 'CUP';
    final v = t.totalFare ?? t.precioEstimado;
    return v == null ? '— $m' : '${v.toStringAsFixed(2)} $m';
  }

  /// Color del icono del stepper: el paso ACTIVO amarillo de marca, los
  /// superados en ambar y los futuros en gris.
  Color _stepColor(int i, bool cancelled) {
    if (cancelled) return AppColors.deshabilitadoTexto;
    if (i < _stepIndex) return AppColors.ambar;
    if (i == _stepIndex) return AppColors.acento;
    return AppColors.deshabilitadoTexto;
  }

  /// Tarjeta del radar de busqueda (estado `requested`, diseno B):
  /// fondo ambar suave, punto pulsante y copia amable.
  Widget _cardBuscando() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8D6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF3E4A8)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.ambar,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Buscando el chófer más cercano',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ambar,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Te avisaremos en cuanto uno acepte el viaje',
                  style: TextStyle(fontSize: 12, color: AppColors.secundario),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Ficha de dato (Categoria / Solicitado): etiqueta gris, valor en
  /// negrita y chip de icono a la derecha.
  Widget _ficha(String etiqueta, String valor, IconData icono) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.campo,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borde),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  etiqueta,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: AppColors.secundario,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  valor,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.tinta,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              color: AppColors.acentoSuave,
              shape: BoxShape.circle,
            ),
            child: Icon(icono, size: 17, color: AppColors.ambar),
          ),
        ],
      ),
    );
  }

  /// Boton "Cancelar viaje": fondo rojo MUY palido, texto e icono rojos.
  Widget _botonCancelar() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton.icon(
        onPressed: _cancelling ? null : _cancel,
        icon: _cancelling
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFFD93840)))
            : const Icon(Icons.close_rounded),
        label: Text(_cancelling ? 'Cancelando...' : 'Cancelar viaje'),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFFBEAEA),
          foregroundColor: const Color(0xFFD93840),
          disabledBackgroundColor: const Color(0xFFFBEAEA),
          disabledForegroundColor:
              const Color(0xFFD93840).withValues(alpha: 0.5),
          elevation: 0,
          shape: const StadiumBorder(),
          textStyle:
              const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  /// Pantalla de recibo al completarse el viaje.
  ///
  /// Se construye con el `ClientTrip` que ya esta en memoria (el backend lo
  /// refresca por WS/sondeo). No se borra nada ni se navega: el viaje sigue
  /// "abierto" en esta pantalla hasta que el pasajero pulse "Finalizar".
  Widget _buildCompletedScreen(ClientTrip t) {
    final scheme = Theme.of(context).colorScheme;
    final moneda = t.currency.isNotEmpty ? t.currency : 'CUP';
    final total = t.totalFare ?? t.precioEstimado;
    String dinero(double? v) => v == null ? '—' : '${v.toStringAsFixed(2)} $moneda';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Viaje completado'),
        // Sin flecha atras: salir sin ver el recibo seria repetir el bug.
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade600, size: 76),
            const SizedBox(height: 10),
            const Text(
              '¡Viaje completado!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Gracias por viajar con TaxiRapid',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 22),
            Card(
              elevation: 0,
              color: scheme.primaryContainer,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 18),
                child: Column(
                  children: [
                    Text('Total pagado',
                        style: TextStyle(color: scheme.onPrimaryContainer)),
                    const SizedBox(height: 6),
                    Text(
                      total == null ? '—' : total.toStringAsFixed(2),
                      style: TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.bold,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    Text(moneda,
                        style: TextStyle(
                            fontSize: 15, color: scheme.onPrimaryContainer)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text('Recibo',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const Divider(height: 18),
            _row('Distancia recorrida',
                t.distanciaKm == null ? '—' : '${t.distanciaKm!.toStringAsFixed(2)} km'),
            _row('Tarifa base', dinero(t.baseFare)),
            _row('Por distancia', dinero(t.distanceFare)),
            _row('Por tiempo', dinero(t.timeFare)),
            const Divider(height: 18),
            _row('TOTAL', dinero(total), bold: true),
            const SizedBox(height: 22),
            Text('Conductor y vehículo',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const Divider(height: 18),
            _row('Chofer', _nombreChofer(t)),
            _row('Vehículo', t.vehicleType.isEmpty ? '—' : t.vehicleType),
            _row('Solicitado', t.requestedAtLocal ?? t.requestedAt ?? '—'),
            if ((t.requestAddress ?? '').isNotEmpty)
              _row('Recogida', t.requestAddress!),
            if ((t.dropoffAddress ?? '').isNotEmpty)
              _row('Destino', t.dropoffAddress!),
            // Contacto directo mientras el viaje esta en curso: llamar o
            // WhatsApp con el CHOFER (sin recopilar ningun dato del cliente).
            if (t.driverPhone != null && t.driverPhone!.isNotEmpty) ...[
              const SizedBox(height: 12),
              _botonesContacto(t.driverPhone!),
            ],
            // El bloqueo tamien vive en el recibo: es donde el pasajero
            // recuerda que no quiere volver a viajar con este chofer.
            if (t.driverId != null) ...[
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _bloqueando ? null : () => _bloquearChofer(t),
                  icon: _bloqueando
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.block_rounded, size: 16),
                  label: const Text('Bloquear chófer'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.ambar,
                    textStyle: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                    minimumSize: const Size(0, 34),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 28),
            FilledButton.icon(
              // Unico punto que cierra el viaje y devuelve al inicio.
              onPressed: _finalizarViaje,
              icon: const Icon(Icons.check),
              label: const Text('Finalizar'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Cierra la pantalla del recibo y limpia el estado del viaje.
  ///
  /// Devuelve `'completed'` al home para que este vuelva al paso 1. Antes de
  /// esto no se toca nada: el recibo queda visible todo el tiempo que haga
  /// falta, aunque el WebSocket se caiga o lleguen eventos repetidos.
  void _finalizarViaje() {
    if (_popped) return;
    _popped = true;
    _poll?.cancel();
    Navigator.of(context).pop('completed');
  }

  /// Fila etiqueta-valor del recibo.
  ///
  /// El valor va en un `Expanded` con wrap: antes las direcciones largas se
  /// salian del ancho (clipping "RecogidaPaseo de Martí...") y no se podian
  /// leer completas.
  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.w500, height: 1.25)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                softWrap: true,
                style: TextStyle(
                    height: 1.25,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal),
              ),
            ),
          ],
        ),
      );

  /// URL absoluta de la foto de perfil del chofer (el backend la manda como
  /// ruta relativa `/trips/{id}/driver-photo`).
  String? _fotoChofer(ClientTrip t) {
    final raw = t.driverProfilePictureUrl?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw.startsWith('http') ? raw : '${ApiConfig.baseUrl}$raw';
  }

  /// Tarjeta del chofer asignado (diseno B): foto con anillo amarillo de
  /// marca, nombre en negrita y debajo la ficha del vehiculo
  /// (tipo • modelo • matricula), con los botones de contacto en pildora.
  Widget _tarjetaChofer(ClientTrip t) {
    final foto = _fotoChofer(t);
    final tipo = t.vehicleType.trim();
    final modelo = t.driverVehicleModel?.trim();
    final placa = t.driverVehiclePlate?.trim();
    final detalle = [
      if (tipo.isNotEmpty) tipo,
      if (modelo != null && modelo.isNotEmpty) modelo,
      if (placa != null && placa.isNotEmpty) 'Matrícula $placa',
    ].join(' • ');

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.campo,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.borde),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Anillo amarillo de marca alrededor de la foto facial.
              Container(
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.acento, width: 2.5),
                ),
                child: CircleAvatar(
                  radius: 26,
                  backgroundColor: AppColors.acentoSuave,
                  foregroundImage: foto == null ? null : NetworkImage(foto),
                  onForegroundImageError: foto == null ? null : (_, _) {},
                  child: const Icon(Icons.person,
                      size: 28, color: AppColors.ambar),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'TU CHOFER',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                        color: AppColors.secundario,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _nombreChofer(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.tinta,
                      ),
                    ),
                    if (detalle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        detalle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.secundario,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (t.driverPhone != null && t.driverPhone!.isNotEmpty) ...[
            const SizedBox(height: 12),
            _botonesContacto(t.driverPhone!),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _bloqueando ? null : () => _bloquearChofer(t),
              icon: _bloqueando
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.block_rounded, size: 16),
              label: const Text('Bloquear chófer'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.ambar,
                textStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pide el motivo y bloquea al chofer del viaje.
  ///
  /// El bloqueo lo guarda el backend por usuario y chofer (idempotente): si ya
  /// estaba bloqueado solo se actualiza el motivo. La lista se ve luego en
  /// "Chóferes bloqueados" del menu lateral.
  ///
  /// El error del backend se muestra TAL CUAL en el aviso: con un mensaje
  /// generico el pasajero no distingue un fallo de red de un rechazo del
  /// servidor, y el bloqueo "no hace nada" sin pista de por que.
  Future<void> _bloquearChofer(ClientTrip t) async {
    final driverId = t.driverId;
    if (driverId == null || driverId.isEmpty || _bloqueando) return;

    final motivo = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: GlassSheet(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Bloquear chófer',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.tinta,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'No volverás a recibir viajes de ${_nombreChofer(t)}. '
                'Cuéntanos qué pasó.',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.secundario, height: 1.35),
              ),
              const SizedBox(height: 14),
              for (final m in _motivosBloqueo)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: AppColors.campo,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => Navigator.of(ctx).pop(m),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                m,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.tinta,
                                ),
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded,
                                size: 20, color: AppColors.secundario),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 2),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancelar'),
              ),
            ],
          ),
        ),
      ),
    );

    if (motivo == null || !mounted) return;

    setState(() => _bloqueando = true);
    try {
      await widget.api.blockDriver(
        driverId: driverId,
        tripId: t.tripId,
        motivo: motivo,
      );
      if (!mounted) return;
      _aviso_('Chófer bloqueado. No volverás a emparejarte con él.');
    } catch (e) {
      if (!mounted) return;
      _aviso_('No se pudo bloquear al chófer: $e');
    } finally {
      if (mounted) setState(() => _bloqueando = false);
    }
  }

  /// Nombre legible del chofer. El id de Mongo NUNCA se pinta en la interfaz
  /// (igual que el del cliente): si el backend aun no manda el nombre se usa
  /// un texto generico.
  String _nombreChofer(ClientTrip t) {
    final nombre = t.driverName?.trim();
    if (nombre != null && nombre.isNotEmpty && nombre != t.driverId) return nombre;
    return 'Chofer asignado';
  }

  /// Telefono en formato internacional para wa.me: Cuba = prefijo 53.
  ///
  /// Los numeros locales se guardan con 8 digitos (movil empieza en 5, fijo
  /// en 2). Si ya viene con prefijo ('+53...'), no se toca.
  String _telefonoWa(String telefono) {
    final solo = telefono.replaceAll(RegExp(r'\D'), '');
    if (solo.length == 8 && (solo.startsWith('5') || solo.startsWith('2'))) {
      return '53$solo';
    }
    return solo;
  }

  /// Abre el dialer del telefono o el chat de WhatsApp con el chofer.
  void _comunicar(String telefono, {required bool whatsapp}) async {
    if (whatsapp) {
      final uri = Uri.https(
        'wa.me',
        '/${_telefonoWa(telefono)}',
        {'text': 'Hola, soy el cliente del viaje'},
      );
      try {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok) throw Exception('WhatsApp no disponible');
      } catch (e) {
        _aviso_('WhatsApp no se pudo abrir. Revisa que esté instalado.');
      }
      return;
    }
    final uri = Uri.parse('tel:$telefono');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw 'El dialer no abrió';
    } catch (e) {
      _aviso_('Llamada no se pudo iniciar.');
    }
  }

  void _aviso_(String mensaje) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(mensaje), behavior: SnackBarBehavior.floating));
  }

  /// Botones Llamar / WhatsApp en pildora, compartidos por el panel del viaje
  /// y el recibo.
  ///
  ///  * WhatsApp: verde palido con borde verde suave (accion preferida).
  ///  * Llamar: azul palido con borde azul suave.
  Widget _botonesContacto(String telefono) => Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _comunicar(telefono, whatsapp: true),
              icon: const Icon(Icons.chat_outlined, size: 18),
              label: const Text('WhatsApp'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE9F6EE),
                foregroundColor: const Color(0xFF1E7A3D),
                disabledBackgroundColor: const Color(0xFFE9F6EE),
                elevation: 0,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: const StadiumBorder(
                  side: BorderSide(color: Color(0xFFBFE3CD)),
                ),
                textStyle: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _comunicar(telefono, whatsapp: false),
              icon: const Icon(Icons.phone_rounded, size: 18),
              label: const Text('Llamar'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFEAF2FE),
                foregroundColor: const Color(0xFF1A73E8),
                disabledBackgroundColor: const Color(0xFFEAF2FE),
                elevation: 0,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: const StadiumBorder(
                  side: BorderSide(color: Color(0xFFBBD3F5)),
                ),
                textStyle: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      );
}
