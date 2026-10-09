import 'package:latlong2/latlong.dart';

/// Configuración central de la app de cliente.
///
/// Por defecto apunta a los servicios desplegados en Render (backend FastAPI
/// y servidor de tiles Martin). Se puede sobreescribir por línea de comandos
/// con --dart-define, por ejemplo para desarrollo local:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 --dart-define=MARTIN_URL=http://localhost:8010
class ApiConfig {
  ApiConfig._();

  /// URL base del backend FastAPI desplegado en Render.
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://rapitaxi-api-fws6.onrender.com',
  );

  /// URL base del servidor de tiles Martin (del que se sirve el estilo).
  static const String martinUrl = String.fromEnvironment(
    'MARTIN_URL',
    defaultValue: 'https://mlh-tdyg.onrender.com',
  );

  /// URL del estilo de MapLibre, servido por Martin desde el MBTiles.
  /// Se sirve de [martinUrl] y no admite override aparte.
  static String get mapStyleUrl => '$martinUrl/styles/taxi';

  // ---------------- Endpoints del backend ----------------

  /// Tiempo máximo que se espera a OSRM (via el proxy del backend) antes de
  /// caer al fallback en línea recta. El proxy sale del backend a OSRM, y desde
  /// una red móvil normal puede tardar más que el backend propio: 30 s dejan
  /// margen sin condenar al pasajero a esperar demasiado.
  static const Duration osrmTimeout = Duration(seconds: 30);

  /// Ruta por carretera calculada por el backend (proxy contra OSRM,
  /// `routers/routing.py`, que monta el prefix `/api/routing`).
  ///
  /// La ruta inicial también va por aquí, no directo al servidor público de
  /// OSRM: desde Cuba ese host es inestable y el fallo dejaba el mapa en línea
  /// recta. Es el mismo canal fiable que ya usa el recalculo de desvíos.
  static String recalculate() => '$baseUrl/api/routing/recalculate';

  /// Cancelación de un viaje por el pasajero.
  static String cancelTrip(String tripId) => '$baseUrl/trips/$tripId/cancel';

  /// Cambio de estado (online/offline) de un chofer.
  static String driverStatus(String driverId) =>
      '$baseUrl/drivers/$driverId/status';

  /// Health check del backend.
  static String health() => '$baseUrl/health';

  /// Todas las tarifas configuradas (GET /api/tariffs del backend).
  static Uri tariffs() => Uri.parse('$baseUrl/api/tariffs');

  /// Tarifa de un tipo de vehiculo concreto (GET /api/tariffs/{vehicle_type}).
  static Uri tariffByType(String vehicleType) =>
      Uri.parse('$baseUrl/api/tariffs/${Uri.encodeComponent(vehicleType)}');

  /// Reglas de precio por horario (GET /api/pricing-rules).
  static Uri pricingRules() => Uri.parse('$baseUrl/api/pricing-rules');

  /// Reglas horarias de un tipo de vehiculo concreto
  /// (GET /api/pricing-rules/{vehicle_type}).
  static Uri pricingRulesByType(String vehicleType) =>
      Uri.parse(
          '$baseUrl/api/pricing-rules/${Uri.encodeComponent(vehicleType)}');

  /// Posición inicial/por defecto del cliente (Centro de La Habana).
  static const LatLng defaultClientLocation = LatLng(23.1136, -82.3666);

  static const double defaultZoom = 14;
  static const int minZoom = 10;
  static const int maxZoom = 18;

  /// Distancia por debajo de la cual se pasa al zoom de calle.
  ///
  /// 500 m. Es el punto en el que al pasajero le empieza a importar mas la
  /// calle exacta que va a ver que el trayecto entero.
  static const double distanciaZoomCerca = 500.0;

  /// Zoom de la vista del cliente cuando el vehiculo va cerca.
  static const double zoomVehiculoCerca = 17;

  /// Zoom segun la distancia al objetivo.
  ///
  /// El cliente NO rota el mapa ni lo inclina, asi que su unica referencia para
  /// decidir cuanto acercar es lo lejos que esta el vehiculo. La tabla es la
  /// misma que usa el chofer, para que ambos vean el mismo encuadre.
  static double zoomPorDistancia(double metros) {
    if (metros <= 300) return 17;
    if (metros <= 800) return 16;
    if (metros <= 2000) return 15;
    if (metros <= 5000) return 14;
    return 13;
  }

  /// Área cubierta por los tiles locales del mapa (La Habana).
  ///
  /// La búsqueda de direcciones se acota a esta zona para que solo ofrezca
  /// calles que existen realmente en el mapa de la app.
  static const double mapSouth = 22.89768;
  static const double mapNorth = 23.30190;
  static const double mapWest = -82.60071;
  static const double mapEast = -82.19971;

  /// `viewbox` de Nominatim (oeste, norte, este, sur) con el área del mapa.
  static String get mapViewBox =>
      '$mapWest,$mapNorth,$mapEast,$mapSouth';

  /// `true` si el punto está dentro del área cartografiada del mapa.
  static bool inMapArea(LatLng p) =>
      p.latitude >= mapSouth &&
      p.latitude <= mapNorth &&
      p.longitude >= mapWest &&
      p.longitude <= mapEast;
}
