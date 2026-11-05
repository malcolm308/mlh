import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/navegacion_geo.dart';
import '../services/osrm_service.dart';
import '../services/ws_cliente.dart';
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
        case 'trip_accepted' ||
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
      _aplicarVista3D();
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
    // El viaje terminado tiene pantalla propia: NO se vuelve al inicio solo.
    // El recibo se queda en pantalla hasta que el pasajero pulse "Finalizar",
    // que es el unico boton que limpia el estado y hace el pop.
    if (t != null && t.status == 'completed') {
      return _buildCompletedScreen(t);
    }
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
                      if (_stepIndex < 4)
                        Positioned(
                          top: 12,
                          left: 12,
                          right: 12,
                          child: _statusBanner(),
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
                    onPressed: () {
                      if (_popped) return;  // Prevent double pop
                      _popped = true;
                      // Si fue cancelado, indicar al home que resetee el estado
                      final result = cancelled ? 'cancelled' : null;
                      Navigator.of(context).pop(result);
                    },
                    icon: const Icon(Icons.check),
                    label: Text(cancelled ? 'Volver al inicio' : 'Listo'),
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
            _row('Chofer', t.driverId ?? 'No asignado'),
            _row('Vehículo', t.vehicleType.isEmpty ? '—' : t.vehicleType),
            _row('Solicitado', t.requestedAt ?? '—'),
            if ((t.requestAddress ?? '').isNotEmpty)
              _row('Recogida', t.requestAddress!),
            if ((t.dropoffAddress ?? '').isNotEmpty)
              _row('Destino', t.dropoffAddress!),
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
