import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Resultado de encajar una posición GPS sobre la ruta.
class PuntoRuta {
  const PuntoRuta({
    required this.posicion,
    required this.posicionCruda,
    required this.tramo,
    required this.fraccion,
    required this.distanciaMetros,
    required this.confiable,
  });

  /// Punto ya proyectado sobre la polilínea. Es el que se DIBUJA.
  ///
  /// Siempre cae sobre una calle de la ruta, incluso cuando el GPS estaba lejos
  /// o dentro de un edificio. Así el marcador del chofer nunca atraviesa una
  /// manzana.
  final LatLng posicion;

  /// Posición original del GPS, sin corregir.
  ///
  /// La usa el detector de desvíos: si le diéramos la ya encajada, la distancia
  /// perpendicular sería siempre cero y dejaría de pedir recálculos.
  final LatLng posicionCruda;

  /// Índice del tramo de la ruta usado.
  final int tramo;

  /// Posición dentro del tramo: 0 en el vértice inicial, 1 en el final.
  final double fraccion;

  /// Distancia perpendicular desde el GPS hasta la ruta, en metros.
  final double distanciaMetros;

  /// `true` cuando el GPS estaba dentro de [MapMatchingService.distanciaMaximaMetros].
  ///
  /// No impide dibujar: solo mide cuánto se ha corregido el punto.
  final bool confiable;
}

/// Map-matching de la POSICIÓN del vehículo sobre la ruta que se está siguiendo.
///
/// El GPS urbano rebota en los edificios ("canyon effect") y la media móvil de
/// `FiltroGps` recorta esquinas: el punto sale de la calle y el vehículo se ve
/// atravesando manzanas. Este servicio proyecta ese punto sobre la polilínea de
/// la ruta (la misma geometría que dibuja el mapa) antes de publicarlo y antes
/// de dibujar la flecha.
///
/// NO sustituye al filtro de rumbo: el heading sigue saliendo del movimiento GPS
/// + Kalman. Aquí solo se corrige dónde está el coche, no hacia dónde apunta.
///
/// Reglas anti-salto:
///  * se busca primero en una ventana alrededor del tramo anterior, y solo se
///    hace una búsqueda global si el punto quedó muy lejos;
///  * cambiar de calle exige varios fixes consecutivos, salvo que los tramos
///    sean adyacentes y el GPS esté cerca de la esquina compartida: entonces el
///    giro se acepta en el acto y pasa por el vértice real;
///  * con el coche parado se conserva el tramo anterior;
///  * el punto dibujado SIEMPRE va sobre la ruta. Si el GPS está lejos se marca
///    como no confiable, pero no se devuelve crudo: el crudo viaja aparte en
///    [PuntoRuta.posicionCruda] para el detector de desvíos.
class MapMatchingService {
  /// Distancia máxima aceptable entre el GPS y la ruta.
  static const double distanciaMaximaMetros = 60.0;

  /// Más allá de esto se hace una búsqueda global en toda la polilínea.
  static const double distanciaBuscaGlobalMetros = 150.0;

  /// Radio alrededor del vértice de una esquina para aceptar el giro sin
  /// esperar tres fixes. Con el GPS a 1 Hz, esperar tres fixes haría que el coche
  /// sigiera recto durante tres segundos después de girar.
  static const double distanciaVerticeMetros = 35.0;

  /// Tramos que se miran hacia delante en la ventana local.
  static const int ventanaTramos = 60;

  /// Tramos que se miran hacia atrás (por si el GPS va retrasado).
  static const int tramosAtras = 10;

  /// Fixes seguidos que hacen falta para aceptar un cambio de tramo.
  static const int fixesParaCambiarTramo = 3;

  /// Tolerancia de rumbo para aceptar un cambio de tramo, en grados.
  static const double toleranciaRumboGrados = 45.0;

  /// Por debajo de 5 km/h se considera que el coche está parado.
  static const double velocidadMinimaMetrosPorSegundo = 1.4;

  List<LatLng> _ruta = const [];
  int _tramo = 0;
  double _fraccion = 0.0;
  int? _candidato;
  int _fixesCandidato = 0;
  LatLng? _ultimoAjuste;

