import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
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

/// Activa el viaje en [donde] siguiendo [ruta].
///
/// [_rumboDesdeRuta] mide desde la posicion del propio servicio (no recibe
/// argumentos), asi que la unica forma de mover el coche en una prueba es
/// sembrar la posicion con [NavigationModeService.activar].
///
/// Se apaga antes de volver a activar porque `activar` es idempotente por fase:
/// dos llamadas seguidas con la misma fase ignorarian la segunda, y con ella la
/// posicion. La ruta se reinyecta al final porque `apagar` la borra, que es lo
/// correcto en produccion (fin de viaje = sin ruta).
void _conViaje(
  NavigationModeService nav,
  LatLng donde,
  List<LatLng> ruta,
) {
  nav.activar(null);
  nav.activar('in_progress', posicionConocida: donde);
  nav.informarRuta(ruta);
}

void main() {
  group('el rumbo sale SOLO de la ruta', () {
    testWidgets('sin viaje no hay rumbo aunque haya ruta cargada',
        (tester) async {
      final nav = await _servicio(tester);
      // Ruta cargada pero viaje desactivado: no hay destino, asi que no hay rumbo.
      nav.informarRuta([
        const LatLng(23.13, -82.36),
        const LatLng(23.15, -82.36),
      ]);
      nav.activar(null, posicionConocida: const LatLng(23.14, -82.36));

      expect(nav.hayViajeActivo, isFalse);
      expect(nav.rumbo, isNull);
      expect(nav.rotacionActual, isNull);
      nav.dispose();
    });

    testWidgets('con viaje y ruta recta al este el mapa va al este',
        (tester) async {
      final nav = await _servicio(tester);
      const lat = 23.14;
      _conViaje(
        nav,
        LatLng(lat, -82.36 + _dLon(50, lat)),
        [
          const LatLng(lat, -82.36),
          LatLng(lat, -82.36 + _dLon(200, lat)),
        ],
      );

      expect(nav.hayViajeActivo, isTrue);
      expect(nav.rumboDesdeRuta(), closeTo(90, 1));
      nav.dispose();
    });

    testWidgets('con viaje y ruta recta al norte el mapa va al norte',
        (tester) async {
      final nav = await _servicio(tester);
      _conViaje(
        nav,
        const LatLng(23.14, -82.36),
        [const LatLng(23.13, -82.36), const LatLng(23.15, -82.36)],
      );

      expect(nav.rumboDesdeRuta(), closeTo(0, 1));
      nav.dispose();
    });

    testWidgets('el segmento mas cercano manda, no el primero de la lista',
        (tester) async {
      final nav = await _servicio(tester);
      // Dos tramos: 300 m al norte y luego 300 m al este. El coche esta en el
      // segundo, asi que el mapa va al este aunque el primer tramo sea al norte.
      const lat = 23.14;
      final esquina = LatLng(lat + 300 * _dLat(1), -82.36);
      final ruta = [
        const LatLng(lat, -82.36),
        esquina,
        LatLng(esquina.latitude, -82.36 + _dLon(300, lat)),
      ];

      _conViaje(nav, LatLng(esquina.latitude, -82.36 + _dLon(50, lat)), ruta);
      expect(nav.rumboDesdeRuta(), closeTo(90, 1));

      _conViaje(nav, LatLng(lat, -82.36 + _dLon(1, lat)), ruta);
      expect(nav.rumboDesdeRuta(), closeTo(0, 1),
          reason: 'en el primer tramo manda el tramo norte');
      nav.dispose();
    });

    testWidgets('un tramo duplicado no rompe la busqueda', (tester) async {
      final nav = await _servicio(tester);
      // OSRM devuelve a veces el origen repetido: el primer tramo tiene longitud
      // cero y su direccion es ruido.
      final ruta = [
        const LatLng(23.1400, -82.3600),
        const LatLng(23.1400, -82.3600),
        const LatLng(23.1500, -82.3600),
      ];
      _conViaje(nav, const LatLng(23.1450, -82.3600), ruta);

      expect(nav.rumboDesdeRuta(), closeTo(0, 1));
      nav.dispose();
    });

    testWidgets('con viaje pero sin ruta no hay rumbo y no hay salto',
        (tester) async {
      final nav = await _servicio(tester);
      _conViaje(nav, const LatLng(23.14, -82.36), const []);

      expect(nav.hayViajeActivo, isTrue);
      expect(nav.rumboDesdeRuta(), isNull);
      // La ultima orientacion valida se conserva en vez de saltar al norte.
      expect(nav.rumboRetenido, isNull);
      nav.dispose();
    });

    testWidgets('sin ruta el rumbo null deja el mapa en norte arriba',
        (tester) async {
      final nav = await _servicio(tester);
      _conViaje(nav, const LatLng(23.14, -82.36), const []);

      // Sin rumbo el servicio no fija rotacion: el mapa se queda en norte, que es
      // lo pedido para el caso "viaje sin ruta cargada".
      expect(nav.rotacionActual, isNull);
      expect(nav.debeSeguir, isTrue);
      nav.dispose();
    });

    testWidgets('apagar el viaje borra el rumbo', (tester) async {
      final nav = await _servicio(tester);
      _conViaje(
        nav,
        const LatLng(23.14, -82.36),
        [const LatLng(23.13, -82.36), const LatLng(23.15, -82.36)],
      );
      expect(nav.rumboDesdeRuta(), closeTo(0, 1));

      nav.apagar();

      expect(nav.rumbo, isNull);
      expect(nav.rumboDesdeRuta(), isNull);
      nav.dispose();
    });
  });
}