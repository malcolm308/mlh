import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../api_config.dart';
import 'api_client.dart';
import 'osrm_service.dart';
import 'traza_fichero.dart';

/// Estado del recalculo de ruta.
enum RouteRecalcState {
  /// Sin nada que hacer.
  idle,

  /// Pidiendiendo ruta nueva al backend.
  calculating,

  /// Llego una ruta nueva.
  success,

  /// El backend fallo. Se reintenta con backoff mientras no se agoten.
  error,

  /// Se agotaron los reintentos. Ya no se vuelve a intentar sola.
  agotado,
}

/// Zona donde se esta conduciendo, que decide el umbral de desvio.
///
/// Ciudad y carretera no usan el mismo margen: en ciudad el GPS tiene mas
/// ruido por los edificios y las calles estrechas, asi que un margen pequeno
/// es conservador y evita recambios por una sola lectura mala. En carretera la
/// carretera es mas ancha y el GPS mas limpio, asi que se puede exigir mas
/// antes de dar un desvio por bueno.
enum ZonaRuta { ciudad, carretera }

/// Umbral de desvio segun lo rapido que se va, en metros.
///
/// Con un unico umbral fijo hay una combinacion que siempre falla: si es
/// pequeno, en ciudad se recalcula cada dos cuadras por el ruido del GPS; si
/// es grande, en carretera no se detecta un desvio real hasta que el chofer
/// lleva media hora yendo por donde no era. El margen tiene que crecer con la
/// velocidad, que es justo cuando mas costly sale recalcular de mas (mas
/// bateria, mas trafico, mas esperas) y cuando el GPS mas tiende a la deriva.
///
///   < 20 km/h  -> 100 m: calles estrechas y GPS muy ruidoso
///   20-40 km/h -> 150 m: ciudad normal
///   40-60 km/h -> 250 m: avenidas
///   > 60 km/h  -> 400 m: carretera
extension UmbralPorVelocidad on ZonaRuta {
  static const double _baja = 100;
  static const double _media = 150;
  static const double _alta = 250;
  static const double _autopista = 400;

  /// Velocidades en km/h que cortan cada tramo.
  static const double _corteBaja = 20;
  static const double _corteMedia = 40;
  static const double _corteAlta = 60;

  double get metros => switch (this) {
        ZonaRuta.ciudad => _media,
        ZonaRuta.carretera => _alta,
      };

  /// Umbral para una velocidad dada, en km/h.
  static double paraVelocidadKmh(double kmh) {
    if (kmh < _corteBaja) return _baja;
    if (kmh < _corteMedia) return _media;
    if (kmh < _corteAlta) return _alta;
    return _autopista;
  }
}

/// Detecta que el conductor se ha salido de la ruta y pide una nueva.
///
/// Va al backend, no a OSRM directo: el movil no sale a internet de forma
/// fiable desde Cuba, y centralizarlo permite cambiar parametros sin tocar la
/// app.
///
/// Decisiones que evitan el bucle de recambios, que es lo unico realmente
/// dificil de este servicio:
///
///  * Tres muestras consecutivas fuera de umbral. El GPS urbano tiene ruido
///    de 10-30 m, asi que una sola lectura no dice nada.
///  * Cinco segundos de calma tras pedir ruta. El conductor va a tardar en
///    corregir, y durante ese rato la posicion sigue en la calle vieja.
///  * Enfriar diez segundos antes del siguiente intento.
///  * Pausa completa por debajo de 1 km/h: parado en un semaforo no es
///    desviarse, y los primeros fixes tras arrancar suelen ir dando tirones.
///
/// No bloquea nada: es un `ChangeNotifier` y todas las peticiones son
/// asincronas. Si el backend falla, la ruta vieja se queda puesta.
class RouteRecalculationService extends ChangeNotifier {
  RouteRecalculationService({
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
        postJson,
  }) : _postJson = postJson ?? _postPorDefecto;

  /// Inyectable para poder probar sin red. Por defecto va al backend.
  final Future<Map<String, dynamic>> Function(
    String path,
    Map<String, dynamic> body,
  ) _postJson;

  RouteRecalcState _estado = RouteRecalcState.idle;

