import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/scheduler.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../api_config.dart';
import '../models/geo_fix.dart';
import 'heading_filter.dart';
import 'location_service.dart';

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
  static void _callbackTic(Duration elapsed) => _instanciaActual?._alTic(elapsed);

  /// Instancia viva, solo para que el callback estatico del ticker la alcance.
  ///
  /// Hay una sola camara de navegacion en la app, asi que una referencia
  /// estatica es suficiente y evita la indireccion de una closure por frame.
  static NavigationModeService? _instanciaActual;

  // ---------------- configuracion ----------------

  /// Buffer circular de rumbos con N = 5 muestras.
  final BufferCircularRumbo _buffer = BufferCircularRumbo();

  /// Distancia minima entre dos fixes para deducir el rumbo por
  /// desplazamiento (course-over-ground) cuando no hay sensor.
  ///
  /// 8 m. Por debajo, el error de posicion GPS hace que el rumbo sea ruido puro:
  /// con 50 m de precision y dos fixes separados 3 m, la direccion medida puede
  /// ser cualquiera.
  static const double _distanciaMinimaCourseOverGround = 8.0;

  /// Metros por grado de latitud. Suficiente para dead-reckoning a escala de
  /// calle; no hace falta mas precision.
  static const double _metrosPorGradoLat = 111320.0;

  /// Tope de extrapolacion entre fixes.
  ///
  /// 3 s. Pasado esto ya no se sabe donde esta el coche, y seguir proyectando
  /// lo saca de la calle.
  static const double _extrapolacionMaxima = 3.0;

  /// Cuanto se acerca la camara a su objetivo por frame (a 60 Hz).
  ///
  /// 0.16: llega al 90 % del camino en unos 14 frames, ~230 ms.
  static const double _respuesta = 0.16;

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

  /// Posicion actual, extrapolada entre fixes. Es la que se dibuja y la que
  /// sigue la camara.
  LatLng _pos = ApiConfig.defaultDriverLocation;
  LatLng get posicion => _pos;

  /// Posicion real del ultimo fix, sin extrapolar. Al backend se le manda esta,
  /// nunca la proyectada: un punto inventado falsearia su posicion real.
  LatLng get posicionReal => _fix?.position ?? _pos;

  /// Rumbo filtrado en grados (0 = norte), o `null` si no hay dato.
  double? _rumbo;
  double? get rumbo => _rumbo;

  /// Velocidad suavizada en km/h.
  double _velocidadKmh = 0;
  double get velocidadKmh => _velocidadKmh;

  /// Posicion del fix anterior, para el course-over-ground.
  LatLng? _fixAnterior;

  /// Rumbo deducido del GPS cuando el sensor no esta disponible.
  double? _rumboGps;

  // Dead reckoning
  int? _ultimoMonotonoMs;

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
  StreamSubscription<double>? _subRumbo;

  /// Si el dispositivo trae sensor de rumbo. Sin el se navega con el rumbo del
  /// GPS, que es mas bruto.
  bool _haySensor = false;

  // ---------------- ciclo de vida ----------------

  /// Prepara el servicio. No mueve el mapa: eso lo hace [activar].
  ///
  /// Se separa para que la pantalla pueda crear el servicio en `initState` y
  /// decidir despues si hay viaje activo.
  void iniciar() {
    if (_subFix != null) return;
    _instanciaActual = this;

    _subFix = LocationService.watchNavegacion().listen(_alRecibirFix);

    // El rumbo del sensor llega a ~50 Hz, mucho mas a menudo que el GPS. Se
    // escucha aparte y se guarda en el buffer, de modo que el filtro siempre
    // tiene muestras recientes aunque el GPS llegue a 1 Hz.
    _subRumbo = LocationService.headings().listen(_alRecibirRumbo);

    LocationService.tieneSensorRumbo().then((v) => _haySensor = v);
  }

  void dispose() {
    if (_instanciaActual == this) _instanciaActual = null;
    _subFix?.cancel();
    _subRumbo?.cancel();
    _desactivarMedicionFps();
    _ticker.dispose();
  }

  /// Activa el modo navegacion para la fase indicada.
