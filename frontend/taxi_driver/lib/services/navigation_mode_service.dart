import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/scheduler.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../api_config.dart';
import '../models/geo_fix.dart';
import 'camara_libre.dart';
import 'filtro_gps.dart';
import 'heading_filter.dart';
import 'location_service.dart';
import 'map_matching_service.dart';
import 'traza_fichero.dart';

/// Estado de la camara de navegacion.
enum ModoNavegacion {
  /// Sin viaje: norte arriba, sin rotacion, sin tilt. Es el comportamiento de
  /// siempre que tuvo la app.
  apagado,

  /// Camara bloqueada al vehiculo, con heading-up y tilt.
  siguiendo,

  /// El usuario ha cogido el mapa con la mano: la camara es suya y el servicio
  /// no la toca hasta que pulse "Recentrar".
  explorando,
}

/// Camara de navegacion viva: sigue al vehiculo, rota con su rumbo y aplica
/// un tilt con perspectiva.
///
/// Por que vive en un servicio y no dentro de `NavCamera`:
///
///  * el rumbo llega a ~50 Hz del sensor y la posicion a 1 Hz del GPS, con
///    ritmos distintos; mezclarlos necesita estado propio;
///  * hay que interpolar en cada frame (un [Ticker]) y `NavCamera` esta pensado
///    para mover la camara solo en eventos discretos (cambio de fase, encuadre);
///  * hay que arbitrar los gestos del usuario: si el chofer toca el mapa, el
///    servicio suelta la camara y espera al boton de recentrar.
class NavigationModeService {
  NavigationModeService({required TickerProvider vsync})
    : _ticker = vsync.createTicker(_callbackTic);

  /// Adaptador para el [Ticker].
  ///
  /// Hace falta porque en un inicializador de campo no se puede referenciar
  /// `this`, asi que no se puede pasar `_alTic` directamente. Se declara despues
  /// del constructor a proposito: es un metodo, no un campo.
  static void _callbackTic(Duration elapsed) =>
      _instanciaActual?._alTic(elapsed);

  /// Instancia viva, solo para que el callback estatico del ticker la alcance.
  ///
  /// Hay una sola camara de navegacion en la app, asi que una referencia
  /// estatica es suficiente y evita la indireccion de una closure por frame.
  static NavigationModeService? _instanciaActual;

  // ---------------- configuracion ----------------

  /// Buffer circular con N = 5 muestras.
  ///
  /// Del buffer solo se lee la velocidad suavizada (que decide el zoom y el
  /// indicador de la interfaz). Su campo de rumbo no lo consulta nadie desde que
  /// el heading-up salio de la ruta: se sigue alimentando porque es lo que lleva
  /// la media movil de velocidad, y lo que se pasa como rumbo es un dato a pelo.
  final BufferCircularRumbo _buffer = BufferCircularRumbo();

  /// Encaje de la posición sobre la ruta. Corrige el "coche por los edificios"
  /// del GPS urbano; el rumbo sigue siendo GPS + Kalman, no sale de aqui.
  final MapMatchingService _mapMatching = MapMatchingService();

  /// Filtro de la posición real. Se aplica ANTES del map-matching: el encaje
  /// corrige la calle, no el ruido del sensor. Antes se encajaba el fix crudo y
  /// el marcador heredaba cada rebote del GPS.
  final FiltroGps _filtroGps = FiltroGps();

  /// Última posición filtrada del GPS, sin encajar.
  LatLng? _posicionFiltrada;

  /// Precisión horizontal del último fix, en metros.
  double? _precisionMetros;

  /// Tope de extrapolacion entre fixes.
  ///
  /// 3 s. Pasado esto ya no se sabe donde esta el coche, y seguir proyectando
  /// lo saca de la calle.
  static const double _extrapolacionMaxima = 3.0;

  /// Tope del avance recto cuando el coche esta FUERA de ruta.
  ///
  /// No se puede seguir la polilinea (seria la calle que acaba de abandonar),
  /// pero tampoco conviene inventar una posicion lejana: 30 m bastan para que
  /// el punto no parezca congelado entre dos fixes y no lo sacan del barrio.
  static const double _avanceFueraRutaMaximoMetros = 30.0;

  /// Velocidad maxima usada para el avance estimado (54 km/h).
  static const double _velocidadMaximaExtrapoladaKmh = 54.0;

  /// A partir de aqui se considera que la senal GPS esta debil.
  static const double _avisoGpsDebilSegundos = 1.5;

  /// Cuanto se acerca la camara al CENTRO y al ZOOM por frame (a 60 Hz).
  ///
  /// El rumbo ya NO usa este valor: tiene su propia respuesta, [_respuestaRotacion].
  /// 0.12 son ~135 ms de constante de tiempo, suficiente para que el vehiculo no
  /// se vea atrasado respecto al marcador sin que el mapa tiemble con el ruido
  /// del GPS a 1 Hz.
  static const double _respuesta = 0.12;

  /// Respuesta de la ROTACION por frame (a 60 Hz).
  ///
  /// Estaba en 0.035 (~470 ms): sumado al Kalman lento del rumbo, el mapa tardaba
  /// varios segundos en girar en una curva y la flecha apuntaba por un lado
  /// mientras el mapa miraba por otro. 0.22 llega al 90 % del giro en ~160 ms.
  static const double _respuestaRotacion = 0.22;

  /// Si el error angular es grande, se acelera todavía más la rotación.
  static const double _giroCamaraGrados = 12.0;
  static const double _respuestaGiroCamara = 0.45;

  final Ticker _ticker;

  // ---------------- estado ----------------

  ModoNavegacion _modo = ModoNavegacion.apagado;
  ModoNavegacion get modo => _modo;

  /// `true` si la camara sigue al vehiculo.
  bool get siguiendo => _modo == ModoNavegacion.siguiendo;

  /// `true` si el usuario tiene el mapa cogido.
  bool get explorando => _modo == ModoNavegacion.explorando;

  /// Fase del viaje para la que se esta aplicando la camara.
  String? _fase;

  /// Ultimo fix recibido.
  GeoFix? _fix;

  /// Encaje calculado para [fix]. Se recalcula SOLO cuando llega un fix nuevo:
  /// `_recalcularObjetivo` corre en cada frame (~60 Hz) y si el map-matching se
  /// llamara ahi, su histeresis de 3 muestras se cumpliria en 50 ms en vez de
  /// 3 s. La extrapolacion si se recalcula por frame.
  GeoFix? _fixAjustado;
  PuntoRuta? _ajusteActual;

  /// Posicion actual, extrapolada entre fixes. Es la que se dibuja y la que
  /// sigue la camara.
  LatLng _pos = ApiConfig.defaultDriverLocation;
  LatLng get posicion => _pos;