  /// Estado actual, para que la UI muestre el indicador discreto.
  RouteRecalcState get estado => _estado;

  /// `true` mientras hay una peticion en vuelo.
  bool get busy => _estado == RouteRecalcState.calculating;

  /// Emitido cada vez que llega una ruta nueva valida.
  ///
  /// El consumidor (el mapa) sustituye la geometria de la capa. No se emite
  /// la misma ruta dos veces.
  final StreamController<OsrmRoute> _rutaCambiada =
      StreamController<OsrmRoute>.broadcast();

  Stream<OsrmRoute> get onRouteChanged => _rutaCambiada.stream;

  /// Destino del viaje en curso. Sin destino no hay nada que recalcular.
  LatLng? _destino;

  /// Trazado que se sigue ahora mismo, para medir la distancia perpendicular.
  List<LatLng> _ruta = const [];

  // ---- Estado de la deteccion ----

  /// Muestras consecutivas fuera de umbral. Se pone a cero con cualquier
  /// lectura dentro de la ruta.
  int _fueraConsecutivas = 0;

  /// Cuantas muestras seguidas lleva el conductor parado.
  int _muestrasParado = 0;

  /// `true` si la deteccion esta en pausa por estar parado.
  bool _pausadoPorParado = false;

  // ---- Estado del control de bucles ----

  /// Momento del ultimo recalculo pedido, en milisegundos de `Stopwatch`.
  ///
  /// Se usa un reloj monotono y no `DateTime.now()`: un cambio de hora del
  /// movil, ya se ha visto, daria intervalos negativos y dejaria el servicio
  /// bloqueado en la pausa de cinco segundos para siempre.
  final Stopwatch _reloj = Stopwatch();
  int? _ultimoRecalculoMs;

  /// Intentos seguidos con fallo. Se reinicia al exito.
  int _intentos = 0;

  /// `true` mientras hay una peticion de recalculo en vuelo.
  ///
  /// Impide que dos POST al backend se pisen: sin el, el sondeo del GPS pedia
  /// uno cada segundo mientras el anterior tardaba mas de eso en volver, y cada
  /// respuesta reemplazaba la ruta anterior. Ver [_pedirRecalculo].
  bool _enVuelo = false;

  /// Cronometro del reintento con backoff.
  Timer? _temporizadorReintento;

  /// Cronometro del enfriamiento posterior a un exito.
  Timer? _temporizadorEnfriamiento;

  bool _descartado = false;

  // ---------------- API ----------------

  /// Arranca el seguimiento sobre una ruta y un destino.
  ///
  /// Llamar de nuevo con una ruta nueva reinicia los contadores, que es
  /// justo lo que hace falta cuando el backend ya ha devuelto un trazado.
void iniciar({required List<LatLng> ruta, required LatLng destino}) {
    // Idempotencia: si es el MISMO trayecto, no se toca NADA.
    //
    // Sin esta guarda el detector es inútil, y no por culpa del GPS. La pantalla
    // pide las rutas cada vez que llega una posicion, y al recibir las del modo
    // navegacion a 1 Hz eso era unas 63 llamadas por minuto. Cada una ejecutaba
    // los resets de mas abajo y, en particular, `_fueraConsecutivas = 0`: el
    // contador exige 3 muestras consecutivas fuera de ruta y se ponia a 1 antes
    // de llegar a 3. Medido en el recorrido del 14/10: 2.243 reinicios en 35
    // minutos, `fuera=0/3` en las 36 trazas, y 3 recalculos de 2.243
    // oportunidades (0,13 %), los tres en huecos en los que llego a llamar
    // `iniciar`.
    if (_mismoTrayecto(ruta, destino)) {
      _ruta = ruta;
      return;
    }

    _destino = destino;
    _ruta = ruta;
    _fueraConsecutivas = 0;
    _muestrasParado = 0;
    _pausadoPorParado = false;
    _intentos = 0;
    _descartado = false;
    _enVuelo = false;
    _contadorTrazas = 0;
    _temporizadorReintento?.cancel();
    _temporizadorEnfriamiento?.cancel();
    _temporizadorReintento = null;
    _temporizadorEnfriamiento = null;
    _ultimoRecalculoMs = null;
    if (!_reloj.isRunning) _reloj.start();
    _setEstado(RouteRecalcState.idle);
    TrazaFichero.instancia.escribir('[RECALC] detector ARRANCADO: '
        '${ruta.length} puntos, destino '
        '${destino.latitude.toStringAsFixed(5)},${destino.longitude.toStringAsFixed(5)}');
  }