  /// Sustituye la ruta de referencia.
  ///
  /// La pantalla publica la ruta en cada fix, así que se compara completa: si un
  /// recálculo cambia el trazado pero conserva origen y destino, la geometría
  /// nueva DEBE reemplazarse. Antes solo se miraban los extremos y se seguía
  /// encajando contra la calle vieja.
  void actualizarRuta(List<LatLng> ruta) {
    if (ruta.length < 2) {
      _ruta = const [];
      _tramo = 0;
      _fraccion = 0.0;
      _candidato = null;
      _fixesCandidato = 0;
      _ultimoAjuste = null;
      return;
    }
    if (_mismaRuta(_ruta, ruta)) return;

    // Con una ruta nueva se recoloca el índice usando el último punto ya
    // encajado, no el primero de la polilínea: si no, tras un recálculo por
    // desvío el marcador saltaría al origen.
    final referencia = _ultimoAjuste ?? ruta.first;
    _ruta = List<LatLng>.unmodifiable(ruta);
    final (i, t, _) = _mejorTramo(referencia, 0, _ruta.length - 2);
    _tramo = i;
    _fraccion = t;
    _candidato = null;
    _fixesCandidato = 0;
  }

  /// Encaja [crudo] sobre la ruta vigente.
  PuntoRuta ajustar(
    LatLng crudo, {
    double? rumbo,
    double? precisionMetros,
    double? velocidadKmh,
  }) {
    if (_ruta.length < 2) {
      return PuntoRuta(
        posicion: crudo,
        posicionCruda: crudo,
        tramo: 0,
        fraccion: 0.0,
        distanciaMetros: 0.0,
        confiable: false,
      );
    }

    final ultimo = _ruta.length - 2;
    final desde = math.max(0, _tramo - tramosAtras);
    final hasta = math.min(ultimo, _tramo + ventanaTramos);
    var mejor = _mejorTramo(crudo, desde, hasta);
    if (mejor.$3 > distanciaBuscaGlobalMetros) {
      mejor = _mejorTramo(crudo, 0, ultimo);
    }

    var (i, t, d) = mejor;
    final confiable = d <= distanciaMaximaMetros;

    // Un giro en una esquina se detecta en el acto: el tramo nuevo es el
    // siguiente (o el anterior) y el GPS está junto al vértice que comparten.
    // Sin esto, la histeresis de tres fixes deja al coche recto dentro del
    // edificio durante tres segundos después de cada giro.
    final giroEnEsquina =
        i != _tramo &&
        (i == _tramo + 1 || i == _tramo - 1) &&
        _rumboCompatible(i, rumbo) &&
        _cercaDelVertice(crudo, i);

    final parado =
        (velocidadKmh ?? 0.0) < velocidadMinimaMetrosPorSegundo * 3.6;
    if (i != _tramo && !parado && !giroEnEsquina) {
      if (_candidato == i) {
        _fixesCandidato++;
      } else {
        _candidato = i;
        _fixesCandidato = 1;
      }

      final puedeCambiar = _fixesCandidato >= fixesParaCambiarTramo;
      if (!puedeCambiar) {
        // Se mantiene el tramo anterior, pero se proyecta el punto sobre él
        // para que el coche no se meta en el edificio de al lado.
        final (tAnterior, dAnterior) = _proyectarEnTramo(crudo, _tramo);
        final ajustado = _puntoEnTramo(_tramo, tAnterior);
        _ultimoAjuste = ajustado;
        return PuntoRuta(
          posicion: ajustado,
          posicionCruda: crudo,
          tramo: _tramo,
          fraccion: tAnterior,
          distanciaMetros: dAnterior,
          confiable: dAnterior <= distanciaMaximaMetros,
        );
      }
      _tramo = i;
      _candidato = null;
      _fixesCandidato = 0;
    }

    if (parado) {
      // Parado en un semáforo el GPS baila: se conserva el tramo y la fracción,
      // pero se dibuja sobre la calle.
      final (tParado, dParado) = _proyectarEnTramo(crudo, _tramo);
      final ajustado = _puntoEnTramo(_tramo, tParado);
      _ultimoAjuste = ajustado;
      return PuntoRuta(
        posicion: ajustado,
        posicionCruda: crudo,
        tramo: _tramo,
        fraccion: tParado,
        distanciaMetros: dParado,
        confiable: dParado <= distanciaMaximaMetros,
      );
    }

    if (giroEnEsquina) {
      // Se fuerza el vértice compartido como punto dibujado. El siguiente fix
      // ya vendrá sobre el tramo nuevo; mientras tanto el coche está exactamente
      // en la esquina, no dentro de la manzana.
      final haciaDelante = i > _tramo;
      final vertice = haciaDelante ? _ruta[_tramo + 1] : _ruta[_tramo];
      _tramo = i;
      _fraccion = haciaDelante ? 0.0 : 1.0;
      _candidato = null;
      _fixesCandidato = 0;
      _ultimoAjuste = vertice;
      return PuntoRuta(
        posicion: vertice,
        posicionCruda: crudo,
        tramo: _tramo,
        fraccion: _fraccion,
        distanciaMetros: d,
        confiable: confiable,
      );
    }

    _tramo = i;
    _fraccion = t;
    final ajustado = _puntoEnTramo(_tramo, t);
    _ultimoAjuste = ajustado;
    return PuntoRuta(
      posicion: ajustado,
      posicionCruda: crudo,
      tramo: _tramo,
      fraccion: t,
      distanciaMetros: d,
      confiable: confiable,
    );
  }

