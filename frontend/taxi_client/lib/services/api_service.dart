import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/models.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// Cliente HTTP para el backend FastAPI de TaxiRapid.
class ApiService {
  final String base;
  String? token;

  ApiService({String? base}) : base = base ?? AppConfig.apiBase;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null && token!.isNotEmpty)
          'Authorization': 'Bearer $token',
      };

  String _error(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      if (j is Map && j['detail'] != null) return j['detail'].toString();
      if (j is Map && j['message'] != null) return j['message'].toString();
    } catch (_) {}
    return 'Error ${r.statusCode}';
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$base$path');
    final encoded = body == null ? null : jsonEncode(body);
    final http.Response r;
    try {
      switch (method) {
        case 'GET':
          r = await http.get(uri, headers: _headers);
        case 'POST':
          r = await http.post(uri, headers: _headers, body: encoded);
        case 'PUT':
          r = await http.put(uri, headers: _headers, body: encoded);
        case 'PATCH':
          r = await http.patch(uri, headers: _headers, body: encoded);
        default:
          throw ApiException('Método no soportado: $method');
      }
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('No se pudo conectar al backend en $base: $e');
    }

    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (r.body.trim().isEmpty) return const {};
      return jsonDecode(utf8.decode(r.bodyBytes));
    }
    throw ApiException('${_error(r)} (HTTP ${r.statusCode})');
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
    return _map('POST', '/trips/$tripId/cancel');
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