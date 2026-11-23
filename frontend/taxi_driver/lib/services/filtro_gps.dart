import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Filtro de posicion GPS del chofer.
///
/// Ya NO es una media movil de los ultimos fixes. Esa media, a 1 Hz, iba dos o
/// tres segundos por detras y al girar mezclaba la calle anterior con la nueva:
/// el coche se dibujaba cortando la esquina y desplazado de la calle.
///
/// Ahora se usa un filtro predictivo adaptativo:
///
///  * predice donde deberia estar el coche con su vector de velocidad;
///  * corrige esa prediccion con el fix nuevo, con un peso que crece con la
///    velocidad (en marcha se confia casi por completo en el GPS; parado se
///    suaviza mas para que no tiemble);
///  * descarta fixes con precision inservible o saltos imposibles;
///  * usa el campo `accuracy` de Android, que antes se ignoraba.
///
/// El resultado es una posicion estable pero sin el retraso de la media movil.
class FiltroGps {
  FiltroGps({this.maxPuntos = 4});

  /// Se conserva por compatibilidad con las llamadas existentes.
  @Deprecated('El filtro ya no usa una ventana de puntos')
  final int maxPuntos;

  /// Un salto mayor que esto en menos de [ventanaSaltoSegundos] es ruido.
  static const double saltoMaximoMetros = 120;

  /// Ventana en la que se considera que un salto es imposible.
  static const double ventanaSaltoSegundos = 2.0;

  /// Con peor precision que esto el fix no mueve el marcador.
  static const double precisionInservibleMetros = 80;

  /// Precision a partir de la cual se suaviza con mas fuerza.
  static const double precisionMalaMetros = 30;

  /// Precision por debajo de la cual se puede confiar casi por completo.
  static const double precisionBuenaMetros = 10;

  /// Fixes malos seguidos que se toleran antes de mover el marcador aunque sea
  /// poco. Con tres o mas, quedarse quieto es peor que avanzar 25 m.
  static const int maxDescartesConsecutivos = 3;

  /// Avance maximo por muestra en la recuperacion tras varios descartes.
  static const double pasoRecuperacionMetros = 25.0;

  LatLng? _ultimoCrudo;
  DateTime? _ultimoInstante;
  LatLng? _ultimoFiltrado;
  double? _velocidadKmh;
  double? _precisionMetros;
  int _descartesConsecutivos = 0;

  // Vector de velocidad en m/s: este (x) y norte (y).
  double _vx = 0;
  double _vy = 0;

  /// Ultima velocidad implicita calculada (km/h).
  ///
  /// Respaldo cuando el fix no trae velocidad del GPS. Sale del desplazamiento
  /// entre fixes ya aceptados, no de la posicion filtrada.
  double? get velocidadKmh => _velocidadKmh;

  /// Ultima precision conocida, en metros.
  double? get precisionMetros => _precisionMetros;

  void reiniciar() {
    _ultimoCrudo = null;
    _ultimoInstante = null;
    _ultimoFiltrado = null;
    _velocidadKmh = null;
    _precisionMetros = null;
    _descartesConsecutivos = 0;
    _vx = 0;
    _vy = 0;
  }