  /// Tolerancia para comparar el destino, en grados.
  ///
  /// 1e-6 son unos 11 cm: bastante mas que el redondeo del JSON de OSRM y bastante
  /// menos que cualquier movimiento real de destino.
  static const double _toleranciaDestino = 1e-6;

  /// `true` si [ruta] y [destino] son el mismo trayecto que ya se sigue.
  ///
  /// Se compara el numero de puntos y el primero y el ultimo, que es lo que
  /// identifica un trazado de OSRM: dos rutas distintas casi nunca coinciden en
  /// los tres, y dos peticiones del mismo trayecto devuelven el mismo dibujo.
  bool _mismoTrayecto(List<LatLng> ruta, LatLng destino) {
    final actual = _destino;
    if (actual == null) return false;
    if ((actual.latitude - destino.latitude).abs() > _toleranciaDestino) {
      return false;
    }
    if ((actual.longitude - destino.longitude).abs() > _toleranciaDestino) {
      return false;
    }
    if (_ruta.length != ruta.length) return false;
    if (ruta.isEmpty) return true;
    return _ruta.first.latitude == ruta.first.latitude &&
        _ruta.first.longitude == ruta.first.longitude &&
        _ruta.last.latitude == ruta.last.latitude &&
        _ruta.last.longitude == ruta.last.longitude;
  }

  /// Corta el seguimiento y suelta los temporizadores.
  ///
  /// Se llama al cancelar o completar el viaje. Cancelar los temporizadores es
  /// lo que evita que una peticion en vuelo wakee el servicio mas tarde.
  void detener() {
    TrazaFichero.instancia.escribir('[RECALC] detector PARADO '
        '(queda _descartado=true hasta el siguiente iniciar)');
    _temporizadorReintento?.cancel();
    _temporizadorEnfriamiento?.cancel();
    _temporizadorReintento = null;
    _temporizadorEnfriamiento = null;
    _ruta = const [];
    _destino = null;
    _fueraConsecutivas = 0;
    _muestrasParado = 0;
    _pausadoPorParado = false;
    _descartado = true;
    _enVuelo = false;
    _setEstado(RouteRecalcState.idle);
  }

  /// Consume una muestra de posicion.
  ///
  /// [velocidadMps] es la velocidad YA filtrada, nunca la cruda del sensor.
  /// [posicion] tambien viene suavizada: medir la distancia contra una
  /// posicion con error de 30 m daria desvios falsos en cada esquina.
  void informarPosicion(LatLng posicion, double velocidadMps) {
    if (!_reloj.isRunning) _reloj.start();

    // La pausa por parado se evalua ANTES de la traza, para que la linea
    // refleje el estado en el que se decide seguir o no.
    if (_ruta.length >= 2) _detectarParado(velocidadMps);

    // Se guarda la ultima posicion para usarla como origen del recalculo: es el
    // punto exacto donde el conductor se salio, no un vertice de la ruta vieja.
    _ultimaPosicionConocida = posicion;

    final hayRuta = _ruta.length >= 2;
    final distancia =
        hayRuta ? distanciaPerpendicularMetros(posicion, _ruta) : double.nan;

    // El umbral sale de la velocidad del tramo, no de un valor fijo: ver
    // [UmbralPorVelocidad.paraVelocidadKmh].
    final umbral = UmbralPorVelocidad.paraVelocidadKmh(velocidadMps * 3.6);

    // La traza va ANTES de cualquier `return`. Si fuera despues, cada una de
    // las cuatro salidas tempranas se llevaria por delante su propia linea y el
    // log no distinguiria "no se llama" de "vuelve antes", que es justo lo que
    // hay que separar para encontrar el bloqueo.
    _trazaDeteccion(distancia, umbral, velocidadMps);

    if (_descartado) return;
    if (!hayRuta) return; // sin trazado no hay nada que comparar

    // En pausa por parado no se cuenta nada, pero tampoco se borra el
    // contador: al arrancar puede que siga fuera de ruta de verdad.
    if (_pausadoPorParado) return;

    // Cinco segundos de calma tras un recalculo. El conductor aun no ha
    // corregido y su posicion sigue en la calle anterior.
    if (enPausaPostRecalculo) return;

    if (distancia > umbral) {
      _fueraConsecutivas++;
      if (_fueraConsecutivas >= ApiConfig.desvioMuestrasConsecutivas) {
        _fueraConsecutivas = 0;
        _pedirRecalculo();
      }
    } else {
      // Cualquier lectura dentro de ruta descarta las anteriores. Es lo que
      // hace que un solo fix malo no dispare nada.
      _fueraConsecutivas = 0;
    }
  }

