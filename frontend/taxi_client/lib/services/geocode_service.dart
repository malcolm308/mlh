import 'dart:async';
import 'dart:convert';

import 'package:latlong2/latlong.dart';

import '../api_config.dart';
import 'api_client.dart';

/// Lugar devuelto por una búsqueda de direcciones (geocodificación directa).
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
///
/// Mantiene cache y rate limit para evitar abusos, sin tocar la UI ni MapLibre.
class GeocodeService {
  static final Map<String, List<GeoPlace>> _cache = {};

  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<void> _pending = Future.value();

  /// Serializa las llamadas y las separa >= 500 ms.
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

  /// Busca direcciones por texto (ej. "calle 23 vedado", "virtudes entre industria y salud").
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
    final key = '$trimmed|$nearLat|$nearLon|$limit';
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
      final res = await _guarded(() => ApiClient.getUri(uri));
      if (res is! Map<String, dynamic>) return const [];
      final ok = res['ok'] == true;
      final resultados = res['resultados'] as List<dynamic>? ?? [];
      if (!ok || resultados.isEmpty) {
        _cache[key] = const [];
        return const [];
      }
      final places = resultados.map<GeoPlace>((r) {
        if (r is! Map<String, dynamic>) return null;
        final lat = (r['lat'] as num?)?.toDouble();
        final lng = (r['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) return null;
        final displayName = r['display_name']?.toString() ?? '';
        final shortLabel = r['short_label']?.toString();
        return GeoPlace(
          lat: lat,
          lng: lng,
          displayName: displayName.isEmpty
              ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
              : displayName,
          shortLabel: shortLabel,
        );
      }).whereType<GeoPlace>().toList();
      _cache[key] = places;
      return places;
    } on ApiException {
      _cache[key] = const [];
      return const [];
    }
  }

  /// Convierte unas coordenadas en una dirección corta de calles.
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