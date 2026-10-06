import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_driver/config.dart';

/// Umbrales de la inclinacion adaptativa del mapa.
///
/// El comportamiento clave es que el tilt NO se pierde al parar: se conserva
/// el ultimo angulo. Un mapa que se aplana al frenar y vuelve a inclinarse al
/// acelerar da dos saltos visibles en cada semaforo.
void main() {
  group('tiltObjetivoParaVelocidad en marcha', () {
    test('por encima del umbral de ciudad da el angulo de ciudad', () {
      // 12.5 m/s es exactamente el umbral alto de ciudad.
      final t = AppConfig.tiltObjetivoParaVelocidad(12.5);
      expect(t, closeTo(AppConfig.tiltCiudad, 0.001));
    });

    test('en carretera se queda en el angulo maximo', () {
      // 25 m/s son 90 km/h, por encima del umbral de carretera.
      final t = AppConfig.tiltObjetivoParaVelocidad(25.0);
      expect(t, closeTo(AppConfig.tiltAutopista, 0.001));
    });

    test('a media velocidad el angulo esta entre los dos umbrales', () {
      // 8 m/s esta entre 1.4 y 12.5, asi que la rampa va por la mitad.
      final t = AppConfig.tiltObjetivoParaVelocidad(8.0);
      expect(t, greaterThan(0));
      expect(t, lessThan(AppConfig.tiltCiudad));
    });
  });

  group('tiltObjetivoParaVelocidad parado', () {
    test('conserva el angulo anterior en vez de aplanarse', () {
      // Este es el cambio de comportamiento: antes devolvia 0.
      final parado = AppConfig.tiltObjetivoParaVelocidad(
        0.0,
        anterior: AppConfig.tiltCiudad,
      );
      expect(parado, closeTo(AppConfig.tiltCiudad, 0.001));
    });

    test('por debajo del umbral conserva cualquier angulo previo', () {
      // 1.0 m/s esta por debajo de 1.4. El valor previo manda.
      final parado = AppConfig.tiltObjetivoParaVelocidad(
        1.0,
        anterior: 42.0,
      );
      expect(parado, closeTo(42.0, 0.001));
    });

    test('sin angulo previo se queda en cero', () {
      // Sin estado previo (entrada fresca al modo) no hay nada que conservar.
      final parado = AppConfig.tiltObjetivoParaVelocidad(0.0);
      expect(parado, closeTo(0.0, 0.001));
    });
  });

  group('coherencia de umbrales', () {
    test('el umbral de ciudad es menor que el de carretera', () {
      expect(
        AppConfig.velocidadTiltCiudad,
        lessThan(AppConfig.velocidadTiltCarretera),
      );
    });

    test('los angulos crecen con la velocidad', () {
      expect(AppConfig.tiltQuieto, lessThan(AppConfig.tiltCiudad));
      expect(AppConfig.tiltCiudad, lessThan(AppConfig.tiltAutopista));
    });
  });

  group('tilt de entrada', () {
    test('el mapa entra inclinado, no plano', () {
      // Es el punto del cambio: recoger un viaje parado ya no parte de 0.
      expect(AppConfig.tiltEntradaNavegacion, greaterThan(0));
    });

    test('el angulo de entrada es el de ciudad, no el de carretera', () {
      // A 65 grados las esquinas de las calles de La Habana quedan escondidas.
      expect(
        AppConfig.tiltEntradaNavegacion,
        closeTo(AppConfig.tiltCiudad, 0.001),
      );
    });

    test('al entrar parado el angulo no se pierde en el primer tic', () {
      // Simula lo que hace la rampa: el objetivo parado devuelve el anterior,
      // asi que el tilt se queda donde esta en vez de aplanarse.
      final siguiente = AppConfig.tiltObjetivoParaVelocidad(
        0.0,
        anterior: AppConfig.tiltEntradaNavegacion,
      );
      expect(siguiente, closeTo(AppConfig.tiltEntradaNavegacion, 0.001));
    });
  });
}
