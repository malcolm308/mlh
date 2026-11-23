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
    required this.enRuta,
  });

  /// Posición que se DIBUJA y que sigue la cámara.
  ///
  /// * Si [enRuta] es `true`, es el punto proyectado sobre la polilínea: cae
  ///   siempre en una calle de la ruta, aunque el GPS haya rebotado contra un
  ///   edificio.
  /// * Si [enRuta] es `false`, es la posición real filtrada, SIN tocar. Antes se
  ///   devolvía la proyección incluso a 300 m de la ruta y el marcador se
  ///   quedaba pegado a la calle vieja hasta el siguiente recálculo.
  final LatLng posicion;

  /// Posición de entrada, ya filtrada y sin encajar.
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

  /// `true` cuando el GPS estaba dentro de
  /// [MapMatchingService.distanciaMaximaMetros].
  ///
  /// Es informativo: no decide si se dibuja encajado. Eso lo hace [enRuta].
  final bool confiable;

  /// `true` si el vehículo se considera sobre la ruta.
  ///
  /// Al desviarse se pone en `false` y [posicion] pasa a ser la posición real
  /// filtrada. El marcador sigue al coche de inmediato, sin esperar a que el
  /// backend devuelva una ruta nueva.
  final bool enRuta;
}

/// Map-matching de la POSICIÓN del vehículo sobre la ruta que se está siguiendo.
///
/// El GPS urbano rebota en los edificios ("canyon effect") y el filtro puede
/// recortar esquinas: el punto sale de la calle y el vehículo se ve atravesando
/// manzanas. Este servicio proyecta ese punto sobre la polilínea de la ruta (la
/// misma geometría que dibuja el mapa) MIENTRAS el coche va por ella.
///
/// Reglas:
///  * en ruta, se busca en una ventana alrededor del tramo anterior para no
///    saltar a una calle paralela;
///  * cambiar de calle exige varios fixes seguidos, salvo que los tramos sean
///    adyacentes y el rumbo sea compatible: es un giro real, no una deriva;
///  * con el coche parado se conserva el tramo anterior;
///  * **al desviarse se suelta el encaje**: si la distancia supera
///    [distanciaSalidaRutaMetros] (adaptada a la precisión del GPS), [posicion]
///    pasa a ser la posición real filtrada y [PuntoRuta.enRuta] queda en
///    `false`. El marcador nunca se queda clavado en la ruta vieja;
///  * no se fuerza el vértice de la esquina: el giro se acepta cuando el punto
///    proyectado cae de verdad en el tramo nuevo.
class MapMatchingService {
  /// Distancia máxima para ENTRAR en la ruta, en metros.
  static const double distanciaEntradaRutaMetros = 45.0;

  /// Distancia a partir de la cual se SALE de la ruta, en metros.
  ///
  /// Es mayor que la de entrada a propósito (histéresis): un fix con 50 m de
  /// error no debe soltar y volver a enganchar el marcador cada segundo.
  static const double distanciaSalidaRutaMetros = 65.0;

  /// Distancia máxima para considerar el encaje "confiable".
  static const double distanciaMaximaMetros = distanciaEntradaRutaMetros;

  /// Más allá de esto se hace una búsqueda global en toda la polilínea.
  static const double distanciaBuscaGlobalMetros = 150.0;

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

  /// Última posición de entrada. Se usa como referencia al cambiar de ruta:
  /// tras un recálculo por desvío la ruta nueva empieza cerca del coche, así
  /// que encajar el último punto conocido evita saltar al origen.
  LatLng? _ultimaEntrada;

  /// `true` si el vehículo está sobre la ruta ahora mismo.
  bool _enRuta = false;

  /// `true` si alguna vez se ha encajado en esta ruta. Distingue el arranque
  /// (aún no hay historial) de una vuelta a la ruta tras un desvío.
  bool _algunaVezEnRuta = false;

  /// `true` si el vehículo se considera sobre la ruta.
  bool get enRuta => _enRuta;