  /// Posicion real del ultimo fix, sin extrapolar. Al backend se le manda esta,
  /// nunca la proyectada: un punto inventado falsearia su posicion real.
  LatLng get posicionReal => _fix?.position ?? _pos;

  /// Posicion real YA FILTRADA, sin encajar sobre la ruta.
  ///
  /// Es la que se dibuja cuando el vehiculo esta fuera de la ruta y la que
  /// alimenta al detector de desvios. Sin viaje tambien es la posicion del
  /// marcador: antes se pintaba el fix crudo a 1 Hz y el ruido se veia en el
  /// mapa.
  LatLng get posicionFiltrada => _posicionFiltrada ?? _fix?.position ?? _pos;

  /// Precision horizontal del ultimo fix, en metros.
  double? get precisionMetros => _precisionMetros;

  /// `true` si el vehiculo esta sobre la ruta que se sigue.
  bool get enRuta => _mapMatching.enRuta;

  /// `true` si ya llego al menos un fix del GPS.
  ///
  /// Lo usa la camara libre (sin viaje) para no centrar en el punto por defecto
  /// antes de tener una posicion de verdad.
  bool get tieneFix => _fix != null;

  /// Velocidad del ultimo fix en km/h, sin suavizar.
  ///
  /// La camara libre la usa para decidir si el movimiento basta para calcular
  /// rumbo. Durante un viaje manda la velocidad filtrada del buffer.
  double? get velocidadRealKmh => _fix?.velocidadKmh;

  /// Rumbo filtrado en grados (0 = norte), o `null` si no hay dato.
  double? _rumbo;
  double? get rumbo => _rumbo;

  /// Ultimo rumbo GPS valido, para no perder la orientacion.
  ///
  /// Cuando el coche se para o el GPS no junta dos fixes con desplazamiento
  /// suficiente, el mapa se queda en el ultimo rumbo conocido en vez de saltar
  /// al norte.
  double? _rumboRetenido;
  double? get rumboRetenido => _rumboRetenido;

  /// Rumbo medido por el movimiento real del GPS y suavizado con Kalman 1D
  /// circular. Es la UNICA fuente de orientacion durante el viaje.
  final RumboMovimiento _rumboGps = RumboMovimiento();

  /// Momento del fix anterior, para medir cuantos segundos han pasado entre dos
  /// posiciones y descartar los saltos imposibles del GPS.
  int? _ultimoFixMs;

  /// `true` si el ultimo fix dio un salto que no puede ser movimiento real.
  bool _fixConSalto = false;

  /// Velocidad suavizada en km/h.
  double _velocidadKmh = 0;
  double get velocidadKmh => _velocidadKmh;

  /// Posicion del fix anterior, para el salto imposible.
  LatLng? _fixAnterior;

  // Direccion de la ruta

  /// Trazado que se esta siguiendo ahora mismo, en el orden del viaje.
  ///
  /// Llega desde la pantalla con [informarRuta] y se conserva solo para
  /// diagnostico (cuantos puntos tiene la ruta viva). Ya NO orienta el mapa: el
  /// rumbo sale del movimiento real del GPS, ver [_aplicarOrientacion].
  List<LatLng> _ruta = const [];

  /// `true` si hay un viaje al que orientar el mapa.
  ///
  /// Es `_fase != null`: sin viaje no hay destino, y sin destino no hay rumbo que
  /// valga. El mapa se queda entonces en norte arriba y sin tilt.
  bool get _hayViajeActivo => _fase != null;
  bool get hayViajeActivo => _hayViajeActivo;

  // Dead reckoning. Se guarda en el reloj MONOTONO del servicio (Stopwatch),
  // no en el del fix: `_extrapolar` corre en cada frame del ticker y necesita
  // comparar siempre contra la misma referencia.
  int? _ultimoFixRelojServicioMs;

  /// `true` cuando llevamos demasiado tiempo sin un fix de posicion.
  ///
  /// Se muestra en la interfaz para que el chofer sepa que el punto se esta
  /// estimando, no midiendo. Se limpia en cuanto llega un fix nuevo.
  bool _gpsDebil = false;
  bool get gpsDebil => _gpsDebil;

  // Camara interpolada: el objetivo es lo que se quiere, el actual es lo que se
  // va moviendo hacia el. Se guardan los dos para poder interpolar sin saltos.
  LatLng? _centroObjetivo;
  double? _zoomObjetivo;
  double? _rotacionObjetivo;

  LatLng? _centroActual;
  double? _zoomActual;
  double? _rotacionActual;

  // Histeresis
  int? _quietoDesdeMs;
  int? _enMarchaDesdeMs;

  // Rendimiento
  double _fps = 60.0;
  final double _fpsMedia = 0;
  int? _bajoFpsDesdeMs;
  int? _altoFpsDesdeMs;
  bool _tiltDegradado = false;

  /// Se avisa UNA vez de cada degradacion o recuperacion, para que la pantalla
  /// pueda mostrar el aviso sin repetirlo en cada frame.
  void Function(bool degradado)? _alDegradar;

  /// Registra el aviso de degradacion.
  void alDegradar(void Function(bool degradado)? fn) => _alDegradar = fn;

  void _avisarDegradacion(bool degradado) => _alDegradar?.call(degradado);

  /// Tilt que se persigue ahora mismo, ya degradado por rendimiento.
  ///
  /// Se mueve con una rampa de [ApiConfig.rampaTiltGradosPorSegundo] y nunca
  /// de golpe: el objetivo sale de la velocidad, pero el camino se recorre
  /// despacio para que no se vea como un tirón al salir de un semaforo.
  double _tiltActual = ApiConfig.tiltDegradado;

  /// Tilt y zoom que impone el recentrar, o `null` cuando manda la velocidad.
  ///
  /// Los usa [recentrar]. El tilt se fuerza porque parado no habria inclinacion,
  /// y el zoom porque el de la fase suele estar mas abierto de lo que se quiere
  /// al situarse sobre el vehiculo.
  ///
  /// Se limpian en cuanto el GPS vuelve a marcar velocidad, para que no se
  /// conviertan en un valor fijo que congele la vista adaptativa.
  double? _tiltForzado;
  double? _zoomForzado;

  /// Suscripciones internas.
  StreamSubscription<GeoFix>? _subFix;

  // ---------------- ciclo de vida ----------------

