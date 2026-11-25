import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../api_config.dart';
import 'api_client.dart';

/// Punto de la vía más cercana al GPS, con un trozo corto de geometría.
///
/// Lo devuelve `GET /geo/calle-cercana`, que consulta la tabla `public.streets`
/// de Supabase/Postgres. Sirve SOLO para dibujar/anclar el vehículo: la
/// posición que se publica al backend y al pasajero sigue siendo la real
/// filtrada.
class AnclajeCalle {
  final LatLng punto;
  final List<LatLng> geom;
  final double distanciaMetros;
  final String? nombre;
  final String? tipo;
  final String origen;

  const AnclajeCalle({
    required this.punto,
    required this.geom,
    required this.distanciaMetros,
    this.nombre,
    this.tipo,
    this.origen = 'supabase:streets',
  });

  /// Convierte la respuesta del backend. Devuelve `null` si viene vacía o
  /// incompleta: ante la duda el marcador se dibuja en la posición real.
  static AnclajeCalle? fromJson(dynamic j) {
    if (j is! Map) return null;
    if (j['ok'] != true) return null;
    final punto = j['punto'];
    if (punto is! Map) return null;
    final lat = _numero(punto['lat']);
    final lon = _numero(punto['lon']);
    if (lat == null || lon == null) return null;

    final geom = <LatLng>[];
    final crudos = j['geom'];
    if (crudos is List) {
      for (final par in crudos) {
        if (par is! List || par.length < 2) continue;
        final a = _numero(par[0]);
        final b = _numero(par[1]);
        if (a != null && b != null) geom.add(LatLng(a, b));
      }
    }
    // Sin al menos dos puntos no se puede extrapolar por la calle: mejor no
    // anclar que dibujar una recta inventada.
    if (geom.length < 2) return null;

    return AnclajeCalle(
      punto: LatLng(lat, lon),
      geom: List<LatLng>.unmodifiable(geom),
      distanciaMetros: _numero(j['dist_m']) ?? 0.0,
      nombre: j['nombre']?.toString(),
      tipo: j['tipo']?.toString(),
      origen: j['origen']?.toString() ?? 'supabase:streets',
    );
  }

  static double? _numero(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

/// Cliente con caché y limitación de frecuencia del anclaje a calle.
///
/// El GPS llega a 1 Hz, pero la malla no cambia: se pide como mucho cada 5 s y
/// se reutiliza la respuesta mientras el coche siga a menos de ~20 m de la
/// coordenada consultada. Así un barrido de edificios no dispara una petición
/// por fix.
class CalleCercanaService {
  static final Map<String, AnclajeCalle> _cache = {};
  static final Map<String, DateTime> _momento = {};
  static DateTime? _ultimaPeticion;

  static const int _cacheMax = 200;
  static const Duration _ttl = Duration(seconds: 60);
  static const Duration _intervaloMinimo = Duration(seconds: 5);

  /// Radio de búsqueda, en metros. Un GPS urbano rara vez se pasa de 60 m; 120 m
  /// dejan margen sin coger la calle de al lado.
  static const double radioMetros = 120.0;

  /// Devuelve el anclaje para [p], o `null` si no hay calle cercana o falla la
  /// red. Nunca lanza: es un adorno del marcador, no puede tumbar el GPS.
  static Future<AnclajeCalle?> de(LatLng p) async {
    if (!ApiConfig.inMapArea(p)) return null;

    final clave = _clave(p);
    final guardado = _cache[clave];
    final ts = _momento[clave];
    if (guardado != null &&
        ts != null &&
        DateTime.now().difference(ts) < _ttl) {
      return guardado;
    }

    final ahora = DateTime.now();
    final ultima = _ultimaPeticion;
    if (ultima != null && ahora.difference(ultima) < _intervaloMinimo) {
      // Se devuelve el valor viejo aunque haya caducado: es mejor que saltar a
      // la posición cruda por una ventaja de milisegundos.
      return guardado;
    }
    _ultimaPeticion = ahora;

    final url = Uri.parse('${ApiConfig.baseUrl}/geo/calle-cercana')
        .replace(queryParameters: <String, String>{
      'lat': p.latitude.toStringAsFixed(6),
      'lon': p.longitude.toStringAsFixed(6),
      'radio_m': radioMetros.toStringAsFixed(0),
    });

    try {
      final anclaje = AnclajeCalle.fromJson(await ApiClient.get(url.toString()));
      if (anclaje == null) return null;
      if (_cache.length >= _cacheMax) {
        _cache.clear();
        _momento.clear();
      }
      _cache[clave] = anclaje;
      _momento[clave] = DateTime.now();
      return anclaje;
    } catch (_) {
      return null;
    }
  }

  /// Rejilla de ~20 m: evita una petición por cada rebote del GPS.
  static String _clave(LatLng p) =>
      '${(p.latitude * 5000).round()}|${(p.longitude * 5000).round()}';

  /// Solo para pruebas.
  static void reiniciar() {
    _cache.clear();
    _momento.clear();
    _ultimaPeticion = null;
  }
}
