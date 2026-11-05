import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Utilidades de navegacion geometrica compartidas por la camara 3D.
///
/// Nada de esto usa la brujula del telefono ni el rumbo crudo del GPS: el
/// rumbo se calcula SIEMPRE sobre la geometria de la ruta (snap + siguiente
/// punto), que es estable aunque el coche vaya lento o el GPS salte.
const double _metrosPorGrado = 111320.0;

/// Distancia aproximada en metros entre dos puntos (suficiente a escala de
/// ciudad y mucho mas barata que haversine para un snap de decenas de puntos).
double distanciaMetros(LatLng a, LatLng b) {
  final dLat = (a.latitude - b.latitude) * _metrosPorGrado;
  final dLng = (a.longitude - b.longitude) *
      _metrosPorGrado *
      math.cos(a.latitude * math.pi / 180.0);
  return math.sqrt(dLat * dLat + dLng * dLng);
}

/// Rumbo (0 = norte, sentido horario) del segmento a -> b.
double bearingEntre(LatLng a, LatLng b) {
  final dLat = (b.latitude - a.latitude) * _metrosPorGrado;
  final dLng = (b.longitude - a.longitude) *
      _metrosPorGrado *
      math.cos(a.latitude * math.pi / 180.0);
  if (dLat.abs() < 1e-9 && dLng.abs() < 1e-9) return 0;
  final grados = math.atan2(dLng, dLat) * 180 / math.pi;
  return (grados + 360) % 360;
}

/// Filtro de posicion GPS.
///
/// Media movil ponderada de los ultimos [maxPuntos] fixes, con mas peso en el
/// mas reciente para no retrasar la camara. Ademas:
///
///  * Descarta el "punto fantasma": un salto de mas de [saltoMaximoMetros] en
///    menos de [ventanaSaltoSegundos] no lo hace un coche, es ruido del GPS.
///  * Calcula la velocidad implicita entre fixes, que se usa como respaldo
///    cuando el backend no la manda.
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

  /// Ultima velocidad implicita calculada, en km/h.
  double? get velocidadKmh => _velocidadKmh;

  /// Reinicia el filtro (nuevo viaje, primer fix tras reconectar).
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
      final d = distanciaMetros(_ultimoCrudo!, punto);

      // Punto fantasma: se ignora y se conserva la ultima posicion buena.
      if (dt > 0 && dt < ventanaSaltoSegundos && d > saltoMaximoMetros) {
        return _ultimoSuave ?? punto;
      }

      // La velocidad se calcula con el fix CRUDO, no con el suavizado: la
      // media movil recortaria justo los cambios que interesan al zoom.
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
}

/// Sigue un punto sobre una polilinea y devuelve el rumbo hacia adelante.
///
/// El indice se conserva entre fixes y solo se busca en una ventana alrededor
/// del ultimo punto conocido: asi una calle paralela o el tramo de vuelta de
/// una ruta no "roban" el snap. Si el punto queda a mas de [umbralGlobal] de
/// la ventana se busca en toda la ruta (recuperacion tras un desvio).
class SeguidorRuta {
  int _indice = 0;
  int _largoRuta = 0;

  void reiniciar() {
    _indice = 0;
    _largoRuta = 0;
  }

  /// Devuelve el rumbo de la ruta para [punto], o `null` si la ruta todavia
  /// no tiene geometria suficiente.
  double? rumbo(LatLng punto, List<LatLng> ruta,
      {int ventana = 80, int adelanto = 3}) {
    if (ruta.length < 3) return null;

    if (ruta.length != _largoRuta) {
      _largoRuta = ruta.length;
      _indice = _indice.clamp(0, ruta.length - 1);
    }

    final desde = math.max(0, _indice - ventana ~/ 4);
    final hasta = math.min(ruta.length - 1, _indice + ventana);
    var mejor = double.infinity;
    var mejorIndice = _indice;

    for (var i = desde; i <= hasta; i++) {
      final d = distanciaMetros(punto, ruta[i]);
      if (d < mejor) {
        mejor = d;
        mejorIndice = i;
      }
    }

    const umbralGlobal = 200.0;
    if (mejor > umbralGlobal) {
      for (var i = 0; i < ruta.length; i++) {
        final d = distanciaMetros(punto, ruta[i]);
        if (d < mejor) {
          mejor = d;
          mejorIndice = i;
        }
      }
    }

    _indice = mejorIndice;

    // Hacia ADELANTE en el orden de la ruta. Nunca hacia atras: el sentido de
    // la ruta es el sentido de la marcha y evita que la camara gire 180 grados
    // cuando el snap cae en un tramo de vuelta.
    final siguiente = math.min(ruta.length - 1, _indice + adelanto);
    if (siguiente == _indice) return null;
    final a = ruta[_indice];
    final b = ruta[siguiente];
    if (distanciaMetros(a, b) < 3) return null;
    return bearingEntre(a, b);
  }
}
