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

  Future<ClientProfile> getCliente(String id) async {
    final j = await _map('GET', '/cliente/$id');
    return ClientProfile.fromJson(j);
  }

  // ------------------- REGISTRO -------------------

  Future<Map<String, dynamic>> registerCliente({
    required String nombre,
    required String apellidos,
    required String email,
    required String telefono,
    required String password,
  }) async {
    return _map('POST', '/cliente', body: {
      'Nombre': nombre,
      'Apellidos': apellidos,
      'email': email,
      'numero_de_telefono': telefono,
      'Enable': true,
      'Fondo': 0,
      'password': password,
    });
  }

  // ------------------- VIAJES -------------------

  Future<Map<String, dynamic>> createTrip({
    required String clientId,
    required double requestLat,
    required double requestLng,
    required double dropoffLat,
    required double dropoffLng,
    String vehicleType = 'basico',
    int numPasajes = 1,
    bool equipaje = false,
    bool mascota = false,
    String? requestAddress,
    String? dropoffAddress,
  }) async {
    return _map('POST', '/trips', body: {
      'client_id': clientId,
      'request_lat': requestLat,
      'request_lng': requestLng,
      'dropoff_lat': dropoffLat,
      'dropoff_lng': dropoffLng,
      'vehicle_type': vehicleType,
      'num_pasajes': numPasajes,
      'equipaje': equipaje,
      'mascota': mascota,
      'request_address': ?requestAddress,
      'dropoff_address': ?dropoffAddress,
    });
  }

  Future<Map<String, dynamic>> estimateTrip({
    required double requestLat,
    required double requestLng,
    required double dropoffLat,
    required double dropoffLng,
    String vehicleType = 'basico',
  }) async {
    return _map('POST', '/trips/estimate', body: {
      'request_lat': requestLat,
      'request_lng': requestLng,
      'dropoff_lat': dropoffLat,
      'dropoff_lng': dropoffLng,
      'vehicle_type': vehicleType,
    });
  }

  Future<ClientTrip> getTrip(String tripId) async {
    final j = await _map('GET', '/trips/$tripId');
    return ClientTrip.fromJson(j);
  }

  Future<List<RoutePoint>> getTripRoute(String tripId) async {
    final j = await _map('GET', '/trips/$tripId/route');
    final list = (j['points'] as List<dynamic>?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(RoutePoint.fromJson)
        .toList();
  }

  Future<Map<String, dynamic>> cancelTrip(String tripId) async {
    return ApiClient.post(ApiConfig.cancelTrip(tripId)) as Map<String, dynamic>;
  }

  Future<List<ClientTrip>> getTripsByClient(String clientId,
      {int limit = 30}) async {
    final list = await _list('GET', '/trips/client/$clientId?limit=$limit');
    return list.whereType<Map<String, dynamic>>().map(ClientTrip.fromJson).toList();
  }

  // ------------------- PUNTOS DE INTERÉS -------------------

  Future<List<Poi>> getPois({String? categoria}) async {
    final filtro = (categoria == null || categoria.isEmpty)
        ? ''
        : '?categoria=${Uri.encodeQueryComponent(categoria)}';
    final list = await _list('GET', '/pois$filtro');
    return list.whereType<Map<String, dynamic>>().map(Poi.fromJson).toList();
  }
}