  /// Devuelve la posicion filtrada para [punto].
  ///
  /// [accuracyMetros] es el radio de error horizontal de Android. Si es `null`,
  /// se usa la ultima precision conocida o un valor conservador de 20 m.
  LatLng filtrar(
    LatLng punto, {
    DateTime? ahora,
    double? accuracyMetros,
    double? velocidadKmh,
  }) {
    final t = ahora ?? DateTime.now();
    // La precision del fix solo se memoriza cuando el fix es utilizable. Si se
    // guardara una lectura pesima, todos los fixes posteriores sin `accuracy`
    // heredarian ese valor y el marcador se quedaria congelado.
    final precisionNueva = (accuracyMetros != null && accuracyMetros > 0)
        ? accuracyMetros
        : _precisionMetros;
    final precision = precisionNueva ?? 20.0;

    // Primer fix: no hay nada con lo que predecir.
    final anterior = _ultimoCrudo;
    final instanteAnterior = _ultimoInstante;
    final filtradoAnterior = _ultimoFiltrado;
    if (anterior == null ||
        instanteAnterior == null ||
        filtradoAnterior == null) {
      if (precision <= precisionInservibleMetros) {
        _precisionMetros = precision;
      }
      _ultimoCrudo = punto;
      _ultimoInstante = t;
      _ultimoFiltrado = punto;
      if (velocidadKmh != null) _velocidadKmh = velocidadKmh;
      return punto;
    }

    final dt = t.difference(instanteAnterior).inMilliseconds / 1000.0;
    final distancia = _distancia(anterior, punto);
    final (dx, dy) = _desplazamientoMetros(anterior, punto);

    // Un fix con precision pesima o un salto imposible no mueve el marcador.
    // PERO el ancla crudo SI avanza: antes se descartaba el fix sin tocar el
    // ancla, y el siguiente fix bueno se comparaba con una posicion de hace
    // varios segundos, volvia a parecer un salto y se descartaba tambien. Ese
    // bucle era el marcador congelado hasta que llegaba un recalculo de ruta.
    final saltoImposible =
        dt > 0 && dt < ventanaSaltoSegundos && distancia > saltoMaximoMetros;
    final descartable =
        precision > precisionInservibleMetros || saltoImposible || dt <= 0;

    if (descartable) {
      _descartesConsecutivos++;
      if (_descartesConsecutivos < maxDescartesConsecutivos) {
        _moverAncla(punto, t, instanteAnterior);
        return filtradoAnterior;
      }

      // Tres o mas fixes malos seguidos: el canyon GPS no se va a arreglar solo.
      // Se acepta un avance LIMITADO hacia la posicion real para que el coche no
      // se quede clavado, sin dar un salto de cientos de metros de una vez.
      final fraccion = distancia > 0
          ? math.min(distancia, pasoRecuperacionMetros) / distancia
          : 0.0;
      final recuperado = _desplazar(
        filtradoAnterior,
        dx * fraccion,
        dy * fraccion,
      );
      _ultimoCrudo = punto;
      _ultimoInstante = t;
      _ultimoFiltrado = recuperado;
      _vx = 0;
      _vy = 0;
      _descartesConsecutivos = 0;
      return recuperado;
    }
    _descartesConsecutivos = 0;
    _precisionMetros = precision;

    final velocidadObservadaKmh = (distancia / dt) * 3.6;
    final velocidad = (velocidadKmh != null && velocidadKmh >= 0)
        ? velocidadKmh
        : velocidadObservadaKmh;
    _velocidadKmh = velocidad;

    // Vector de velocidad suavizado. Con dt largo (GPS perdido un rato) se
    // confia mas en la muestra nueva para no arrastrar una direccion vieja.
    //
    // Parado, el desplazamiento entre fixes es ruido del sensor (el punto
    // "baila" varios metros): aprenderlo como velocidad haria que la
    // prediccion se fuera sola y el marcador derivara con el coche quieto.
    if (velocidad < 3) {
      _vx *= 0.30;
      _vy *= 0.30;
    } else {
      final alfaVelocidad = dt >= 0.8 ? 0.55 : 0.30;
      _vx = _vx * (1 - alfaVelocidad) + (dx / dt) * alfaVelocidad;
      _vy = _vy * (1 - alfaVelocidad) + (dy / dt) * alfaVelocidad;
    }

    final predicho = _desplazar(filtradoAnterior, _vx * dt, _vy * dt);

    // Peso del fix nuevo. En marcha se confia en el GPS; parado se suaviza.
    var alfa = switch (velocidad) {
      < 3 => 0.18,
      < 10 => 0.35,
      < 25 => 0.55,
      < 45 => 0.72,
      _ => 0.86,
    };
    if (precision > precisionMalaMetros) {
      alfa *= 0.70;
    } else if (precision <= precisionBuenaMetros) {
      alfa = math.min(1.0, alfa * 1.15);
    }

    // Si el fix cae muy lejos de la prediccion, no es ruido: es un giro o un
    // cambio real de carril. Se confia mas en el dato nuevo para no cortar la
    // esquina ni quedarse en la calle anterior.
    final errorPrediccion = _distancia(predicho, punto);
    if (errorPrediccion > 15 && velocidad > 5) {
      alfa = math.max(alfa, 0.88);
    }

    final salida = _interpolar(predicho, punto, alfa);

    _ultimoCrudo = punto;
    _ultimoInstante = t;
    _ultimoFiltrado = salida;
    return salida;
  }

  /// Desplazamiento en metros: (este, norte).
  static (double, double) _desplazamientoMetros(LatLng desde, LatLng hasta) {
    const metrosPorGrado = 111320.0;
    final cosLat = math.cos(desde.latitude * math.pi / 180.0);
    final dy = (hasta.latitude - desde.latitude) * metrosPorGrado;
    final dx = (hasta.longitude - desde.longitude) * metrosPorGrado * cosLat;
    return (dx, dy);
  }

  /// Mueve [punto] [este] metros al este y [norte] al norte.
  static LatLng _desplazar(LatLng punto, double este, double norte) {
    const metrosPorGrado = 111320.0;
    final cosLat = math.cos(punto.latitude * math.pi / 180.0);
    if (cosLat.abs() < 1e-6) return punto;
    return LatLng(
      punto.latitude + norte / metrosPorGrado,
      punto.longitude + este / (metrosPorGrado * cosLat),
    );
  }

  /// Interpola linealmente entre [a] y [b] con peso [alfa] para [b].
  static LatLng _interpolar(LatLng a, LatLng b, double alfa) {
    final f = alfa.clamp(0.0, 1.0);
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * f,
      a.longitude + (b.longitude - a.longitude) * f,
    );
  }

  /// Actualiza la referencia cruda sin adoptar la posición del fix.
  ///
  /// Así el siguiente fix se mide contra la lectura inmediatamente anterior y
  /// no contra una posición antigua que hacía descartar todos los fixes futuros.
  void _moverAncla(LatLng punto, DateTime t, DateTime instanteAnterior) {
    _ultimoCrudo = punto;
    if (!t.isBefore(instanteAnterior)) _ultimoInstante = t;
  }

  static double _distancia(LatLng a, LatLng b) {
    const metrosPorGrado = 111320.0;
    final dLat = (a.latitude - b.latitude) * metrosPorGrado;
    final dLng =
        (a.longitude - b.longitude) *
        metrosPorGrado *
        math.cos(a.latitude * math.pi / 180.0);
    return math.sqrt(dLat * dLat + dLng * dLng);
  }
}
