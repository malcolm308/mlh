import 'dart:convert';

import '../api_config.dart';
import '../models/models.dart';
import 'api_client.dart';
import 'token_store.dart';

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
      case 'DELETE':
        return ApiClient.delete(url);
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

  /// Entra con el número de teléfono o con el correo. El backend distingue los
  /// dos por su forma: si hay dígitos y no hay arroba, lo trata como teléfono.
  /// El JWT que devuelve sigue llevando el correo, así que `jwtId` no cambia.
  Future<String> login(String telefono, String password) async {
    final j = await _map('POST', '/login',
        body: {'email': telefono, 'password': password});
    final t = j['access_token']?.toString();
    if (t == null || t.isEmpty) throw ApiException('Respuesta de login inválida');
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

  // ------------------- PERFIL -------------------

  Future<DriverProfile> getChofer(String id) async {
    final j = await _map('GET', '/chofer/$id');
    return DriverProfile.fromJson(j);
  }

  /// Elimina para siempre la cuenta del chofer autenticado.
  ///
  /// Borrar la cuenta es irreversible: el backend borra los vehiculos y sus
  /// fotos, anonimiza el perfil y deja el token inservible. La sesion local
  /// hay que limpiarla en cuanto responde.
  Future<void> deleteAccount() async {
    await _map('DELETE', '/driver/account');
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
    String? codigoReferido,
  }) async {
    final fields = <String, String>{
      'Nombre': nombre,
      'Apellidos': apellidos,
      'email': email,
      'numero_de_telefono': telefono,
      'codigo_referido': (codigoReferido ?? '').trim(),
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
      String driverId, double lat, double lng,
      {double? bearing, double? speed}) async {
    await _map('POST', '/drivers/$driverId/location',
        body: {
          'lat': lat,
          'lng': lng,
          'bearing': ?bearing,
          'speed': ?speed,
        });
  }

  // ------------------- BLOQUEOS Y PROMOCIONES -------------------

  /// Bloqueos del chofer (la misma coleccion que usa el pasajero): aqui
  /// miramos los que van a PASAJEROS con `passenger_id`, y `passenger_name`
  /// llega ya resuelto desde el backend.
  Future<List<Map<String, dynamic>>> getBloqueos() async {
    final list = await _list('GET', '/incidencias/bloqueos');
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Bloquea a un pasajero desde el panel del viaje aceptado/cancelado.
  Future<void> bloquearPasajero({
    required String passengerId,
    required String tripId,
    required String motivo,
  }) async {
    await _map('POST', '/incidencias/bloquear-pasajero', body: {
      'passenger_id': passengerId,
      'trip_id': tripId,
      'motivo': motivo,
    });
  }

  /// Quita un pasajero de la lista de bloqueados del chofer.
  Future<void> desbloquearPasajero(String passengerId) async {
    final id = Uri.encodeComponent(passengerId);
    await _send('DELETE', '/incidencias/bloqueos/$id');
  }

  /// Promociones y bonificaciones vigentes (el mismo estado que ve el panel).
  Future<Map<String, dynamic>> promocionVigente() async {
    return _map('GET', '/admin/promociones/vigente');
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

  // ------------------- MI GARAJE -------------------

  Future<List<DriverVehicle>> getMyVehicles() async {
    final list = await _list('GET', '/driver/vehicles');
    return list
        .whereType<Map<String, dynamic>>()
        .map(DriverVehicle.fromJson)
        .toList();
  }

  /// Alta del vehiculo. Va multipart porque el backend exige la licencia de
  /// conducir en la misma peticion (`license_front` / `license_back`).
  ///
  /// Las fotos del vehiculo se suben despues con [addVehicleFotos].
  Future<DriverVehicle> addVehicle({
    required String tipoVehiculo,
    required String marca,
    required String modelo,
    required String matricula,
    required Map<String, String> licencias,
  }) async {
    final j = await ApiClient.multipart(
      '$base/driver/vehicles',
      {
        'tipo_vehiculo': tipoVehiculo,
        'marca': marca,
        'modelo': modelo,
        'matricula': matricula,
      },
      files: licencias,
      prefijo: '',
    );
    return DriverVehicle.fromJson((j as Map).cast<String, dynamic>());
  }

  Future<void> selectVehicle(String vehicleId) async {
    await _map('PUT', '/driver/vehicles/$vehicleId/select');
  }

  /// Edita los datos de un vehiculo del chofer autenticado.
  ///
  /// Si estaba aprobado, el backend lo vuelve a revision y lo desactiva hasta
  /// la nueva aprobacion del administrador.
  Future<Map<String, dynamic>> updateVehicle(
    String vehicleId, {
    required String tipoVehiculo,
    required String marca,
    required String modelo,
    required String matricula,
  }) async {
    final j = await _map('PUT', '/driver/vehicles/$vehicleId', body: {
      'tipo_vehiculo': tipoVehiculo,
      'marca': marca,
      'modelo': modelo,
      'matricula': matricula,
    });
    return (j as Map).cast<String, dynamic>();
  }

  /// Elimina del garaje un vehiculo del chofer autenticado.
  Future<void> deleteVehicle(String vehicleId) async {
    await _send('DELETE', '/driver/vehicles/$vehicleId');
  }

  /// Sube fotos del vehiculo: ruta local → campo.
  ///
  /// Igual que el registro, va multipart (SIN el prefijo `doc_`: Mi Garaje
  /// espera los nombres pelados de campo) y el backend marca cada foto
  /// `pendiente` para que la revise el administrador.
  Future<Map<String, dynamic>> addVehicleFotos(
    String vehicleId,
    Map<String, String> archivos,
  ) async {
    final url = '${ApiConfig.baseUrl}/driver/vehicles/$vehicleId/fotos';
    final j = await ApiClient.multipart(url, const {}, files: archivos,
        prefijo: '');
    return (j as Map).cast<String, dynamic>();
  }

  /// Sube o reemplaza fotos del registro (rostro, carnet, ...).
  ///
  /// Va a `POST /documentos/chofer/{id}` con el prefijo `doc_` que espera el
  /// backend. Cada foto que se sube reemplaza a la anterior.
  Future<Map<String, dynamic>> updateDocumentos(
    String driverId,
    Map<String, String> archivos,
  ) async {
    final url = '${ApiConfig.baseUrl}/documentos/chofer/$driverId';
    final j = await ApiClient.multipart(url, const {}, files: archivos);
    return (j as Map).cast<String, dynamic>();
  }

  /// Actualiza los datos personales del chofer autenticado cambio por cambio.
  Future<void> updatePerfil(
    String driverId, {
    String? nombre,
    String? apellidos,
    String? telefono,
  }) async {
    final body = <String, dynamic>{
      'Nombre': ?nombre,
      'Apellidos': ?apellidos,
      'numero_de_telefono': ?telefono,
    };
    if (body.isEmpty) return;
    await _map('PATCH', '/chofer/$driverId/perfil', body: body);
  }

  // ------------------- OFERTAS / VIAJES -------------------
  Future<List<TripOffer>> getNearbyRequestedTrips(
    double lat,
    double lng, {
    double radiusKm = 5,
    int limit = 20,
    String? driverId,
    String? vehicleType,
  }) async {
    final id = driverId == null || driverId.isEmpty ? '' : '&driver_id=$driverId';
    // El tipo de vehiculo viaja al backend para que el sondeo devuelva solo
    // viajes del mismo tipo. Sin esto el chofer con moto veia ofertas de
    // viajes 'confort', que no puede atender.
    final tipo = vehicleType == null || vehicleType.trim().isEmpty
        ? ''
        : '&vehicle_type=${Uri.encodeQueryComponent(vehicleType.trim())}';
    final list = await _list(
      'GET',
      '/trips/requested-nearby?lat=$lat&lng=$lng&radius_km=$radiusKm&limit=$limit$id$tipo',
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

  /// Total historico de ganancias. El backend decide el corte de los dias en
  /// hora de Cuba; el reloj del telefono no interviene.
  Future<DriverEarnings> getEarnings(String driverId) async {
    final j = await _map('GET', '/drivers/$driverId/earnings');
    return DriverEarnings.fromJson(j);
  }

  /// Ganancias de hoy. No se manda la fecha del dispositivo: si el movil tiene
  /// la hora mal (Cuba no retraso el reloj en 2026), mandaria otro dia.
  Future<DriverEarnings> getTodayEarnings(String driverId) async {
    final j = await _map('GET', '/drivers/$driverId/earnings?scope=today');
    return DriverEarnings.fromJson(j);
  }

  /// Ultimos [days] dias con desglose diario, para separar cada jornada.
  Future<DriverEarnings> getEarningsLastDays(String driverId, {int days = 7}) async {
    final j = await _map('GET', '/drivers/$driverId/earnings?days=$days');
    return DriverEarnings.fromJson(j);
  }

  // ------------------- RELOJ DEL SERVIDOR -------------------

  /// Diferencia entre el reloj del servidor y el del telefono.
  ///
  /// Se aplica al calcular la antiguedad de un viaje aceptado. Con un movil
  /// una hora adelantado, un viaje recien aceptado parecia de 60 minutos y la
  /// app lo descartaba como obsoleto.
  Duration _desfaseReloj = Duration.zero;

  DateTime get ahoraUtc => DateTime.now().toUtc().add(_desfaseReloj);

  Future<void> sincronizarReloj() async {
    try {
      final j = await _map('GET', '/health');
      final s = j['server_time'];
      if (s is! String) return;
      final servidor = DateTime.tryParse(s)?.toUtc();
      if (servidor == null) return;
      _desfaseReloj = servidor.difference(DateTime.now().toUtc());
    } catch (_) {
      // Sin red se conserva el desfase anterior (o cero).
    }
  }

  Future<Map<String, dynamic>> getDailyTripCount(String driverId) async {
    return _map('GET', '/drivers/$driverId/daily-trip-count');
  }

  Future<Map<String, dynamic>> applyDailyBonus(String driverId) async {
    return _map('POST', '/drivers/$driverId/bonus');
  }

  /// Minutes de espera que regala la plataforma.
  ///
  /// Lo lee el chofer para poder decirle al pasajero, mientras espera, cuanto
  /// le queda gratis. No hace falta administrador: es el mismo dato que la
  /// tarifa base, publico. Si la peticion falla se devuelve el valor por
  /// defecto y el chofer sigue trabajando igual, porque la espera se cobra en el
  /// backend de todos modos y aqui solo se esta pintando informacion.
  Future<int> fetchCortesiaMinutos({int porDefecto = 4}) async {
    try {
      final datos = await _map('GET', '/admin/promociones/tarifas-espera');
      final valor = datos['tiempo_espera_cortesia_minutos'];
      if (valor is num) return valor.round();
    } catch (_) {
      // Sin internet o backend caido: se sigue con el valor por defecto.
    }
    return porDefecto;
  }
}