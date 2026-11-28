import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taxi_driver/widgets/driver_map/driver_idle_layouts.dart';
import 'package:taxi_driver/widgets/driver_map/trip_request_layout.dart';

/// Los tres estados del mapa se montan solos, sin API ni MapLibre, para fijar
/// que caben en cualquier ancho de telefono (360-430 px) y que las acciones
/// siguen conectadas.
const anchos = <double>[360, 390, 430];

Future<void> _pantalla(
  WidgetTester tester,
  Widget child,
  double ancho, {
  double alto = 820,
}) async {
  const dpr = 3.0;
  tester.view.physicalSize = Size(ancho * dpr, alto * dpr);
  tester.view.devicePixelRatio = dpr;
  addTearDown(() => tester.view.reset());

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Stack(children: <Widget>[child])),
    ),
  );
  // El radar y el FAB se repiten: usar `pumpAndSettle` nunca terminaria.
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  for (final ancho in anchos) {
    testWidgets('Pausado cabe y activa viajes a ${ancho.toStringAsFixed(0)} px',
        (tester) async {
      var activaciones = 0;
      await _pantalla(
        tester,
        BottomSheetPaused(
          tipoVehiculo: 'Taxi',
          modeloVehiculo: 'Toyota Corolla · AMB 123',
          gananciasHoy: 1822,
          onActivar: () => activaciones++,
        ),
        ancho,
      );

      expect(find.text('Activar viajes'), findsOneWidget);
      expect(find.text('1,822 CUP'), findsOneWidget);
      await tester.tap(find.text('Activar viajes'));
      await tester.pump();
      expect(activaciones, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Activo cabe y desactiva viajes a ${ancho.toStringAsFixed(0)} px',
        (tester) async {
      var desactivaciones = 0;
      await _pantalla(
        tester,
        ActiveOverlay(
          gananciasHoy: 1822,
          onDesactivar: () => desactivaciones++,
          onUbicacion: () {},
        ),
        ancho,
      );

      expect(find.byType(RadarMarker), findsOneWidget);
      expect(find.byType(StopFab), findsOneWidget);
      await tester.tap(find.text('Desactivar'));
      await tester.pump();
      expect(desactivaciones, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Solicitud cabe y acepta/rechaza a ${ancho.toStringAsFixed(0)} px',
        (tester) async {
      var aceptadas = 0;
      var rechazadas = 0;
      var menus = 0;
      await _pantalla(
        tester,
        TripRequestOverlay(
          onMenu: () => menus++,
          tipoVehiculo: 'Taxi',
          metodoPago: 'Efectivo',
          precio: 1250,
          distanciaKm: 4.2,
          pasajeros: 2,
          tiempoMin: 9.4,
          recogidaKm: 1.2,
          direccionRecogida: 'Calle 23 e I, Vedado',
          direccionDestino: 'Paseo del Prado, Centro Habana',
          countdown: 12,
          countdownTotal: 60,
          aceptando: false,
          ocupado: false,
          saldoNegativo: false,
          onAceptar: () => aceptadas++,
          onRechazar: () => rechazadas++,
          promocion: const SizedBox(height: 24),
        ),
        ancho,
      );

      // El contador se expone como region viva para lectores de pantalla.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics && w.properties.label == 'Aceptar en 12 segundos',
        ),
        findsOneWidget,
      );
      expect(find.text('RECOGER EN · 1.2 KM'), findsOneWidget);
      expect(find.text('Paseo del Prado, Centro Habana'), findsOneWidget);

      await tester.tap(find.text('Aceptar'));
      await tester.tap(find.text('Rechazar'));
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Abrir menú',
        ),
      );
      await tester.pump();

      expect(aceptadas, 1);
      expect(rechazadas, 1);
      expect(menus, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