  /// Prepara el servicio. No mueve el mapa: eso lo hace [activar].
  ///
  /// Se separa para que la pantalla pueda crear el servicio en `initState` y
  /// decidir despues si hay viaje activo.
  void iniciar() {
    if (_subFix != null) return;
    _instanciaActual = this;

    // Se pide el GPS a 1 Hz SIN sensor de rumbo.
    //
    // El heading-up sale del movimiento real del GPS + Kalman (ver
    // [_aplicarOrientacion]), no de la brujula. Se apago del todo y no solo de
    // dejar de leerla: [LocationService.watchNavegacion] avisa al nativo con
    // `sensor: false`, de modo que Android no registra el listener y no llegan
    // ~50 eventos por segundo por el canal. En un taxi durante un viaje son
    // unas 180.000 notificaciones que no se usan para nada.
    _subFix = LocationService.watchNavegacion(
      usarSensor: false,
    ).listen(_alRecibirFix);
  }

  void dispose() {
    if (_instanciaActual == this) _instanciaActual = null;
    _subFix?.cancel();
    _desactivarMedicionFps();
    _ticker.dispose();
  }

  /// Activa el modo navegacion para la fase indicada.
  ///
  /// [rumboInicial] siembra el filtro de rumbo con el ultimo valor del modo
  /// libre. Solo se aplica al arrancar un viaje (transicion de apagado a activo):
  /// asi el mapa no salta al norte mientras el GPS junta dos fixes con
  /// desplazamiento suficiente. El filtro lo corrige con cada muestra.
  ///
  /// Cambiar de fase reevalua el encuadre y dispara el unico momento en el que se
  /// toca el tilt (entrar o salir del modo). El tilt NUNCA se anima por tic: la
  /// perspectiva repinta la capa entera y hacerlo cada frame deja el mapa a 20
  /// fps.
  ///
  /// Si la fase no cambia no hace nada: es el guardado contra reencuadrar en cada
  /// fix del GPS.
  void activar(
    String? status, {
    LatLng? posicionConocida,
    double? rumboInicial,
  }) {
    if (_fase == status && _modo != ModoNavegacion.apagado) return;
    final estabaApagado = _modo == ModoNavegacion.apagado;
    _fase = status;

    if (status == null) {
      apagar();
      return;
    }

    // Siembra el rumbo al arrancar el viaje, no en cada cambio de fase: el
    // valor que llega es el ultimo del modo libre y solo sirve para el salto
    // inicial. Despues manda el GPS.
    if (estabaApagado && rumboInicial != null) {
      _rumboGps.sembrar(rumboInicial);
      // Orienta la camara YA, sin esperar al primer fix. [_recalcularObjetivo]
      // vuelve antes de tocar nada si todavia no llego ningun GPS, y sin esto
      // el mapa arrancaba mirando al norte para girar de golpe un segundo
      // despues, justo el salto que quiere evitar la siembra.
      _aplicarOrientacion();
    }

    // Siembra la posicion con la que ya se sabe, en vez de esperar al primer
    // fix de 1 Hz. Sin esto, [_pos] sigue valiendo el punto fijo por defecto de
    // `ApiConfig.defaultDriverLocation` (el centro de La Habana) y el mapa, y
    // con el el marcador del vehiculo, aparecen ahi en vez de donde esta el
    // coche. Se nota al aceptar un viaje parado: la flecha salta y parece que
    // desaparece.
    if (posicionConocida != null) _pos = posicionConocida;

    // El filtro no debe arrastrar muestras de la fase anterior. Si se conoce la
    // posicion se siembra con ella, para que el primer fix real no se mezcle con
    // un historial viejo.
    if (estabaApagado) {
      _filtroGps.reiniciar();
      _precisionMetros = null;
      if (posicionConocida != null) {
        _posicionFiltrada = _filtroGps.filtrar(posicionConocida);
      } else {
        _posicionFiltrada = null;
      }
    }

    _modo = ModoNavegacion.siguiendo;
    _iniciarTicker();
    _activarMedicionFps();
    _recalcularObjetivo();
    notificar();
    debugPrint('[NAV] modo navegacion ACTIVADO fase=$status pos=$_pos');

    // Unico sitio donde se toca el tilt: entrar o salir del modo. Adentro la
    // rampa por frame se encarga sola.
    //
    // Se entra ya inclinado ([ApiConfig.tiltEntradaNavegacion]) en vez de
    // arrancar en 0 y subirlo con el primer fix. Recoger un viaje parado no
    // es momento de ver el mapa aplanarse y luego inclinarse: el conductor
    // esta quieto, mirando la calle, y el angulo le hace falta ya. Al arrancar
    // en movimiento, la rampa lo lleva igual al valor de velocidad en ~2 s.
    if (estabaApagado) {
      _tiltActual = _tiltDegradado
          ? ApiConfig.tiltReducidoPorRendimiento
          : ApiConfig.tiltEntradaNavegacion;
      _notificarCambioTilt();
    }
  }

  /// Corta el modo navegacion y deja el mapa como estaba.
  void apagar() {
    final estabaSiguiendo = _modo == ModoNavegacion.siguiendo;
    _modo = ModoNavegacion.apagado;
    _fase = null;
    _rumbo = null;
    _ruta = const [];
    _fixAjustado = null;
    _ajusteActual = null;
    _quietoDesdeMs = null;
    _enMarchaDesdeMs = null;
    _centroObjetivo = null;
    _rotacionObjetivo = null;
    _filtroGps.reiniciar();
    _posicionFiltrada = null;
    _precisionMetros = null;
    _ticker.stop();
    _desactivarMedicionFps();
    notificar();
    if (estabaSiguiendo) _notificarCambioTilt();
  }

  /// Detiene el modo navegacion al terminar o cancelarse el viaje.
  ///
  /// A diferencia de [apagar], aqui se deja la camara en el punto en el que
  /// estaba: si el mapa volviera de golpe al centro de La Habana seria jarringo.
  void finalizar() {
    _modo = ModoNavegacion.apagado;
    _fase = null;
    _rumbo = null;
    _ruta = const [];
    _fixAjustado = null;
    _ajusteActual = null;
    _enMarchaDesdeMs = null;
    _quietoDesdeMs = null;
    _filtroGps.reiniciar();
    _posicionFiltrada = null;
    _precisionMetros = null;
    _ticker.stop();
    notificar();
  }

  /// El usuario ha movido el mapa con la mano: suelta la camara.
  ///
  /// Se llama desde `onPositionChanged` cuando `hasGesture` es `true`. flutter_map
  /// marca con `hasGesture: false` sus propias llamadas, asi que `true` significa
  /// gesture del usuario sin ambiguedad.
  void usuarioExplorando() {
    if (_modo == ModoNavegacion.apagado) return;
    _modo = ModoNavegacion.explorando;
    _centroObjetivo = null;
    _rotacionObjetivo = null;
    _ticker.stop();
    notificar();
  }

