import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../config.dart';

/// Geocodificación inversa (coordenadas → calle) con Nominatim (OpenStreetMap).
///
/// El chofer ve la dirección en nombres de calle. La dirección que envía el
/// pasajero (si la escribió al buscar) tiene prioridad; este servicio solo
/// actúa de respaldo cuando el viaje se creó sin dirección (pin en el mapa).
///
/// Política de uso de Nominatim: como máximo 1 petición por segundo, con
/// User-Agent de la aplicación. Además se cachea en memoria para no repetir
/// llamadas al cambiar de oferta/viaje.
class GeocodeService {
  static const String _userAgent = 'TaxiRapid/1.0 (flutter taxi_driver)';

  static final Map<String, String> _cache = {};
  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<void> _pending = Future.value();

  /// Serializa las llamadas y las separa >= 1.1 s (política de Nominatim).
  static Future<T> _guarded<T>(Future<T> Function() action) {
    final run = _pending.then((_) async {
      final waitMs =
          1100 - DateTime.now().difference(_lastRequest).inMilliseconds;
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
      _lastRequest = DateTime.now();
      return action();
    });
    _pending = run.then((_) {}, onError: (_) {});
    return run;
  }

  static String? _shortAddress(Map<String, dynamic>? addr) {
    if (addr == null) return null;
    final road = (addr['road'] ??
            addr['pedestrian'] ??
            addr['footway'] ??
            addr['residential'] ??
            addr['living_street'])
        ?.toString();
    final num = addr['house_number']?.toString();
    final suburb =
        (addr['suburb'] ?? addr['neighbourhood'] ?? addr['quarter'])?.toString();
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

  /// Convierte coordenadas en una dirección de calle (ej. "Calle 23, Vedado").
  /// Devuelve `null` si el punto está fuera del mapa o si Nominatim no
  /// responde o no encuentra una calle.
  static Future<String?> reverse(LatLng p) async {
    // Solo calles que existen en el mapa de la app.
    if (!AppConfig.inMapArea(p)) return null;
    final key =
        '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}';
    final cached = _cache[key];
    if (cached != null) return cached.isEmpty ? null : cached;

    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': '${p.latitude}',
      'lon': '${p.longitude}',
      'zoom': '18',
      'format': 'json',
      'email': 'taxirapid.dev@example.com',
    });

    String? addr;
    try {
      final res = await _guarded(() => http.get(
            uri,
            headers: {'User-Agent': _userAgent},
          ));
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        addr = _shortAddress(json['address'] as Map<String, dynamic>?);
      }
    } catch (_) {
      addr = null;
    }
    // Se cachea también el fallo (vacío) para no repetir la llamada.
    _cache[key] = addr ?? '';
    return addr;
  }
}