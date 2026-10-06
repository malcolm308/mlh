import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../config.dart';
import 'osrm_service.dart';

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
/// ruido por los edificios y las calles estrechas, asi que 40 m es
/// conservador y evita recambios por una sola lectura mala. En carretera la
/// carretera es mas ancha y el GPS mas limpio, asi que se puede exigir mas
/// antes de dar un desvio por bueno.
enum ZonaRuta { ciudad, carretera }

/// Cuanto mide un desvio antes de pedir ruta nueva, en metros.
///
/// Se sube de 40 a 80 en carretera. Un parametro generico daria falsos
/// positivos en una y falsos negativos en la otra.
extension UmbralZonaRuta on ZonaRuta {
  double get metros => switch (this) {
        ZonaRuta.ciudad => AppConfig.desvioUmbralCiudadMetros,
        ZonaRuta.carretera => AppConfig.desvioUmbralCarreteraMetros,
      };
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

  /// Zona actual, la decide la velocidad como en el resto del modo navegacion.
  ZonaRuta _zona = ZonaRuta.ciudad;

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
    _destino = destino;
    _ruta = ruta;
    _fueraConsecutivas = 0;
    _muestrasParado = 0;
    _pausadoPorParado = false;
    _intentos = 0;
    _descartado = false;
    _temporizadorReintento?.cancel();
    _temporizadorEnfriamiento?.cancel();
    _temporizadorReintento = null;
    _temporizadorEnfriamiento = null;
    _ultimoRecalculoMs = null;
    if (!_reloj.isRunning) _reloj.start();
    _setEstado(RouteRecalcState.idle);
  }

  /// Corta el seguimiento y suelta los temporizadores.
  ///
  /// Se llama al cancelar o completar el viaje. Cancelar los temporizadores es
  /// lo que evita que una peticion en vuelo wakee el servicio mas tarde.
  void detener() {
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
    _setEstado(RouteRecalcState.idle);
  }

  /// Consume una muestra de posicion.
  ///
  /// [velocidadMps] es la velocidad YA filtrada, nunca la cruda del sensor.
  /// [posicion] tambien viene suavizada: medir la distancia contra una
  /// posicion con error de 30 m daria desvios falsos en cada esquina.
  void informarPosicion(LatLng posicion, double velocidadMps) {
    if (_descartado) return;
    if (_ruta.length < 2) return; // sin trazado no hay nada que comparar
    if (!_reloj.isRunning) _reloj.start();

    _actualizarZona(velocidadMps);
    _detectarParado(velocidadMps);

    // Se guarda la ultima posicion para usarla como origen del recalculo: es el
    // punto exacto donde el conductor se salio, no un vertice de la ruta vieja.
    _ultimaPosicionConocida = posicion;

    // En pausa por parado no se cuenta nada, pero tampoco se borra el
    // contador: al arrancar puede que siga fuera de ruta de verdad.
    if (_pausadoPorParado) return;

    // Cinco segundos de calma tras un recalculo. El conductor aun no ha
    // corregido y su posicion sigue en la calle anterior.
    if (enPausaPostRecalculo) return;

    final distancia = distanciaPerpendicularMetros(posicion, _ruta);

    if (distancia > _zona.metros) {
      _fueraConsecutivas++;
      if (_fueraConsecutivas >= AppConfig.desvioMuestrasConsecutivas) {
        _fueraConsecutivas = 0;
        _pedirRecalculo();
      }
    } else {
      // Cualquier lectura dentro de ruta descarta las anteriores. Es lo que
      // hace que un solo fix malo no dispare nada.
      _fueraConsecutivas = 0;
    }
  }

  // ---------------- Deteccion ----------------

  void _actualizarZona(double velocidadMps) {
    _zona = velocidadMps >= AppConfig.desvioVelocidadCarreteraMps
        ? ZonaRuta.carretera
        : ZonaRuta.ciudad;
  }

  /// Gestiona la pausa por vehiculo parado.
  ///
  /// Entra por debajo de 1 km/h y solo se considera parado si aguanta mas de
  /// 10 s: arrancar y frenar en un semaforo no debe paucar nada. Sale al
  /// superar 3 km/h, con margen para que el GPS no fluctuate en el umbral.
  void _detectarParado(double velocidadMps) {
    if (velocidadMps < AppConfig.pausaVelocidadBajaMps) {
      _muestrasParado++;
      if (_muestrasParado >= AppConfig.pausaMuestrasParado &&
          !_pausadoPorParado) {
        _pausadoPorParado = true;
        notifyListeners();
      }
    } else if (velocidadMps > AppConfig.pausaVelocidadAltaMps) {
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
    return transcurrido < AppConfig.desvioPausaMsTrasRecalculo.inMilliseconds;
  }

  // ---------------- Peticion ----------------

  Future<void> _pedirRecalculo() async {
    final destino = _destino;
    if (destino == null) return;
    if (_descartado) return;

    _ultimoRecalculoMs = _reloj.elapsedMilliseconds;
    _setEstado(RouteRecalcState.calculating);

    final origen = _ultimaPosicionConocida;
    if (origen == null) {
      _setEstado(RouteRecalcState.error);
      return;
    }

    try {
      final json = await _postJson(_rutaEndpoint, {
        'origin': {'lat': origen.latitude, 'lng': origen.longitude},
        'destination': {'lat': destino.latitude, 'lng': destino.longitude},
        'profile': 'driving',
      });
      if (_descartado) return;

      final ruta = _rutaDesdeJson(json);
      if (ruta == null || ruta.points.length < 2) {
        _fallarYReintentar();
        return;
      }

      _ruta = ruta.points;
      _intentos = 0;
      _setEstado(RouteRecalcState.success);
      _rutaCambiada.add(ruta);

      // Enfriamiento: si elChofer sigue fuera de la nueva ruta, se necesita un
      // margen antes de volver a intentarlo. Sin esto se encadena un recalculo
      // cada tres segundos si el destino no es alcanzable.
      _temporizadorEnfriamiento?.cancel();
      _temporizadorEnfriamiento = Timer(
        AppConfig.desvioEnfriamientoMs,
        () {
          _temporizadorEnfriamiento = null;
          if (!_descartado) _setEstado(RouteRecalcState.idle);
        },
      );
    } catch (_) {
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
    if (_intentos >= AppConfig.desvioIntentosMaximos) {
      _descartado = true;
      _setEstado(RouteRecalcState.agotado);
      return;
    }

    _setEstado(RouteRecalcState.error);

    final espera = AppConfig.desvioBackoffInicial * (1 << (_intentos - 1));
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
    final uri = Uri.parse('${AppConfig.apiBase}$endpoint');
    final respuesta = await http.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (respuesta.statusCode < 200 || respuesta.statusCode >= 300) {
      throw Exception('Backend devolvio ${respuesta.statusCode}');
    }
    if (respuesta.body.trim().isEmpty) return const {};
    return jsonDecode(utf8.decode(respuesta.bodyBytes))
        as Map<String, dynamic>;
  }
}