  /// El usuario ha pulsado "Recentrar": vuelve al modo seguimiento.
  ///
  /// Recupera ademas el detalle de calle ([ApiConfig.zoomRecentrar]) y el angulo
  /// de ciudad ([ApiConfig.tiltRecentrar]). El zoom lo elige recentrar y no la
  /// fase porque el chofer que pulsa esto quiere ver la calle que tiene delante,
  /// no un encuadre de conjunto. El tilt se fuerza porque recentrar no cambia la
  /// velocidad, y por tanto el tilt adaptativo daria 0 justo en el momento en que
  /// mas falta hace la perspectiva.
  ///
  /// Sin viaje activo no hace nada: no hay modo navegacion al que volver, y la
  /// camara la lleva [NavCamera]. La excepcion es el movimiento en idle: si el
  /// chofer se esta desplazando sin carrera, el modo de conduccion esta vivo y
  /// recentrar debe recuperar el control, como durante un viaje.
  void recentrar() {
    // Sin viaje no hay modo navegacion al que volver: el mapa va en norte
    // arriba y lo lleva [NavCamera]. Con viaje, el rumbo sale del GPS + Kalman y
    // se conserva hasta el siguiente fix.
    if (!_hayViajeActivo) return;
    _modo = ModoNavegacion.siguiendo;
    _quietoDesdeMs = null;
    _enMarchaDesdeMs = null;
    _buffer.clear();
    _tiltForzado = ApiConfig.tiltRecentrar;
    _zoomForzado = ApiConfig.zoomRecentrar;
    _iniciarTicker();
    _recalcularObjetivo();
    _notificarCambioTilt();
    notificar();
  }

  /// Entra en el modo navegacion.
  ///
  /// Es el equivalente publico de [activar] con la semantica del enunciado: el
  /// `AnimationController` de [NavigationMapView] escucha [alCambiarTilt] y anima
  /// de 0 al objetivo adaptativo.
  void enterMode([String? status]) {
    _tiltDegradadoPorFpsAntesDeEntrar = _tiltDegradado;
    activar(status ?? _fase ?? 'in_progress');
  }

  /// Sale del modo navegacion.
  ///
  /// El orden importa y lo hace cumplir quien llama, no este metodo: primero hay
  /// que llamar a `MapController.rotate(0)` y despues a [exitMode], porque bajar
  /// el tilt no resetea la rotacion por si sola.
  void exitMode() {
    _tiltActual = ApiConfig.tiltDegradado;
    apagar();
  }

  /// Estado de degradacion previo a la entrada, para no perder un aviso ya
  /// mostrado si el dispositivo ya venia degradado.
  bool _tiltDegradadoPorFpsAntesDeEntrar = false;

  /// Si el tilt estaba degradado antes de la ultima [enterMode].
  ///
  /// Permite que el widget decida si tiene que avisar al usuario: si ya se
  /// degrado en una ventana anterior, el aviso se dio entonces.
  bool get tiltDegradadoAlEntrar => _tiltDegradadoPorFpsAntesDeEntrar;

  /// Se avisa de un cambio en el objetivo de tilt, para que el widget lo anime.
  ///
  /// Se dispara solo al entrar y al salir del modo, nunca por tic del GPS: es el
  /// unico sitio donde el `AnimationController` tiene permiso a repintar.
  void Function(double objetivo)? _alCambiarTilt;

  /// Registra el callback que anima el tilt.
  void alCambiarTilt(void Function(double objetivo)? fn) => _alCambiarTilt = fn;

  void _notificarCambioTilt() => _alCambiarTilt?.call(tiltObjetivo);

  /// Tilt que corresponde al modo navegacion, en grados.
  ///
  /// Es un valor FIJO de [ApiConfig.tiltNavegacion] (45) mientras la camara
  /// sigue al vehiculo, sea cual sea la velocidad o que haya viaje activo.
  /// Antes era adaptativo por velocidad ([ApiConfig.tiltObjetivoParaVelocidad]):
  /// al frenar en un semaforo el mapa se aplanaba y al acelerar volvia a
  /// levantarse, un doble salto en cada cruce. Con el angulo constante la
  /// perspectiva no se pierde al parar, que es justo lo que se pide: durante
  /// un viaje activo (o mientras el coche se mueve en idle) el mapa se queda
  /// inclinado siempre.
  double get tiltObjetivo {
    if (_modo != ModoNavegacion.siguiendo) return ApiConfig.tiltDegradado;
    if (_tiltDegradado) return ApiConfig.tiltReducidoPorRendimiento;
    return ApiConfig.tiltNavegacion;
  }

  /// Tilt vigente, ya rampingado, en grados.
  ///
  /// Es lo que aplica la perspectiva. NUNCA se asigna de golpe: [_rampearTilt]
  /// lo acerca al objetivo como mucho [ApiConfig.rampaTiltGradosPorSegundo]
  /// grados por segundo, de modo que acelerar o frenar no produce un tirón.
  double get tiltActual => _tiltActual;

  /// Tilt objetivo en grados. Lo consume la transicion de entrada al modo.
  double get tiltObjetivoActual => tiltObjetivo;

  /// `true` si el mapa esta mostrando la perspectiva.
  bool get tieneTilt => _tiltActual > 0.5;

  /// Velocidad filtrada en m/s, que es la unidad en la que decide el tilt.
  double get _velocidadMps => _buffer.velocidadFiltrada();

  /// Velocidad filtrada en m/s, en publica.
  ///
  /// La consume el detector de desvios, que necesita exactamente el mismo
  /// dato suavizado que usa el tilt. Si tomara la velocidad cruda del sensor,
  /// un aceleron de leitura daria un desvio que no existe.
  double get velocidadMps => _velocidadMps;

  /// FPS medidos, utiles para diagnosticar en el log.
  double get fps => _fps;

  /// Si la perspectiva se ha desactivado por rendimiento.
  bool get tiltDegradadoPorRendimiento => _tiltDegradado;

  /// Pasa el trazado de la ruta que se esta siguiendo.
  ///
  /// [ruta] es la geometria que se DIBUJA (puede caer a la recta de respaldo).
  /// [rutaParaMatching] es la polilinea real de calles, la misma que usa la
  /// pantalla para encajar la posicion. Si no se entrega, se usa [ruta].
  ///
  /// La orientacion de la camara sigue saliendo del rumbo GPS + Kalman; la
  /// geometria solo corrige DONDE esta el coche. Antes este metodo guardaba la
  /// ruta unicamente para diagnostico y el `_mapMatching` de este servicio se
  /// quedaba sin ruta: el marcador seguia yendo por los edificios aunque la
  /// pantalla ya publicara la posicion encajada al pasajero.
  void informarRuta(List<LatLng> ruta, {List<LatLng>? rutaParaMatching}) {
    _ruta = List<LatLng>.unmodifiable(ruta);
    _mapMatching.actualizarRuta(rutaParaMatching ?? ruta);
    // La geometria cambio: el encaje guardado pertenece a la ruta vieja. Se
    // fuerza recalcularlo con el proximo fix (o con el actual, en el proximo frame).
    _fixAjustado = null;
  }

