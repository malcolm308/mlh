import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../api_config.dart';
import 'api_client.dart';

/// Un paso de la ruta, tal como lo devuelve `POST /api/routing/navegacion`.
class PasoRuta {
  final String instruccion;
  final double distanciaMetros;
  final String tipoManiobra;
  final LatLng coordenada;

  const PasoRuta({
    required this.instruccion,
    required this.distanciaMetros,
    required this.tipoManiobra,
    required this.coordenada,
  });

  factory PasoRuta.fromJson(Map<String, dynamic> j) {
    final coord = (j['coordenada'] ?? const {}) as Map;
    return PasoRuta(
      instruccion: (j['instruccion'] ?? '').toString(),
      distanciaMetros: (j['distancia_metros'] as num?)?.toDouble() ?? 0,
      tipoManiobra: (j['tipo_maniobra'] ?? '').toString(),
      coordenada: LatLng(
        (coord['lat'] as num?)?.toDouble() ?? 0,
        (coord['lng'] as num?)?.toDouble() ?? 0,
      ),
    );
  }
}

/// Estado que consume el widget flotante.
class EstadoAsistente {
  final String instruccion;
  final double distanciaMetros;
  final String tipoManiobra;

  const EstadoAsistente({
    required this.instruccion,
    required this.distanciaMetros,
    required this.tipoManiobra,
  });

  bool get activa => instruccion.isNotEmpty;
}

/// Asistente de ruta paso a paso, con ROUTE SNAPPING.
///
/// Tres piezas evitan el mareo del asistente:
///
///  1. **Polyline**: se guarda la geometria completa que devuelve
///     `/api/routing/navegacion` (LineString de OSRM). La distancia a la
///     proxima maniobra NO se parte del GPS crudo ni de una recta: se proyecta
///     el coche sobre el trazado (`snap`) y se camina el arco hasta el vertice
///     del giro.
///  2. **Snap**: en cada fix se busca el tramo mas cercano SOLO alrededor del
///     ultimo indice conocido (ventana de [snapVentana] puntos): barato y sin
///     confundir calles paralelas. Si el mejor queda > 150 m (desvio grande),
///     se busca global una vez y la ruta se re-pide desde ahi.
///  3. **Filtro GPS**: con velocidad < [velocidadBajaKmh] (parado, trafico)
///     NO se actualiza la distancia ni se avanza: queda la ultima instrucccion
///     valida.
///
/// El paso avanza solo si se cumplen DOS condiciones:
///
///  * la distancia de ARCO desde el punto encajado hasta el giro es menor que
///    el umbral dinamico por velocidad ([radioAvancePara]: 20 m por debajo de
///    20 km/h, 150 m por encima de 50 km/h), y
///  * el indice del coche en el trazado ya supero el punto de la maniobra
///    ANTERIOR. Asi un salto del GPS no puede saltarse instrucciones.
class AsistenteRutaService extends ChangeNotifier {
  /// Radio de avance en ciudad (velocidad < 20 km/h).
  static const double radioAvanceCiudad = 20.0;

  /// Radio de avance en carretera (velocidad > 50 km/h).
  static const double radioAvanceCarretera = 150.0;

  static const double velocidadBajaKmh = 5.0;
  static const double _velocidadCiudadKmh = 20.0;
  static const double _velocidadCarreteraKmh = 50.0;

  static const Duration refrescoRuta = Duration(seconds: 60);
  static const int snapVentana = 60;

  /// Umbral de avance segun la velocidad del momento.
  ///
  /// Por debajo de 20 km/h avanza a 20 m del giro; por encima de 50 km/h, a
  /// 150 m. En medio se interpola linealmente para que el salto no sea brusco.
  static double radioAvancePara(double? velocidadKmh) {
    final v = velocidadKmh ?? 0;
    if (v <= _velocidadCiudadKmh) return radioAvanceCiudad;
    if (v >= _velocidadCarreteraKmh) return radioAvanceCarretera;
    final t = (v - _velocidadCiudadKmh) /
        (_velocidadCarreteraKmh - _velocidadCiudadKmh);
    return radioAvanceCiudad + t * (radioAvanceCarretera - radioAvanceCiudad);
  }

  final List<PasoRuta> _pasos = [];
  final List<LatLng> _polyline = [];

