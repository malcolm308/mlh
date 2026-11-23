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

    test('un punto lejano se pinta en la calle y guarda el crudo', () {
      final svc = MapMatchingService()..actualizarRuta(calle);
      const crudo = LatLng(23.1430, -82.3550); // ~333 m al norte

      final r = svc.ajustar(crudo, velocidadKmh: 30);

      // Antes se devolvia el crudo y el coche aparecia dentro del edificio.
      // Ahora se dibuja sobre la ruta, pero se marca como no confiable y el
      // detector de desvios sigue viendo la posicion original.
      expect(r.confiable, isFalse);
      expect(r.posicion.latitude, closeTo(23.1400, 1e-6));
      expect(r.posicion.longitude, closeTo(-82.3550, 1e-4));
      expect(r.posicionCruda, crudo);
    });

    test('sin ruta no se inventa una posición', () {
      final svc = MapMatchingService();
      const crudo = LatLng(23.1401, -82.3550);

      final r = svc.ajustar(crudo, velocidadKmh: 30);

      expect(r.confiable, isFalse);
      expect(r.posicion, crudo);
    });

    test('un solo fix no salta a una calle paralela', () {
      // Dos calles este-oeste separadas 40 m. El GPS de la primera se desvía
      // un instante hacia la segunda: no debe cambiar de tramo con un solo fix.
      final svc = MapMatchingService()
        ..actualizarRuta(const <LatLng>[
          LatLng(23.1400, -82.3600),
          LatLng(23.1400, -82.3500),
          LatLng(23.14036, -82.3500),
          LatLng(23.14036, -82.3600),
        ]);

      final r = svc.ajustar(
        const LatLng(23.14036, -82.3550),
        rumbo: 270,
        velocidadKmh: 30,
      );

      expect(r.tramo, 0);
      expect(r.posicion.latitude, closeTo(23.1400, 1e-6));
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

    test('un giro en esquina pasa por el vertice con un solo fix', () {
      // L: de oeste a este y luego al norte en -82.3550.
      final svc = MapMatchingService()
        ..actualizarRuta(const <LatLng>[
          LatLng(23.1400, -82.3600),
          LatLng(23.1400, -82.3550),
          LatLng(23.14045, -82.3550),
        ]);
      svc.ajustar(const LatLng(23.1400, -82.3580), rumbo: 90, velocidadKmh: 30);

      final r = svc.ajustar(
        const LatLng(23.14006, -82.3549),
        rumbo: 0,
        velocidadKmh: 30,
      );

      // No espera tres fixes (3 s a 1 Hz): entra directo por el vértice.
      expect(r.tramo, 1);
      expect(r.posicion.latitude, closeTo(23.1400, 1e-6));
      expect(r.posicion.longitude, closeTo(-82.3550, 1e-6));
    });

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

      expect(r.posicion.latitude, closeTo(23.1400, 1e-6));
      expect(r.posicion.longitude, closeTo(-82.3550, 1e-6));
    });
  });
}