///
/// Cambiar de fase reevalua el encuadre y dispara el unico momento en el que se
/// toca el tilt (entrar o salir del modo). El tilt NUNCA se anima por tic: la
/// perspectiva repinta la capa entera y hacerlo cada frame deja el mapa a 20
/// fps.
///
/// Si la fase no cambia no hace nada: es el guardado contra reencuadrar en cada
/// fix del GPS.
void activar(String? status, {LatLng? posicionConocida}) {
    if (_fase == status && _modo != ModoNavegacion.apagado) return;
    final estabaApagado = _modo == ModoNavegacion.apagado;
    _fase = status;

    if (status == null) {
      apagar();
      return;
    }

    // Siembra la posicion con la que ya se sabe, en vez de esperar al primer
    // fix de 1 Hz. Sin esto, [_pos] sigue valiendo el punto fijo por defecto de
    // `ApiConfig.defaultDriverLocation` (el centro de La Habana) y el mapa, y
    // con el el marcador del vehiculo, aparecen ahi en vez de donde esta el
    // coche. Se nota al aceptar un viaje parado: la flecha salta y parece que
    // desaparece.
    if (posicionConocida != null) _pos = posicionConocida;

    _modo = ModoNavegacion.siguiendo;
    _iniciarTicker();
    _activarMedicionFps();
    _recalcularObjetivo();
    notificar();

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
          ? _tiltActual
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
    _rumboGps = null;
    _quietoDesdeMs = null;
    _enMarchaDesdeMs = null;
    _centroObjetivo = null;
    _rotacionObjetivo = null;
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
    _enMarchaDesdeMs = null;
    _quietoDesdeMs = null;
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
  /// camara la lleva [NavCamera].
  void recentrar() {
    if (_fase == null) return;
    _modo = ModoNavegacion.siguiendo;
    _rumboGps = null;
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
  void alCambiarTilt(void Function(double objetivo)? fn) =>
      _alCambiarTilt = fn;

  void _notificarCambioTilt() => _alCambiarTilt?.call(tiltObjetivo);

  /// Tilt que corresponde a la velocidad actual, en grados.
  ///
  /// Es el valor ADAPTATIVO: 0 quieto, ~42 en ciudad, hasta 58 en carretera.
  /// Ver [ApiConfig.tiltObjetivoParaVelocidad].
double get tiltObjetivo {
    if (_modo != ModoNavegacion.siguiendo) return ApiConfig.tiltDegradado;
    if (_tiltDegradado) return ApiConfig.tiltDegradado;
    // El recentrar impone su angulo mientras el GPS siga sin velocidad.
    final forzado = _tiltForzado;
    if (forzado != null && _velocidadMps < ApiConfig.velocidadMinimaTilt) {
      return forzado;
    }
    // Por debajo del umbral se conserva el angulo que ya tenia en vez de
    // aplanarse: ver [ApiConfig.tiltObjetivoParaVelocidad]. Se pasa el tilt
    // actual, no el objetivo, para que la rampa de 30 grados/s siga
    // mandando y el congelado no de un salto.
    return ApiConfig.tiltObjetivoParaVelocidad(
      _velocidadMps,
      anterior: _tiltActual,
    );
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

  // ---------------- datos ----------------

  void _alRecibirFix(GeoFix fix) {
    if (fix.mocked) return;

    // Solo se alimenta el buffer de rumbo en marcha. Con el vehiculo parado el
    // GPS no aporta rumbo fiable y solo contaminaria el filtro.
    _fix = fix;
    _fixAnterior = _fixAnterior ?? fix.position;

    // Rumbo deducido de dos fixes, como respaldo del sensor.
    if (_fixAnterior != null) {
      final d = LocationService.distanceBetween(_fixAnterior!, fix.position);
      if (d >= _distanciaMinimaCourseOverGround) {
        _rumboGps = LocationService.bearingBetween(_fixAnterior!, fix.position);
      }
    }
    _fixAnterior = fix.position;

    if (_haySensor && fix.rumbo != null) {
      _buffer.add(
        rumbo: fix.rumbo!,
        velocidadMps: fix.speedMps ?? 0.0,
        // Reloj monotono del fix. Nunca `DateTime.now()`: un cambio de hora del
        // dispositivo daria intervalos negativos y el filtro de aceleracion
        // descartaria todo.
        tiempoMs: fix.elapsedRealtimeMs ?? _ahoraMs,
      );
    } else if (fix.bearing != null) {
      _buffer.add(
        rumbo: fix.bearing!,
        velocidadMps: fix.speedMps ?? 0.0,
        tiempoMs: fix.elapsedRealtimeMs ?? _ahoraMs,
      );
    }

    // El fix real es el punto de partida de la extrapolacion.
    _ultimoMonotonoMs = fix.elapsedRealtimeMs ?? _ultimoMonotonoMs;

    if (_modo == ModoNavegacion.siguiendo) {
      _recalcularObjetivo();
      _revisarHisteresis(fix);
    }
    notificar();
  }

  void _alRecibirRumbo(double grados) {
    // El sensor llega a ~50 Hz y el GPS a 1 Hz. Se alimenta el buffer con la
    // velocidad que se conoce del ultimo fix, de modo que el filtro de
    // aceleracion sigue teniendo sentido.
    _buffer.add(
      rumbo: grados,
      velocidadMps: (_fix?.speedMps ?? 0.0),
      tiempoMs: _ultimoMonotonoMs ?? _ahoraMs,
    );
    if (_modo == ModoNavegacion.siguiendo) {
      _recalcularObjetivo();
    }
  }

  /// Reloj monotono del servicio, en milisegundos.
  ///
  /// [Stopwatch] es monotono por definicion: no se ve afectado por el cambio de
  /// hora del movil ni por la zona horaria. `DateTime.now()` SI lo sufre, y aqui
  /// eso produciria intervalos negativos y decisiones de histeresis equivocadas,
  /// que es justo lo que no puede pasar en un mapa de conduccion.
  static final Stopwatch _reloj = Stopwatch()..start();

  /// Milisegundos monotonos desde que arranco el servicio.
  static int get _ahoraMs => _reloj.elapsedMilliseconds;

  /// Duracion de un tramo, en milisegundos monotonos.
  static int _desde(int? desde) => desde == null ? 0 : _ahoraMs - desde;

  // ---------------- histeresis ----------------

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
          _desde(_enMarchaDesdeMs) >= ApiConfig.antiguedadReactivar.inMilliseconds) {
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

    _pos = _extrapolar(fix.position, fix);

final v = _buffer.velocidadFiltrada();
    _velocidadKmh = v * 3.6;

    // El recentrar solo impone tilt y zoom mientras el vehiculo siga parado.
    // En cuanto arranca, manda la velocidad y la vista vuelve a ser adaptativa;
    // si no, el forzado se congelaria en 18 y 55 grados para siempre.
    if (v >= ApiConfig.velocidadMinimaTilt &&
        (_tiltForzado != null || _zoomForzado != null)) {
      _tiltForzado = null;
      _zoomForzado = null;
      _notificarCambioTilt();
    }

    // Rumbo: primero el buffer (sensor + GPS filtrados), luego el respaldo.
    final r = _buffer.rumboFiltrado() ?? _rumboGps;
    _rumbo = r;

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
    // Suelo 14 (no bajar de ahi al acelerar) y techo 17 (maximo de la tabla).
    _zoomObjetivo = z.clamp(
      ApiConfig.zoomSueloNavegacion,
      ApiConfig.zoomTechoNavegacion,
    );

    // La rotacion se mantiene al parar en vez de volver al norte arriba.
    //
    // Antes, tras 5 s quieto, el mapa volvia a norte. Con el tilt
    // conservado eso daba un plano inclinado girandose de golpe a norte, que
    // es el peor de los dos mundos: se ve el giro y encima el mapa queda
    // torcido. Google Maps mantiene tilt y rumbo juntos, y es lo coherente.
    //
    // El umbral de [ApiConfig.velocidadMinimaHeading] (0.7 m/s) sigue
    // mandando: por debajo de unos 2.5 km/h el sensor de rumbo es ruido, y ahi
    // si se congela la ultima orientacion estable, que es lo que ya hacia el
    // filtro de heading.
    if (v < ApiConfig.velocidadMinimaHeading) {
      _rotacionObjetivo = _rumboGps != null
          ? normalizarGrados(_rumboGps!)
          : _rotacionActual ?? 0.0;
    } else {
      _rotacionObjetivo = normalizarGrados(r ?? 0.0);
    }

    _centroObjetivo = _pos;
  }

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

  /// Proyecta la posicion entre fixes para que el mapa no se congele.
  ///
  /// Usa el rumbo y la velocidad con el reloj monotono del ultimo fix. Si se
  /// pasa de [_extrapolacionMaxima] deja de proyectar, porque a partir de ahi la
  /// posicion es una suposicion y ya no un dato.
  LatLng _extrapolar(LatLng base, GeoFix fix) {
    final r = _buffer.retenido ?? _rumbo;
    final v = fix.speedMps ?? 0.0;
    if (r == null || v <= 0.5) return base;

    final ahora = fix.elapsedRealtimeMs ?? _ahoraMs;
    final dtReal = _ultimoMonotonoMs == null
        ? 0.0
        : (ahora - _ultimoMonotonoMs!) / 1000.0;
    if (dtReal <= 0 || dtReal > _extrapolacionMaxima) return base;

    final rad = r * math.pi / 180.0;
    final distancia = v * dtReal;
    final dLat = (distancia * math.sin(rad)) / _metrosPorGradoLat;
    final dLng = (distancia * math.cos(rad)) /
        (_metrosPorGradoLat * math.cos(base.latitude * math.pi / 180.0));

    return LatLng(
      (base.latitude + dLat).clamp(-90.0, 90.0),
      (base.longitude + dLng).clamp(-180.0, 180.0),
    );
  }

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
          _rotacionActual = normalizarGrados(ra + d * k);
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