  /// Indice del vertice de la polilinea donde esta cada maniobra. Se calcula
  /// UNA vez al recibir la ruta: comparar indices es barato y es lo que
  /// permite validar "ya pase la maniobra anterior".
  final List<int> _indicesGiro = [];

  int _indice = 0;
  int _snapIndex = 0;
  double _snapFraccion = 0;
  double _restoAlPunto = 0;
  double _velocidadKmh = 0;
  Timer? _refresco;
  String? _tripId;
  String? _fase; // 'recogida' | 'destino'
  LatLng? _origen;
  LatLng? _destino;
  bool _pidiendo = false;

  /// Generacion de la ruta. Cada `iniciar`/`detener` la incrementa: una
  /// respuesta de OSRM que llega tarde (viaje completado, cambio de fase) se
  /// descarta en vez de repoblar la cola de maniobras de un viaje que ya no
  /// existe.
  int _generacion = 0;

  EstadoAsistente estado() {
    if (_pasos.isEmpty || _indice >= _pasos.length) {
      return EstadoAsistente(
          instruccion: '', distanciaMetros: 0, tipoManiobra: '');
    }
    final paso = _pasos[_indice];
    // `_restoAlPunto` es la distancia de ARCO que falta HASTA ESTE giro
    // (no la longitud del paso de OSRM, que era lo que se restaba antes y
    // daba cifras sin sentido).
    final restante = _restoAlPunto;
    return EstadoAsistente(
      instruccion: paso.instruccion,
      distanciaMetros: restante < 0 ? 0 : restante,
      tipoManiobra: paso.tipoManiobra,
    );
  }

  bool get activo => _destino != null && _pasos.isNotEmpty;

  /// Aviso de RUTA NUEVA (fase o recalculo): ahi arriba camino todo el trazo
  /// para que el chofer sea el DUEÑO de la ruta y el cliente la replique
  /// copiando la misma geometria.
  void Function(List<LatLng> puntos)? _onRutaNueva;
  set onRutaNueva(void Function(List<LatLng> puntos)? cb) => _onRutaNueva = cb;

  /// Arranca (o rearraanca con destino/fase nueva). [fase]=`recogida` al
  /// aceptar, `destino` al presionar "Iniciar Viaje": el cambio de fase
  /// OBLIGA a borrar los pasos viejos y pedir la ruta hacia el nuevo destino
  /// (si no, el asistente seguiria dando indicaciones de la ruta vieja).
  Future<void> iniciar({
    required String tripId,
    required String fase,
    required LatLng origen,
    required LatLng destino,
  }) async {
    final mismo = _tripId == tripId &&
        _fase == fase &&
        _destino != null &&
        _pasos.isNotEmpty;
    if (mismo) return;
    _generacion++;
    _pidiendo = false;
    _tripId = tripId;
    _fase = fase;
    _origen = origen;
    _destino = destino;
    _pasos.clear();
    _polyline.clear();
    _indicesGiro.clear();
    _indice = 0;
    _snapIndex = 0;
    _snapFraccion = 0;
    _restoAlPunto = 0;
    _velocidadKmh = 0;
    notifyListeners();
    await _pedirRuta();
    _refresco?.cancel();
    _refresco = Timer.periodic(refrescoRuta, (_) => unawaited(_pedirRuta()));
  }

  /// Reset completo (completar, cancelar, perder el viaje).
  void detener() {
    _generacion++;
    _pidiendo = false;
    _tripId = null;
    _fase = null;
    _destino = null;
    _pasos.clear();
    _polyline.clear();
    _indicesGiro.clear();
    _indice = 0;
    _snapIndex = 0;
    _refresco?.cancel();
    _refresco = null;
    notifyListeners();
  }

