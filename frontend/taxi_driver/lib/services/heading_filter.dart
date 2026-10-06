import 'dart:math' as math;

/// Normaliza cualquier angulo al rango [0, 360).
double normalizarGrados(double grados) {
  var d = grados % 360.0;
  if (d < 0) d += 360.0;
  return d;
}

/// Diferencia angular mas corta de [desde] a [hasta], en el rango (-180, 180].
///
/// Imprescindible para interpolar la camara: pasar de 350 grados a 10 son
/// +20 grados, no -340. Sin esto el mapa "daria la vuelta" en cada cruce.
double deltaCorto(double desde, double hasta) {
  var d = (hasta - desde) % 360.0;
  if (d > 180.0) d -= 360.0;
  if (d <= -180.0) d += 360.0;
  return d;
}

/// Media circular (media vectorial) de un conjunto de rumbos en grados.
///
/// Este es el motivo de que el filtro exista: la media aritmetica de 350 y 10
/// da 180, que es justo lo contrario de lo que quiere decir el conductor
/// (que va al este, dando la vuelta al norte). Promediando los vectores unidad
/// el resultado es ~0, correcto.
double mediaCircularGrados(List<double> rumbos) {
  if (rumbos.isEmpty) return 0.0;
  var sx = 0.0;
  var sy = 0.0;
  for (final r in rumbos) {
    final rad = r * math.pi / 180.0;
    sx += math.cos(rad);
    sy += math.sin(rad);
  }
  // Vectores opuestos: media indeterminada, se devuelve el ultimo dato real.
  if (sx.abs() < 1e-9 && sy.abs() < 1e-9) return normalizarGrados(rumbos.last);
  final media = math.atan2(sy, sx) * 180.0 / math.pi;
  // `atan2` puede devolver un angulo negativo diminuto (por ejemplo -1e-15) al
  // promediar vectores casi alineados al norte. Sumar 360 deja 359.99999999999999
  // en vez de 0. Como rotacion ambos valen lo mismo, pero un valor tan cercano a
  // 360 rompe las comparaciones y el deadband de la camara, asi que se redondea
  // al extremo mas cercano.
  const epsilon = 1e-6;
  var salida = normalizarGrados(media);
  if (salida >= 360.0 - epsilon || salida <= epsilon) salida = 0.0;
  return salida;
}

/// Una muestra de rumbo/velocidad con su instante monotono.
class MuestraRumbo {
  final double rumbo;
  final double velocidadMps;
  final int tiempoMs;

  const MuestraRumbo({
    required this.rumbo,
    required this.velocidadMps,
    required this.tiempoMs,
  });
}

/// Buffer circular de las ultimas N muestras de rumbo.
///
/// Es O(1) tanto al escribir como al leer: no se usa `List.removeAt(0)`, que
/// seria O(n) ademas de reordenar la lista entera en cada fix. Al llegar a
/// [capacidad] la muestra mas antigua se sobrescribe en el indice [_cabeza].
class BufferCircularRumbo {
  /// N = 5 muestras, segun el requerimiento del modo navegacion.
  ///
  /// Suficiente para promediar el ruido magnetico sin que la camara tarde medio
  /// segundo en reaccionar en una curva.
  static const int capacidad = 5;

  /// Aceleracion maxima creible en m/s^2 (~54 km/h en un segundo).
  ///
  /// Por encima de esto la muestra se considera un salto del GPS y se descarta.
  /// Se usa aceleracion y NO distancia bruta a proposito: dos fixes separados
  /// 300 m pueden ser un tunnel real (valido) o un salto de posicion
  /// (basura), y la distancia sola no distingue los dos casos.
  static const double aceleracionMaxima = 15.0;

  /// Intervalo minimo creible entre dos muestras, en segundos.
  ///
  /// Por debajo, `dv/dt` explota por division y marcaria como Acceleration
  /// imposible cualquier cambio de velocidad. 0.2 s es el limite de ruido del
  /// GPS y del sensor a 50 Hz.
  static const double dtMinimo = 0.2;

  /// Velocidad EMA: cuanto pesa la muestra nueva. 0.35 ~ 3 muestras para
  /// estabilizarse.
  static const double alfaVelocidad = 0.35;

  final List<double?> _rumbos = List<double?>.filled(capacidad, null);
  final List<double?> _velocidades = List<double?>.filled(capacidad, null);
  final List<int> _tiempos = List<int>.filled(capacidad, 0);
  int _cabeza = 0;
  int _cantidad = 0;

  /// Ultimo rumbo estable, para conservarlo con el vehiculo parado.
  double? _retenido;

  int get length => _cantidad;

  bool get vacio => _cantidad == 0;

  /// Muestra mas reciente, o `null` si el buffer esta vacio.
  MuestraRumbo? get ultima {
    if (_cantidad == 0) return null;
    final i = _cabeza - 1;
    return MuestraRumbo(
      rumbo: _rumbos[i]!,
      velocidadMps: _velocidades[i]!,
      tiempoMs: _tiempos[i],
    );
  }

  /// Instante monotono (ms) de la ultima muestra.
  int? get ultimoTiempoMs => _cantidad == 0 ? null : _tiempos[_cabeza - 1];

  /// Ultimo rumbo estable retenido.
  double? get retenido => _retenido;

  /// Escribe una muestra sobrescribiendo la mas antigua si hace falta.
  void add({
    required double rumbo,
    required double velocidadMps,
    required int tiempoMs,
  }) {
    final i = _cabeza;
    _rumbos[i] = normalizarGrados(rumbo);
    _velocidades[i] = velocidadMps < 0 ? 0.0 : velocidadMps;
    _tiempos[i] = tiempoMs;
    _cabeza = (_cabeza + 1) % capacidad;
    if (_cantidad < capacidad) _cantidad++;
  }

