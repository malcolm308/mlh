import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/models/geo_fix.dart';
import 'package:taxi_driver/services/navigation_mode_service.dart';

/// Monta el servicio con un [TickerProvider] real. Ver `navigation_position_test`.
Future<NavigationModeService> _servicio(WidgetTester tester) async {
  late NavigationModeService nav;
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: _HostTicker(
        onListo: (TickerProvider vsync) =>
            nav = NavigationModeService(vsync: vsync),
      ),
    ),
  );
  return nav;
}

class _HostTicker extends StatefulWidget {
  final void Function(TickerProvider vsync) onListo;

  const _HostTicker({required this.onListo});

  @override
  State<_HostTicker> createState() => _EstadoHostTicker();
}

class _EstadoHostTicker extends State<_HostTicker>
    with SingleTickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    widget.onListo(this);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Grados de longitud que son [metros] a esta latitud.
double _dLon(double metros, double lat) =>
    metros / (111320.0 * math.cos(lat * math.pi / 180.0));

/// Grados de latitud que son [metros].
double _dLat(double metros) => metros / 111320.0;

/// Fix sintético. El rumbo `bearing` se deja a null a proposito: si el motor
/// lo leyera, la prueba no demostraria que la fuente es el movimiento.
GeoFix _fix(LatLng pos, {double velocidadKmh = 30}) => GeoFix(
      position: pos,
      speedMps: velocidadKmh / 3.6,
      provider: 'gps',
    );

void main() {
  group('el rumbo sale SOLO del movimiento GPS + Kalman', () {
    testWidgets('sin viaje no hay rumbo aunque se alimente el GPS',
        (tester) async {
      final nav = await _servicio(tester);
      const lat = 23.14;
      nav.informarRuta(const [
        LatLng(lat, -82.36),
        LatLng(lat + 0.002, -82.36),
      ]);
      nav.informarFix(_fix(const LatLng(lat, -82.36)));
      nav.informarFix(_fix(LatLng(lat, -82.36 + _dLon(50, lat))));

      expect(nav.hayViajeActivo, isFalse);
      expect(nav.rumbo, isNull);
      expect(nav.rotacionActual, isNull);
      nav.dispose();
    });

    testWidgets('dos fixes al este orientan el mapa al este', (tester) async {
      final nav = await _servicio(tester);
      const lat = 23.14;
      nav.activar('in_progress', posicionConocida: const LatLng(lat, -82.36));

      nav.informarFix(_fix(const LatLng(lat, -82.36)));
      nav.informarFix(_fix(LatLng(lat, -82.36 + _dLon(50, lat))));

      expect(nav.rumboGps, closeTo(90, 2));
      expect(nav.rumbo, closeTo(90, 2));
      expect(nav.rumboRetenido, closeTo(90, 2));
      nav.dispose();
    });

    testWidgets('dos fixes al norte orientan el mapa al norte', (tester) async {
      final nav = await _servicio(tester);
      const lat = 23.14;
      nav.activar('in_progress', posicionConocida: const LatLng(lat, -82.36));

      nav.informarFix(_fix(const LatLng(lat, -82.36)));
      nav.informarFix(_fix(LatLng(lat + _dLat(50), -82.36)));

      expect(nav.rumboGps, closeTo(0, 2));
      expect(nav.rumbo, closeTo(0, 2));
      nav.dispose();
    });

    testWidgets('la geometria de la ruta ya no orienta el mapa', (tester) async {
      final nav = await _servicio(tester);
      const lat = 23.14;
      // Ruta recta al NORTE, pero el coche se mueve al ESTE: tiene que mandar
      // el GPS. Antes este caso daba 0 porque se proyectaba sobre la ruta.
      nav.activar('in_progress', posicionConocida: const LatLng(lat, -82.36));
      nav.informarRuta([
        const LatLng(lat, -82.36),
        LatLng(lat + _dLat(300), -82.36),
      ]);

      nav.informarFix(_fix(const LatLng(lat, -82.36)));
      nav.informarFix(_fix(LatLng(lat, -82.36 + _dLon(50, lat))));

      expect(nav.rumbo, closeTo(90, 2),
          reason: 'la ruta apunta al norte, el coche va al este');
      nav.dispose();
    });

    testWidgets('parado se conserva el ultimo rumbo valido', (tester) async {
      final nav = await _servicio(tester);
      const lat = 23.14;
      nav.activar('in_progress', posicionConocida: const LatLng(lat, -82.36));

      nav.informarFix(_fix(const LatLng(lat, -82.36)));
      nav.informarFix(_fix(LatLng(lat, -82.36 + _dLon(50, lat))));
      expect(nav.rumbo, closeTo(90, 2));

      // Fix al norte pero a 0 km/h: por debajo de 5 km/h el GPS no tiene
      // direccion fiable y el filtro no debe girar el mapa.
      nav.informarFix(_fix(
        LatLng(lat + _dLat(50), -82.36 + _dLon(50, lat)),
        velocidadKmh: 0,
      ));

      expect(nav.rumbo, closeTo(90, 2));
      nav.dispose();
    });

    testWidgets('un giro brusco se suaviza con el filtro de Kalman',
        (tester) async {
      final nav = await _servicio(tester);
      const lat = 23.14;
      nav.activar('in_progress', posicionConocida: const LatLng(lat, -82.36));

      nav.informarFix(_fix(const LatLng(lat, -82.36)));
      nav.informarFix(_fix(LatLng(lat, -82.36 + _dLon(50, lat))));
      final este = nav.rumbo!;
      expect(este, closeTo(90, 2));

      // Giro de 90 grados en una muestra: el medicion es 0 (norte), pero el
      // Kalman tiene que quedarse en un valor intermedio, no dar un salto.
      nav.informarFix(_fix(
        LatLng(lat + _dLat(50), -82.36 + _dLon(50, lat)),
      ));

      expect(nav.rumbo, greaterThan(0));
      expect(nav.rumbo, lessThan(este));
      nav.dispose();
    });

    testWidgets('rumboInicial siembra el filtro al aceptar el viaje',
        (tester) async {
      final nav = await _servicio(tester);
      nav.activar('accepted', rumboInicial: 270);

      expect(nav.rumbo, closeTo(270, 1));
      expect(nav.rumboGps, closeTo(270, 1));
      nav.dispose();
    });

    testWidgets('apagar el viaje quita el rumbo del mapa', (tester) async {
      final nav = await _servicio(tester);
      const lat = 23.14;
      nav.activar('in_progress', posicionConocida: const LatLng(lat, -82.36));
      nav.informarFix(_fix(const LatLng(lat, -82.36)));
      nav.informarFix(_fix(LatLng(lat, -82.36 + _dLon(50, lat))));
      expect(nav.rumbo, closeTo(90, 2));

      nav.apagar();

      expect(nav.hayViajeActivo, isFalse);
      expect(nav.rumbo, isNull);
      nav.dispose();
    });
  });
}
