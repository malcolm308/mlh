import 'package:flutter/foundation.dart' show debugPrint;
import 'package:latlong2/latlong.dart';

import '../api_config.dart';
import 'api_client.dart';

/// Ruta calculada por OSRM entre dos puntos.
class OsrmRoute {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  OsrmRoute({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  double get distanceKm => distanceMeters / 1000;
  double get durationMinutes => durationSeconds / 60;
}

/// Cliente de ruteo del pasajero.
///
/// La ruta NO se pide directo al servidor publico de OSRM: desde Cuba ese host
/// es inestable (a veces responde en 1 s, a veces se cuelga 30 s+). Por eso
/// esta app habla con el backend propio ([ApiConfig.recalculate]), que ya es
/// fiable desde aqui, y es el backend quien consulta a OSRM desde su red (mismo
/// canal que usa el recalculo de desvios del conductor).
class OsrmService {
  OsrmService._();

  /// Ultima ruta calculada con exito, con su instante y sus extremos.
  ///
  /// Sin esto, un fallo puntual (el backend lento, un pico de la red) borra la
  /// ruta buena que ya se tenia y el mapa cae a la linea recta durante los
  /// segundos que tarda la siguiente consulta. Con la cache, un fallo se
  /// limita a envejar la geometria anterior.
  static _RutaCache? _ultima;

  static const Duration _vigeExacta = Duration(minutes: 5);
  static const Duration _vigeAproximada = Duration(minutes: 2);

  /// Distancia maxima (en grados) para considerar que dos destinos son "el
  /// mismo" y poder reutilizar una ruta calculada para otro punto de partida.
  /// 0.0015 grados son unos 150 m: el vehiculo se ha movido, la ruta sigue
  /// siendo valida.
  static const double _tolanciaDestino = 0.0015;

  /// Calcula la ruta por carretera entre [from] y [to].
  ///
  /// Devuelve `null` si el proxy no encuentra ruta o si el backend/OSRM no
  /// responde a tiempo. Cuando eso pasa, la pantalla se queda con el fallback
  /// en linea recta, asi que se deja constancia en el log para poder distinguir
  /// si el fallo fue de red (timeout) o de ruta inexistente. Lleva su propio
  /// timeout ([ApiConfig.osrmTimeout]) y no el generico de 15 s del [ApiClient].
  static Future<OsrmRoute?> route(LatLng from, LatLng to) async {
    final cronometro = Stopwatch()..start();

    // Ya se tiene esta ruta exacta y es reciente: no se vuelve a preguntar.
    // Ademas asi no se golpea el proxy en cada tic del GPS, que es lo que
    // hacia que el calculo se degradara con el tiempo.
    final exacta = _cacheada(from, to, exacta: true);
    if (exacta != null) {
      debugPrint('[OSRM] CACHE ${cronometro.elapsedMilliseconds} ms - '
          '${exacta.points.length} puntos, sin consultar');
      return exacta;
    }

    try {
      final json = await ApiClient.post(
        ApiConfig.recalculate(),
        body: {
          'origin': {'lat': from.latitude, 'lng': from.longitude},
          'destination': {'lat': to.latitude, 'lng': to.longitude},
          'profile': 'driving',
        },
        timeout: ApiConfig.osrmTimeout,
      );
      // Respuesta del proxy: {route, geometry, distance_meters,
      // duration_seconds}. La geometría es un LineString GeoJSON con
      // coordenadas [lon, lat], el mismo orden que leia la respuesta de OSRM.
      final geometry = json['geometry'] as Map<String, dynamic>?;
      final coords = geometry?['coordinates'] as List<dynamic>?;
      if (coords == null || coords.length < 2) {
        debugPrint('[OSRM] FALLA en ${cronometro.elapsedMilliseconds} ms - '
            'sin ruta para ${from.latitude},${from.longitude} -> '
            '${to.latitude},${to.longitude}');
        return _cacheada(from, to, exacta: false);
      }
      final ruta = OsrmRoute(
        points: coords
            .map((c) =>
                LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
            .toList(),
        distanceMeters:
            ((json['distance_meters'] ?? json['distance']) as num).toDouble(),
        durationSeconds:
            ((json['duration_seconds'] ?? json['duration']) as num).toDouble(),
      );
      _ultima = _RutaCache(
        origen: from,
        destino: to,
        ruta: ruta,
        cuando: DateTime.now(),
      );
      debugPrint('[OSRM] OK en ${cronometro.elapsedMilliseconds} ms - '
          '${ruta.points.length} puntos '
          '(${ruta.distanceKm.toStringAsFixed(1)} km, '
          '${ruta.durationMinutes.toStringAsFixed(0)} min)');
      return ruta;
    } catch (e) {
      final guardada = _cacheada(from, to, exacta: false);
      debugPrint('[OSRM] FALLA en ${cronometro.elapsedMilliseconds} ms - '
          'fallback en linea recta: $e'
          '${guardada == null ? '' : ' (se reutiliza la ultima ruta buena)'}');
      return guardada;
    }
  }

  /// Devuelve la ultima ruta buena si sirve para este trayecto, o `null`.
  ///
  /// Con [exacta] se exige el mismo origen y destino (redondeados a 4
  /// decimales, ~11 m). Sin ella basta con que el destino sea el mismo para
  /// alguno: el vehiculo se ha movido un poco, pero la ruta por calles sigue
  /// siendo la correcta y desde luego mejor que la recta.
  static OsrmRoute? _cacheada(LatLng from, LatLng to, {required bool exacta}) {
    final c = _ultima;
    if (c == null) return null;
    final edad = DateTime.now().difference(c.cuando);
    if (edad > (exacta ? _vigeExacta : _vigeAproximada)) return null;
    if (exacta) {
      final mismoOrigen = (c.origen.latitude - from.latitude).abs() < 1e-4 &&
          (c.origen.longitude - from.longitude).abs() < 1e-4;
      final mismoDestino = (c.destino.latitude - to.latitude).abs() < 1e-4 &&
          (c.destino.longitude - to.longitude).abs() < 1e-4;
      return (mismoOrigen && mismoDestino) ? c.ruta : null;
    }
    final cerca = (c.destino.latitude - to.latitude).abs() < _tolanciaDestino &&
        (c.destino.longitude - to.longitude).abs() < _tolanciaDestino;
    return cerca ? c.ruta : null;
  }

  /// Olvida la ruta guardada. Se llama al empezar un viaje nuevo, para no
  /// pintar el trayecto del viaje anterior.
  static void olvidarCache() => _ultima = null;
}

/// Una ruta guardada con los extremos y el momento en que se calculo.
class _RutaCache {
  final LatLng origen;
  final LatLng destino;
  final OsrmRoute ruta;
  final DateTime cuando;

  _RutaCache({
    required this.origen,
    required this.destino,
    required this.ruta,
    required this.cuando,
  });
}