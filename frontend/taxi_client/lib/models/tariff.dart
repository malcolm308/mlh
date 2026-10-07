/// Tarifa de un tipo de vehiculo, tal como la devuelve GET /api/tariffs.
class Tariff {
  final int tariffId;
  final String vehicleType;
  final double baseFare;
  final double pricePerKm;
  final double pricePerMinute;
  final int maxPassengers;

  const Tariff({
    required this.tariffId,
    required this.vehicleType,
    required this.baseFare,
    required this.pricePerKm,
    required this.pricePerMinute,
    required this.maxPassengers,
  });

  factory Tariff.fromJson(Map<String, dynamic> j) => Tariff(
        tariffId: (j['tariff_id'] as num?)?.toInt() ?? 0,
        vehicleType: j['vehicle_type']?.toString() ?? '',
        baseFare: (j['base_fare'] as num?)?.toDouble() ?? 0,
        pricePerKm: (j['price_per_km'] as num?)?.toDouble() ?? 0,
        pricePerMinute: (j['price_per_minute'] as num?)?.toDouble() ?? 0,
        maxPassengers: (j['max_passengers'] as num?)?.toInt() ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'tariff_id': tariffId,
        'vehicle_type': vehicleType,
        'base_fare': baseFare,
        'price_per_km': pricePerKm,
        'price_per_minute': pricePerMinute,
        'max_passengers': maxPassengers,
      };
}

/// Regla de precio por horario, tal como la devuelve GET /api/pricing-rules.
class PricingRule {
  final int id;
  final String vehicleType;
  final String startTime;
  final String endTime;
  final double baseFareMultiplier;
  final double pricePerKmMultiplier;
  final double pricePerMinuteMultiplier;
  final String? description;

  const PricingRule({
    required this.id,
    required this.vehicleType,
    required this.startTime,
    required this.endTime,
    required this.baseFareMultiplier,
    required this.pricePerKmMultiplier,
    required this.pricePerMinuteMultiplier,
    this.description,
  });

  factory PricingRule.fromJson(Map<String, dynamic> j) => PricingRule(
        id: (j['id'] as num?)?.toInt() ?? 0,
        vehicleType: j['vehicle_type']?.toString() ?? '',
        startTime: j['start_time']?.toString() ?? '',
        endTime: j['end_time']?.toString() ?? '',
        baseFareMultiplier:
            (j['base_fare_multiplier'] as num?)?.toDouble() ?? 1,
        pricePerKmMultiplier:
            (j['price_per_km_multiplier'] as num?)?.toDouble() ?? 1,
        pricePerMinuteMultiplier:
            (j['price_per_minute_multiplier'] as num?)?.toDouble() ?? 1,
        description: j['description']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'vehicle_type': vehicleType,
        'start_time': startTime,
        'end_time': endTime,
        'base_fare_multiplier': baseFareMultiplier,
        'price_per_km_multiplier': pricePerKmMultiplier,
        'price_per_minute_multiplier': pricePerMinuteMultiplier,
        'description': description,
      };
}