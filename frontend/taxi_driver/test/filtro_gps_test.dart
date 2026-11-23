import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/services/filtro_gps.dart';

/// El filtro predictivo sustituyo a la media movil de cuatro puntos. Estas
/// pruebas fijan las dos cosas que se rompian: el retraso al girar/acelerar y
/// la entrada de fixes con precision inservible o saltos imposibles.
void main() {
  final t0 = DateTime(2026, 11, 23, 10, 0, 0);

  /// Punto [metros] al este de [base], a la latitud de La Habana.
  LatLng este(LatLng base, double metros) {
    const gradosPorMetro = 1 / 111320.0;
    final cosLat = 0.9195; // cos(23.14 grados)
    return LatLng(
      base.latitude,
      base.longitude + metros * gradosPorMetro / cosLat,
    );
  }

  /// Distancia aproximada en metros, con el mismo coseno que [este].
  double dist(LatLng a, LatLng b) {
    const m = 111320.0;
    final dLat = (a.latitude - b.latitude) * m;
    final dLng = (a.longitude - b.longitude) * m * 0.9195;
    return math.sqrt(dLat * dLat + dLng * dLng);
  }

  group('FiltroGps', () {
    test('el primer fix se devuelve tal cual', () {
      final f = FiltroGps();
      const p = LatLng(23.1400, -82.3600);

      expect(f.filtrar(p, ahora: t0), p);
    });

    test('rechaza un salto imposible y conserva la ultima posicion buena', () {
      final f = FiltroGps();
      const a = LatLng(23.1400, -82.3600);
      f.filtrar(a, ahora: t0, accuracyMetros: 5, velocidadKmh: 30);

      final b = este(a, 500);
      final r = f.filtrar(
        b,
        ahora: t0.add(const Duration(seconds: 1)),
        accuracyMetros: 5,
        velocidadKmh: 30,
      );

      expect(r, a);
    });

    test('un fix con precision pesima no mueve el marcador', () {
      final f = FiltroGps();
      const a = LatLng(23.1400, -82.3600);
      f.filtrar(a, ahora: t0, accuracyMetros: 5, velocidadKmh: 30);

      final b = este(a, 10);
      final r = f.filtrar(
        b,
        ahora: t0.add(const Duration(seconds: 1)),
        accuracyMetros: 200,
        velocidadKmh: 30,
      );

      expect(r, a);
      // La precision mala no se memoriza: el siguiente fix bueno vuelve a mover.
      expect(f.precisionMetros, 5);
    });

    test('en marcha sigue al fix nuevo sin el retraso de la media movil', () {
      final f = FiltroGps();
      var p = const LatLng(23.1400, -82.3600);
      f.filtrar(p, ahora: t0, accuracyMetros: 5, velocidadKmh: 36);

      LatLng? ultimo;
      for (var i = 1; i <= 6; i++) {
        p = este(p, 10); // 10 m/s = 36 km/h, un fix por segundo
        ultimo = f.filtrar(
          p,
          ahora: t0.add(Duration(seconds: i)),
          accuracyMetros: 5,
          velocidadKmh: 36,
        );

        // El punto dibujado no puede quedarse dos o tres fixes atras.
        final error = dist(ultimo, p);
        expect(error, lessThan(8.0), reason: 'fix $i atrasado $error m');
      }
      expect(f.velocidadKmh, closeTo(36, 1));
    });

    test('parado suaviza el baile del GPS', () {
      final f = FiltroGps();
      const a = LatLng(23.1400, -82.3600);
      f.filtrar(a, ahora: t0, accuracyMetros: 5, velocidadKmh: 0);

      final b = este(a, 6);
      final r = f.filtrar(
        b,
        ahora: t0.add(const Duration(seconds: 1)),
        accuracyMetros: 5,
        velocidadKmh: 0,
      );

      expect(dist(a, r), lessThan(3.0));
      expect(dist(b, r), greaterThan(3.0));
    });

    test('reiniciar olvida la ventana y la velocidad', () {
      final f = FiltroGps();
      const a = LatLng(23.1400, -82.3600);
      f.filtrar(a, ahora: t0, accuracyMetros: 5, velocidadKmh: 36);
      f.reiniciar();

      expect(f.velocidadKmh, isNull);
      final b = este(a, 100);
      expect(f.filtrar(b, ahora: t0, accuracyMetros: 5), b);
    });
  });
}
