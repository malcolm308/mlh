import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_driver/services/update_service.dart';

/// El aviso de actualizacion obligatoria NUNCA puede interrumpir un viaje,
/// pero TAMPOCO puede quedarse pegado cuando el backend ya no lo exige.
void main() {
  final update = UpdateService.instance;

  setUp(() {
    update
      ..viajeActivo = false
      ..depurarApkPendiente(null)
      ..depurarReiniciarDialogo();
  });

  tearDown(() {
    update
      ..viajeActivo = false
      ..depurarApkPendiente(null)
      ..depurarReiniciarDialogo();
  });

  /// Monta una pantalla con un boton que dispara el aviso y lo pulsa.
  Future<void> disparar(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => update.mostrarSiHaceFalta(context),
              child: const Text('revisar'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('revisar'));
    await tester.pumpAndSettle();
  }

  testWidgets('con viaje activo no muestra el dialogo', (tester) async {
    update
      ..depurarApkPendiente('https://example.com/static/app_latest.apk')
      ..viajeActivo = true;

    await disparar(tester);

    expect(find.text('Actualización requerida'), findsNothing);
    // Sigue pendiente para cuando termine el viaje.
    expect(update.hayActualizacionPendiente, isTrue);
  });

  testWidgets('sin viaje el dialogo es bloqueante', (tester) async {
    update
      ..depurarApkPendiente('https://example.com/static/app_latest.apk')
      ..viajeActivo = false;

    await disparar(tester);

    expect(find.text('Actualización requerida'), findsOneWidget);
    expect(find.text('Actualizar ahora'), findsOneWidget);

    // El boton atras del sistema no lo puede cerrar (PopScope canPop: false).
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Actualización requerida'), findsOneWidget);
  });

  testWidgets('cuando el backend deja de pedirla el cartel se cierra solo',
      (tester) async {
    update
      ..depurarApkPendiente('https://example.com/static/app_latest.apk')
      ..viajeActivo = false;

    await disparar(tester);
    expect(find.text('Actualización requerida'), findsOneWidget);

    // El chofer instalo el APK por su cuenta y el backend ya dice "none".
    update.depurarSinActualizacion();
    await tester.pumpAndSettle();

    expect(find.text('Actualización requerida'), findsNothing);
    expect(update.hayActualizacionPendiente, isFalse);
  });
}
