import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/models/geo_fix.dart';
import 'package:taxi_driver/services/calle_cercana_service.dart';
import 'package:taxi_driver/services/location_service.dart';
import 'package:taxi_driver/services/navigation_mode_service.dart';

/// El marcador del chofer no debe dar saltos visibles cuando cambia el GPS o
/// cuando llega una respuesta nueva de `/geo/calle-cercana`.
///
/// El punto que se publica al backend es la posición real; aquí solo se mira la
/// posición DIBUJADA, que debe recorrer el camino en varios frames.
void main() {
  const inicio = LatLng(23.1400, -82.3550);
  const masAdelante = LatLng(23.14009, -82.3550); // ~10 m al norte

  AnclajeCalle anclaje(LatLng punto) => AnclajeCalle(
        punto: punto,
        geom: [
          LatLng(punto.latitude, -82.3600),
          LatLng(punto.latitude, -82.3500),
        ],
        distanciaMetros: 9.0,
        nombre: 'Calle 23',
      );

  Future<NavigationModeService> servicio(WidgetTester tester) async {
    late NavigationModeService nav;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: _HostTicker(
          onListo: (vsync) => nav = NavigationModeService(vsync: vsync),
        ),
      ),
    );
    // Sin `iniciar()` el ticker estático no conoce la instancia y no hay frames
    // de interpolación: `posicionVisual` caería directamente al objetivo.
    nav.iniciar();
    return nav;
  }

  Future<void> frames(WidgetTester tester, [int cantidad = 60]) async {
    for (var i = 0; i < cantidad; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  setUp(() => NavigationModeService.pedirAnclajeAutomatico = false);
  tearDown(() => NavigationModeService.pedirAnclajeAutomatico = true);

  group('suavizado del marcador', () {
    testWidgets('un fix nuevo no mueve el coche de golpe', (tester) async {
      final nav = await servicio(tester);

      nav.informarFix(const GeoFix(
        position: inicio,
        accuracy: 5,
        speedMps: 0,
      ));
      await frames(tester);
      expect(nav.posicionVisual, inicio);

      // Salto de 10 m en un solo fix. El marcador apenas se mueve en el primer
      // frame y llega al destino en menos de un segundo.
      nav.informarFix(const GeoFix(
        position: masAdelante,
        accuracy: 5,
        speedMps: 5,
      ));
      await tester.pump(const Duration(milliseconds: 16));
      final primerFrame = LocationService.distanceBetween(
        inicio,
        nav.posicionVisual,
      );
      expect(primerFrame, lessThan(3.0));

      await frames(tester);
      // El objetivo real es la posición FILTRADA (el filtro GPS no salta 10 m
      // en un solo fix), no la coordenada cruda del nuevo fix.
      final objetivo = nav.posicionAnclada;
      expect(
        LocationService.distanceBetween(nav.posicionVisual, objetivo),
        lessThan(1.0),
      );

      nav.apagar();
      nav.dispose();
    });

    testWidgets('cambiar el anclaje de la calle no teletransporta', (tester) async {
      final nav = await servicio(tester);
      nav.informarFix(const GeoFix(
        position: inicio,
        accuracy: 5,
        speedMps: 0,
      ));
      nav.informarAnclajeCalle(anclaje(inicio));
      await frames(tester);

      final antes = nav.posicionVisual;
      // La respuesta nueva coloca la calle 12 m más al norte.
      final nuevaCalle = LatLng(23.140108, -82.3550);
      nav.informarAnclajeCalle(anclaje(nuevaCalle));

      await tester.pump(const Duration(milliseconds: 16));
      expect(LocationService.distanceBetween(antes, nav.posicionVisual),
          lessThan(3.0));

      await frames(tester);
      expect(
        LocationService.distanceBetween(
          nav.posicionVisual,
          nav.posicionAnclada,
        ),
        lessThan(1.5),
      );

      nav.apagar();
      nav.dispose();
    });

    testWidgets('suavizar no cambia la posición que se publica', (tester) async {
      final nav = await servicio(tester);
      nav.informarFix(const GeoFix(
        position: inicio,
        accuracy: 5,
        speedMps: 0,
      ));
      await frames(tester);
      nav.informarFix(const GeoFix(
        position: masAdelante,
        accuracy: 5,
        speedMps: 5,
      ));
      await tester.pump(const Duration(milliseconds: 16));

      // El backend sigue recibiendo la posición filtrada real aunque el
      // marcador vaya por detrás durante unos frames.
      expect(nav.posicionReal, masAdelante);
      expect(
        LocationService.distanceBetween(nav.posicionVisual, masAdelante),
        greaterThan(0.0),
      );

      nav.apagar();
      nav.dispose();
    });
  });
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