  // ---------------- datos ----------------

  void _alRecibirFix(GeoFix fix) {
    if (fix.mocked) return;

    _fix = fix;
    _fixAnterior = _fixAnterior ?? fix.position;

    // Se descarta el fix si entre los dos se ha movido mas de lo que un coche
    // puede hacer en el intervalo. Medido en el backend: a las 05:19:51 la
    // posicion salto de 23.1391 a 23.1277, un 1,2 km entre dos fixes seguidos. Un
    // salto asi no es movimiento, es un fix malo.
    //
    // Solo se marca: la posicion es real aunque el salto no lo sea, y lo que
    // decide el rumbo es la ruta, no este fix.
    final anterior = _fixAnterior;
    var salto = false;
    if (anterior != null) {
      final d = LocationService.distanceBetween(anterior, fix.position);
      final dt = _ultimoFixMs == null
          ? null
          : (_ahoraMs - _ultimoFixMs!) / 1000.0;
      final velocidadImplicita = (dt == null || dt <= 0.2) ? null : d / dt;
      if (velocidadImplicita != null &&
          velocidadImplicita > ApiConfig.velocidadMaximaGps) {
        _fixConSalto = true;
        salto = true;
      }
    }
    _fixAnterior = fix.position;
    _ultimoFixMs = _ahoraMs;

    // Filtro de posicion. Se alimenta con TODOS los fixes, tambien con los que
    // dan un salto: es el filtro quien los rechaza y conserva la ultima
    // posicion buena, incluida su precision.
    _posicionFiltrada = _filtroGps.filtrar(
      fix.position,
      accuracyMetros: fix.accuracy,
      velocidadKmh: fix.velocidadKmh,
    );
    _precisionMetros = _filtroGps.precisionMetros ?? fix.accuracy;

    // Rumbo por movimiento GPS + Kalman. Se ignora un fix con salto imposible:
    // su direccion es ruido y meteria un giro de 180 grados en el mapa.
    if (!salto) {
      _rumboGps.actualizar(
        posicion: fix.position,
        velocidadKmh: fix.velocidadKmh,
        ahoraMs: _ahoraMs,
      );
    }

    // El buffer se sigue alimentando para leer la velocidad suavizada (la que
    // decide el zoom y el indicador). El rumbo ya no se toma de aqui: la
    // orientacion sale de [_rumboGps].
    final speedMps = fix.speedMps ?? 0.0;
    _buffer.add(
      rumbo: _rumboGps.rumbo ?? 0.0,
      velocidadMps: speedMps,
      tiempoMs: _ahoraMs,
    );

    // Instante del ultimo fix en el reloj del servicio. La extrapolacion se
    // recalcula en cada frame, asi que mide el tiempo desde AQUI con el mismo
    // reloj monotono. Antes se guardaba el `elapsedRealtimeMs` del propio fix y
    // se comparaba contra ese mismo valor: el delta daba siempre 0 y la flecha
    // nunca avanzaba entre fixes.
    _ultimoFixRelojServicioMs = _ahoraMs;
    _gpsDebil = false;

    if (_modo == ModoNavegacion.siguiendo) {
      _recalcularObjetivo();
      _revisarHisteresis(fix);
    }

    // Aviso de fix, UNA vez por posicion del GPS (1 Hz). Existe para el detector
    // de desvios, que cuenta "muestras" de GPS y por tanto tiene que correr al
    // ritmo del GPS. Antes se alimentaba desde [notificar], que se dispara en
    // cada frame del bucle de camara (~60 Hz): sus tres muestras consecutivas
    // se cumplian en 50 ms en vez de 3 s, y sus diez muestras de parado en 170 ms
    // en vez de 10 s. Con eso cualquier salto de posicion del GPS lanzaba un
    // POST de recalculo y la pausa por semaforo no pausaba nada.
    _alFix?.call();

    notificar();
  }

  /// Registra el callback que se dispara con cada fix del GPS.
  ///
  /// A diferencia de [alCambiar], que es por frame y para repintar el mapa, este
  /// es por posicion del GPS. Lo que cuenta muestras del GPS (el detector de
  /// desvios) tiene que engancharse aqui, no ahi.
  void alFix(void Function()? fn) => _alFix = fn;

  void Function()? _alFix;

  /// Reloj monotono del servicio, en milisegundos.
  ///
  /// [Stopwatch] es monotono por definicion: no se ve afectado por el cambio de
  /// hora del movil ni por la zona horaria. `DateTime.now()` SI lo sufre, y aqui
  /// eso produciria intervalos negativos y decisiones de histeresis equivocadas,
  /// que es justo lo que no puede pasar en un mapa de conduccion.
  static final Stopwatch _reloj = Stopwatch()..start();

  /// Reloj falso, usado solo por las pruebas para avanzar sin esperar de verdad.
  @visibleForTesting
  static int? relojPruebaMs;

  /// Milisegundos monotonos desde que arranco el servicio.
  static int get _ahoraMs => relojPruebaMs ?? _reloj.elapsedMilliseconds;

  /// Duracion de un tramo, en milisegundos monotonos.
  static int _desde(int? desde) => desde == null ? 0 : _ahoraMs - desde;

  void _revisarHisteresis(GeoFix fix) {
    final v = fix.speedMps ?? 0.0;
    final ahora = _ahoraMs;

    if (v >= ApiConfig.velocidadMinimaHeading) {
      _quietoDesdeMs = null;
      _enMarchaDesdeMs ??= ahora;
      // Si el usuario habia cogido el mapa y el coche lleva mas de 3 s en
      // marcha, se vuelve al follow solo: estaba mirando el barrio, no
      // conduciendo.
      if (_modo == ModoNavegacion.explorando &&
          v >= ApiConfig.velocidadReactivarFollow &&
          _desde(_enMarchaDesdeMs) >=
              ApiConfig.antiguedadReactivar.inMilliseconds) {
        _modo = ModoNavegacion.siguiendo;
        _centroObjetivo = null;
        _iniciarTicker();
        _recalcularObjetivo();
        notificar();
      }
    } else {
      _enMarchaDesdeMs = null;
      _quietoDesdeMs ??= ahora;
    }
  }

  // ---------------- objetivo de camara ----------------

