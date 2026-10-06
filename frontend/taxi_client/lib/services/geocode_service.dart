import 'dart:async';

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

/// Servicio de geocodificación y geocodificación inversa basado en
/// OpenStreetMap (Nominatim): búsqueda por calles y resolución de
/// coordenadas a nombre de calle.
///
/// Política de uso de Nominatim: como máximo 1 petición por segundo y un
/// User-Agent que identifique la aplicación. Todas las llamadas se serializan.
class GeocodeService {
  static const String _userAgent = 'TaxiRapid/1.0 (flutter taxi_client)';

  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<void> _pending = Future.value();

  /// Serializa las llamadas y las separa >= 1.1 s para cumplir la política.
  static Future<T> _guarded<T>(Future<T> Function() action) {
    final run = _pending.then((_) async {
      var waitMs = 1100 - DateTime.now().difference(_lastRequest).inMilliseconds;
      if (waitMs > 0) await Future<void>.delayed(Duration(milliseconds: waitMs));
      _lastRequest = DateTime.now();
      return action();
    });
    _pending = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<Map<String, dynamic>?> _getJson(String url) async {
    try {
      final j = await ApiClient.get(url, headers: {'User-Agent': _userAgent});
      return j is Map<String, dynamic> ? j : null;
    } on ApiException {
      return null;
    }
  }

  static Future<List<dynamic>?> _getListJson(String url) async {
    try {
      final j = await ApiClient.get(url, headers: {'User-Agent': _userAgent});
      return j is List ? j : null;
    } on ApiException {
      return null;
    }
  }

  /// Traduce un dict `address` de Nominatim a una dirección calle corta.
  static String? _shortAddress(Map<String, dynamic>? addr) {
    if (addr == null) return null;
    final road = (addr['road'] ??
            addr['pedestrian'] ??
            addr['footway'] ??
            addr['residential'] ??
            addr['living_street'])
        ?.toString();
    final num = addr['house_number']?.toString();
    final suburb = (addr['suburb'] ??
            addr['neighbourhood'] ??
            addr['quarter'] ??
            addr['city_district'])
        ?.toString();
    final roadPart = (road != null && num != null && num.isNotEmpty)
        ? '$road $num'
        : road;
    final parts = <String>[
      ?roadPart,
      if (suburb?.isNotEmpty ?? false) ?suburb,
    ];
    final joined = parts.join(', ');
    return joined.isEmpty ? null : joined;
  }

  /// Busca direcciones por texto (ej. "Calle 23, La Habana").
  static Future<List<GeoPlace>> search(
    String query, {
    LatLng? near,
    int limit = 6,
    String? viewBox,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 3) return const [];
    final url = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': trimmed,
      // jsonv2 incluye 'category', necesaria para quedarse solo con calles.
      'format': 'jsonv2',
      'addressdetails': '1',
      'limit': '${limit * 3}',
      'email': 'taxirapid.dev@example.com',
      // Acota los resultados al área del mapa de la app.
      'viewbox': viewBox ?? ApiConfig.mapViewBox,
      'bounded': '1',
      if (near != null) 'lat': '${near.latitude}',
      if (near != null) 'lon': '${near.longitude}',
    }).toString();
    final results = await _guarded(() => _getListJson(url));
    if (results == null) return const [];
    return results
        .where((r) => _isStreet(r))
        .map<GeoPlace?>((r) {
          final lat = double.tryParse('${r['lat'] ?? ''}');
          final lng = double.tryParse('${r['lon'] ?? ''}');
          if (lat == null || lng == null) return null;
          final addr = (r['address'] as Map<String, dynamic>?);
          final displayName = (r['display_name'] ?? '').toString();
          final short = _shortAddress(addr);
          return GeoPlace(
            displayName: displayName.isEmpty
                ? ('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}')
                : displayName,
            shortLabel: short ?? displayName,
            lat: lat,
            lng: lng,
          );
        })
        .whereType<GeoPlace>()
        .take(limit)
        .toList();
  }

  /// Un resultado es una calle si Nominatim lo clasifica como vía
  /// (`category == 'highway'`). Así se descartan barrios, parques, hoteles,
  /// estadios y otros lugares que no son calles del mapa.
  static bool _isStreet(Map<String, dynamic> r) =>
      (r['category'] ?? '').toString() == 'highway';

  /// Convierte unas coordenadas en una dirección corta de calles
  /// (ej. "Calle 23, Vedado"). Devuelve `null` si el punto cae fuera del
  /// área del mapa o si no se puede resolver a una calle.
  static Future<String?> reverse(LatLng p) async {
    if (!ApiConfig.inMapArea(p)) return null;
    final url = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': '${p.latitude}',
      'lon': '${p.longitude}',
      'zoom': '18',
      'format': 'json',
      'email': 'taxirapid.dev@example.com',
    }).toString();
    final json = await _guarded(() => _getJson(url));
    if (json == null) return null;
    return _shortAddress(json['address'] as Map<String, dynamic>?);
  }
}