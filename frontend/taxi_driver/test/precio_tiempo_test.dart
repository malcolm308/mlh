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

  TripOffer esperandoCon({int? esperaSegundos, String status = 'driver_arrived'}) {
    return TripOffer.fromJson({
      'trip_id': 't2',
      'status': status,
      'hora_llegada': '2026-01-01T12:00:00',
      'hora_inicio_viaje': '2026-01-01T12:06:00',
      'espera_segundos': ?esperaSegundos,
      'tiempo_espera_cortesia_minutos': 4,
    });
  }

  test('la cortesia baja segundo a segundo con el reloj del servidor', () {
    final viaje = esperandoCon(esperaSegundos: 0);
    final ahora = DateTime.utc(2026, 1, 1, 12, 1, 30);

    expect(viaje.esperaVivaSegs(ahora), 90);
    // 4 min de cortesia - 90 s esperados = 150 s gratis.
    expect(viaje.cortesiaRestanteSegs(ahora), 150);
    expect(viaje.excedenteVivo(ahora), 0);
  });

  test('un espera vieja del backend no clava el contador', () {
    final viaje = esperandoCon(esperaSegundos: 15);
    final ahora = DateTime.utc(2026, 1, 1, 12, 2);

    expect(viaje.esperaVivaSegs(ahora), 120);
    expect(viaje.cortesiaRestanteSegs(ahora), 120);
  });

  test('agotada la cortesia el excedente tambien corre en vivo', () {
    final viaje = esperandoCon(esperaSegundos: 0);
    final ahora = DateTime.utc(2026, 1, 1, 12, 5);

    expect(viaje.esperaVivaSegs(ahora), 300);
    expect(viaje.cortesiaRestanteSegs(ahora), 0);
    expect(viaje.excedenteVivo(ahora), 60);
  });

  test('con el viaje iniciado la espera se queda en lo que ocurrio antes', () {
    final viaje = esperandoCon(
        esperaSegundos: 360, status: 'in_progress');
    final muchoDespues = DateTime.utc(2026, 1, 1, 12, 20);

    expect(viaje.esperaVivaSegs(muchoDespues), 360);
    expect(viaje.excedenteVivo(muchoDespues), 120);
  });
}
