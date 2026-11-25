import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/models/geo_fix.dart';
import 'package:taxi_driver/services/calle_cercana_service.dart';
import 'package:taxi_driver/services/map_matching_service.dart';
import 'package:taxi_driver/services/navigation_mode_service.dart';

/// El chofer libre no tiene ruta de viaje donde encajar el GPS. Estas pruebas
/// fijan que el marcador se ancla a la vía que devuelve Supabase y que un fix
/// que rebota contra un edificio no lo mete dentro de la manzana.
void main() {
  const calle = <LatLng>[
    LatLng(23.1400, -82.3600),
    LatLng(23.1400, -82.3500),
  ];

  AnclajeCalle anclaje() => AnclajeCalle(
        punto: const LatLng(23.1400, -82.3550),
        geom: calle,
        distanciaMetros: 9.0,
        nombre: 'Calle 23',
      );

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

  setUp(() => NavigationModeService.pedirAnclajeAutomatico = false);
  tearDown(() => NavigationModeService.pedirAnclajeAutomatico = true);

  group('anclaje a la calle cercana', () {
    test('la respuesta del backend se convierte y valida', () {
      final a = AnclajeCalle.fromJson({
        'ok': true,
        'punto': {'lat': 23.14, 'lon': -82.355},
        'geom': [
          [23.14, -82.36],
          [23.14, -82.35],
        ],
        'dist_m': 9.0,
        'nombre': 'Calle 23',
        'origen': 'supabase:streets',
      });

      expect(a, isNotNull);
      expect(a!.punto.latitude, 23.14);
      expect(a.geom.length, 2);
      expect(a.origen, 'supabase:streets');

      // Sin geometría suficiente no se ancla: mejor dibujar el GPS real que
      // inventar una recta.
      expect(
        AnclajeCalle.fromJson({
          'ok': true,
          'punto': {'lat': 23.14, 'lon': -82.355},
          'geom': [[23.14, -82.36]],
        }),
        isNull,
      );
      expect(AnclajeCalle.fromJson({'ok': false}), isNull);
    });

    test('sin ruta el GPS desplazado se proyecta sobre la calle', () {
      final svc = MapMatchingService()..actualizarRuta(anclaje().geom);
      final r = svc.ajustar(
        const LatLng(23.14009, -82.3550),
        velocidadKmh: 20,
      );

      expect(r.enRuta, isTrue);
      expect(r.posicion.latitude, closeTo(23.1400, 1e-6));
      expect(r.posicion.longitude, closeTo(-82.3550, 1e-4));
    });

    testWidgets('el vehículo se dibuja en la calle y no salta al edificio',
        (tester) async {
      final nav = await _servicio(tester);
      nav.activar('accepted', posicionConocida: anclaje().punto);
      // Viaje sin trazado todavía: es el caso que se estaba dibujando sobre
      // los edificios.
      nav.informarRuta(const [], rutaParaMatching: const []);
      nav.informarAnclajeCalle(anclaje());

      nav.informarFix(
        const GeoFix(
          position: LatLng(23.14009, -82.3550),
          accuracy: 5,
          speedMps: 0,
        ),
      );
      await tester.pump();

      expect(nav.posicionAnclada.latitude, closeTo(23.1400, 1e-6));
      expect(nav.posicion.latitude, closeTo(23.1400, 1e-5));
      expect(nav.enRuta, isTrue);
      final enCalle = nav.posicion;

      // Rebote típico del GPS urbano: el punto salta 40 m al norte, dentro de
      // una manzana. El marcador se queda en el último punto de la vía.
      nav.informarFix(
        const GeoFix(
          position: LatLng(23.14036, -82.3550),
          accuracy: 12,
          speedMps: 0,
        ),
      );
      await tester.pump();

      // El filtro puede suavizar el salto; tanto si se proyecta como si se
      // conserva el último punto de la vía, el marcador NO entra en la manzana.
      expect(nav.posicion.latitude, closeTo(enCalle.latitude, 1e-5));
      expect(nav.posicion.longitude, closeTo(enCalle.longitude, 1e-5));

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
