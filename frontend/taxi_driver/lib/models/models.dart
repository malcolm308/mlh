import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Convierte un punto WKT "POINT(lng lat)" que devuelve PostGIS a LatLng.
LatLng? parseWktPoint(String? wkt) {
  if (wkt == null) return null;
  final m = RegExp(r'POINT\(\s*([-\d.]+)\s+([-\d.]+)\s*\)').firstMatch(wkt);
  if (m == null) return null;
  final lng = double.tryParse(m.group(1) ?? '');
  final lat = double.tryParse(m.group(2) ?? '');
  if (lat == null || lng == null) return null;
  return LatLng(lat, lng);
}

String? _str(Map<String, dynamic> j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v != null && v.toString().isNotEmpty) return v.toString();
  }
  return null;
}

/// Perfil del chofer tal como lo devuelve GET /chofer/{id}.
class DriverProfile {
  final String id;
  final String nombre;
  final String apellidos;
  final String email;
  final String telefono;
  final double fondo;
  final double raiting;
  final String? vehicleType;
  final String vehicleModel;
  final String? licenseNumber;
  final int maxPassengers;
  final bool documentsVerified;

  DriverProfile({
    required this.id,
    required this.nombre,
    required this.apellidos,
    required this.email,
    required this.telefono,
    required this.fondo,
    required this.raiting,
    this.vehicleType,
    this.vehicleModel = '',
    this.licenseNumber,
    this.maxPassengers = 4,
    this.documentsVerified = true,
  });

  factory DriverProfile.fromJson(Map<String, dynamic> j) {
    final nombre =
        _str(j, ['Nombre', 'nombre', 'name']) ?? _nested(j, 'profile', 'name') ?? '';
    final apellidos =
        _str(j, ['Apellidos', 'apellidos']) ?? '';
    final vehicle = j['vehicle'];
    final vtype = vehicle is Map
        ? (vehicle['type'] ?? j['vehicle_type'] ?? j['type_vehicle'])
        : (j['vehicle_type'] ?? j['type_vehicle']);
    return DriverProfile(
      id: (j['_id'] ?? j['id'] ?? '').toString(),
      nombre: nombre,
      apellidos: apellidos,
      email: _str(j, ['email']) ?? '',
      telefono: _str(j, ['numero_de_telefono', 'phone']) ?? '',
      fondo: (j['Fondo'] ?? j['fondo'] ?? 0).toDouble(),
      raiting: (j['raiting'] ?? j['rating'] ?? j['Rating'] ?? 5.0).toDouble(),
      vehicleType: vtype?.toString(),
      vehicleModel: _vehicleModelOf(j),
      licenseNumber: _str(j, ['license_number', 'licenseNumber']),
      maxPassengers: (j['max_passengers'] ?? 4).toInt(),
      documentsVerified: (j['documents_verified'] ?? true) == true,
    );
  }

  String get fullName => '$nombre $apellidos'.trim();
}

/// Extrae "Marca model" del dict `vehicle` (ej. "Lada 2105").
String _vehicleModelOf(Map<String, dynamic> j) {
  final v = j['vehicle'];
  if (v is Map) {
    final marca = v['Marca']?.toString() ?? '';
    final model = v['model']?.toString() ?? '';
    final s = '$marca $model'.trim();
    if (s.isNotEmpty) return s;
  }
  return _str(j, ['vehicle_model', 'vehicleModel']) ?? '';
}

String? _nested(Map<String, dynamic> j, String key, String sub) {
  final v = j[key];
  if (v is Map) return v[sub]?.toString();
  return null;
}

/// Viaje sin asignar (oferta) o viaje activo.
class TripOffer {
  final String tripId;
  final String? clientId;
  final LatLng? pickup;
  final LatLng? dropoff;
  final double? precioEstimado;
  final String vehicleType;
  final int numPasajes;
  final bool equipaje;
  final bool mascota;
  final double? distanciaChoferKm;
  final String? clientName;
  final String? clientPhone;
final String status;
  final String? requestedAt;
  final String? requestAddress;
  final String? dropoffAddress;
  final double? totalFare;
  final double? distanceKm;
  final String currency;
  final int? offerExpiresInSecs;

  /// Chofer adjudicado al viaje, si lo hay.
  ///
  /// Lo devuelve el backend en `driver_id` de `getTrip`. Se usa para saber si
  /// un viaje que desaparece del sondeo lo tomó otro chofer o lo ganó este:
  /// si el `driver_id` es el nuestro, no es un viaje perdido.
  final String? tripDriverId;

  TripOffer({
    required this.tripId,
    this.clientId,
    this.pickup,
    this.dropoff,
    this.precioEstimado,
    this.vehicleType = 'basico',
    this.numPasajes = 1,
    this.equipaje = false,
    this.mascota = false,
    this.distanciaChoferKm,
    this.clientName,
    this.clientPhone,
    this.status = 'requested',
    this.requestedAt,
    this.requestAddress,
    this.dropoffAddress,
    this.totalFare,
    this.distanceKm,
this.currency = 'CUP',
    this.offerExpiresInSecs,
    this.tripDriverId,
  });

