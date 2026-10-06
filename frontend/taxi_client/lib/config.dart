import 'package:latlong2/latlong.dart';

/// Configuración central de la app de cliente.
///
/// Por defecto apunta al backend local en el puerto 8000 y al servidor de
/// tiles local en el puerto 8010. Se puede sobreescribir por línea de
/// comandos usando --dart-define, por ejemplo para un emulador Android:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
/// o contra el despliegue de producción:
///   flutter build apk --release --dart-define=API_BASE_URL=https://api.onrender.com
class AppConfig {
  AppConfig._();

  static const String apiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  /// URL del estilo de MapLibre, servido por Martin desde el MBTiles.
  ///
  /// Antes esta constante era una plantilla de teselas raster PNG
  /// (`/tiles/{z}/{x}/{y}.png`) que consumia `flutter_map`. Con vector tiles ya
  /// no hay URL de tesela que construir: el cliente pide un estilo completo y el
  /// motor negocia los PBF por su cuenta a partir del `source` que declara. Es
  /// el mismo servidor y el mismo estilo que usa la app del chofer.
  static const String mapStyleUrl = String.fromEnvironment(
    'MAP_STYLE_URL',
    defaultValue: 'http://localhost:8010/style/taxi',
  );

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

  /// Tarifa estimada por carretera: base + por kilómetro (igual que el
  /// mapa web de referencia).
  static const double fareBase = 2.00;
  static const double farePerKm = 1.50;

  /// Tipos de vehículo disponibles (deben existir en la tabla tariffs).
  static const List<String> vehicleTypes = [
    'basico',
    'moto',
    'triciclo',
    'confort',
  ];
}