  /// Muestra como va la deteccion, sin actuar.
  ///
  /// Va a la traza cada [cadaCuantasTrazas] muestras del GPS. Sin esto no hay
  /// forma de saber por que el recalculo no dispara: las cuatro salidas
  /// tempranas de [informarPosicion] y la comparacion con el umbral son
  /// silenciosas, y sin GPS no se ve si el problema es que no se llama, que
  /// vuelve antes, o que la distancia nunca pasa del umbral.
  ///
  /// [corte] es la condicion que haria volver a la llamada justo despues, y va
  /// escrita en la linea para no tener que deducirla leyendo el codigo.
  void _trazaDeteccion(
    double distancia,
    double umbral,
    double velocidadMps,
  ) {
    final corte = _descartado
        ? 'DESCARTADO'
        : (_ruta.length < 2
            ? 'SIN_RUTA'
            : (_pausadoPorParado
                ? 'PARADO'
                : (enPausaPostRecalculo ? 'ESPERA' : 'ok')));

    _contadorTrazas++;
    if (_contadorTrazas % cadaCuantasTrazas != 0) return;
    TrazaFichero.instancia.escribir(
      '[RECALC-DET] corte=$corte '
      'dist=${distancia.isNaN ? 'nan' : distancia.toStringAsFixed(0)} '
      'umbral=${umbral.toStringAsFixed(0)} '
      'v=${(velocidadMps * 3.6).toStringAsFixed(1)}km/h '
      'fuera=$_fueraConsecutivas/${ApiConfig.desvioMuestrasConsecutivas} '
      'pts=${_ruta.length} parachute=$_descartado '
      'parado=$_pausadoPorParado espera=$enPausaPostRecalculo '
      'intentos=$_intentos',
    );
  }

  /// Cada cuantas muestras del GPS se escribe una linea de deteccion.
  ///
  /// 5. A 1 Hz es una linea cada 5 s: bastante para ver la tendencia de la
  /// distancia sin llenar el fichero (que ya llega a 10 MB en un viaje).
  static const int cadaCuantasTrazas = 5;

  int _contadorTrazas = 0;

  // ---------------- Deteccion ----------------

  /// Gestiona la pausa por vehiculo parado.
  ///
  /// Entra por debajo de 1 km/h y solo se considera parado si aguanta mas de
  /// 10 s: arrancar y frenar en un semaforo no debe paucar nada. Sale al
  /// superar 3 km/h, con margen para que el GPS no fluctuate en el umbral.
  void _detectarParado(double velocidadMps) {
    if (velocidadMps < ApiConfig.pausaVelocidadBajaMps) {
      _muestrasParado++;
      if (_muestrasParado >= ApiConfig.pausaMuestrasParado &&
          !_pausadoPorParado) {
        _pausadoPorParado = true;
        notifyListeners();
      }
    } else if (velocidadMps > ApiConfig.pausaVelocidadAltaMps) {
      _muestrasParado = 0;
      if (_pausadoPorParado) {
        _pausadoPorParado = false;
        notifyListeners();
      }
    }
    // En la banda intermedia no se toca nada: es la zona de ruido y es
    // justo donde el vehiculo acelera o frena.
  }

  bool get pausadoPorParado => _pausadoPorParado;

