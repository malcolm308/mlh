import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_driver/screens/driver_home_screen.dart';

/// El aviso de viaje inactivo es útil cuando el chofer tocó una notificación
/// o llegó un evento nuevo. No debe aparecer por una asignación huérfana que
/// el servicio en segundo plano guardó y la app recupera al volver al frente.
void main() {
  test('la asignación recuperada en silencio no avisa de viaje inactivo', () {
    expect(debeAvisarViajeInactivo(asignacionRecuperada: true), isFalse);
  });

  test('una notificación o evento reciente sí avisa de viaje inactivo', () {
    expect(debeAvisarViajeInactivo(asignacionRecuperada: false), isTrue);
  });
}
