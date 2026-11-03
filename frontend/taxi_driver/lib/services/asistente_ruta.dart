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

/// El estado que consume el widget flotante.
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

/// El asistente de ruta paso a paso.
///
/// Trabaja en dos capas:
///
///  * **Ruta**: se pide al backend (`POST /api/routing/navegacion`, OSRM con
///    `steps=true`) la lista de maniobras desde el punto del chofer hasta el
///    destino del viaje activo. Se refresca cada [refrescoRuta] y tambien al
///    terminar cada tramo (sirve para rutas largas con mas tramos).
///  * **Posicion**: con cada fix del GPS mido Haversine al punto de maniobra
///    siguiente; a menos de [radioAvance] metros se avanza al paso que sigue
///    sin pedir nada al backend, y el contador del mensaje se refresca en
///    caliente (5 m de tolerancia para no vibrar el numero).
class AsistenteRutaService extends ChangeNotifier {
  static const double radioAvance = 30.0;
  static const Duration refrescoRuta = Duration(seconds: 60);

  final List<PasoRuta> _pasos = [];
  int _indice = 0;
  double _restoAlPunto = 0;
  Timer? _refresco;
  String? _tripId;
  LatLng? _origen;
  LatLng? _destino;
  bool _pidiendo = false;

  /// Estado actual para el widget (paso activo + metros que faltan).
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

  /// Arranca (o rearrranca con destino nuevo). [origen] es la posicion
  /// actual del chofer, [destino] el final del viaje activo.
  Future<void> iniciar({
    required String tripId,
    required LatLng origen,
    required LatLng destino,
  }) async {
    final repetido = _tripId == tripId &&
        _destino != null &&
        (_destino!.latitude - destino.latitude).abs() < 1e-5 &&
        (_destino!.longitude - destino.longitude).abs() < 1e-5;
    if (repetido) return;
    _tripId = tripId;
    _origen = origen;
    _destino = destino;
    _indice = 0;
    _pasos.clear();
    notifyListeners();
    await _pedirRuta();
    _refresco?.cancel();
    _refresco = Timer.periodic(refrescoRuta, (_) => unawaited(_pedirRuta()));
  }

  /// Termina todo: al completar o cancelar el viaje.
  void detener() {
    _tripId = null;
    _destino = null;
    _pasos.clear();
    _indice = 0;
    _refresco?.cancel();
    _refresco = null;
    notifyListeners();
  }

  /// El fix nuevo del chofer: avanza pasos por radio y actualiza el contador.
  void conPosicion(LatLng p) {
    if (_pasos.isEmpty || _indice >= _pasos.length) return;
    _origen = p;
    final resto = _distancia(p, _pasos[_indice].coordenada);
    if (resto <= radioAvance) {
      // Punto de maniobra alcanzado: se salta cada paso pegado a este (las
      // rotondas pueden mandar 2-3 pasos muy juntos) y el contador del nuevo
      // mensaje apunta al paso siguiente.
      while (_indice < _pasos.length - 1 &&
          _distancia(p, _pasos[_indice].coordenada) <= radioAvance) {
        _indice++;
      }
      _restoAlPunto = 0;
      notifyListeners();
      unawaited(_pedirRuta());
      return;
    }
    // El contador muestra "en N m" con la distancia REAL al punto de
    // maniobra, no la del tramo: el delta de 5 m evita vibrar el numero con
    // el cruego normal del GPS.
    if ((resto - _restoAlPunto).abs() > 5) {
      _restoAlPunto = resto;
      notifyListeners();
    }
  }

  /// Al recalcular por desvio, se regeneran los pasos desde el punto actual.
  Future<void> recalcularDesde(LatLng p) async {
    _origen = p;
    await _pedirRuta();
  }

  static double _distancia(LatLng a, LatLng b) {
    final dx = (a.latitude - b.latitude) * 111000;
    final dy = (a.longitude - b.longitude) * 111000 * math.cos(a.latitude);
    return math.sqrt(dx * dx + dy * dy);
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
      // El primer paso ("Salga...") esta en la posicion ACTUAL: el asistente
      // apunta directamente al segundo, que es la primera instruccion real.
      _pasos
        ..clear()
        ..addAll(lista);
      _indice = _pasos.length > 1 ? 1 : 0;
      notifyListeners();
    } catch (e) {
      debugPrint('[ASISTENTE] ruta paso a paso fallo: $e');
    } finally {
      _pidiendo = false;
    }
  }
}
