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
///     proxima maniobra NO se parte del GPS crudo: se parte del punto de la
///     ruta mas cercano al coche (`snap`), caminando el trazo hasta el punto
///     de maniobra.
///  2. **Snap**: en cada fix se busca el punto mas cercano SOLO alrededor del
///     ultimo indice conocido (ventana de [snapVentana] puntos): barato y sin
///     confundir calles paralelas. Si el mejor queda > 150 m (desvio grande),
///     se busca global una vez y la ruta se re-pide desde ahi.
///  3. **Filtro GPS**: con velocidad < [velocidadBajaKmh] (parado, trafico)
///     NO se actualiza la distancia ni se avanza: queda la ultima instrucccion
///     valida.
///
/// El paso avanza al pasar a menos de [radioAvance] (20 m) del punto de
/// maniobra, medido desde el punto ENCAJADO (no desde el GPS crudo).
class AsistenteRutaService extends ChangeNotifier {
  static const double radioAvance = 30.0;
  static const double velocidadBajaKmh = 5.0;
  static const Duration refrescoRuta = Duration(seconds: 60);
  static const int snapVentana = 60;

  final List<PasoRuta> _pasos = [];
  final List<LatLng> _polyline = [];
  int _indice = 0;
  int _snapIndex = 0;
  double _restoAlPunto = 0;
  Timer? _refresco;
  String? _tripId;
  String? _fase; // 'recogida' | 'destino'
  LatLng? _origen;
  LatLng? _destino;
  bool _pidiendo = false;

  EstadoAsistente estado() {
    if (_pasos.isEmpty || _indice >= _pasos.length) {
      return EstadoAsistente(
          instruccion: '', distanciaMetros: 0, tipoManiobra: '');
    }
    final paso = _pasos[_indice];
    final restante = paso.distanciaMetros - _restoAlPunto;
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
    _tripId = tripId;
    _fase = fase;
    _origen = origen;
    _destino = destino;
    _pasos.clear();
    _polyline.clear();
    _indice = 0;
    _snapIndex = 0;
    _restoAlPunto = 0;
    notifyListeners();
    await _pedirRuta();
    _refresco?.cancel();
    _refresco = Timer.periodic(refrescoRuta, (_) => unawaited(_pedirRuta()));
  }

  /// Reset completo (completar, cancelar, perder el viaje).
  void detener() {
    _tripId = null;
    _fase = null;
    _destino = null;
    _pasos.clear();
    _polyline.clear();
    _indice = 0;
    _snapIndex = 0;
    _refresco?.cancel();
    _refresco = null;
    notifyListeners();
  }

  /// Llega el fix del chofer. Con velocidad < 5 km/h se ignora para el
  /// calculo: mantine la ultima instruccion valida.
  void conPosicion(LatLng p, {double? velocidadKmh}) {
    if (_pasos.isEmpty || _indice >= _pasos.length) return;
    _origen = p;
    if (velocidadKmh != null && velocidadKmh < velocidadBajaKmh) return;
    if (_polyline.length < 2) {
      // Sin polyline (OSRAM fallo): fallback con el GPS crudo.
      _apuntarResto(_distancia(p, _pasos[_indice].coordenada), radioAvance);
      return;
    }

    // 1. Snap: punto de la ruta mas cercano alrededor del ultimo indice.
    final snap = _snap(p);
    _snapIndex = snap.$1;
    final enRuta = _polyline[_snapIndex];
    if (snap.$2 > 150) {
      // DESVIO: el chofer ya no esta cerca del trazo. Se vuelve a pedir la
      // ruta a OSRM y la cola REINICIA desde el punto actual (comportamiento
      // de navegadores reales). La polyline se limpia para que no quede
      // ninguna instruccion del trazado viejo.
      _polyline.clear();
      _indice = 0;
      notifyListeners();
      unawaited(_pedirRuta());
      return;
    }

    // 2. Distancia POR LA RUTA: del punto encajado, caminando el trazo
    //    hasta el punto de maniobra del paso vigente.
    final hasta = _pasos[_indice].coordenada;
    var idx = _snapIndex;
    var anterior = enRuta;
    var resto = 0.0;
    while (idx < _polyline.length - 1) {
      final siguiente = _polyline[idx + 1];
      resto += _distancia(anterior, siguiente);
      if (_distancia(siguiente, hasta) <= radioAvance) break;
      anterior = siguiente;
      idx++;
    }
    if (idx >= _polyline.length - 1) resto = _distancia(enRuta, hasta);

    // 3. Avance: la distancia del punto ENCAJADO al punto de maniobra:
    //    < radioAvance => paso siguiente.
    if (_distancia(enRuta, hasta) <= radioAvance) {
      var i = _indice;
      while (i < _pasos.length - 1 &&
          _distancia(enRuta, _pasos[i].coordenada) <= radioAvance) {
        i++;
      }
      _indice = i + 1 <= _pasos.length - 1 ? i + 1 : _pasos.length - 1;
      _snapIndex = _snap(enRuta).$1;
      _restoAlPunto = 0;
      notifyListeners();
      // Si se agotaron los pasos de ESTA ruta (fase terminada), el refresco
      // periodic re-pide desde el punto actual con el destino vigente.
      return;
    }
    _apuntarResto(resto, radioAvance);
  }

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
    _snapIndex = 0;
    await _pedirRuta();
  }

  void _apuntarResto(double resto, double radio) {
    if ((resto - _restoAlPunto).abs() > 5) {
      _restoAlPunto = resto;
      notifyListeners();
    }
  }

  static double _distancia(LatLng a, LatLng b) {
    final dx = (a.latitude - b.latitude) * 111000;
    final dy = (a.longitude - b.longitude) * 111000 * math.cos(a.latitude);
    return math.sqrt(dx * dx + dy * dy);
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
      // El primer paso ("Salga...") ya es la posicion actual: apuntar al
      // segundo, la instruccion real.
      _indice = _pasos.length > 1 ? 1 : 0;
      _snapIndex = _polyline.isEmpty ? 0 : _snap(origen).$1;
      notifyListeners();
      // Nueva ruta (fase/num recalculo): avisar a quien quiera dibujar el
      // mismo trazo (el cliente lo recibe por WS desde el chofer).
      _onRutaNueva?.call(_polyline);
    } catch (e) {
      debugPrint('[ASISTENTE] ruta paso a paso fallo: $e');
    } finally {
      _pidiendo = false;
    }
  }
}
