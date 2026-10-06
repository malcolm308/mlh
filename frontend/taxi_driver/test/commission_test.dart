import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_driver/models/models.dart';

/// El pasajero paga `total_fare`. La comision se descuenta del Fondo del
/// chofer, nunca del precio del viaje, asi que estas pruebas blindan que el
/// total que ve el chofer nunca sea `total_fare - commission`.
void main() {
  Map<String, dynamic> jsonTrip({
    double totalFare = 1804.21,
    double commission = 270.63,
    double commissionRate = 0.15,
    String commissionLabel = '15%',
    bool discount = false,
  }) =>
      {
        'trip_id': '99',
        'distance_km': 12.5,
        'duration_secs': 1500,
        'base_fare': 500.0,
        'distance_fare': 1000.0,
        'time_fare': 250.0,
        'tip': 0.0,
        'total_fare': totalFare,
        'commission': commission,
        'commission_rate': commissionRate,
        'commission_label': commissionLabel,
        'commission_discount': discount,
        'currency': 'CUP',
      };

  group('CompletedTrip', () {
    test('el total del viaje es el precio final, sin restar la comision', () {
      final t = CompletedTrip.fromJson(jsonTrip());

      expect(t.totalFare, 1804.21);
      expect(t.commission, 270.63);
      // El total NO debe ser el precio menos la comision.
      expect(t.totalFare, isNot(1533.58));
    });

    test('viaje normal usa la comision del 15%', () {
      final t = CompletedTrip.fromJson(jsonTrip());

      expect(t.commissionRate, 0.15);
      expect(t.commissionLabel, '15%');
      expect(t.commissionDiscount, isFalse);
    });

    test('el 3er viaje del dia muestra la comision reducida del 10%', () {
      final t = CompletedTrip.fromJson(jsonTrip(
        commission: 180.42,
        commissionRate: 0.10,
        commissionLabel: '10%',
        discount: true,
      ));

      expect(t.commissionRate, 0.10);
      expect(t.commissionLabel, '10%');
      expect(t.commissionDiscount, isTrue);
      expect(t.commission, 180.42);
      expect(t.totalFare, 1804.21, reason: 'el descuento no altera el precio');
    });

    test('si el backend no manda los campos, muestra 15% sin romperse', () {
      final json = jsonTrip()..remove('commission_rate');
      json.remove('commission_label');
      json.remove('commission_discount');

      final t = CompletedTrip.fromJson(json);

      expect(t.commissionRate, 0.15);
      expect(t.commissionLabel, '15%');
      expect(t.commissionDiscount, isFalse);
    });

    test('la comision del 10% es exactamente un tercio menos que la del 15%', () {
      final normal = CompletedTrip.fromJson(jsonTrip());
      final tercero = CompletedTrip.fromJson(jsonTrip(
        commission: 180.42,
        commissionRate: 0.10,
        commissionLabel: '10%',
        discount: true,
      ));

      expect(tercero.commission, lessThan(normal.commission));
      expect(1804.21 * 0.10, closeTo(180.42, 0.01));
      expect(1804.21 * 0.15, closeTo(270.63, 0.01));
    });
  });
}
