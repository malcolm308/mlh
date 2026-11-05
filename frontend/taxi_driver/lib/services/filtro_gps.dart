import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Filtro de posicion GPS del chofer.
///
/// Media movil ponderada de los ultimos [maxPuntos] fixes (mas peso al mas
/// reciente) para quitar el "baile" del GPS sin retrasar la camara. Descarta
/// ademas los puntos fantasma: un salto de mas de [saltoMaximoMetros] en menos
/// de [ventanaSaltoSegundos] no lo hace un coche, es ruido del sensor.
class FiltroGps {
  FiltroGps({this.maxPuntos = 4});

  final int maxPuntos;

  static const double saltoMaximoMetros = 120;
  static const double ventanaSaltoSegundos = 2.0;

  final List<LatLng> _ventana = [];
  LatLng? _ultimoCrudo;
  DateTime? _ultimoInstante;
  LatLng? _ultimoSuave;
  double? _velocidadKmh;

  /// Ultima velocidad implicita calculada (km/h). Respaldo cuando el fix no
  /// trae velocidad del GPS.
  double? get velocidadKmh => _velocidadKmh;

  void reiniciar() {
    _ventana.clear();
    _ultimoCrudo = null;
    _ultimoInstante = null;
    _ultimoSuave = null;
    _velocidadKmh = null;
  }

  LatLng filtrar(LatLng punto, {DateTime? ahora}) {
    final t = ahora ?? DateTime.now();

    if (_ultimoCrudo != null && _ultimoInstante != null) {
      final dt = t.difference(_ultimoInstante!).inMilliseconds / 1000.0;
      final d = _distancia(_ultimoCrudo!, punto);

      if (dt > 0 && dt < ventanaSaltoSegundos && d > saltoMaximoMetros) {
        return _ultimoSuave ?? punto;
      }
      if (dt >= 0.5 && dt <= 10) {
        _velocidadKmh = (d / dt) * 3.6;
      }
    }

    _ventana.add(punto);
    while (_ventana.length > maxPuntos) {
      _ventana.removeAt(0);
    }

    var pesoTotal = 0.0;
    var lat = 0.0;
    var lng = 0.0;
    for (var i = 0; i < _ventana.length; i++) {
      final peso = (i + 1).toDouble();
      lat += _ventana[i].latitude * peso;
      lng += _ventana[i].longitude * peso;
      pesoTotal += peso;
    }

    final suave = LatLng(lat / pesoTotal, lng / pesoTotal);
    _ultimoCrudo = punto;
    _ultimoInstante = t;
    _ultimoSuave = suave;
    return suave;
  }

  static double _distancia(LatLng a, LatLng b) {
    const metrosPorGrado = 111320.0;
    final dLat = (a.latitude - b.latitude) * metrosPorGrado;
    final dLng = (a.longitude - b.longitude) *
        metrosPorGrado *
        math.cos(a.latitude * math.pi / 180.0);
    return math.sqrt(dLat * dLat + dLng * dLng);
  }
}
