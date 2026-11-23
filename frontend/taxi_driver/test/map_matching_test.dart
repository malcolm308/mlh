import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/services/map_matching_service.dart';

/// El GPS urbano rebota en los edificios: sin map-matching el marcador se ve
/// atravesando manzanas. Estas pruebas fijan que la posición publicada caiga
/// siempre sobre la polilínea de la ruta, sin saltos entre calles paralelas.
void main() {
  /// Calle este-oeste. Diez metros al norte son ~0.00009 grados de latitud.
  const calle = <LatLng>[LatLng(23.1400, -82.3600), LatLng(23.1400, -82.3500)];

  group('map matching de la posición', () {
    test('proyecta un GPS desplazado sobre la calle', () {
      final svc = MapMatchingService()..actualizarRuta(calle);

      final r = svc.ajustar(const LatLng(23.14009, -82.3550), velocidadKmh: 30);

      expect(r.confiable, isTrue);
      expect(r.posicion.latitude, closeTo(23.1400, 1e-6));
      expect(r.posicion.longitude, closeTo(-82.3550, 1e-4));
      expect(r.posicionCruda.latitude, closeTo(23.14009, 1e-9));
      // 10 m de error perpendicular, informativo para el diagnóstico.
      expect(r.distanciaMetros, closeTo(10.0, 1.0));
    });

    test('un punto lejano suelta el encaje y dibuja la posicion real', () {
      final svc = MapMatchingService()..actualizarRuta(calle);
      const crudo = LatLng(23.1430, -82.3550); // ~333 m al norte

      final r = svc.ajustar(crudo, velocidadKmh: 30);

      // Al desviarse NO se dibuja sobre la calle vieja: el marcador sigue al
      // coche aunque la polilinea siga pintada hasta que llegue el recalculo.
      expect(r.enRuta, isFalse);
      expect(r.confiable, isFalse);
      expect(r.posicion, crudo);
      expect(r.posicionCruda, crudo);
    });

    test('al volver cerca de la ruta se reengancha de inmediato', () {
      final svc = MapMatchingService()..actualizarRuta(calle);
      svc.ajustar(const LatLng(23.14005, -82.3550), velocidadKmh: 30);

      // Desvio claro.
      final fuera = svc.ajustar(
        const LatLng(23.1430, -82.3550),
        velocidadKmh: 30,
      );
      expect(fuera.enRuta, isFalse);

      // Vuelve a la calle: no espera tres fixes como al arrancar, porque ya
      // se sabe que antes estaba en ruta.
      final vuelta = svc.ajustar(
        const LatLng(23.14003, -82.3520),
        velocidadKmh: 30,
      );
      expect(vuelta.enRuta, isTrue);
      expect(vuelta.posicion.latitude, closeTo(23.1400, 1e-6));
    });

    test('la precision mala amplia el umbral, pero nunca mete el coche en un edificio', () {
      final svc = MapMatchingService()..actualizarRuta(calle);
      const cercano = LatLng(23.14018, -82.3550); // ~20 m al norte
      const lejano = LatLng(23.14065, -82.3550); // ~72 m al norte

      // 20 m con precision normal esta justo en el limite de entrada.
      final normal = svc.ajustar(
        cercano,
        precisionMetros: 5,
        velocidadKmh: 30,
      );
      expect(normal.enRuta, isTrue);

      // Con 45 m declarados, 20 m sigue siendo plausible.
      final tolerante = svc.ajustar(
        cercano,
        precisionMetros: 45,
        velocidadKmh: 30,
      );
      expect(tolerante.enRuta, isTrue);

      // Antes 60 m de precision autorizaban a dibujar el coche a 72 m de la
      // calle: eso es pintarlo encima de la manzana. El tope es 35 m de entrada
      // y 45 m de salida, asi que este fix se dibuja donde esta de verdad.
      final lejanoSvc = MapMatchingService()..actualizarRuta(calle);
      final malo = lejanoSvc.ajustar(
        lejano,
        precisionMetros: 60,
        velocidadKmh: 30,
      );
      expect(malo.enRuta, isFalse);
      expect(malo.posicion, lejano);
    });

    test('una calle paralela mas cercana gana aunque la vieja siga dentro del umbral', () {
      // Vuelta cerrada: la calle de abajo (tramo 0) y la de arriba (tramo 2).
      final svc = MapMatchingService()
        ..actualizarRuta(const <LatLng>[
          LatLng(23.1400, -82.3600),
          LatLng(23.1400, -82.3500),
          LatLng(23.14036, -82.3500),
          LatLng(23.14036, -82.3600),
        ]);
      svc.ajustar(
        const LatLng(23.14002, -82.3580),
        rumbo: 90,
        velocidadKmh: 30,
      );

      // El coche ya esta en la calle de arriba: 1 m de la nueva, 38 de la
      // vieja. La busqueda global impone la nueva (el primer fix muestra la
      // posicion real mientras se confirma el cambio de calle).
      const arriba = LatLng(23.14035, -82.3580);
      svc.ajustar(arriba, rumbo: 270, velocidadKmh: 30);
      final r = svc.ajustar(arriba, rumbo: 270, velocidadKmh: 30);

      expect(r.tramo, 2);
      expect(r.enRuta, isTrue);
      expect(r.posicion.latitude, closeTo(23.14036, 1e-6));
    });

    test('fuera de ruta no se extrapola por la polilinea vieja', () {
      final svc = MapMatchingService()..actualizarRuta(calle);
      final fuera = svc.ajustar(
        const LatLng(23.1430, -82.3550),
        velocidadKmh: 30,
      );

      final avanzado = svc.avanzar(fuera, 50);

      expect(fuera.enRuta, isFalse);
      expect(avanzado, fuera.posicion);
    });

    test('sin ruta no se inventa una posición', () {
      final svc = MapMatchingService();
      const crudo = LatLng(23.1401, -82.3550);

      final r = svc.ajustar(crudo, velocidadKmh: 30);

      expect(r.confiable, isFalse);
      expect(r.posicion, crudo);
    });

    test('un solo fix no salta a una calle paralela, pero tampoco pinta la vieja', () {
      // Dos calles este-oeste separadas 40 m. El GPS de la primera se desvía
      // un instante hacia la segunda: no debe cambiar de tramo con un solo fix.
      final svc = MapMatchingService()
        ..actualizarRuta(const <LatLng>[
          LatLng(23.1400, -82.3600),
          LatLng(23.1400, -82.3500),
          LatLng(23.14036, -82.3500),
          LatLng(23.14036, -82.3600),
        ]);

      const crudo = LatLng(23.14036, -82.3550);
      final r = svc.ajustar(crudo, rumbo: 270, velocidadKmh: 30);

      // La histeresis sigue evitando el salto de calle...
      expect(r.tramo, 0);
      // ...pero ANTES se dibujaba a 40 m de aqui, sobre la calle vieja. Ahora
      // se muestra la posicion real hasta que se confirma el cambio.
      expect(r.enRuta, isFalse);
      expect(r.posicion, crudo);

      final confirmado = svc.ajustar(crudo, rumbo: 270, velocidadKmh: 30);
      expect(confirmado.enRuta, isTrue);
      expect(confirmado.tramo, 2);
      expect(confirmado.posicion.latitude, closeTo(23.14036, 1e-6));
    });

    test('varios fixes compatibles acaban cambiando de tramo', () {
      final svc = MapMatchingService()
        ..actualizarRuta(const <LatLng>[
          LatLng(23.1400, -82.3600),
          LatLng(23.1400, -82.3500),
          LatLng(23.14036, -82.3500),
          LatLng(23.14036, -82.3600),
        ]);

      PuntoRuta? r;
      for (var i = 0; i < 5; i++) {
        r = svc.ajustar(
          const LatLng(23.14036, -82.3560),
          rumbo: 270,
          velocidadKmh: 30,
        );
      }

      expect(r!.tramo, 2);
      expect(r.posicion.latitude, closeTo(23.14036, 1e-6));
    });

    test('parado se conserva el tramo pero se sigue dibujando en la calle', () {
      final svc = MapMatchingService()..actualizarRuta(calle);
      svc.ajustar(const LatLng(23.14005, -82.3550), velocidadKmh: 30);

      final r = svc.ajustar(const LatLng(23.14012, -82.3550), velocidadKmh: 0);

      expect(r.tramo, 0);
      expect(r.posicion.latitude, closeTo(23.1400, 1e-6));
    });

    test('una ruta recalculada recoloca el índice sin volver al origen', () {
      final svc = MapMatchingService()..actualizarRuta(calle);
      svc.ajustar(const LatLng(23.14005, -82.3520), velocidadKmh: 30);

      svc.actualizarRuta(const <LatLng>[
        LatLng(23.1400, -82.3550),
        LatLng(23.1400, -82.3500),
      ]);
      final r = svc.ajustar(const LatLng(23.14005, -82.3520), velocidadKmh: 30);

      expect(r.confiable, isTrue);
      expect(r.posicion.longitude, closeTo(-82.3520, 1e-4));
    });

    test(
      'un giro en esquina entra en el tramo nuevo sin forzar el vertice',
      () {
        // L: de oeste a este y luego al norte en -82.3550.
        final svc = MapMatchingService()
          ..actualizarRuta(const <LatLng>[
            LatLng(23.1400, -82.3600),
            LatLng(23.1400, -82.3550),
            LatLng(23.14045, -82.3550),
          ]);
        svc.ajustar(
          const LatLng(23.1400, -82.3580),
          rumbo: 90,
          velocidadKmh: 30,
        );

        final r = svc.ajustar(
          const LatLng(23.14006, -82.3549),
          rumbo: 0,
          velocidadKmh: 30,
        );

        // No espera tres fixes (3 s a 1 Hz): el rumbo confirma el giro. Pero el
        // punto se dibuja donde el GPS lo proyecta, NO en el vertice de la
        // esquina: el coche no puede aparecer alli antes de haber llegado.
        expect(r.tramo, 1);
        expect(r.enRuta, isTrue);
        expect(r.posicion.latitude, closeTo(23.14006, 1e-5));
        expect(r.posicion.longitude, closeTo(-82.3550, 1e-6));
      },
    );

    test('la extrapolacion sigue la calle y no corta la manzana', () {
      final svc = MapMatchingService()
        ..actualizarRuta(const <LatLng>[
          LatLng(23.1400, -82.3600),
          LatLng(23.1400, -82.3550),
          LatLng(23.14045, -82.3550),
        ]);
      svc.ajustar(const LatLng(23.1400, -82.3580), rumbo: 90, velocidadKmh: 30);
      final esquina = svc.ajustar(
        const LatLng(23.14006, -82.3549),
        rumbo: 0,
        velocidadKmh: 30,
      );

      final proyectado = svc.avanzar(esquina, 25);

      // Si se extrapolase en recta con el rumbo antiguo, seguiria en
      // latitud 23.1400 y se meteria en la manzana. Aqui sube por la calle.
      expect(proyectado.latitude, greaterThan(23.1401));
      expect(proyectado.longitude, closeTo(-82.3550, 1e-4));
    });

    test('un recalculo con los mismos extremos pero otra calle se aplica', () {
      const a = LatLng(23.1400, -82.3600);
      const b = LatLng(23.1400, -82.3550);
      const c = LatLng(23.14045, -82.3550);
      final svc = MapMatchingService()..actualizarRuta(const <LatLng>[a, c]);
      svc.ajustar(const LatLng(23.1402, -82.3570), velocidadKmh: 30);

      // Extremos identicos, geometria distinta: antes se ignoraba.
      svc.actualizarRuta(const <LatLng>[a, b, c]);
      final r = svc.ajustar(
        const LatLng(23.14006, -82.3549),
        rumbo: 0,
        velocidadKmh: 30,
      );

      expect(r.enRuta, isTrue);
      expect(r.posicion.latitude, closeTo(23.14006, 1e-5));
      expect(r.posicion.longitude, closeTo(-82.3550, 1e-6));
    });
  });
}