  void _recalcularObjetivo() {
    final fix = _fix;
    if (fix == null) return;

    final v = _buffer.velocidadFiltrada();
    _velocidadKmh = v * 3.6;

    // Posición dibujada. Se encaja la posición YA FILTRADA sobre la geometría
    // de la calle mientras el vehículo va en ruta. Si se desvía, el map-matching
    // devuelve la posición real con `enRuta = false` y el marcador deja de
    // arrastrarse por la polilínea vieja sin esperar al recálculo.
    // El encaje se calcula una vez por fix; la extrapolación se refresca en
    // cada frame con el mismo punto ya encajado.
    if (!identical(fix, _fixAjustado)) {
      _ajusteActual = _mapMatching.ajustar(
        posicionFiltrada,
        // [_rumbo] se actualiza mas abajo, en [_aplicarOrientacion], con este
        // mismo fix: usarlo aqui era usar el rumbo del fix ANTERIOR y el mapa
        // aceptaba el giro una muestra tarde. [_rumboGps] ya se actualizo en
        // [_alRecibirFix], asi que es la medicion fresca.
        rumbo: _rumboGps.rumbo ?? _rumbo,
        precisionMetros: _precisionMetros,
        velocidadKmh: _velocidadKmh,
      );
      _fixAjustado = fix;
    }
    final ajuste = _ajusteActual;
    if (ajuste == null) return;
    _pos = _extrapolar(ajuste, fix);

    // El recentrar solo impone tilt y zoom mientras el vehiculo siga parado.
    // En cuanto arranca, manda la velocidad y la vista vuelve a ser adaptativa;
    // si no, el forzado se congelaria para siempre (zoom 19, el mismo de la
    // navegacion).
    if (v >= ApiConfig.velocidadMinimaTilt &&
        (_tiltForzado != null || _zoomForzado != null)) {
      _tiltForzado = null;
      _zoomForzado = null;
      _notificarCambioTilt();
    }

    // Rumbo. Sale del movimiento real del GPS suavizado con Kalman 1D circular
    // (ver [RumboMovimiento]), igual que en el modo libre.
    //
    // Se elimino el uso de la brujula (clavada en muchas muestras) y tambien la
    // geometria de la ruta: OSRM da la direccion del trazado, no la direccion en
    // la que apunta el coche, y en un cruce o parado en un semaforo orientaba el
    // mapa hacia una calle por la que aun no se va.
    //
    // El filtro conserva el ultimo rumbo valido por debajo de 5 km/h y descarta
    // saltos imposibles del GPS, asi que no hay giros bruscos ni vuelco al norte.
    _aplicarOrientacion();

    // Zoom de la fase. Al ir a 30 km/h o mas se ALEJA un nivel (zoom out),
    // filosofia tipo Google Maps/Waze: con velocidad el conductor necesita
    // horizonte, no el detalle de calle. Parado o lento se mantiene la fase.
    var z = ApiConfig.zoomParaFase(status: _fase);
    if (v >= ApiConfig.velocidadParaZoomRapido) {
      z -= 1;
    }
    // El recentrar impone su zoom mientras el GPS siga sin velocidad.
    final zoomForzado = _zoomForzado;
    if (zoomForzado != null && v < ApiConfig.velocidadMinimaTilt) {
      z = zoomForzado;
    }
    // Suelo y techo a 20: zoom de calle siempre, tambien al acelerar. La resta
    // por velocidad queda neutralizada por el clamp y se conserva solo para no
    // perder el gancho si algun dia se vuelve a permitir alejar la vista.
    _zoomObjetivo = z.clamp(
      ApiConfig.zoomSueloNavegacion,
      ApiConfig.zoomTechoNavegacion,
    );

    // La rotacion sale de [_aplicarOrientacion]. Con viaje es el rumbo del GPS +
    // Kalman; sin viaje es 0 (norte arriba).
    //
    // Con el vehiculo parado el mapa CONGELA la ultima orientacion estable en
    // vez de apagarse: en un semaforo el chofer quiere seguir viendo hacia donde
    // avanza, no que el mapa le salte al norte. El filtro de rumbo ya hace esa
    // congelacion (por debajo de 5 km/h no actualiza) y [_rumboRetenido] cubre
    // el arranque.
    _centroObjetivo = _pos;

    // Traza de la camara: una linea cada vez que el objetivo cambia de verdad.
    // Es lo que dice si el heading-up tiene datos con los que trabajar o si se
    // queda clavado en el norte porque nunca llega un rumbo.
    final clave =
        '${_rotacionObjetivo?.toStringAsFixed(0)}|'
        '${_rotacionActual?.toStringAsFixed(0)}|'
        '${_rumboRetenido?.toStringAsFixed(0)}|'
        '$_contadorTics|${_ticker.isActive}|'
        '${_tiltActual.toStringAsFixed(0)}|${z.toStringAsFixed(1)}';
    if (clave != _trazaCamara) {
      _trazaCamara = clave;
      TrazaFichero.instancia.escribir(
        '[NAV] rotacion=${_rotacionObjetivo?.toStringAsFixed(0)} '
        'actual=${_rotacionActual?.toStringAsFixed(0)} '
        'ruta=${_ruta.length} '
        'viaje=$_hayViajeActivo '
        'fuente=${_rumbo != null ? "GPS" : "FALLBACK"} '
        'retenido=${_rumboRetenido?.toStringAsFixed(0)} '
        'tics=$_contadorTics act=${_ticker.isActive} '
        'salto=$_fixConSalto '
        'v=${v.toStringAsFixed(1)} tilt=${_tiltActual.toStringAsFixed(0)} '
        'zoom=${_zoomObjetivo ?? z}',
      );
    }
  }

  /// Ultima combinacion de camara registrada en la traza, para no repetir linea.
  String? _trazaCamara;

  /// Cuantos tics ha corrido el bucle de camara desde que arranco el modo.
  ///
  /// Solo diagnostico. La rotacion aplicada solo se interpola en [_alTic], asi
  /// que si este numero no crece mientras la traza si que cambia, es que las
  /// lineas vienen de la llegada de fixes y el bucle no esta corriendo: la
  /// camara se queda con el ultimo valor, o en null, y el mapa no rota.
  int _contadorTics = 0;
  int get contadorTics => _contadorTics;