  factory TripOffer.fromJson(Map<String, dynamic> j) => TripOffer(
        tripId: (j['trip_id'] ?? '').toString(),
        clientId: j['client_id']?.toString(),
        pickup: parseWktPoint(j['request_location']?.toString() ??
            j['pickup_location']?.toString()),
        dropoff: parseWktPoint(j['dropoff_location']?.toString()),
        precioEstimado: (j['precio_estimado'] ?? j['precioEstimado'])?.toDouble(),
        vehicleType: (j['vehicle_type'] ?? 'basico').toString(),
        numPasajes: (j['num_pasajes'] ?? 1).toInt(),
        equipaje: (j['equipaje'] ?? false) == true,
        mascota: (j['mascota'] ?? false) == true,
        distanciaChoferKm:
            (j['distance_from_driver_km'] ?? j['distance_from_driver_km'])?.toDouble(),
        clientName: j['client_name']?.toString(),
        clientPhone: j['client_phone']?.toString(),
        status: (j['status'] ?? 'requested').toString(),
        requestedAt: j['requested_at']?.toString(),
        requestAddress: j['request_address']?.toString(),
        dropoffAddress: j['dropoff_address']?.toString(),
        totalFare: (j['total_fare'] ?? j['total_fare'])?.toDouble(),
        distanceKm: (j['distance_km'] ?? j['distance_km'])?.toDouble(),
currency: (j['currency'] ?? 'CUP').toString(),
        offerExpiresInSecs: (j['offer_expires_in_secs'])?.toInt(),
        tripDriverId: j['driver_id']?.toString(),
      );
}

/// Resultado de completar un viaje.
class CompletedTrip {
  final String tripId;
  final double distanceKm;
  final int durationSecs;
  final double baseFare;
  final double distanceFare;
  final double timeFare;
  final double tip;
  final double totalFare;
  final double commission;

  /// Tasa de comision aplicada: 0.15 normal, 0.10 en el 3er viaje del dia.
  final double commissionRate;

  /// Etiqueta lista para pintar, por ejemplo "15%" o "10%".
  final String commissionLabel;

  /// `true` cuando este viaje uso el descuento del 3er viaje del dia.
  final bool commissionDiscount;

  final String currency;
  final String? appliedRule;

  CompletedTrip({
    required this.tripId,
    required this.distanceKm,
    required this.durationSecs,
    required this.baseFare,
    required this.distanceFare,
    required this.timeFare,
    required this.tip,
    required this.totalFare,
    required this.commission,
    required this.currency,
    this.commissionRate = 0.15,
    this.commissionLabel = '15%',
    this.commissionDiscount = false,
    this.appliedRule,
  });

  factory CompletedTrip.fromJson(Map<String, dynamic> j) => CompletedTrip(
        tripId: (j['trip_id'] ?? '').toString(),
        distanceKm: (j['distance_km'] ?? 0).toDouble(),
        durationSecs: (j['duration_secs'] ?? 0).toInt(),
        baseFare: (j['base_fare'] ?? 0).toDouble(),
        distanceFare: (j['distance_fare'] ?? 0).toDouble(),
        timeFare: (j['time_fare'] ?? 0).toDouble(),
        tip: (j['tip'] ?? 0).toDouble(),
        totalFare: (j['total_fare'] ?? 0).toDouble(),
        commission: (j['commission'] ?? 0).toDouble(),
        commissionRate: (j['commission_rate'] ?? 0.15).toDouble(),
        commissionLabel: (j['commission_label'] ?? '15%').toString(),
        commissionDiscount: (j['commission_discount'] ?? false) == true,
        currency: (j['currency'] ?? 'CUP').toString(),
        appliedRule: j['applied_rule']?.toString(),
      );
}

/// Punto de la ruta trazada por Traccar: /trips/{id}/route.
class RoutePoint {
  final double lat;
  final double lng;
  final String? time;

  RoutePoint({required this.lat, required this.lng, this.time});

  factory RoutePoint.fromJson(Map<String, dynamic> j) => RoutePoint(
        lat: (j['lat'] ?? 0).toDouble(),
        lng: (j['lng'] ?? 0).toDouble(),
        time: j['time']?.toString(),
      );

  LatLng get point => LatLng(lat, lng);
}

/// Ganancias del conductor: /drivers/{id}/earnings.
class DriverEarnings {
  final int totalTrips;
  final double totalEarnings;
  final double avgFare;
  final double totalDistanceKm;
  final double totalDurationSecs;

  DriverEarnings({
    required this.totalTrips,
    required this.totalEarnings,
    required this.avgFare,
    required this.totalDistanceKm,
    required this.totalDurationSecs,
  });

  factory DriverEarnings.fromJson(Map<String, dynamic> j) => DriverEarnings(
        totalTrips: (j['total_trips'] ?? 0).toInt(),
        totalEarnings: (j['total_earnings'] ?? 0).toDouble(),
        avgFare: (j['avg_fare'] ?? 0).toDouble(),
        totalDistanceKm: (j['total_distance_km'] ?? 0).toDouble(),
totalDurationSecs: (j['total_duration_secs'] ?? 0).toDouble(),
      );
}
