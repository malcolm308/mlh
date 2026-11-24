import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/models/geo_fix.dart';
import 'package:taxi_driver/services/navigation_mode_service.dart';

/// Servicio con ticker real. Ver `navigation_position_test.dart`.
///
/// [NavigationModeService.iniciar] es obligatorio en esta prueba: el callback
/// estático del [Ticker] solo llega a la instancia viva que registra ese método.
/// Sin él el reloj de pruebas avanza pero no se recalcula ningún frame.
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
  nav.iniciar();
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

double _dLon(double metros, double lat) =>
    metros / (111320.0 * math.cos(lat * math.pi / 180.0));

/// Apaga el modo antes de soltar el [Ticker]: `dispose` no lo detiene y el
/// framework falla si el árbol se desmonta con un ticker todavía activo.
void _limpiar(NavigationModeService nav) {
  nav.apagar();
  nav.dispose();
}

double _distancia(LatLng a, LatLng b) {
  final dLat = (a.latitude - b.latitude) * 111320.0;
  final dLng = (a.longitude - b.longitude) *
      111320.0 *
      math.cos(a.latitude * math.pi / 180.0);
  return math.sqrt(dLat * dLat + dLng * dLng);
}

GeoFix _fix(LatLng pos, double velocidadKmh) => GeoFix(
      position: pos,
      speedMps: velocidadKmh / 3.6,
      provider: 'gps',
    );

/// Deja el coche fuera de ruta, avanzando al ESTE, con dos fixes separados 1 s.
///
/// La ruta va al NORTE, así que 50 m al este ya son desvío. El segundo fix se
/// acepta porque 50 m/s está por debajo del tope de salto imposible.
Future<NavigationModeService> _fueraDeRuta(
  WidgetTester tester, {
  double velocidadKmh = 30,
}) async {
  const lat = 23.14;
  const lng = -82.36;
  const inicio = LatLng(lat, lng);

  NavigationModeService.relojPruebaMs = 1000;
  final nav = await _servicio(tester);
  nav.activar('in_progress', posicionConocida: inicio);
  nav.informarRuta([
    inicio,
    LatLng(lat + 0.003, lng),
  ]);
  nav.informarFix(_fix(inicio, velocidadKmh));

  NavigationModeService.relojPruebaMs = 2000;
  await tester.pump(const Duration(seconds: 1));
  nav.informarFix(_fix(
    LatLng(lat, lng + _dLon(50, lat)),
    velocidadKmh,
  ));
  await tester.pump(const Duration(milliseconds: 16));
  return nav;
}

void main() {
  tearDown(() => NavigationModeService.relojPruebaMs = null);

  group('avance entre fixes fuera de ruta', () {
    testWidgets('el marcador sigue moviéndose con el último rumbo', (tester) async {
      final nav = await _fueraDeRuta(tester);
      addTearDown(() => _limpiar(nav));

      final real = nav.posicionFiltrada;
      expect(nav.enRuta, isFalse, reason: 'el coche se desvió al este');

      NavigationModeService.relojPruebaMs = 3000;
      await tester.pump(const Duration(milliseconds: 16));

      final estimada = nav.posicion;
      final avance = _distancia(real, estimada);
      expect(avance, greaterThan(3.0));
      expect(avance, lessThan(13.0));
      expect(estimada.longitude, greaterThan(real.longitude));
      expect(nav.gpsDebil, isFalse);
      nav.apagar();
    });

    testWidgets('nunca se aleja más de 30 m del último fix real', (tester) async {
      final nav = await _fueraDeRuta(tester, velocidadKmh: 60);
      addTearDown(() => _limpiar(nav));

      final real = nav.posicionFiltrada;
      NavigationModeService.relojPruebaMs = 4500;
      await tester.pump(const Duration(milliseconds: 16));

      expect(_distancia(real, nav.posicion), lessThan(30.5));
      expect(_distancia(real, nav.posicion), greaterThan(20.0));
      expect(nav.gpsDebil, isTrue);
      nav.apagar();
    });

    testWidgets('sin fix en 4 s vuelve al punto real y avisa de GPS débil',
        (tester) async {
      final nav = await _fueraDeRuta(tester);
      addTearDown(() => _limpiar(nav));

      final real = nav.posicionFiltrada;
      NavigationModeService.relojPruebaMs = 6000;
      await tester.pump(const Duration(milliseconds: 16));

      expect(_distancia(real, nav.posicion), closeTo(0.0, 1e-9));
      expect(nav.gpsDebil, isTrue);
      nav.apagar();
    });

    testWidgets('un fix nuevo quita el aviso y salta a la posición medida',
        (tester) async {
      final nav = await _fueraDeRuta(tester);
      addTearDown(() => _limpiar(nav));

      NavigationModeService.relojPruebaMs = 6000;
      await tester.pump(const Duration(milliseconds: 16));
      expect(nav.gpsDebil, isTrue);

      final real = nav.posicionFiltrada;
      NavigationModeService.relojPruebaMs = 7000;
      nav.informarFix(_fix(real, 0));
      await tester.pump(const Duration(milliseconds: 16));

      expect(nav.gpsDebil, isFalse);
      // El filtro GPS suaviza el nuevo fix unos metros; lo que se comprueba es
      // que ya no está en la posición estimada ni sigue avanzando solo.
      expect(_distancia(real, nav.posicion), lessThan(5.0));
      nav.apagar();
    });
  });
}
