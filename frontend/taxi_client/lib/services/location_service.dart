import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

/// Estado del permiso de ubicacion, para poder avisar al usuario.
enum LocationPermissionState {
  granted,
  denied,
  deniedForever,
  serviceDisabled,
  error,
}

/// Ubicacion GPS del dispositivo.
///
/// Se apoya en el LocationManager de Android a traves de un MethodChannel
/// (`taxirapid/location`) expuesto por MainActivity, en vez de una libreria
/// externa, para no depender de pub.dev.
class LocationService {
  static const _channel = MethodChannel('taxirapid/location');
  static const _fallback = LatLng(23.1136, -82.3666);

  static final _positions = StreamController<LatLng>.broadcast();
  static bool _handlerReady = false;
  static bool _watching = false;
  static DateTime? _lastFixAt;
  static LatLng? _lastPosition;

  /// Momento del ultimo fix recibido, o `null` si aun no llego ninguno.
  static DateTime? get lastFixAt => _lastFixAt;

  /// Ultima posicion recibida por [watch], o `null` si aun no hay ninguna.
  static LatLng? get lastPosition => _lastPosition;

  static void _ensureHandler() {
    if (_handlerReady) return;
    _handlerReady = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLocation') {
        final p = _toLatLng(call.arguments);
        if (p != null && !_positions.isClosed) {
          _lastFixAt = DateTime.now();
          _lastPosition = p;
          _positions.add(p);
        }
      }
      return null;
    });
  }

  /// Emisiones de posicion mientras el usuario se mueve.
  ///
  /// [distanceFilter] evita inundar el backend: Android solo notifica cuando
  /// el desplazamiento supera los metros indicados.
  static Stream<LatLng> watch({
    int distanceFilter = 20,
    Duration interval = const Duration(seconds: 10),
  }) {
    _ensureHandler();
    // Siempre se (re)arranca el listener nativo: es idempotente y evita que
    // una bandera vieja deje el GPS apagado para siempre.
    unawaited(ensureWatching(
      distanceFilter: distanceFilter,
      interval: interval,
    ));
    return _positions.stream;
  }

  /// Arranca (o reinicia) el listener nativo de posicion.
  ///
  /// Devuelve `true` si Android acepto el pedido. Es seguro llamarlo varias
  /// veces: [MainActivity] quita el listener anterior antes de registrar el
  /// nuevo.
  static Future<bool> ensureWatching({
    int distanceFilter = 8,
    Duration interval = const Duration(seconds: 5),
  }) async {
    _ensureHandler();
    try {
      final ok = await _channel.invokeMethod<bool>('start', <String, dynamic>{
        'intervalMs': interval.inMilliseconds,
        'minDistanceM': distanceFilter,
      });
      _watching = ok ?? true;
      return _watching;
    } catch (_) {
      _watching = false;
      return false;
    }
  }

  /// Detiene las actualizaciones continuas.
  static Future<void> stopWatching() async {
    _watching = false;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  static LatLng? _toLatLng(dynamic event) {
    if (event is! Map) return null;
    final lat = event['latitude'];
    final lng = event['longitude'];
    if (lat is num && lng is num) return LatLng(lat.toDouble(), lng.toDouble());
    return null;
  }

  /// Comprueba si el GPS esta activo y pide el permiso si hace falta.
  static Future<LocationPermissionState> ensurePermission() async {
    try {
      final enabled = await _channel.invokeMethod<bool>('isEnabled') ?? false;
      if (!enabled) return LocationPermissionState.serviceDisabled;
      final granted = await _channel.invokeMethod<bool>('ensurePermission') ?? false;
      return granted
          ? LocationPermissionState.granted
          : LocationPermissionState.denied;
    } on PlatformException catch (e) {
      if (e.code == 'EN_CURSO') return LocationPermissionState.denied;
      return LocationPermissionState.error;
    } catch (_) {
      return LocationPermissionState.error;
    }
  }

  /// Abre los ajustes del sistema para conceder el permiso manualmente.
  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod('openSettings');
    } catch (_) {}
  }

  /// Posicion actual. Devuelve null si el GPS no responde a tiempo.
  static Future<LatLng?> current({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'getCurrent',
        <String, dynamic>{'timeoutMs': timeout.inMilliseconds},
      );
      return _toLatLng(res);
    } catch (_) {
      return await lastKnown();
    }
  }

  /// Posicion al abrir la app, sin esperar al GPS (rapido y sin parpadeo).
  static Future<LatLng?> lastKnown() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getLastKnown');
      return _toLatLng(res);
    } catch (_) {
      return null;
    }
  }

  /// Distancia en metros entre dos puntos (formula de Haversine).
  static double distanceBetween(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    final dLat = _rad(b.latitude - a.latitude);
    final dLng = _rad(b.longitude - a.longitude);
    final lat1 = _rad(a.latitude);
    final lat2 = _rad(b.latitude);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.pow(math.sin(dLng / 2), 2) * math.cos(lat1) * math.cos(lat2);
    return 2 * earthRadius * math.asin(math.sqrt(h));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  /// Centro de La Habana, usado solo si el usuario no da permiso.
  static LatLng get fallback => _fallback;
}