  void clear() {
    for (var i = 0; i < capacidad; i++) {
      _rumbos[i] = null;
      _velocidades[i] = null;
      _tiempos[i] = 0;
    }
    _cabeza = 0;
    _cantidad = 0;
    _retenido = null;
  }

  /// Las muestras en orden cronologico, de mas antigua a mas reciente.
  List<MuestraRumbo> get muestras {
    final out = <MuestraRumbo>[];
    for (var k = 0; k < _cantidad; k++) {
      final i = (_cabeza - _cantidad + k) % capacidad;
      final r = _rumbos[i];
      if (r == null) continue;
      out.add(MuestraRumbo(
        rumbo: r,
        velocidadMps: _velocidades[i]!,
        tiempoMs: _tiempos[i],
      ));
    }
    return out;
  }

  /// Descarta las muestras con un salto de velocidad imposiblemente brusco.
  ///
  /// Compara cada muestra con la anterior: si `|dv| / dt` supera
  /// [aceleracionMaxima], esa muestra es un salto del GPS y su rumbo no vale.
  /// La primera muestra nunca se descarta porque no tiene con que compararse.
  List<MuestraRumbo> get muestrasCreibles {
    final todas = muestras;
    if (todas.length < 2) return todas;
    final out = <MuestraRumbo>[todas.first];
    for (var i = 1; i < todas.length; i++) {
      final a = todas[i - 1];
      final b = todas[i];
      final dt = (b.tiempoMs - a.tiempoMs) / 1000.0;
      if (dt < dtMinimo) {
        // Muestreo demasiado rapido: no se puede juzgar, se conserva.
        out.add(b);
        continue;
      }
      final acel = (b.velocidadMps - a.velocidadMps).abs() / dt;
      if (acel <= aceleracionMaxima) out.add(b);
    }
    return out;
  }

  /// Velocidad suavizada con media movil exponencial.
  ///
  /// Con alfa 0.35 tarda unas 3 muestras en estabilizarse: suficiente para que
  /// el indicador de velocidad no parpadee, sin retrasar la frenada.
  double velocidadFiltrada() {
    final s = muestrasCreibles;
    if (s.isEmpty) return 0.0;
    var acc = s.first.velocidadMps;
    for (var i = 1; i < s.length; i++) {
      acc = acc * alfaVelocidad + s[i].velocidadMps * (1 - alfaVelocidad);
    }
    return acc;
  }

  /// Rumbo filtrado, o `null` si no hay dato utilizable.
  ///
  /// Reglas, en este orden:
  ///  1. Sin muestras: `null`. El llamante mantiene el norte arriba.
  ///  2. Vehiculo por debajo de [minVelocidadMps]: se devuelve [retenido], el
  ///     ultimo rumbo estable. Es lo que evita que el mapa gire solo en un
  ///     semaforo por el ruido de la brújula.
  ///  3. Se descartan los saltos imposibles (ver [muestrasCreibles]).
  ///  4. Media circular de las muestras que quedan.
  ///
  /// Devuelve siempre un angulo normalizado en [0, 360).
  double? rumboFiltrado({
    double minVelocidadMps = 0.7, // ~2.5 km/h
  }) {
    final s = muestrasCreibles;
    if (s.isEmpty) return null;

    // 2. Casi parado: el ultimo rumbo estable gana a cualquier ruido.
    //
    // La decision usa la velocidad de la ultima muestra y NO la suavizada: la
    // EMA decae despacio y tras frenar seguia dando 3.5 m/s durante varios
    // fixes, con lo que el mapa mantenia el heading-up con el vehiculo ya
    // parado. La histeresis para que un fix a cero en un semaforo no haga
    // parpadear el mapa la aporta el servicio de navegacion, no el filtro.
    if (s.last.velocidadMps < minVelocidadMps) {
      // Parado: se retiene el ultimo rumbo *en marcha* que hubiera en el
      // buffer. Guardar el rumbo de la muestra parada daria un valor arbitrario
      // (la brujula girada al azar con el coche quieto) y el mapa saltaria al
      // despertar en semaforo.
      if (_retenido == null) {
        for (var i = s.length - 1; i >= 0; i--) {
          if (s[i].velocidadMps >= minVelocidadMps) {
            _retenido = s[i].rumbo;
            break;
          }
        }
        // Todo el buffer es de vehiculo parado: no hay rumbo fiable.
        _retenido ??= s.last.rumbo;
      }
      return _retenido;
    }

    // 3. En marcha, se ignoran las muestras que se tomaron con el vehiculo
    // parado: su rumbo viene de ruido magnetico y ademas ya esta obsoleto.
    // Sin esto, arrancar en un semaforo orienta el mapa con readings viejos
    // durante los siguientes 5 s. Se conserva la mas reciente de esas para no
    // quedarse sin ninguna muestra valida.
    final enMarcha = <MuestraRumbo>[];
    for (var i = s.length - 1; i >= 0; i--) {
      if (s[i].velocidadMps >= minVelocidadMps) {
        enMarcha.add(s[i]);
      } else {
        if (enMarcha.isEmpty) enMarcha.add(s[i]);
        break;
      }
    }

    // 4. Media circular: promedia los vectores unidad, no los numeros.
    final out = mediaCircularGrados(enMarcha.map((e) => e.rumbo).toList());
    _retenido = out;
    return out;
  }
}