  /// `true` dentro de los cinco segundos posteriores a pedir un recalculo.
  bool get enPausaPostRecalculo {
    final ultimo = _ultimoRecalculoMs;
    if (ultimo == null) return false;
    final transcurrido = _reloj.elapsedMilliseconds - ultimo;
    return transcurrido < ApiConfig.desvioPausaMsTrasRecalculo.inMilliseconds;
  }

  // ---------------- Peticion ----------------

  Future<void> _pedirRecalculo() async {
    final destino = _destino;
    TrazaFichero.instancia.escribir('[RECALC] pido ruta: origen='
        '${_ultimaPosicionConocida?.latitude.toStringAsFixed(5)},'
        '${_ultimaPosicionConocida?.longitude.toStringAsFixed(5)} '
        'destino=${destino?.latitude.toStringAsFixed(5)},'
        '${destino?.longitude.toStringAsFixed(5)} '
        'intento=${_intentos + 1}');
    if (destino == null) return;
    if (_descartado) return;

    // Candado de una peticion en vuelo. Sin esto se encadenaban varias: el
    // sondeo del GPS llegaba cada segundo, la primera peticion todavia no habia
    // vuelto y se lanzaba otra encima. `_ultimoRecalculoMs` solo se escribe al
    // pedir, asi que la pausa no cubria la ventana entre pedir y recibir, que es
    // justo la que dura el POST al backend. Con varias en vuelo, cada respuesta
    //idia reiniciando la ruta y la anterior, y el mapa no terminaba de fijarse
    // en ninguna: de ahi que se veía "el mapa no orienta".
    if (_enVuelo) return;
    _enVuelo = true;

    _ultimoRecalculoMs = _reloj.elapsedMilliseconds;
    _setEstado(RouteRecalcState.calculating);

    final origen = _ultimaPosicionConocida;
    if (origen == null) {
      _enVuelo = false;
      _setEstado(RouteRecalcState.error);
      return;
    }

    try {
      final json = await _postJson('$_rutaEndpoint?_=${_reloj.elapsedMilliseconds}', {
        'origin': {'lat': origen.latitude, 'lng': origen.longitude},
        'destination': {'lat': destino.latitude, 'lng': destino.longitude},
        'profile': 'driving',
      });
      // El candado se suelta en cuanto llega la respuesta, antes de decidir que
      // hacer con ella: si se quedara puesto durante el enfriamiento, un fallo
      // bloquearia los reintentos del backoff.
      _enVuelo = false;
      if (_descartado) return;

      final ruta = _rutaDesdeJson(json);
      if (ruta == null || ruta.points.length < 2) {
        _fallarYReintentar();
        return;
      }

      // La ruta devuelta tiene que ser NUESTRA, no la del viaje original.
      //
      // Queja del conductor: al corregir el desvio y cogerse la secundaria, el
      // mapa volvia a la ruta de antes, ya estando lejos. Lo que encaja es que el
      // backend tenga el resultado cacheado por el par origen/destino, y como el
      // origen se manda redondeado, una peticion desde la nueva posicionCaen en
      // la entrada vieja y devuelve el trazado inicial.
      //
      // Una ruta de verdad empieza donde estamos, a pocos metros. Si el punto de
      // la polilinea mas cercano esta lejos, lo que ha llegado no es la ruta que
      // se pidio y no se aplica: se cuenta como fallo y se reintenta con el
      // candado de espera que ya hay.
      final aqui = _ultimaPosicionConocida;
      if (aqui != null && !_empiezaCercaDe(aqui, ruta.points)) {
        final d = _distanciaMinima(aqui, ruta.points);
        debugPrint('[RECALC] ruta descartada: su punto mas cercano esta a '
            '${d.toStringAsFixed(0)} m (parece la cache del viaje original)');
        _fallarYReintentar();
        return;
      }

      _ruta = ruta.points;
      _intentos = 0;
      _setEstado(RouteRecalcState.success);
      TrazaFichero.instancia.escribir('[RECALC] ruta nueva APLICADA: '
          '${ruta.points.length} puntos, ${ruta.distanceKm.toStringAsFixed(2)} km');
      _rutaCambiada.add(ruta);

      // Enfriamiento: si el chofer sigue fuera de la nueva ruta, se necesita un
      // margen antes de volver a intentarlo. Sin esto se encadena un recalculo
      // cada tres segundos si el destino no es alcanzable.
      _temporizadorEnfriamiento?.cancel();
      _temporizadorEnfriamiento = Timer(
        ApiConfig.desvioEnfriamientoMs,
        () {
          _temporizadorEnfriamiento = null;
          if (!_descartado) _setEstado(RouteRecalcState.idle);
        },
      );
    } catch (_) {
      _enVuelo = false;
      if (_descartado) return;
      _fallarYReintentar();
    }
  }

