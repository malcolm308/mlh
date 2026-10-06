import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Una muestra completa del GPS entregada por el MethodChannel
/// `taxirapid/location`.
///
/// Antes de implementar el modo navegacion el canal solo transportaba [LatLng]
/// y se perdian justo los tres datos que hacen falta para el heading-up: el
/// rumbo, la velocidad y el reloj monotono.
///
/// Regla importante: los campos ausentes son `null`, NUNCA `0`. Android devuelve
/// `0.0` tanto para "rumbo norte" como para "no tengo rumbo", y esa ambiguedad
/// haria que el mapa se orientase al norte en un tunel.
class GeoFix {
  /// Posicion del fix.
  final LatLng position;

  /// Radio de error horizontal en metros segun Android.
  ///
  /// Si supera [accuracyMaximaNavegacion] el fix sirve para mostrar el punto
  /// pero no para orientar el mapa.
  final double? accuracy;

  /// Rumbo en grados (0 = norte, sentido horario) calculado por Android.
  ///
  /// Solo si el propio fix trae rumbo util. Es el ultimo recurso: mientras el
  /// vehiculo esta en marcha se prefiere el sensor (ver `NavigationModeService`).
  final double? bearing;

  /// Rumbo suavizado, en grados, injectionsado por el giroscopio/brújula.
  ///
  /// Llega a unos 50 Hz por el canal, independiente del GPS que va a 1 Hz.
  final double? sensorBearing;

  /// Velocidad en m/s segun el GPS (no el odometro del vehiculo).
  final double? speedMps;

  /// `location.time`: hora del reloj del sistema. Solo informativa.
  ///
  /// NUNCA se usa para calcular deltas de tiempo: un cambio de hora o de zona
  /// horaria produciria intervalos negativos. Para integrar tiempos esta
  /// [elapsedRealtimeMs].
  final int? wallTimeMs;

  /// `location.elapsedRealtimeNanos / 1e6`: reloj monotono en ms desde el
  /// arranque del dispositivo. Es el unico reloj fiable para dead-reckoning.
  final int? elapsedRealtimeMs;

  /// Proveedor Android: 'gps', 'network', 'fused'...
  final String? provider;

  /// Android marca las posiciones de un proveedor de ubicacion simulado.
  final bool mocked;

  const GeoFix({
    required this.position,
    this.accuracy,
    this.bearing,
    this.sensorBearing,
    this.speedMps,
    this.wallTimeMs,
    this.elapsedRealtimeMs,
    this.provider,
    this.mocked = false,
  });

  /// Precision por debajo de la cual el fix sirve para navegar.
  static const double accuracyMaximaNavegacion = 60.0;

  /// Un fix con exactitud suficiente para orientar el mapa.
  bool get navegable =>
      !mocked && (accuracy == null || accuracy! <= accuracyMaximaNavegacion);

  bool get tieneRumbo => sensorBearing != null || bearing != null;

  /// Rumbo que se debe usar, priorizando el sensor sobre el GPS.
  double? get rumbo => sensorBearing ?? bearing;

  double get velocidadKmh => (speedMps ?? 0.0) * 3.6;

  /// Copia con el rumbo del sensor incorporado.
  ///
  /// El sensor es un dato independiente del fix GPS, asi que se combina aqui
  /// en lugar de mezclarlo en el mismo evento nativo.
  GeoFix conRumboSensor(double? grados) => GeoFix(
        position: position,
        accuracy: accuracy,
        bearing: bearing,
        sensorBearing: grados,
        speedMps: speedMps,
        wallTimeMs: wallTimeMs,
        elapsedRealtimeMs: elapsedRealtimeMs,
        provider: provider,
        mocked: mocked,
      );

  /// Convierte el payload que llega del MethodChannel.
  ///
  /// Devuelve `null` si el evento no trae coordenadas numericas, que es el
  /// caso que antes contemplaba `LocationService._toLatLng`.
  static GeoFix? fromEvent(dynamic event) {
    if (event is! Map) return null;
    final lat = event['latitude'];
    final lng = event['longitude'];
    if (lat is! num || lng is! num) return null;

    final tieneBearing = event['hasBearing'] == true;
    final tieneSpeed = event['hasSpeed'] == true;
    final rawBearing = event['bearing'];
    final rawSpeed = event['speed'];
    final rawWall = event['wallTimeMs'];
    final rawElapsed = event['elapsedRealtimeMs'];

    return GeoFix(
      position: LatLng(lat.toDouble(), lng.toDouble()),
      accuracy: (event['accuracy'] as num?)?.toDouble(),
      // Sin el flag `hasBearing`, Android devuelve 0.0 = norte, no "sin dato".
      bearing: (tieneBearing && rawBearing is num) ? rawBearing.toDouble() : null,
      speedMps: (tieneSpeed && rawSpeed is num) ? rawSpeed.toDouble() : null,
      wallTimeMs: rawWall is num ? rawWall.toInt() : null,
      elapsedRealtimeMs: rawElapsed is num ? rawElapsed.toInt() : null,
      provider: event['provider'] as String?,
      mocked: event['mocked'] == true,
    );
  }

  @override
  String toString() => 'GeoFix(${position.latitude}, ${position.longitude}, '
      'acc=${accuracy?.toStringAsFixed(1)}, rumbo=${rumbo?.toStringAsFixed(1)}, '
      'v=${speedMps?.toStringAsFixed(2)} m/s)';
}