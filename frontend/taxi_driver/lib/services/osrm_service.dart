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

/// Cliente del servicio público de ruteo OSRM (mismo que usa el
/// mapa web de referencia):
///   https://router.project-osrm.org/route/v1/driving/{lon,lat};{lon,lat}...
class OsrmService {
  OsrmService._();

  /// Calcula la ruta por carretera entre [from] y [to].
  ///
  /// Devuelve `null` si el servidor no responde o no encuentra ruta. Cuando
  /// eso pasa, la pantalla se queda con el fallback en linea recta, asi que se
  /// deja constancia en el log para poder distinguir si el fallo fue de red
  /// (timeout) o de ruta inexistente.
  static Future<OsrmRoute?> route(LatLng from, LatLng to) async {
    final url = '${ApiConfig.routing()}/${from.longitude},${from.latitude};'
        '${to.longitude},${to.latitude}'
        '?overview=full&geometries=geojson&steps=false&alternatives=false';
    try {
      final json = await ApiClient.get(
        url,
        timeout: ApiConfig.osrmTimeout,
      );
      final routes = json['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) {
        debugPrint('[OSRM] FALLA - sin ruta para ${from.latitude},'
            '${from.longitude} -> ${to.latitude},${to.longitude}');
        return null;
      }
      final route = routes.first as Map<String, dynamic>;
      final geometry = route['geometry'] as Map<String, dynamic>;
      final coords =
          (geometry['coordinates'] as List<dynamic>).cast<List<dynamic>>();
      final ruta = OsrmRoute(
        points: coords
            .map((c) =>
                LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
            .toList(),
        distanceMeters: (route['distance'] as num).toDouble(),
        durationSeconds: (route['duration'] as num).toDouble(),
      );
      debugPrint('[OSRM] OK - ${ruta.points.length} puntos '
          '(${ruta.distanceKm.toStringAsFixed(1)} km, '
          '${ruta.durationMinutes.toStringAsFixed(0)} min)');
      return ruta;
    } catch (e) {
      debugPrint('[OSRM] FALLA - usando fallback en linea recta: $e');
      return null;
    }
  }
}