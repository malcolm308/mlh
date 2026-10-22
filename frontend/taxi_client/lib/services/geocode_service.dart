import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../api_config.dart';
import 'api_client.dart';

/// Lugar devuelto por una búsqueda de direcciones
class GeoPlace {
  final String displayName;
  final String? shortLabel;
  final double lat;
  final double lng;

  GeoPlace({
    required this.displayName,
    this.shortLabel,
    required this.lat,
    required this.lng,
  });

  LatLng get point => LatLng(lat, lng);
}

/// Servicio de geocodificación basado en backend propio (/geo/buscar).
class GeocodeService {
  static final Map<String, List<GeoPlace>> _cache = {};

  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<void> _pending = Future.value();

  static Future<T> _guarded<T>(Future<T> Function() action) {
    final run = _pending.then((_) async {
      var waitMs = 500 - DateTime.now().difference(_lastRequest).inMilliseconds;
      if (waitMs > 0) await Future<void>.delayed(Duration(milliseconds: waitMs));
      _lastRequest = DateTime.now();
      return action();
    });
    _pending = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<List<GeoPlace>> search(
    String query, {
    LatLng? near,
    int limit = 8,
    String? viewBox,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) return const [];
    final nearLat = near?.latitude;
    final nearLon = near?.longitude;
    final key = '${trimmed.toLowerCase()}|${nearLat ?? ''}|${nearLon ?? ''}|$limit';
    if (_cache.containsKey(key)) return _cache[key]!;

    final uri = Uri.parse('${ApiConfig.baseUrl}/geo/buscar').replace(
      queryParameters: {
        'q': trimmed,
        if (nearLat != null) 'lat': nearLat.toString(),
        if (nearLon != null) 'lon': nearLon.toString(),
        'limit': limit.toString(),
      },
    );

    try {
      final resp = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw http.ClientException('HTTP ${resp.statusCode} en /geo/buscar');
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      if (json['ok'] != true) return const [];
      final resultados = json['resultados'] as List? ?? const [];
      final places = <GeoPlace>[];
      for (final r in resultados) {
        if (r is! Map) continue;
        final latv = (r['lat'] as num?)?.toDouble();
        final lngv = (r['lng'] as num?)?.toDouble();
        if (latv == null || lngv == null) continue;
        final short = r['short_label']?.toString() ?? r['display_name']?.toString();
        final display = r['display_name']?.toString() ?? short ?? '';
        places.add(GeoPlace(lat: latv, lng: lngv, displayName: display, shortLabel: short));
      }
      _cache[key] = places;
      return places;
    } catch (e) {
      // Se propaga el error para que la UI pueda avisar al usuario.
      throw GeocodeException('No se pudo consultar el servidor: $e');
    }
  }

  static Future<String?> reverse(LatLng p) async {
    if (!ApiConfig.inMapArea(p)) return null;
    try {
      final res = await _guarded(
        () => ApiClient.get('/geo/direccion?lat=${p.latitude}&lon=${p.longitude}'),
      );
      if (res is! Map<String, dynamic>) return null;
      if (res['ok'] != true) return null;
      final texto = res['texto']?.toString() ?? res['calle']?.toString();
      return texto?.isNotEmpty == true ? texto : null;
    } on ApiException {
      return null;
    }
  }
}

/// Error de red al consultar el backend de geocodificacion.
class GeocodeException implements Exception {
  final String message;
  GeocodeException(this.message);
  @override
  String toString() => message;
}
