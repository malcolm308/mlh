import 'package:flutter/foundation.dart' show debugPrint;
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

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

/// Cliente de ruteo del conductor.
///
/// La ruta NO se pide directo al servidor publico de OSRM: desde Cuba ese host
/// es inestable (a veces responde en 1 s, a veces se cuelga 30 s+ y OSRM
/// descarta las peticiones por su rate-limit cuando el telefono dispara varias
/// a la vez). Por eso esta app habla con el backend propio
/// ([ApiConfig.recalculate]), que ya es fiable desde aqui, y es el backend quien
/// consulta a OSRM desde su red (mismo canal que usa el recalculo de desvios).
class OsrmService {
  OsrmService._();

  /// Calcula la ruta por carretera entre [from] y [to].
  ///
  /// Devuelve `null` si el proxy no encuentra ruta o si el backend/OSRM no
  /// responde a tiempo. Cuando eso pasa, la pantalla se queda con el fallback
  /// en linea recta, asi que se deja constancia en el log para poder distinguir
  /// si el fallo fue de red (timeout) o de ruta inexistente. Lleva su propio
  /// timeout ([ApiConfig.osrmTimeout]) y no el generico de 15 s del [ApiClient].
  static Future<OsrmRoute?> route(LatLng from, LatLng to) async {
    final cronometro = Stopwatch()..start();
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
      // duration_seconds}. La geometria es un LineString GeoJSON con
      // coordenadas [lon, lat], el mismo orden que leia la respuesta de OSRM.
      final geometry = json['geometry'] as Map<String, dynamic>?;
      final coords = geometry?['coordinates'] as List<dynamic>?;
      if (coords == null || coords.length < 2) {
        debugPrint('[OSRM] FALLA en ${cronometro.elapsedMilliseconds} ms - '
            'sin ruta para ${from.latitude},${from.longitude} -> '
            '${to.latitude},${to.longitude}');
        return null;
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
      debugPrint('[OSRM] OK en ${cronometro.elapsedMilliseconds} ms - '
          '${ruta.points.length} puntos '
          '(${ruta.distanceKm.toStringAsFixed(1)} km, '
          '${ruta.durationMinutes.toStringAsFixed(0)} min)');
      return ruta;
    } catch (e) {
      debugPrint('[OSRM] FALLA en ${cronometro.elapsedMilliseconds} ms - '
          'fallback en linea recta: $e');
      return null;
    }
  }
}