  /// Marca un fallo y programa el siguiente intento con backoff exponencial.
  ///
  /// La secuencia es 5, 10, 20 y 40 segundos. Al cuarto fallo se para: a partir
  /// de ahi no hay ruta que dibujar y el chofer sigue viendo la anterior, que
  /// es mejor que un spinner infinito.
  void _fallarYReintentar() {
    _intentos++;
    TrazaFichero.instancia.escribir('[RECALC] fallo, intento $_intentos'
        '${_intentos >= ApiConfig.desvioIntentosMaximos ? ' -> AGOTADO' : ''}');
    if (_intentos >= ApiConfig.desvioIntentosMaximos) {
      _descartado = true;
      _setEstado(RouteRecalcState.agotado);
      return;
    }

    _setEstado(RouteRecalcState.error);

    final espera = ApiConfig.desvioBackoffInicial * (1 << (_intentos - 1));
    _temporizadorReintento?.cancel();
    _temporizadorReintento = Timer(espera, () {
      _temporizadorReintento = null;
      if (!_descartado) _pedirRecalculo();
    });
  }

  /// Ruta leida de la respuesta del backend.
  ///
  /// Acepta el formato propio del endpoint (`geometry` como GeoJSON) y tambien
  /// el de OSRM crudo (`routes[0].geometry`), para no depender de un unico
  /// formato si el backend cambia.
  OsrmRoute? _rutaDesdeJson(Map<String, dynamic> json) {
    Map<String, dynamic>? geo;

    final g = json['geometry'];
    if (g is Map<String, dynamic>) {
      geo = g;
    } else {
      final routes = json['routes'];
      if (routes is List && routes.isNotEmpty) {
        final primero = routes.first;
        if (primero is Map<String, dynamic>) {
          final gg = primero['geometry'];
          if (gg is Map<String, dynamic>) geo = gg;
        }
      }
    }
    if (geo == null || geo['type'] != 'LineString') return null;

    final coords = geo['coordinates'];
    if (coords is! List || coords.length < 2) return null;

    final puntos = <LatLng>[];
    for (final c in coords) {
      if (c is! List || c.length < 2) continue;
      final lon = (c[0] as num).toDouble();
      final lat = (c[1] as num).toDouble();
      puntos.add(LatLng(lat, lon));
    }
    if (puntos.length < 2) return null;

    return OsrmRoute(
      points: puntos,
      distanceMeters: (json['distance_meters'] as num?)?.toDouble() ??
          (json['distance'] as num?)?.toDouble() ??
          0.0,
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble() ??
          (json['duration'] as num?)?.toDouble() ??
          0.0,
    );
  }

  void _setEstado(RouteRecalcState s) {
    if (_estado == s) return;
    _estado = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _temporizadorReintento?.cancel();
    _temporizadorEnfriamiento?.cancel();
    _rutaCambiada.close();
    _reloj.stop();
    super.dispose();
  }

  // ---------------- Geometria ----------------

  /// Posicion sobre la que se pide el recalculo: la ultima informada.
  ///
  /// Se guarda aparte de `_ruta` porque la polilinea es el trazado y aqui hace
  /// falta el punto donde esta el coche, que es el origen de la ruta nueva.
  LatLng? _ultimaPosicionConocida;

  /// Endpoint del backend para el recalculo.
  static const String _rutaEndpoint = '/api/routing/recalculate';

