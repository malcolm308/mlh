import 'package:latlong2/latlong.dart';

/// Perfil del cliente que entra en la app de pasajeros.
class ClientProfile {
  final String id;
  final String fullName;
  final String email;
  final String? telefono;

  /// Codigo con el que este pasajero invita a otros. El backend lo devuelve en
  /// el perfil y crea uno si la cuenta es anterior al sistema de referidos.
  final String? codigoReferido;

  const ClientProfile({
    required this.id,
    required this.fullName,
    required this.email,
    this.telefono,
    this.codigoReferido,
  });

  factory ClientProfile.fromJson(Map<String, dynamic> j) => ClientProfile(
        id: j['_id']?.toString() ?? '',
        fullName: '${j['Nombre'] ?? ''} ${j['Apellidos'] ?? ''}'.trim(),
        email: j['email']?.toString() ?? '',
        telefono: j['numero_de_telefono']?.toString(),
        codigoReferido: (j['codigo_referido'] ?? '') is String &&
                (j['codigo_referido'] as String).trim().isNotEmpty
            ? (j['codigo_referido'] as String).trim()
            : null,
      );
}

/// Viaje visto desde la app del cliente.
class ClientTrip {
  final String tripId;
  final String status;
  final String vehicleType;
  final String currency;
  final String? requestedAt;
  final String? requestAddress;
  final String? dropoffAddress;
  final LatLng? requestLocation;
  final LatLng? pickupLocation;
  final LatLng? dropoffLocation;
  final double? distanciaKm;
  final double? precioEstimado;
  final double? baseFare;
  final double? distanceFare;
  final double? timeFare;
  final double? totalFare;
  final double? commission;
  final String? driverId;

  /// Nombre legible del chofer (Mongo), para el recibo y el panel.
  final String? driverName;

  /// Telefono del chofer: botones Llamar / WhatsApp del pasajero.
  final String? driverPhone;

  /// URL (relativa) de la foto de perfil del chofer. El backend solo la manda
  /// cuando la foto de rostro del registro existe de verdad.
  final String? driverProfilePictureUrl;

  /// Marca + modelo del vehiculo del chofer, para la tarjeta del pasajero.
  final String? driverVehicleModel;

  /// Matricula del vehiculo del chofer.
  final String? driverVehiclePlate;

  /// `requested_at` ya formateado en hora de Cuba por el backend, listo para
  /// pintar (el reloj del telefono no interviene).
  final String? requestedAtLocal;

  /// Rumbo del vehiculo (0 = norte, sentido horario) tal como lo reporto el
  /// chofer con su GPS. `null` = sin dato (chofer parado o sin viaje).
  final double? driverBearing;

  /// Ultima posicion conocida del chofer, cacheada por el backend. Es el
  /// respaldo del WebSocket para que la camara 3D no se congele si el push
  /// falla (el sondeo de 3 s sigue actualizando).
  final double? driverLat;
  final double? driverLng;

  /// Velocidad del chofer en km/h. Decide el zoom dinamico de la camara 3D.
  final double? driverSpeed;

  const ClientTrip({
    required this.tripId,
    required this.status,
    required this.vehicleType,
    required this.currency,
    this.requestedAt,
    this.requestAddress,
    this.dropoffAddress,
    this.requestLocation,
    this.pickupLocation,
    this.dropoffLocation,
    this.distanciaKm,
    this.precioEstimado,
    this.baseFare,
    this.distanceFare,
    this.timeFare,
    this.totalFare,
    this.commission,
    this.driverId,
    this.driverName,
    this.driverPhone,
    this.driverProfilePictureUrl,
    this.driverVehicleModel,
    this.driverVehiclePlate,
    this.requestedAtLocal,
    this.driverBearing,
    this.driverLat,
    this.driverLng,
    this.driverSpeed,
  });

  factory ClientTrip.fromJson(Map<String, dynamic> j) => ClientTrip(
        tripId: j['trip_id']?.toString() ?? '',
        status: j['status']?.toString() ?? '',
        vehicleType: j['vehicle_type']?.toString() ?? '',
        currency: j['currency']?.toString() ?? 'CUP',
        requestedAt: j['requested_at']?.toString(),
        requestAddress: j['request_address']?.toString(),
        dropoffAddress: j['dropoff_address']?.toString(),
        requestLocation: _parsePoint(j['request_location']),
        pickupLocation: _parsePoint(j['pickup_location']),
        dropoffLocation: _parsePoint(j['dropoff_location']),
        distanciaKm: (j['distance_km'] as num?)?.toDouble(),
        precioEstimado: (j['precio_estimado'] as num?)?.toDouble(),
        baseFare: (j['base_fare'] as num?)?.toDouble(),
        distanceFare: (j['distance_fare'] as num?)?.toDouble(),
        timeFare: (j['time_fare'] as num?)?.toDouble(),
        totalFare: (j['total_fare'] as num?)?.toDouble(),
        commission: (j['commission'] as num?)?.toDouble(),
        driverId: j['driver_id']?.toString(),
        driverName: j['driver_name']?.toString(),
        driverPhone: j['driver_phone']?.toString(),
        driverProfilePictureUrl: j['driver_profile_picture_url']?.toString(),
        driverVehicleModel: j['driver_vehicle_model']?.toString(),
        driverVehiclePlate: j['driver_vehicle_plate']?.toString(),
        requestedAtLocal: j['requested_at_local']?.toString(),
        driverBearing: (j['driver_bearing'] as num?)?.toDouble(),
        driverLat: (j['driver_lat'] as num?)?.toDouble(),
        driverLng: (j['driver_lng'] as num?)?.toDouble(),
        driverSpeed: (j['driver_speed'] as num?)?.toDouble(),
      );

  /// El backend entrega las coordenadas como "POINT(lng lat)".
  static LatLng? _parsePoint(dynamic raw) {
    if (raw == null) return null;
    final s = raw.toString();
    final m = RegExp(r'POINT\(\s*([-.0-9]+)\s+([-.0-9]+)\s*\)').firstMatch(s);
    if (m != null) {
      return LatLng(double.parse(m.group(2)!), double.parse(m.group(1)!));
    }
    final parts = s.split(',');
    if (parts.length == 2) {
      final lat = double.tryParse(parts[0].trim());
      final lng = double.tryParse(parts[1].trim());
      if (lat != null && lng != null) return LatLng(lat, lng);
    }
    return null;
  }
}

/// Punto de una ruta devuelta por el backend (OSRM).
class RoutePoint {
  final double lat;
  final double lng;
  final String? time;

  const RoutePoint({required this.lat, required this.lng, this.time});

  factory RoutePoint.fromJson(Map<String, dynamic> j) => RoutePoint(
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lng: (j['lng'] as num?)?.toDouble() ?? 0,
        time: j['time']?.toString(),
      );

  LatLng get point => LatLng(lat, lng);
}