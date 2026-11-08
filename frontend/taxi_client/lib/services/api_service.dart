import 'dart:convert';

import 'package:latlong2/latlong.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../models/tariff.dart';
import 'api_client.dart';
import 'token_store.dart';

export 'api_client.dart' show ApiException;

/// Cliente HTTP de alto nivel para el backend FastAPI de TaxiRapid.
class ApiService {
  final String base;

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
      case 'DELETE':
        return ApiClient.delete(url);
      default:
        throw ApiException('Metodo no soportado: $method');
    }
  }

  Future<Map<String, dynamic>> _map(String method, String path,
          {Map<String, dynamic>? body}) async =>
      (await _send(method, path, body: body)) as Map<String, dynamic>;

  Future<List<dynamic>> _list(String method, String path,
          {Map<String, dynamic>? body}) async =>
      (await _send(method, path, body: body)) as List<dynamic>;

  // ---------------- AUTH ----------------

  Future<String> login(String email, String password) async {
    final j = await _map('POST', '/login',
        body: {'email': email, 'password': password});
    final t = j['access_token']?.toString();
    if (t == null || t.isEmpty) throw ApiException('Respuesta de login invalida');
    final refresh = j['refresh_token']?.toString();
    token = t;
    if (refresh != null && refresh.isNotEmpty) {
      await TokenStore.instance
          .guardarSesion(accessToken: t, refreshToken: refresh);
    } else {
      // Backend viejo o instalacion a medias: al menos guarda el access.
      await TokenStore.instance.guardarAccess(t);
    }
    ApiClient.marcarSesionActiva();
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

  /// Pide al backend que envie un codigo de recuperacion al correo.
  Future<Map<String, dynamic>> forgotPassword(String email) async {
    return _map('POST', '/auth/forgot-password',
        body: {'email': email.trim()});
  }

  /// Cambia la contrasena usando el codigo recibido por correo.
  Future<Map<String, dynamic>> resetPassword({
    required String email,
    required String codigo,
    required String nuevaPassword,
  }) async {
    return _map('POST', '/auth/reset-password', body: {
      'email': email.trim(),
      'codigo': codigo.trim(),
      'nueva_password': nuevaPassword,
    });
  }

  // ---------------- PERFIL ----------------

  Future<ClientProfile> getCliente(String id) async {
    final j = await _map('GET', '/cliente/$id');
    return ClientProfile.fromJson(j);
  }

  Future<Map<String, dynamic>> registerCliente({
    required String nombre,
    required String apellidos,
    required String email,
    required String telefono,
    String? codigoReferido,
    required String password,
  }) async {
    return _map('POST', '/cliente', body: {
      'Nombre': nombre,
      'Apellidos': apellidos,
      'email': email,
      'numero_de_telefono': telefono,
      'codigo_referido': (codigoReferido ?? '').trim(),
      'Enable': true,
      'Fondo': 0,
      'password': password,
    });
  }

  // ---------------- TARIFAS ----------------

  Future<List<Tariff>> getTariffs() async {
    final j = await _map('GET', ApiConfig.tariffs().path);
    final list = (j['tariffs'] as List<dynamic>?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(Tariff.fromJson)
        .toList();
  }

  Future<Tariff> getTariff(String vehicleType) async {
    final j = await _map('GET', ApiConfig.tariffByType(vehicleType).path);
    return Tariff.fromJson(j);
  }

  Future<List<PricingRule>> getPricingRules() async {
    final j = await _map('GET', ApiConfig.pricingRules().path);
    final list = (j['rules'] as List<dynamic>?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(PricingRule.fromJson)
        .toList();
  }

  // ---------------- VIAJES ----------------

  Future<Map<String, dynamic>> createTrip({
    required String clientId,
    required double requestLat,
    required double requestLng,
    required double dropoffLat,
    required double dropoffLng,
    required String vehicleType,
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
      'request_address': requestAddress,
      'dropoff_address': dropoffAddress,
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

  /// Ultimo trazado compartido por el chofer para este viaje.
  ///
  /// Respaldo HTTP del evento WS `trip_route_updated`: si al pasajero se le
  /// cayo el socket en el momento del recalculo, aqui recupera la ruta
  /// vigente. Lista vacia si el chofer no ha compartido nada.
  Future<List<LatLng>> getDriverRoute(String tripId) async {
    final j = await _map('GET', '/trips/$tripId/driver-route');
    if (j['found'] != true) return const [];
    final list = (j['points'] as List<dynamic>?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((p) => LatLng(
              (p['lat'] as num?)?.toDouble() ?? 0,
              (p['lng'] as num?)?.toDouble() ?? 0,
            ))
        .toList();
  }

  Future<Map<String, dynamic>> cancelTrip(String tripId) async {
    try {
      final res = await ApiClient.post(ApiConfig.cancelTrip(tripId));
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return <String, dynamic>{'ok': true};
    } on Exception catch (_) {
      rethrow;
    }
  }

  Future<List<ClientTrip>> getTripsByClient(String clientId,
      {int limit = 30}) async {
    final list = await _list('GET', '/trips/client/$clientId?limit=$limit');
    return list
        .whereType<Map<String, dynamic>>()
        .map(ClientTrip.fromJson)
        .toList();
  }

  Future<List<Map<String, dynamic>>> getTripHistory(String clientId,
      {int limit = 50}) async {
    final list = await _list('GET', '/trips/history/$clientId?limit=$limit');
    return list.whereType<Map<String, dynamic>>().toList();
  }

  // ---------------- ESTIMACION ----------------

  Future<Map<String, dynamic>> estimateTrip({
    required double requestLat,
    required double requestLng,
    required double dropoffLat,
    required double dropoffLng,
    required String vehicleType,
  }) async {
    return _map('POST', '/trips/estimate', body: {
      'request_lat': requestLat,
      'request_lng': requestLng,
      'dropoff_lat': dropoffLat,
      'dropoff_lng': dropoffLng,
      'vehicle_type': vehicleType,
    });
  }

  Future<Map<String, dynamic>> estimateAll({
    required double requestLat,
    required double requestLng,
    required double dropoffLat,
    required double dropoffLng,
  }) async {
    return _map('POST', '/trips/estimate-all', body: {
      'request_lat': requestLat,
      'request_lng': requestLng,
      'dropoff_lat': dropoffLat,
      'dropoff_lng': dropoffLng,
    });
  }

  // ---------------- FAVORITOS ----------------

  Future<List<Map<String, dynamic>>> getFavorites() async {
    final list = await _list('GET', '/favoritos/');
    return list.whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>> createFavorite({
    required String alias,
    required String direccion,
    double? lat,
    double? lng,
    String? userId,
  }) async {
    return _map('POST', '/favoritos/', body: {
      'alias': alias,
      'direccion': direccion,
      'lat': ?lat,
      'lng': ?lng,
      'user_id': ?userId,
    });
  }

  Future<void> deleteFavorite(String favoriteId) async {
    await _map('DELETE', '/favoritos/$favoriteId');
  }

  // ---------------- INCIDENCIAS ----------------

  Future<void> blockDriver({
    required String driverId,
    required String tripId,
    required String motivo,
  }) async {
    await _map('POST', '/incidencias/bloquear-chofer', body: {
      'driver_id': driverId,
      'trip_id': tripId,
      'motivo': motivo,
    });
  }

  /// Choferes que ESTE pasajero bloqueo (para el menu lateral).
  Future<List<Map<String, dynamic>>> getBloqueos() async {
    final list = await _list('GET', '/incidencias/bloqueos');
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Resumen STATISTICO de viaje del pasajero para su Perfil.
  Future<Map<String, dynamic>> resumenViajes(String clientId) async {
    return _map('GET', '/trips/client/$clientId/resumen');
  }

  /// Promocion vigente PUBLICA (singles del panel de administracion).
  Future<Map<String, dynamic>> promocionVigente() async {
    return _map('GET', '/admin/promociones/vigente');
  }

  /// Quita un chofer de la lista de bloqueados del pasajero.
  ///
  /// `driverId` es el `driver_id` que devolvio `getBloqueos`: nunca se toca
  /// ninguna coleccion ajena, el backend matchea USER + chofer.
  Future<void> desbloquearChofer(String driverId) async {
    final id = Uri.encodeComponent(driverId);
    await _send('DELETE', '/incidencias/bloqueos/$id');
  }

  // ---------------- SOPORTE ----------------

  Future<Map<String, dynamic>> createSupportTicket({
    required String tipo,
    required String mensaje,
  }) async {
    return _map('POST', '/soporte/ticket', body: {
      'tipo': tipo,
      'mensaje': mensaje,
    });
  }

  // ---------------- CUENTA ----------------

  Future<void> deleteAccount() async {
    await _send('DELETE', '/users/me');
  }

  // ---------------- REFERIDOS ----------------

  Future<Map<String, dynamic>> getMyReferralCode() async {
    return _map('GET', '/referidos/mi-codigo');
  }

  Future<Map<String, dynamic>> getMyDiscounts() async {
    return _map('GET', '/referidos/mis-descuentos');
  }

  Future<List<Map<String, dynamic>>> getMyReferrals() async {
    final list = await _list('GET', '/referidos/mis-referidos');
    return list.whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>> validateReferralCode(String code) async {
    return _map('POST', '/referidos/validar-codigo', body: {'codigo': code});
  }

  Future<Map<String, dynamic>> redeemReferralCode(String code) async {
    return _map('POST', '/referidos/canjear-codigo', body: {'codigo': code});
  }

  Future<Map<String, dynamic>> applyTripDiscount(String tripId) async {
    return _map('POST', '/referidos/aplicar-descuento', body: {'trip_id': tripId});
  }

  // ---------------- CORTESIA ----------------

  Future<int?> fetchCortesiaMinutos({int porDefecto = 4}) async {
    try {
      final datos = await _map('GET', '/admin/promociones/tarifas-espera');
      final valor = datos['tiempo_espera_cortesia_minutos'];
      if (valor is num) return valor.round();
    } catch (_) {}
    return null;
  }
}
