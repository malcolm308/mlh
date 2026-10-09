import 'dart:convert';

import '../api_config.dart';
import '../models/models.dart';
import 'api_client.dart';

export 'api_client.dart' show ApiException;

/// Cliente HTTP de alto nivel para el backend FastAPI de TaxiRapid.
///
/// Todo el transporte lo hace [ApiClient]: timeout de 15 s, reintentos de
/// fallos de red con backoff, headers y descodificación JSON.
class ApiService {
  final String base;

  /// Token JWT para `Authorization: Bearer`. Vive en [ApiClient] y aquí solo
  /// se expone con el mismo nombre que tenía antes del refactor.
  String? get token => ApiClient.token;
  set token(String? value) => ApiClient.token = value;

  ApiService({String? base}) : base = base ?? ApiConfig.baseUrl;

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final url = '$base$path';
    switch (method) {
      case 'GET':
        return ApiClient.get(url);
      case 'POST':
        return ApiClient.post(url, body: body);
      case 'PUT':
        return ApiClient.put(url, body: body);
      case 'PATCH':
        return ApiClient.patch(url, body: body);
      default:
        throw ApiException('Método no soportado: $method');
    }
  }

  Future<Map<String, dynamic>> _map(String method, String path,
          {Map<String, dynamic>? body}) async =>
      (await _send(method, path, body: body)) as Map<String, dynamic>;

  Future<List<dynamic>> _list(String method, String path,
          {Map<String, dynamic>? body}) async =>
      (await _send(method, path, body: body)) as List<dynamic>;

  // ------------------- AUTH -------------------

  Future<String> login(String email, String password) async {
    final j = await _map('POST', '/login',
        body: {'email': email, 'password': password});
    final t = j['access_token']?.toString();
    if (t == null || t.isEmpty) throw ApiException('Respuesta de login inválida');
    token = t;
    return t;
  }

  /// Extrae el campo `id` del payload del JWT (sin verificar firma).
  String? jwtId(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return null;
    try {
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (payload is Map && payload['id'] != null) {
        return payload['id'].toString();
      }
    } catch (_) {}
    return null;
  }

  // ------------------- PERFIL -------------------

  Future<DriverProfile> getChofer(String id) async {
    final j = await _map('GET', '/chofer/$id');
    return DriverProfile.fromJson(j);
  }

  // ------------------- REGISTRO -------------------

  /// Registra un conductor nuevo con los datos que exige POST /chofer.
  Future<Map<String, dynamic>> registerChofer({
    required String nombre,
    required String apellidos,
    required String email,
    required String telefono,
    required String password,
    required String marca,
    required String model,
    required int year,
    required String chapa,
    required String color,
    required String servicio,
    required int maxPassengers,
    String typeVehicle = 'basico',
    double fondo = 1000,
    double rating = 5.0,
  }) async {
    return _map('POST', '/chofer', body: {
      'Nombre': nombre,
      'Apellidos': apellidos,
      'email': email,
      'numero_de_telefono': telefono,
      'Enable': true,
      'Fondo': fondo,
      'password': password,
      'raiting': rating,
      'type_vehicle': typeVehicle,
      'status': 'active',
      'documents_verified': true,
      'max_passengers': maxPassengers,
      'vehicle': {
        'Marca': marca,
        'model': model,
        'year': year,
        'chapa': chapa,
        'color': color,
        'servicio': servicio,
      },
    });
  }

  // ------------------- REGISTRO CON DOCUMENTOS -------------------

  /// Registra al chofer junto con sus 10 fotos obligatorias.
  ///
  /// Las fotos se envian como multipart/form-data con el prefijo `doc_`.
  /// [fotos] mapea el nombre del documento (rostro, carnet_frente, ...) a la
  /// ruta del archivo local.
  Future<Map<String, dynamic>> registerChoferConFotos({
    required String nombre,
    required String apellidos,
    required String email,
    required String telefono,
    required String password,
    required String marca,
    required String model,
    required int year,
    required String chapa,
    required String color,
    required String servicio,
    required int maxPassengers,
    required Map<String, String> fotos,
  }) async {
    final fields = <String, String>{
      'Nombre': nombre,
      'Apellidos': apellidos,
      'email': email,
      'numero_de_telefono': telefono,
      'password': password,
      'marca': marca,
      'model': model,
      'year': '$year',
      'chapa': chapa,
      'color': color,
      'servicio': servicio,
      'max_passengers': '$maxPassengers',
    };
    try {
      return (await ApiClient.multipart(
        '$base/documentos/registro',
        fields,
        files: fotos,
      )) as Map<String, dynamic>;
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('No se pudieron subir las fotos: $e');
    }
  }

  /// Estado de los 10 documentos de un chofer.
  Future<Map<String, dynamic>> getDocumentos(String driverId) async {
    return _map('GET', '/documentos/chofer/$driverId/estado');
  }

  // ------------------- ESTADO Y POSICIÓN -------------------

  Future<void> setDriverStatus(String driverId, String status) async {
    await ApiClient.post(ApiConfig.driverStatus(driverId),
        body: {'status': status});
  }

  Future<void> setDriverLocation(
      String driverId, double lat, double lng) async {
    await _map('POST', '/drivers/$driverId/location',
        body: {'lat': lat, 'lng': lng});
  }

  // ------------------- FONDO / TRANSFERENCIAS -------------------

  Future<Map<String, dynamic>> getDriverFondo(String driverId) async {
    return _map('GET', '/drivers/$driverId/fondo');
  }

  Future<Map<String, dynamic>> transferFondo({
    required String driverId,
    required String toDriverEmail,
    required double amount,
  }) async {
    return _map('POST', '/drivers/$driverId/transfer', body: {
      'to_driver_email': toDriverEmail,
      'amount': amount,
    });
  }

  // ------------------- OFERTAS / VIAJES -------------------

  Future<List<TripOffer>> getNearbyRequestedTrips(
    double lat,
    double lng, {
    double radiusKm = 5,
    int limit = 20,
    String? driverId,
  }) async {
    final id = driverId == null || driverId.isEmpty ? '' : '&driver_id=$driverId';
    final list = await _list(
      'GET',
      '/trips/requested-nearby?lat=$lat&lng=$lng&radius_km=$radiusKm&limit=$limit$id',
    );
    return list
        .whereType<Map<String, dynamic>>()
        .map(TripOffer.fromJson)
        .toList();
  }

  Future<Map<String, dynamic>> acceptTrip(
      String tripId, String driverId) async {
    return _map('POST', '/trips/$tripId/accept?driver_id=$driverId');
  }

  Future<Map<String, dynamic>> declineTrip(
      String tripId, String driverId) async {
    return _map('POST', '/trips/$tripId/decline?driver_id=$driverId');
  }

  /// Libera un viaje 'accepted' que quedo obsoleto al reabrir la app.
  ///
  /// Reutiliza el endpoint de cancelar SIN `driver_id` a proposito: asi el
  /// backend lo trata como una cancelacion ajena al chofer (la del pasajero),
  /// que no descuenta ninguna de las tres chances del dia. No existe un
  /// endpoint `release` aparte.
  Future<void> releaseTrip(String tripId) async {
    await _map('POST', '/trips/$tripId/cancel', body: const {});
  }

  Future<TripOffer> getTrip(String tripId) async {
    final j = await _map('GET', '/trips/$tripId');
    return TripOffer.fromJson(j);
  }

  Future<void> updateTripStatus(String tripId, String status) async {
    await _map('PATCH', '/trips/$tripId/status', body: {'status': status});
  }

  Future<void> setPickup(String tripId, double lat, double lng) async {
    await _map('PUT', '/trips/$tripId/pickup', body: {'lat': lat, 'lng': lng});
  }

  Future<List<RoutePoint>> getTripRoute(String tripId) async {
    final j = await _map('GET', '/trips/$tripId/route');
    final list = (j['points'] as List<dynamic>?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(RoutePoint.fromJson)
        .toList();
  }

  Future<CompletedTrip> completeTrip(
    String tripId, {
    required double dropoffLat,
    required double dropoffLng,
    double tip = 0,
  }) async {
    final j = await _map('PUT', '/trips/$tripId/complete', body: {
      'dropoff_lat': dropoffLat,
      'dropoff_lng': dropoffLng,
      'tip': tip,
    });
    return CompletedTrip.fromJson(j);
  }

  Future<List<TripOffer>> getTripsByDriver(String driverId,
      {int limit = 20}) async {
    final list = await _list('GET', '/trips/driver/$driverId?limit=$limit');
    return list.whereType<Map<String, dynamic>>().map(TripOffer.fromJson).toList();
  }

  // ------------------- ECONÓMICO -------------------

  Future<DriverEarnings> getEarnings(String driverId) async {
    final j = await _map('GET', '/drivers/$driverId/earnings');
    return DriverEarnings.fromJson(j);
  }

  /// Ganancias acumuladas hoy (hora local del dispositivo): el backend
  /// filtra por `requested_at` entre `from_date` y `to_date`.
  Future<DriverEarnings> getTodayEarnings(String driverId) async {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final today = '${now.year}-$month-$day';
    final j = await _map(
      'GET',
      '/drivers/$driverId/earnings?from_date=$today&to_date=$today',
    );
    return DriverEarnings.fromJson(j);
  }

  Future<Map<String, dynamic>> getDailyTripCount(String driverId) async {
    return _map('GET', '/drivers/$driverId/daily-trip-count');
  }

  Future<Map<String, dynamic>> applyDailyBonus(String driverId) async {
    return _map('POST', '/drivers/$driverId/bonus');
  }
}