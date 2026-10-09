import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:taxi_driver/widgets/trip_info_panel.dart';

/// Regresiones del panel de viaje en curso.
///
/// Antes el panel se montaba en un `Positioned` de `Stack` con solo `bottom`,
/// lo que dejaba `maxHeight` en infinito y la `DraggableScrollableSheet`
/// degeneraba: el panel no se pintaba y el mapa acumulaba errores de
/// transformación no invertible. Ahora el widget acota la altura él mismo.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Widget hostAcotado(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  testWidgets('con altura acotada el panel pinta el resumen colapsado',
      (tester) async {
    await tester.pumpWidget(hostAcotado(
      CollapsibleTripPanel(
        tripId: 't1',
        collapsed: const Text('RESUMEN_DESTINO'),
        expanded: const Text('FICHA_EXPANDIDA'),
      ),
    ));
    await tester.pump();
    // Estado inicial: colapsado, solo el resumen.
    expect(find.text('RESUMEN_DESTINO'), findsOneWidget);
    expect(find.text('FICHA_EXPANDIDA'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrastrar la hoja hacia arriba despliega la ficha',
      (tester) async {
    await tester.pumpWidget(hostAcotado(
      CollapsibleTripPanel(
        tripId: 't2',
        collapsed: const Text('RESUMEN_DESTINO'),
        expanded: const Text('FICHA_EXPANDIDA'),
      ),
    ));
    await tester.pump();
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(find.text('FICHA_EXPANDIDA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('en altura NO acotada (Positioned solo bottom) el panel sigue '
      'pintandose (sin errores de geometria)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 1080,
        height: 2280,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: CollapsibleTripPanel(
                tripId: 't3',
                collapsed: const Text('RESUMEN_NO_ACOTADO'),
                expanded: const Text('FICHA_NO_ACOTADA'),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('RESUMEN_NO_ACOTADO'), findsOneWidget);
    // Sin la acotacion de altura, la hoja tira una excepcion de constraints
    // inflacionaria y el test lo detectaria aqui.
    expect(tester.takeException(), isNull);
  });

  testWidgets('el estado expandido se restaura al reabrir la app',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'panel_viaje_trip': 't4',
      'panel_viaje_estado': 'exp',
    });
    await tester.pumpWidget(hostAcotado(
      CollapsibleTripPanel(
        tripId: 't4',
        collapsed: const Text('RESUMEN_DESTINO'),
        expanded: const Text('FICHA_EXPANDIDA'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('FICHA_EXPANDIDA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}