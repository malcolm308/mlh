import 'package:latlong2/latlong.dart';

/// Perfil del cliente que entra en la app de pasajeros.
class ClientProfile {
  final String id;
  final String fullName;
  final String email;
  final String? telefono;

  const ClientProfile({
    required this.id,
    required this.fullName,
    required this.email,
    this.telefono,
  });

  factory ClientProfile.fromJson(Map<String, dynamic> j) => ClientProfile(
        id: j['_id']?.toString() ?? '',
        fullName: '${j['Nombre'] ?? ''} ${j['Apellidos'] ?? ''}'.trim(),
        email: j['email']?.toString() ?? '',
        telefono: j['numero_de_telefono']?.toString(),
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