  /// Llega el fix del chofer. Con velocidad < 5 km/h se ignora para el
  /// calculo: mantiene la ultima instruccion valida.
  void conPosicion(LatLng p, {double? velocidadKmh}) {
    if (_pasos.isEmpty || _indice >= _pasos.length) return;
    _origen = p;
    if (velocidadKmh != null) _velocidadKmh = velocidadKmh;
    // Parado (semáforo, atasco): el GPS vibra y un avance aqui seria
    // fantasma. Se conserva la instruccion y la distancia anteriores.
    if (_velocidadKmh < velocidadBajaKmh) return;
    if (_polyline.length < 2) {
      // Sin polyline (OSRM fallo): fallback con el GPS crudo. El umbral
      // dinamico sigue vigente.
      _apuntarResto(_distancia(p, _pasos[_indice].coordenada));
      return;
    }

    // 1. Snap sobre TRAMOS (no vertices): el coche queda proyectado en el
    //    punto exacto del trazado, no en la esquina de celda mas proxima.
    final snap = _snapSegmento(p);
    if (snap.$3 > 150) {
      // DESVIO: el chofer ya no esta cerca del trazo. Se vacia la COLA de
      // maniobras, se vuelve a pedir la ruta a OSRM y el indice reinicia en
      // 0 (comportamiento de navegadores reales). Ninguna instruccion del
      // trazado viejo puede quedar visible.
      _polyline.clear();
      _pasos.clear();
      _indicesGiro.clear();
      _indice = 0;
      _snapIndex = 0;
      _snapFraccion = 0;
      _restoAlPunto = 0;
      notifyListeners();
      unawaited(_pedirRuta());
      return;
    }
    _snapIndex = snap.$1;
    _snapFraccion = snap.$2;

    // 2. Validacion de "pasado el punto": el indice del coche en el trazado
    //    debe haber superado el vertice de la maniobra ANTERIOR. Sin esto,
    //    un salto del GPS avanzaria la cola entera de golpe.
    final giroVigente = _polylineIndexDe(_indice);
    final superoAnterior = _indice == 0 ||
        _snapIndex >= _polylineIndexDe(_indice - 1);

    // 3. Distancia de ARCO: del punto proyectado, caminando el trazado
    //    hacia adelante hasta el vertice del giro vigente.
    _apuntarResto(_arcoHastaVertice(_snapIndex, _snapFraccion, giroVigente));

    // 4. Avance: solo con AMBAS condiciones. Un avance por fix (el proximo
    //    fix, 1 s despues, avanza el siguiente si corresponde).
    if (superoAnterior && _restoAlPunto <= _umbralAvance()) {
      if (_indice < _pasos.length - 1) {
        _indice++;
        _restoAlPunto = _arcoHastaVertice(
            _snapIndex, _snapFraccion, _polylineIndexDe(_indice));
      }
      notifyListeners();
    }
  }

  /// Indice del vertice de la maniobra [paso] en la polilinea. Si los pasos y
  /// los vertices no estan alineados (ruta recargada a medias), lo busca.
  int _polylineIndexDe(int paso) {
    if (paso < 0 || paso >= _indicesGiro.length) return 0;
    return _indicesGiro[paso];
  }

  /// Umbral de avance del momento: 20 m por debajo de 20 km/h, 150 m por
  /// encima de 50 km/h, interpolado en medio.
  double _umbralAvance() => radioAvancePara(_velocidadKmh);

  /// Rumbo del VEHICULO calculado analiticamente desdee la ruta (no la
  /// brujula del telefono): punto snap -> punto 2-3 posiciones adelante.
  ///
  /// Es el bearing que viaja forward: al cliente (WS y `/drivers/location`)
  /// para que ambos mapas apunten igual, y como respaldo para el modo
  /// navegacion del chofer cuando el GPS.CourseOfGround no vale.
  ///
  /// Devuelve null si el snap es muy cerca del final (no queda adelante) o
  /// si la velocidad no lo avala (la capa llamante ya resolvera conservar
  /// el ultimo rumbo conocido).
  double? rumboDesdeRuta(LatLng p) {
    if (_polyline.length < 3) return null;
    final idx = _snap(p).$1;
    final desde = _polyline[idx];
    final hasta = _polyline[math.min(_polyline.length - 1, idx + 2)];
    const M = 111000.0;
    final dLat = (hasta.latitude - desde.latitude) * M;
    final dLng = (hasta.longitude - desde.longitude) *
        M *
        math.cos(desde.latitude);
    if (dLat.abs() < 1e-9 && dLng.abs() < 1e-9) return null;
    var deg = math.atan2(dLng, dLat) * 180 / math.pi;
    return (deg + 360) % 360;
  }

