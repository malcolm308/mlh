import 'dart:convert';
import 'dart:io';

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
    final req = http.MultipartRequest('POST', Uri.parse('$base/documentos/registro'))
      ..fields['Nombre'] = nombre
      ..fields['Apellidos'] = apellidos
      ..fields['email'] = email
      ..fields['numero_de_telefono'] = telefono
      ..fields['password'] = password
      ..fields['marca'] = marca
      ..fields['model'] = model
      ..fields['year'] = '$year'
      ..fields['chapa'] = chapa
      ..fields['color'] = color
      ..fields['servicio'] = servicio
      ..fields['max_passengers'] = '$maxPassengers';

    fotos.forEach((campo, ruta) {
      req.files.add(http.MultipartFile.fromBytes(
        'doc_$campo',
        File(ruta).readAsBytesSync(),
        filename: File(ruta).uri.pathSegments.last,
      ));
    });

    try {
      final streamed = await req.send();
      final r = await http.Response.fromStream(streamed);
      if (r.statusCode >= 200 && r.statusCode < 300) {
        final cuerpo = utf8.decode(r.bodyBytes);
        return cuerpo.trim().isEmpty
            ? <String, dynamic>{}
            : jsonDecode(cuerpo) as Map<String, dynamic>;
      }
      throw ApiException('${_error(r)} (HTTP ${r.statusCode})');
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
    await _map('POST', '/drivers/$driverId/status',
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

  // ------------------- PUNTOS DE INTERÉS -------------------

  Future<List<Poi>> getPois({String? categoria}) async {
    final filtro = (categoria == null || categoria.isEmpty)
        ? ''
        : '?categoria=${Uri.encodeQueryComponent(categoria)}';
    final list = await _list('GET', '/pois$filtro');
    return list.whereType<Map<String, dynamic>>().map(Poi.fromJson).toList();
  }
}