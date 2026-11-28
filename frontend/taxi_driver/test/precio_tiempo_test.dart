import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_driver/models/models.dart';

/// El chofer debe ver el tiempo real del viaje y el precio que ese tiempo
/// cambia. El reloj viene del servidor, igual que el contador de cortesía, y
/// el precio provisional lo calcula el backend en cada sondeo.
void main() {
  TripOffer viajeCon({
    String? horaInicio,
    double? precioProvisional,
    int? tiempoTranscurridoSecs,
  }) {
    return TripOffer.fromJson({
      'trip_id': 't1',
      'status': 'in_progress',
      'precio_estimado': 100.0,
      'hora_inicio_viaje': ?horaInicio,
      'precio_provisional': ?precioProvisional,
      'tiempo_transcurrido_secs': ?tiempoTranscurridoSecs,
    });
  }

  test('el modelo lee el inicio y el precio provisional del backend', () {
    final viaje = viajeCon(
      horaInicio: '2026-01-01T12:00:00',
      precioProvisional: 118.5,
      tiempoTranscurridoSecs: 600,
    );

    expect(viaje.horaInicio, '2026-01-01T12:00:00');
    expect(viaje.horaInicioUtc, DateTime.utc(2026, 1, 1, 12));
    expect(viaje.precioProvisional, 118.5);
    expect(viaje.tiempoTranscurridoSecs, 600);
  });

  test('el tiempo se cuenta con el reloj del servidor, no con el del telefono',
      () {
    final viaje = viajeCon(horaInicio: '2026-01-01T12:00:00');
    final ahoraServidor = DateTime.utc(2026, 1, 1, 12, 7, 30);

    expect(viaje.tiempoEnViajeSegs(ahoraServidor), 450);
  });

  test('sin hora de inicio se usa el ultimo valor que mando el backend', () {
    final viaje = viajeCon(tiempoTranscurridoSecs: 321);

    expect(viaje.horaInicioUtc, isNull);
    expect(viaje.tiempoEnViajeSegs(DateTime.utc(2026, 1, 1, 13)), 321);
  });

  test('un reloj local adelantado no inventa tiempo de viaje', () {
    final viaje = viajeCon(horaInicio: '2026-01-01T12:00:00Z');

    // El telefono cree que son las 13:00, pero el servidor dice 12:01.
    expect(viaje.tiempoEnViajeSegs(DateTime.utc(2026, 1, 1, 12, 1)), 60);
  });
}