  /// Al recalcular por desvio, se regeneran pasos desde el punto actual.
  Future<void> recalcularDesde(LatLng p) async {
    _origen = p;
    _polyline.clear();
    _pasos.clear();
    _indicesGiro.clear();
    _indice = 0;
    _snapIndex = 0;
    _snapFraccion = 0;
    _restoAlPunto = 0;
    notifyListeners();
    await _pedirRuta();
  }

  void _apuntarResto(double resto) {
    if (resto < 0) resto = 0;
    if ((resto - _restoAlPunto).abs() > 5) {
      _restoAlPunto = resto;
      notifyListeners();
    } else {
      // Se guarda sin repintar: cambios de menos de 5 m no valen un frame.
      _restoAlPunto = resto;
    }
  }

  static double _distancia(LatLng a, LatLng b) {
    final dx = (a.latitude - b.latitude) * 111000;
    final dy = (a.longitude - b.longitude) * 111000 * math.cos(a.latitude);
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Proyecta [p] sobre el tramo [a]-[b]. Devuelve `(fraccion, metros)`:
  /// `fraccion` es 0 en [a] y 1 en [b]; `metros` es la distancia perpendicular.
  (double, double) _proyectar(LatLng p, LatLng a, LatLng b) {
    const m = 111000.0;
    final cosLat =
        math.cos(((a.latitude + b.latitude) / 2) * math.pi / 180);
    final ax = a.longitude * m * cosLat;
    final ay = a.latitude * m;
    final bx = b.longitude * m * cosLat;
    final by = b.latitude * m;
    final px = p.longitude * m * cosLat;
    final py = p.latitude * m;
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-9) return (0.0, _distancia(p, a));
    var t = ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final qx = ax + t * dx;
    final qy = ay + t * dy;
    return (t, math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy)));
  }

  /// Tramo de la polilinea mas cercano a [p] entre los indices [desde]..[hasta]
  /// (inclusive). Devuelve `(indiceDelTramo, fraccion, metros)`.
  (int, double, double) _mejorTramo(LatLng p, int desde, int hasta) {
    var mejorI = desde;
    var mejorT = 0.0;
    var mejorD = double.infinity;
    for (var i = desde; i <= hasta; i++) {
      final proj = _proyectar(p, _polyline[i], _polyline[i + 1]);
      if (proj.$2 < mejorD) {
        mejorD = proj.$2;
        mejorI = i;
        mejorT = proj.$1;
      }
    }
    return (mejorI, mejorT, mejorD);
  }

  /// Snap a nivel de TRAMO alrededor de [_snapIndex]. Igual que el snap por
  /// vertice, pero proyectando: el error baja de "media arista" a centimetros.
  /// Devuelve `(indiceDelTramo, fraccion, metros)` y con desvio busca global.
  (int, double, double) _snapSegmento(LatLng p) {
    final ultimo = _polyline.length - 2;
    if (ultimo < 0) return (0, 0.0, _distancia(p, _polyline.first));
    final desde = math.max(0, _snapIndex - 10);
    final hasta = math.min(ultimo, _snapIndex + snapVentana);
    var mejor = _mejorTramo(p, desde, hasta);
    if (mejor.$3 > 150) {
      // Desvio: buscar en todo el trazado; el proximo refresco re-pide pasos.
      mejor = _mejorTramo(p, 0, ultimo);
    }
    return mejor;
  }

  /// Vertice de la polilinea mas cercano a un punto (global). Se usa una vez
  /// por maniobra, al recibir la ruta: ubica el giro en el trazado.
  int _verticeMasCercano(LatLng p) {
    var mejor = 0;
    var mejorD = double.infinity;
    for (var i = 0; i < _polyline.length; i++) {
      final d = _distancia(p, _polyline[i]);
      if (d < mejorD) {
        mejorD = d;
        mejor = i;
      }
    }
    return mejor;
  }

  /// Distancia de ARCO (metros) desde el punto proyectado `(desdeSeg,
  /// desdeT)` hasta el vertice [giro], caminando el trazado hacia adelante.
  /// Si el giro ya quedo atras, devuelve 0.
  double _arcoHastaVertice(int desdeSeg, double desdeT, int giro) {
    final ultimo = _polyline.length - 1;
    final seg = desdeSeg.clamp(0, ultimo - 1 < 0 ? 0 : ultimo - 1);
    if (ultimo < 1) return 0;
    if (giro <= seg) return 0;
    final largoTramo = _distancia(_polyline[seg], _polyline[seg + 1]);
    var arco = largoTramo * (1 - desdeT.clamp(0.0, 1.0));
    for (var i = seg + 1; i < giro; i++) {
      arco += _distancia(_polyline[i], _polyline[i + 1]);
    }
    return arco;
  }

  /// Indice del punto de la ruta mas cercano, buscando cerca de [_snapIndex].
  /// Devuelve `(indice, distanciaMetros)`.
  (int, double) _snap(LatLng p) {
    if (_polyline.isEmpty) return (0, 0);
    final desde = math.max(0, _snapIndex - snapVentana ~/ 4);
    final hasta = math.min(_polyline.length - 1, _snapIndex + snapVentana);
    var mejorIdx = _snapIndex;
    var mejor = double.infinity;
    for (var i = desde; i <= hasta; i++) {
      final d = _distancia(p, _polyline[i]);
      if (d < mejor) {
        mejor = d;
        mejorIdx = i;
      }
    }
    if (mejor > 150) {
      // Desvio: buscar global y con esto el proximo refresco re-pide pasos.
      for (var i = 0; i < _polyline.length; i++) {
        final d = _distancia(p, _polyline[i]);
        if (d < mejor) {
          mejor = d;
          mejorIdx = i;
        }
      }
    }
    return (mejorIdx, mejor);
  }

  Future<void> _pedirRuta() async {
    if (_pidiendo) return;
    final origen = _origen;
    final destino = _destino;
    if (origen == null || destino == null) return;
    final generacion = _generacion;
    _pidiendo = true;
    try {
      final json = await ApiClient.post(
        '${ApiConfig.baseUrl}/api/routing/navegacion',
        body: {
          'origin': {'lat': origen.latitude, 'lng': origen.longitude},
          'destination': {'lat': destino.latitude, 'lng': destino.longitude},
          'profile': 'driving',
        },
      );
      // Respuesta tardia de un viaje/fase que ya no existe: no se toca la cola.
      if (generacion != _generacion || _destino == null) return;
      final lista = (json['steps'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PasoRuta.fromJson)
          .toList();
      final geo = json['geometry'] as Map<String, dynamic>?;
      final coords = geo?['coordinates'] as List<dynamic>? ?? const [];
      _polyline
        ..clear()
        ..addAll(coords.whereType<List>().map(
            (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())));
      _pasos
        ..clear()
        ..addAll(lista);
      // Ubicar cada maniobra en su vertice del trazado UNA vez: es lo que
      // permite comparar "indice del coche vs indice del giro" en cada fix
      // sin rebuscar en la polilinea.
      _indicesGiro
        ..clear()
        ..addAll(_pasos.map((p) => _verticeMasCercano(p.coordenada)));
      // El primer paso ("Salga...") ya es la posicion actual: apuntar al
      // segundo, la instruccion real.
      _indice = _pasos.length > 1 ? 1 : 0;
      final snap = _snapSegmento(origen);
      _snapIndex = _polyline.length < 2 ? 0 : snap.$1;
      _snapFraccion = snap.$2;
      // Distancia inicial por arco hasta la maniobra vigente, para que el
      // tablero no arranque en "0 m" hasta el primer fix del GPS.
      _restoAlPunto = _indicesGiro.isEmpty || _indice >= _indicesGiro.length
          ? 0
          : _arcoHastaVertice(
              _snapIndex, _snapFraccion, _indicesGiro[_indice]);
      notifyListeners();
      // Nueva ruta (fase/num recalculo): avisar a quien quiera dibujar el
      // mismo trazo (el cliente lo recibe por WS desde el chofer).
      _onRutaNueva?.call(_polyline);
    } catch (e) {
      debugPrint('[ASISTENTE] ruta paso a paso fallo: $e');
    } finally {
      // Solo la peticion vigente puede liberar el candado: si se reinicio la
      // fase mientras esta volaba, el candado pertenece a la nueva.
      if (generacion == _generacion) _pidiendo = false;
    }
  }
}