  /// `true` si hay una ruta con al menos dos puntos.
  bool get tieneRuta => _ruta.length >= 2;

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
      _ultimaEntrada = null;
      _enRuta = false;
      _algunaVezEnRuta = false;
      return;
    }
    if (_mismaRuta(_ruta, ruta)) return;

    // Con una ruta nueva se recoloca el índice usando la última posición real
    // conocida, no el primer punto de la polilínea: si no, tras un recálculo por
    // desvío el marcador saltaría al origen de la ruta.
    final referencia = _ultimaEntrada ?? _ultimoAjuste ?? ruta.first;
    _ruta = List<LatLng>.unmodifiable(ruta);
    final (i, t, _) = _mejorTramo(referencia, 0, _ruta.length - 2);
    _tramo = i;
    _fraccion = t;
    _candidato = null;
    _fixesCandidato = 0;
    _enRuta = false;
  }

  /// Encaja [crudo] sobre la ruta vigente.
  ///
  /// [crudo] debe ser la posición YA filtrada por `FiltroGps`: el map-matching
  /// corrige la calle, no el ruido del sensor.
  PuntoRuta ajustar(
    LatLng crudo, {
    double? rumbo,
    double? precisionMetros,
    double? velocidadKmh,
  }) {
    _ultimaEntrada = crudo;

    if (_ruta.length < 2) {
      return PuntoRuta(
        posicion: crudo,
        posicionCruda: crudo,
        tramo: 0,
        fraccion: 0.0,
        distanciaMetros: 0.0,
        confiable: false,
        enRuta: false,
      );
    }

    final ultimo = _ruta.length - 2;
    final entrada = _umbralEntrada(precisionMetros);
    final salida = _umbralSalida(precisionMetros);

    // Ventana local alrededor del progreso actual. Al volver de un desvío se
    // mira hacia delante desde el último tramo conocido; si no aparece nada
    // cerca, se busca en toda la ruta (rodeos, calles que se vuelven a cruzar).
    final desde = math.max(0, _tramo - tramosAtras);
    final hasta = math.min(ultimo, _tramo + ventanaTramos);
    var mejor = _mejorTramo(crudo, desde, hasta);
    if (mejor.$3 > (_enRuta ? salida : entrada)) {
      final global = _mejorTramo(crudo, 0, ultimo);
      if (global.$3 < mejor.$3) mejor = global;
    }

    var (i, t, d) = mejor;

    // Fuera de ruta: se devuelve la posición real filtrada, sin inventar una
    // calle. El marcador sigue al vehículo aunque la polilínea vieja siga
    // dibujada, sin esperar al recálculo.
    if (d > (_enRuta ? salida : entrada)) {
      _enRuta = false;
      _candidato = null;
      _fixesCandidato = 0;
      _ultimoAjuste = null;
      return PuntoRuta(
        posicion: crudo,
        posicionCruda: crudo,
        tramo: _tramo,
        fraccion: _fraccion,
        distanciaMetros: d,
        confiable: false,
        enRuta: false,
      );
    }

    final parado =
        (velocidadKmh ?? 0.0) < velocidadMinimaMetrosPorSegundo * 3.6;

    // Un giro real: el tramo nuevo es adyacente y el rumbo del vehículo encaja
    // con el de la calle nueva. Se acepta en el acto, sin forzar el vértice:
    // la proyección normal ya deja el punto en el tramo nuevo, cerca de la
    // esquina, y el coche no aparece en la esquina antes de llegar.
    final giroEnEsquina =
        i != _tramo &&
        (i == _tramo + 1 || i == _tramo - 1) &&
        _rumboCompatible(i, rumbo);

    // Al arrancar (nunca se ha encajado) o yendo en ruta, un cambio de calle
    // exige varios fixes para no saltar a una paralela. Al VOLVER de un desvío
    // se engancha en el acto: ya se sabe que la calle anterior no era.
    final exigeHisteresis =
        i != _tramo &&
        !parado &&
        !giroEnEsquina &&
        (_enRuta || !_algunaVezEnRuta);
    if (exigeHisteresis) {
      if (_candidato == i) {
        _fixesCandidato++;
      } else {
        _candidato = i;
        _fixesCandidato = 1;
      }

      if (_fixesCandidato < fixesParaCambiarTramo) {
        // Se mantiene el tramo anterior. Si aun así el punto queda demasiado
        // lejos de él, el GPS está claramente en la calle nueva: se acepta para
        // no dibujar el coche a 80 m de donde está.
        final (tAnterior, dAnterior) = _proyectarEnTramo(crudo, _tramo);
        if (dAnterior <= salida) {
          final ajustado = _puntoEnTramo(_tramo, tAnterior);
          _ultimoAjuste = ajustado;
          _enRuta = true;
          _algunaVezEnRuta = true;
          return PuntoRuta(
            posicion: ajustado,
            posicionCruda: crudo,
            tramo: _tramo,
            fraccion: tAnterior,
            distanciaMetros: dAnterior,
            confiable: dAnterior <= distanciaMaximaMetros,
            enRuta: true,
          );
        }
      }
    }

    _tramo = i;
    _candidato = null;
    _fixesCandidato = 0;

    if (parado) {
      // Parado en un semáforo el GPS baila: se conserva el tramo, pero se
      // dibuja sobre la calle.
      final (tParado, dParado) = _proyectarEnTramo(crudo, _tramo);
      _fraccion = tParado;
      final ajustado = _puntoEnTramo(_tramo, tParado);
      _ultimoAjuste = ajustado;
      _enRuta = true;
      _algunaVezEnRuta = true;
      return PuntoRuta(
        posicion: ajustado,
        posicionCruda: crudo,
        tramo: _tramo,
        fraccion: tParado,
        distanciaMetros: dParado,
        confiable: dParado <= distanciaMaximaMetros,
        enRuta: true,
      );
    }

    _fraccion = t;
    final ajustado = _puntoEnTramo(_tramo, t);
    _ultimoAjuste = ajustado;
    _enRuta = true;
    _algunaVezEnRuta = true;
    return PuntoRuta(
      posicion: ajustado,
      posicionCruda: crudo,
      tramo: _tramo,
      fraccion: t,
      distanciaMetros: d,
      confiable: d <= distanciaMaximaMetros,
      enRuta: true,
    );
  }

  /// Avanza [metros] por la ruta desde el punto encajado [punto].
  ///
  /// Solo tiene sentido EN ruta. Fuera de ella devuelve la posición real sin
  /// tocar: extrapolar por la polilínea vieja es justo lo que hacía que el
  /// marcador siguiera moviéndose por la ruta abandonada.
  LatLng avanzar(PuntoRuta punto, double metros) {
    if (!punto.enRuta || _ruta.length < 2 || metros <= 0) return punto.posicion;

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

  /// Umbral de entrada, ampliado si el GPS declara poca precisión.
  static double _umbralEntrada(double? precisionMetros) {
    final p = precisionMetros;
    if (p == null || p <= 0) return distanciaEntradaRutaMetros;
    return (p * 1.5).clamp(distanciaEntradaRutaMetros, 75.0);
  }

  /// Umbral de salida. Siempre por encima del de entrada (histéresis).
  static double _umbralSalida(double? precisionMetros) {
    return (_umbralEntrada(precisionMetros) + 20.0).clamp(
      distanciaSalidaRutaMetros,
      95.0,
    );
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
