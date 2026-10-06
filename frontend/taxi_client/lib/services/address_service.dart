import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import 'geocode_service.dart';

/// Direccion de calle con las dos calles que la cruzan.
///
/// El backend tiene las calles de La Habana descargadas y resuelve
/// "Calle 23 entre 11 y 12" en local. Si el backend no responde (por ejemplo
/// si la app se usa sin el servidor) se cae a [GeocodeService], que solo
/// consulta Nominatim y devuelve la calle sin las secundarias.
class Direccion {
  final String texto;
  final String? calle;
  final String? numero;
  final String? barrio;

  /// Las dos calles que cruzan, ya abreviadas ("11", "12").
  final List<String> entre;

  /// De donde salio: 'backend', 'nominatim' o 'cache'.
  final String origen;

  const Direccion({
    required this.texto,
    this.calle,
    this.numero,
    this.barrio,
    this.entre = const [],
    this.origen = 'backend',
  });

  bool get vacia => texto.isEmpty;

  /// true si vino con las calles secundarias.
  bool get tieneEntre => entre.length >= 2;
}

class AddressService {
  AddressService._();

  static final Map<String, Direccion> _cache = {};
  static const int _cacheMax = 300;

  static String _clave(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}';

  /// Direccion del punto, esperando lo que se pueda.
  static Future<Direccion> de(LatLng p) async {
    if (!AppConfig.inMapArea(p)) {
      return const Direccion(texto: '', origen: 'fuera');
    }
    final guardada = _cache[_clave(p)];
    if (guardada != null) return guardada;

    final d = await _delBackend(p) ?? await _deNominatim(p);
    if (_cache.length > _cacheMax) _cache.clear();
    _cache[_clave(p)] = d;
    return d;
  }

  /// Pide la direccion al backend, que ya sabe las calles que cruzan.
  static Future<Direccion?> _delBackend(LatLng p) async {
    final uri = Uri.parse(
      '${AppConfig.apiBase}/geo/direccion'
      '?lat=${p.latitude}&lon=${p.longitude}',
    );
    try {
      // 15 s y no 8: mientras el backend esta importando calles puede tener que
      // preguntar a Overpass, y ese camino tarda. Con el import completo esto
      // no pasa y responde en un par de segundos.
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final texto = (j['texto'] ?? '').toString();
      if (texto.isEmpty) return null;
      return Direccion(
        texto: texto,
        calle: j['calle']?.toString(),
        numero: j['numero']?.toString(),
        barrio: j['barrio']?.toString(),
        entre: ((j['entre'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        origen: (j['origen'] ?? 'backend').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Respaldo: Nominatim desde el telefono (calle, sin las secundarias).
  static Future<Direccion> _deNominatim(LatLng p) async {
    final addr = await GeocodeService.reverse(p);
    if (addr == null || addr.isEmpty) {
      return const Direccion(texto: '', origen: 'nominatim');
    }
    return Direccion(texto: addr, origen: 'nominatim');
  }
}