  /// Mueve el tilt vigente hacia el objetivo sin pasarse.
  ///
  /// El objetivo depende de la velocidad y por eso cambia de forma continua,
  /// pero el valor aplicado va con rampa de
  /// [ApiConfig.rampaTiltGradosPorSegundo]. Sin esta rampa, entrar y salir de un
  /// semaforo a 40 km/h cambiaria el angulo de golpe y se veria como un jerk.
  ///
  /// El reloj es monotono y se avanza por frame, no por fix del GPS: asi la
  /// rampa dura lo mismo a 1 Hz que a 60 Hz.
  void _rampearTilt(Duration elapsed) {
    final objetivo = tiltObjetivo;
    final delta = objetivo - _tiltActual;
    if (delta.abs() < 0.1) {
      _tiltActual = objetivo;
      return;
    }
    final dt = (elapsed.inMicroseconds / 1e6).clamp(0.0, 0.1);
    final maximo = ApiConfig.rampaTiltGradosPorSegundo * dt;
    _tiltActual += delta.clamp(-maximo, maximo);
  }

  /// Avanza la posicion entre fixes para que el mapa no se congele.
  ///
  /// Antes se avanzaba en LINEA RECTA con el rumbo: al girar, la flecha apuntaba
  /// bien pero el punto salia de la calle y se metia en el edificio hasta el
  /// siguiente fix. Ahora el avance se hace SOBRE LA POLILINEA, así que el coche
  /// pasa por el vertice de la esquina. El rumbo sigue siendo GPS + Kalman y no
  /// interviene aqui: solo mueve el punto por la calle.
  LatLng _extrapolar(PuntoRuta ajuste, GeoFix fix) {
    final desde = _ultimoFixRelojServicioMs;
    if (desde == null) return ajuste.posicion;

    final dtReal = (_ahoraMs - desde) / 1000.0;
    _gpsDebil = dtReal >= _avisoGpsDebilSegundos;

    if (!ajuste.enRuta) {
      // Fuera de ruta NO se avanza por la polilínea: seguiría moviendo el coche
      // por la calle que acaba de abandonar. Pero quedarse clavado en el último
      // fix tampoco: se avanza en línea recta con el último rumbo y velocidad,
      // con tope de 30 m y solo mientras el fix tenga menos de 3 s.
      if (dtReal <= 0 || dtReal > _extrapolacionMaxima) {
        return ajuste.posicion;
      }
      return _extrapolarFueraRuta(ajuste, dtReal);
    }

    final v = _velocidadKmh > 0 ? _velocidadKmh / 3.6 : (fix.speedMps ?? 0.0);
    if (v <= 0.5) return ajuste.posicion;

    if (dtReal <= 0 || dtReal > _extrapolacionMaxima) {
      return ajuste.posicion;
    }

    return _mapMatching.avanzar(ajuste, v * dtReal);
  }

  /// Avance estimado en línea recta cuando el GPS se pierde fuera de ruta.
  ///
  /// Usa el rumbo GPS + Kalman ya calculado y la velocidad suavizada. Nunca se
  /// aleja más de [_avanceFueraRutaMaximoMetros] del último fix real y, en
  /// cuanto llega uno nuevo, el punto vuelve a la posición medida.
  LatLng _extrapolarFueraRuta(PuntoRuta ajuste, double dtReal) {
    final rumbo = _rumboGps.rumbo ?? _rumboRetenido;
    if (rumbo == null) return ajuste.posicion;

    final vKmh = _velocidadKmh > 0
        ? _velocidadKmh
        : (_fix?.speedMps ?? 0.0) * 3.6;
    final vMps = vKmh.clamp(0.0, _velocidadMaximaExtrapoladaKmh) / 3.6;
    if (vMps <= 0.5) return ajuste.posicion;

    final metros = math.min(vMps * dtReal, _avanceFueraRutaMaximoMetros);
    if (metros <= 0) return ajuste.posicion;

    const metrosPorGrado = 111320.0;
    final rad = rumbo * math.pi / 180.0;
    final lat = ajuste.posicion.latitude;
    final cosLat = math.cos(lat * math.pi / 180.0).abs().clamp(0.01, 1.0);
    return LatLng(
      lat + metros * math.cos(rad) / metrosPorGrado,
      ajuste.posicion.longitude +
          metros * math.sin(rad) / (metrosPorGrado * cosLat),
    );
  }

  // ---------------- rumbo por movimiento GPS ----------------

  /// Aplica la orientacion del mapa con el rumbo del GPS + Kalman.
  ///
  /// Es la misma fuente que el modo libre: [RumboMovimiento] mide el bearing
  /// entre la posicion anterior y la actual y lo suaviza con un Kalman 1D
  /// circular. La geometria de la ruta (OSRM) ya no orienta la camara.
  ///
  /// Sin viaje, norte arriba. Con viaje pero sin dos fixes con desplazamiento
  /// suficiente (parado, tunel o primer fix), se conserva el ultimo rumbo
  /// valido en vez de saltar al norte.
  void _aplicarOrientacion() {
    if (!_hayViajeActivo) {
      _rumbo = null;
      _rotacionObjetivo = 0.0;
      return;
    }

    final medido = _rumboGps.rumbo;
    if (medido != null) {
      _rumboRetenido = medido;
      _rumbo = medido;
      _rotacionObjetivo = normalizarGrados(medido);
      return;
    }

    _rumbo = null;
    _rotacionObjetivo = normalizarGrados(
      _rumboRetenido ?? _rotacionActual ?? 0.0,
    );
  }

  /// Visible para las pruebas: rumbo suavizado que orienta el mapa.
  @visibleForTesting
  double? get rumboGps => _rumboGps.rumbo;

  // ---------------- bucle de render ----------------

  void _iniciarTicker() {
    if (!_ticker.isActive) _ticker.start();
  }

  /// Un tic del bucle de animacion de la camara.
  void _alTic(Duration elapsed) {
    if (_modo != ModoNavegacion.siguiendo) {
      _ticker.stop();
      return;
    }
    _contadorTics++;

    _recalcularObjetivo();

    final centroObjetivo = _centroObjetivo;
    final zoomObjetivo = _zoomObjetivo;
    final rotacionObjetivo = _rotacionObjetivo;
    if (centroObjetivo == null || zoomObjetivo == null) return;

    if (_centroActual == null) {
      // Primer tick tras arrancar el modo: se coloca sin interpolar, o la
      // camara haria un barrido largo desde donde el usuario la dejo.
      _centroActual = centroObjetivo;
      _zoomActual = zoomObjetivo;
      _rotacionActual = rotacionObjetivo;
    } else {
      // Interpolacion exponencial. Se pondera por el tiempo real del frame y no
      // por un factor fijo: asi la velocidad de la camara es la misma a 30 fps
      // que a 60.
      final dt = (elapsed.inMicroseconds / 1e6).clamp(0.0, 0.1);
      final k = 1 - math.pow(1 - _respuesta, dt * 60).toDouble();

      final ca = _centroActual!;
      _centroActual = LatLng(
        ca.latitude + (centroObjetivo.latitude - ca.latitude) * k,
        ca.longitude + (centroObjetivo.longitude - ca.longitude) * k,
      );

      final za = _zoomActual!;
      _zoomActual = za + (zoomObjetivo - za) * k;

      final ra = _rotacionActual;
      if (ra != null && rotacionObjetivo != null) {
        final d = deltaCorto(ra, rotacionObjetivo);
        if (d.abs() >= ApiConfig.deadbandRotacion) {
          final kRot = d.abs() >= _giroCamaraGrados
              ? math.max(k, _respuestaGiroCamara)
              : 1 - math.pow(1 - _respuestaRotacion, dt * 60).toDouble();
          _rotacionActual = normalizarGrados(ra + d * kRot);
        }
      } else {
        _rotacionActual = rotacionObjetivo;
      }
    }

    // El tilt se rampea con el reloj del frame, nunca por fix del GPS.
    _rampearTilt(elapsed);

    // El widget lee estos valores y aplica `move` + `rotate` una vez por frame.
    notificar();
  }