  /// Avanza [metros] por la ruta desde el punto encajado [punto].
  ///
  /// Sustituye la extrapolación en línea recta: entre fixes (1 Hz) el coche se
  /// mueve SIGUIENDO la polilínea, de modo que al girar pasa por el vértice de
  /// la esquina en vez de salir disparado hacia el edificio.
  LatLng avanzar(PuntoRuta punto, double metros) {
    if (_ruta.length < 2 || metros <= 0) return punto.posicion;

    var tramo = punto.tramo.clamp(0, _ruta.length - 2);
    var fraccion = punto.fraccion.clamp(0.0, 1.0);
    var restante = metros;

    while (restante > 0 && tramo < _ruta.length - 1) {
      final largo = _distancia(_ruta[tramo], _ruta[tramo + 1]);
      if (largo < 1e-6) {
        tramo++;
        fraccion = 0.0;
        continue;
      }
      final disponible = largo * (1.0 - fraccion);
      if (restante < disponible) {
        fraccion += restante / largo;
        restante = 0.0;
      } else {
        restante -= disponible;
        tramo++;
        fraccion = 0.0;
      }
    }

    if (tramo >= _ruta.length - 1) return _ruta.last;
    return _puntoEnTramo(tramo, fraccion);
  }

  bool _cercaDelVertice(LatLng crudo, int tramoNuevo) {
    if (tramoNuevo < 0 || tramoNuevo >= _ruta.length - 1) return false;
    final vertice = tramoNuevo > _tramo ? _ruta[_tramo + 1] : _ruta[_tramo];
    return _distancia(crudo, vertice) <= distanciaVerticeMetros;
  }

  bool _mismaRuta(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// `true` si el rumbo del tramo no contradice el rumbo del vehículo.
  bool _rumboCompatible(int tramo, double? rumbo) {
    if (rumbo == null) return true;
    final a = _ruta[tramo];
    final b = _ruta[tramo + 1];
    final dLat = (b.latitude - a.latitude) * 111000.0;
    final dLng =
        (b.longitude - a.longitude) *
        111000.0 *
        math.cos(a.latitude * math.pi / 180.0);
    if (dLat.abs() < 1e-6 && dLng.abs() < 1e-6) return true;
    final rumboTramo = math.atan2(dLng, dLat) * 180.0 / math.pi;
    final diferencia = ((rumbo - rumboTramo + 540) % 360) - 180;
    return diferencia.abs() <= toleranciaRumboGrados;
  }

  (double, double) _proyectarEnTramo(LatLng p, int tramo) {
    final i = tramo.clamp(0, _ruta.length - 2);
    return _proyectar(p, _ruta[i], _ruta[i + 1]);
  }

  LatLng _puntoEnTramo(int tramo, double t) {
    final i = tramo.clamp(0, _ruta.length - 2);
    final a = _ruta[i];
    final b = _ruta[i + 1];
    final f = t.clamp(0.0, 1.0);
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * f,
      a.longitude + (b.longitude - a.longitude) * f,
    );
  }

  /// Proyecta [p] sobre el tramo [a]-[b]. Devuelve `(fracción, metros)`.
  (double, double) _proyectar(LatLng p, LatLng a, LatLng b) {
    const m = 111000.0;
    final cosLat = math.cos(((a.latitude + b.latitude) / 2) * math.pi / 180);
    final ax = a.longitude * m * cosLat;
    final ay = a.latitude * m;
    final bx = b.longitude * m * cosLat;
    final by = b.latitude * m;
    final px = p.longitude * m * cosLat;
    final py = p.latitude * m;
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-9) {
      return (0.0, _distancia(p, a));
    }
    var t = ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final qx = ax + t * dx;
    final qy = ay + t * dy;
    return (t, math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy)));
  }

  (int, double, double) _mejorTramo(LatLng p, int desde, int hasta) {
    var mejorI = desde.clamp(0, _ruta.length - 2);
    var mejorT = 0.0;
    var mejorD = double.infinity;
    for (var i = desde; i <= hasta; i++) {
      final proj = _proyectar(p, _ruta[i], _ruta[i + 1]);
      if (proj.$2 < mejorD) {
        mejorD = proj.$2;
        mejorI = i;
        mejorT = proj.$1;
      }
    }
    return (mejorI, mejorT, mejorD);
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