  /// Distancia maxima a la que puede estar la ruta nueva respecto de donde
  /// estamos para darla por buena.
  ///
  /// 200 m. Una ruta calculada ahora mismo arranca en el origen, a unos metros.
  /// Este margen Absorbe el error del GPS y que el backend parta el origen con
  /// precision propia, y aun asi deja fuera el caso de la ruta cacheada: cuando
  /// ha vuelto a la inicial, el punto mas cercano estaba a cientos de metros,
  /// porque el conductor ya habia salido de ella.
  static const double _distanciaRutaValidaM = 200.0;

  /// `true` si algun punto de la polilinea esta lo bastante cerca de [origen].
  static bool _empiezaCercaDe(LatLng origen, List<LatLng> puntos) {
    return _distanciaMinima(origen, puntos) <= _distanciaRutaValidaM;
  }

  /// Distancia en metros de [origen] al vertice mas proximo de [puntos].
  static double _distanciaMinima(LatLng origen, List<LatLng> puntos) {
    if (puntos.isEmpty) return double.infinity;
    var min = double.infinity;
    for (final p in puntos) {
      final dx = (p.longitude - origen.longitude) * 111320.0 *
          math.cos(origen.latitude * math.pi / 180.0);
      final dy = (p.latitude - origen.latitude) * 110574.0;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < min) min = d;
    }
    return min;
  }

  /// Distancia perpendicular del punto [p] a la polilinea [linea], en metros.
  ///
  /// Proyecta sobre cada segmento y se queda con la minima. Calcular la
  /// distancia al vertice mas cercano daria un error grande en los tramos
  /// largos: en un segmento de 200 m de recto, el punto mas cercano es uno de
  /// los extremos y el calculo da hasta 100 m de mas.
  ///
  /// Trabaja en metros locales: convierte a un plano tangente con la
  /// latitud de referencia, que a escala de ciudad no distorsiona.
  static double distanciaPerpendicularMetros(LatLng p, List<LatLng> linea) {
    if (linea.length < 2) return double.infinity;

    // Escala local: 1 grado de latitud son unos 111320 m. En longitud el factor
    // lleva el coseno de la latitud, que es lo que hace la cuenta valida fuera
    // del ecuador.
    const metrosPorGradoLat = 111320.0;
    final escalaLon =
        metrosPorGradoLat * math.cos(p.latitude * math.pi / 180.0);

    double mejor = double.infinity;

    for (var i = 0; i < linea.length - 1; i++) {
      final a = linea[i];
      final b = linea[i + 1];

      // Punto en metros locales respecto de [p], para no arrastrar los valores
      // grandes de latitud en cada resta.
      final ax = (a.longitude - p.longitude) * escalaLon;
      final ay = (a.latitude - p.latitude) * metrosPorGradoLat;
      final bx = (b.longitude - p.longitude) * escalaLon;
      final by = (b.latitude - p.latitude) * metrosPorGradoLat;

      final dx = bx - ax;
      final dy = by - ay;
      final largo2 = dx * dx + dy * dy;

      // Segmento degenerado: dos vertices identicos. Se trata como distancia
      // al punto, que es lo que es.
      if (largo2 <= 1e-9) {
        final d = math.sqrt(ax * ax + ay * ay);
        if (d < mejor) mejor = d;
        continue;
      }

      // Proyeccion del punto [p] (que aqui es el origen) sobre el segmento.
      final t = (-ax * dx - ay * dy) / largo2;
      final tc = t.clamp(0.0, 1.0);
      final px = ax + tc * dx;
      final py = ay + tc * dy;

      final d = math.sqrt(px * px + py * py);
      if (d < mejor) mejor = d;
    }

    return mejor;
  }

  // ---------------- Red ----------------

  /// Cliente HTTP por defecto, contra el backend propio.
  ///
  /// Va al backend y no a OSRM directo por dos razones: el movil no sale a
  /// internet de forma fiable, y centralizarlo permite cambiar el umbral o el
  /// perfil sin reinstalar la app.
  static Future<Map<String, dynamic>> _postPorDefecto(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final j = await ApiClient.post('${ApiConfig.baseUrl}$endpoint', body: body);
    return (j as Map<String, dynamic>?) ?? const {};
  }
}