  // ---------------- rendimiento ----------------

  /// Registra la medicion de FPS por `SchedulerBinding`.
  ///
  /// Se usa el callback del framework y no un reloj propio porque es el unico
  /// que ve los tiempos reales de construccion de cada frame, incluidos los que
  /// se pierden antes de llegar al `Ticker`.
  ///
  /// En un binding de test la asercion de `addTimingsCallback` falla, porque el
  /// binding de `flutter_test` gestiona los timings por su cuenta. La medicion
  /// se salta ahi en lugar de romper: en tests no hay FPS que vigilar.
  void _activarMedicionFps() {
    if (!_timingsDisponibles) return;
    _desactivarMedicionFps();
    SchedulerBinding.instance.addTimingsCallback(_callbackTimings);
  }

  void _desactivarMedicionFps() {
    if (!_timingsDisponibles) return;
    SchedulerBinding.instance.removeTimingsCallback(_callbackTimings);
  }

  /// `true` si `addTimingsCallback` va a funcionar en este binding.
  static bool get _timingsDisponibles {
    if (kIsWeb) return false;
    // `flutter_test` sustituye el binding por uno que ya entrega las medidas de
    // frame por otra via; ahi el callback nativo no se puede instalar.
    return !SchedulerBinding.instance.runtimeType.toString().contains('Test');
  }

  /// Acumula las duraciones de frame y decide si degrada la perspectiva.
  ///
  /// Criterio: por debajo de [ApiConfig.fpsMinimoTilt] durante mas de
  /// [ApiConfig.antiguedadDegradacion] se apaga el tilt, y se recupera al
  /// superar [ApiConfig.fpsRecuperacionTilt] durante
  /// [ApiConfig.antiguedadRecuperacion]. Los dos margenes son deliberados: sin
  /// ellos la perspectiva entraria y saldria en cada cambio de carga.
  void _callbackTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;

    var us = <int>[0];
    for (final t in timings) {
      us[0] += t.totalSpan.inMicroseconds;
    }
    if (us[0] <= 0) return;
    final fpsMuestra = 1000.0 / ((us[0] / timings.length) / 1000.0);

    // Media movil: un frame perdido no debe degradar la perspectiva.
    _fps = _fpsMedia == 0 ? fpsMuestra : _fpsMedia * 0.7 + fpsMuestra * 0.3;
    _evaluarFps();
  }

  /// Aplica los umbrales sobre el FPS actual.
  ///
  /// Vive aparte para que [informarFps] pueda reutilizarla en las pruebas.
  void _evaluarFps() {
    if (_fps < ApiConfig.fpsMinimoTilt) {
      _altoFpsDesdeMs = null;
      _bajoFpsDesdeMs ??= _ahoraMs;
      if (!_tiltDegradado &&
          _desde(_bajoFpsDesdeMs) >=
              ApiConfig.antiguedadDegradacion.inMilliseconds) {
        _tiltDegradado = true;
        _avisarDegradacion(true);
        notificar();
      }
      return;
    }

    _bajoFpsDesdeMs = null;
    if (_fps > ApiConfig.fpsRecuperacionTilt) {
      _altoFpsDesdeMs ??= _ahoraMs;
      if (_tiltDegradado &&
          _desde(_altoFpsDesdeMs) >=
              ApiConfig.antiguedadRecuperacion.inMilliseconds) {
        _tiltDegradado = false;
        _avisarDegradacion(false);
        notificar();
      }
    } else {
      _altoFpsDesdeMs = null;
    }
  }

  /// Inyecta FPS medidos, para las pruebas.
  ///
  /// Permite simular 20 fps sin depender del rendimiento real de la maquina, y
  /// comprobar que la degradacion se produce tras el tiempo exigido.
  @visibleForTesting
  void informarFps(double fps) {
    _fps = fps;
    _evaluarFps();
  }

  /// Inyecta un fix del GPS como si llegara del canal nativo.
  ///
  /// Permite probar el rumbo GPS + Kalman sin depender del plugin de ubicacion
  /// ni del canal de plataforma. El servicio usa su reloj monotono igual que en
  /// produccion; lo que el test controla es la posicion y la velocidad.
  @visibleForTesting
  void informarFix(GeoFix fix) => _alRecibirFix(fix);

  // ---------------- estado para el widget ----------------

  void Function()? _alCambiar;

  /// Se registra el callback que repinta el mapa.
  void alCambiar(void Function()? fn) => _alCambiar = fn;

  void notificar() => _alCambiar?.call();

  /// Centro ya interpolado que el mapa debe tener ahora mismo.
  LatLng? get centroActual => _centroActual;

  /// Zoom ya interpolado que el mapa debe tener ahora mismo.
  double? get zoomActual => _zoomActual;

  /// Rotacion ya interpolada, en grados.
  ///
  /// Se interpola por el camino angular mas corto: de 350 a 10 son +20 grados.
  /// Sin esto el mapa "daria la vuelta" en cada cruce. El deadband evita tocar
  /// nada por variaciones de decimas de grado, que si no redibujan los tiles y
  /// hacen que el mapa tiemble.
  double? get rotacionActual => _rotacionActual;

  /// `true` si la camara debe seguir al vehiculo.
  bool get debeSeguir => _modo == ModoNavegacion.siguiendo;

  /// Velocidad actual en km/h, para el indicador de la interfaz.
  double get velocidadActual => _velocidadKmh;

  /// `true` si el GPS nativo deberia seguir activo.
  ///
  /// El nativo se pausa solo tras 10 s parado, pero el servicio lo refleja para
  /// el indicador de la interfaz.
  bool get gpsPausado => _velocidadKmh < 1.0;
}
