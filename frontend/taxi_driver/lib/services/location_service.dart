import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../models/geo_fix.dart';

/// Estado del permiso de ubicacion, para poder avisar al usuario.
enum LocationPermissionState {
  granted,
  denied,
  deniedForever,
  serviceDisabled,
  error,
}

/// GPS del dispositivo.
///
/// Se apoya en el LocationManager de Android a traves de un MethodChannel
/// (`taxirapid/location`) expuesto por MainActivity, en vez de una libreria
/// externa, para no depender de pub.dev.
///
/// Hay dos modos de escucha, y son distintos a proposito:
///
///  * **Modo flota** ([watch]): 10 s / 20 m. Suficiente para refrescar la
///    posicion que ve el backend. Es el que usa la app en reposo.
///  * **Modo navegacion** ([watchNavegacion]): 1 Hz. El mapa necesita refresco
///    frecuente para no dar saltos. El nativo se encarga de pausar el GPS si el
///    vehiculo lleva parado mas de 10 s.
class LocationService {
  static const _channel = MethodChannel('taxirapid/location');
  static const _fallback = LatLng(23.1136, -82.3666);

  static final _positions = StreamController<GeoFix>.broadcast();

  /// Rumbo del sensor, en el rango [0, 360). Llega a ~50 Hz, independiente del
  /// GPS que va a 1 Hz, asi que va en un stream aparte.
  static final _headings = StreamController<double>.broadcast();

  static bool _handlerReady = false;
  static bool _watching = false;
  static bool _navWatching = false;

  /// Ultimo rumbo del sensor, para poder combinarlo con un fix ya recibido.
  static double? _ultimoRumboSensor;

  static void _ensureHandler() {
    if (_handlerReady) return;
    _handlerReady = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onLocation':
          final fix = GeoFix.fromEvent(call.arguments);
          if (fix != null) {
            // El rumbo del sensor y el fix GPS son datos independientes, asi
            // que se combinan aqui en lugar de mezclarlos en nativo.
            final conRumbo = fix.conRumboSensor(_ultimoRumboSensor);
            if (!_positions.isClosed) _positions.add(conRumbo);
          }
          break;
        case 'onHeading':
          final args = call.arguments;
          if (args is Map && args['bearing'] is num) {
            final grados = ((args['bearing'] as num).toDouble() % 360 + 360) % 360;
            _ultimoRumboSensor = grados;
            if (!_headings.isClosed) _headings.add(grados);
          }
          break;
      }
      return null;
    });
  }

  /// Emisiones de posicion mientras el usuario se mueve (modo flota).
  ///
  /// [distanceFilter] evita inundar el backend: Android solo notifica cuando
  /// el desplazamiento supera los metros indicados.
  static Stream<GeoFix> watch({
    int distanceFilter = 20,
    Duration interval = const Duration(seconds: 10),
  }) {
    _ensureHandler();
    if (!_watching) {
      _watching = true;
      _channel.invokeMethod('start', <String, dynamic>{
        'intervalMs': interval.inMilliseconds,
        'minDistanceM': distanceFilter,
      }).catchError((_) {
        _watching = false;
      });
    }
    return _positions.stream;
  }

  /// Emisiones de posicion a 1 Hz para el modo navegacion.
  ///
  /// El GPS se pausa solo si el vehiculo lleva mas de 10 s parado, y se reanuda
  /// en cuanto arranca. Eso lo decide el nativo; aqui solo se pide el arranque.
  static Stream<GeoFix> watchNavegacion() {
    _ensureHandler();
    if (!_navWatching) {
      _navWatching = true;
      _ultimoRumboSensor = null;
      _channel.invokeMethod('startNav').catchError((_) {
        _navWatching = false;
      });
    }
    return _positions.stream;
  }

  /// Rumbo del sensor en grados, 0 = norte. Llega a ~50 Hz.
  static Stream<double> headings() {
    _ensureHandler();
    return _headings.stream;
  }

  /// Ultimo rumbo del sensor conocido, o `null` si aun no ha llegado ninguno.
  static double? get ultimoRumbo => _ultimoRumboSensor;

  /// Si el dispositivo tiene sensor de rumbo utilizable.
  ///
  /// Sin el se navega con el rumbo del GPS, que es mucho mas bruto.
  static Future<bool> tieneSensorRumbo() async {
    try {
      return await _channel.invokeMethod<bool>('hasHeadingSensor') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Corta las actualizaciones continuas.
  static Future<void> stopWatching() async {
    _watching = false;
    _navWatching = false;
    try {
      await _channel.invokeMethod('stop');
      await _channel.invokeMethod('stopNav');
    } catch (_) {}
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
    final fix = await currentFix(timeout: timeout);
    return fix?.position;
  }

  /// Posicion actual con su metadata (rumbo, velocidad, exactitud).
  static Future<GeoFix?> currentFix({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'getCurrent',
        <String, dynamic>{'timeoutMs': timeout.inMilliseconds},
      );
      final fix = GeoFix.fromEvent(res);
      return fix?.conRumboSensor(_ultimoRumboSensor);
    } catch (_) {
      return await lastKnownFix();
    }
  }

  /// Posicion al abrir la app, sin esperar al GPS (rapido y sin parpadeo).
  static Future<LatLng?> lastKnown() async => (await lastKnownFix())?.position;

  /// Igual que [lastKnown] pero con los metadatos del fix.
  static Future<GeoFix?> lastKnownFix() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getLastKnown');
      final fix = GeoFix.fromEvent(res);
      return fix?.conRumboSensor(_ultimoRumboSensor);
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

  /// Rumbo en grados de [a] a [b] (0 = norte, sentido horario).
  static double bearingBetween(LatLng a, LatLng b) {
    final lat1 = _rad(a.latitude);
    final lat2 = _rad(b.latitude);
    final dLng = _rad(b.longitude - a.longitude);
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return ((math.atan2(y, x) * 180 / math.pi) + 360) % 360;
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  /// Centro de La Habana, usado solo si el usuario no da permiso.
  static LatLng get fallback => _fallback;
}