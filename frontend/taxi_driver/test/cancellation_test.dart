import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taxi_driver/services/cancellation_service.dart';
import 'package:taxi_driver/widgets/cancel_reason_dialog.dart';
import 'package:taxi_driver/widgets/cancel_trip_dialog.dart';

/// Fecha fija para que los tests no dependan de la hora de la maquina.
final _hoy = DateTime(2026, 10, 2, 14, 30);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('claveDe fecha', () {
    test('incluye la fecha con dos digitos', () {
      expect(CancellationService.claveDe(DateTime(2026, 1, 5, 9, 0)),
          'chofer_cancelaciones_2026-01-05');
    });

    test('dos dias distintos dan claves distintas', () {
      final a = CancellationService.claveDe(DateTime(2026, 10, 2));
      final b = CancellationService.claveDe(DateTime(2026, 10, 3));
      expect(a, isNot(b));
    });
  });

  group('limite diario de tres', () {
    late List<Map<String, dynamic>> envios;

    CancellationService crear() {
      envios = [];
      return CancellationService(
        httpPost: (ruta, cuerpo) async {
          envios.add({'ruta': ruta, ...cuerpo});
          return {'ok': true};
        },
        httpGet: (ruta) async => null,
      );
    }

    testWidgets('empieza con las tres disponibles', (tester) async {
      final s = crear();
      await s.cargar(driverId: 'c1', hoy: _hoy);
      expect(s.restantes, 3);
      expect(s.limiteAlcanzado, isFalse);
      s.dispose();
    });

    testWidgets('cada cancelar descuenta una y solo al tercero falla',
        (tester) async {
      final s = crear();
      await s.cargar(driverId: 'c1', hoy: _hoy);

      for (var i = 0; i < 3; i++) {
        final r = await s.cancelarViajeAceptado(
          tripId: 't$i',
          driverId: 'c1',
          hoy: _hoy,
        );
        expect(r, ResultadoCancelacion.ok, reason: 'cancelacion $i');
      }
      expect(s.restantes, 0);
      expect(s.limiteAlcanzado, isTrue);
      s.dispose();
    });

    testWidgets('un cuarto intento se rechaza sin llamar al backend',
        (tester) async {
      final s = crear();
      await s.cargar(driverId: 'c1', hoy: _hoy);
      for (var i = 0; i < 3; i++) {
        await s.cancelarViajeAceptado(tripId: 't$i', driverId: 'c1', hoy: _hoy);
      }
      final enviosAntes = envios.length;

      final r = await s.cancelarViajeAceptado(
        tripId: 't3',
        driverId: 'c1',
        hoy: _hoy,
      );

      expect(r, ResultadoCancelacion.limiteAlcanzado);
      expect(envios.length, enviosAntes,
          reason: 'no debe gastar una peticion si ya no puede');
      s.dispose();
    });

    testWidgets('el contador NO se descuenta si el backend falla',
        (tester) async {
      // Un fallo de red no debe costar una de las tres oportunidades.
      final s = CancellationService(
        httpPost: (ruta, cuerpo) async => throw Exception('sin red'),
        httpGet: (ruta) async => null,
      );
      await s.cargar(driverId: 'c1', hoy: _hoy);

      final r = await s.cancelarViajeAceptado(
        tripId: 't1',
        driverId: 'c1',
        hoy: _hoy,
      );

      expect(r, ResultadoCancelacion.error);
      expect(s.restantes, 3, reason: 'no debe contar un fallo');
      s.dispose();
    });

    testWidgets('el backend manda si dice que ya no quedan',
        (tester) async {
      // Guarda contra un reloj del movil desajustado: si el backend tiene mas
      // cuenta, el movil se sincroniza hacia abajo en vez de dejar cancelar.
      final s = CancellationService(
        httpPost: (ruta, cuerpo) async => {'ok': true},
        httpGet: (ruta) async => {'restantes': 0},
      );
      await s.cargar(driverId: 'c1', hoy: _hoy);
      expect(s.limiteAlcanzado, isTrue);
      s.dispose();
    });

    testWidgets('el backend puede parar una cancelacion en el momento',
        (tester) async {
      // El backend responde con codigo de limite aunque el movil creyera que
      // queden. Gana el backend y el boton se deshabilita.
      final s = CancellationService(
        httpPost: (ruta, cuerpo) async => {'code': 'limite_alcanzado'},
        httpGet: (ruta) async => null,
      );
      await s.cargar(driverId: 'c1', hoy: _hoy);

      final r = await s.cancelarViajeAceptado(
        tripId: 't1',
        driverId: 'c1',
        hoy: _hoy,
      );

      expect(r, ResultadoCancelacion.limiteAlcanzado);
      expect(s.limiteAlcanzado, isTrue);
      s.dispose();
    });
  });

  group('el contador se reinicia al cambiar de dia', () {
    testWidgets('las usadas de ayer no cuentan hoy', (tester) async {
      SharedPreferences.setMockInitialValues({
        // Se guardan tres de ayer a proposito: hoy debe empezar limpio.
        'chofer_cancelaciones_2026-10-01': 3,
      });
      final s = CancellationService(
        httpPost: (ruta, cuerpo) async => {'ok': true},
        httpGet: (ruta) async => null,
      );

      await s.cargar(driverId: 'c1', hoy: _hoy);

      expect(s.restantes, 3,
          reason: 'el limite es por dia natural, no acumulado');
      expect(s.limiteAlcanzado, isFalse);
      s.dispose();
    });

    testWidgets('las usadas de hoy siguen contando', (tester) async {
      SharedPreferences.setMockInitialValues({
        'chofer_cancelaciones_2026-10-02': 2,
      });
      final s = CancellationService(
        httpPost: (ruta, cuerpo) async => {'ok': true},
        httpGet: (ruta) async => null,
      );

      await s.cargar(driverId: 'c1', hoy: _hoy);

      expect(s.restantes, 1);
      expect(s.limiteAlcanzado, isFalse);
      s.dispose();
    });

    testWidgets('sobrevive a cerrar y reabrir la app', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('chofer_cancelaciones_2026-10-02', 2);

      // Servicio nuevo, como si la app se hubiera cerrado y abierto.
      final s = CancellationService(
        httpPost: (ruta, cuerpo) async => {'ok': true},
        httpGet: (ruta) async => null,
      );
      await s.cargar(driverId: 'c1', hoy: _hoy);

      expect(s.restantes, 1);
      s.dispose();
    });
  });

  group('estados vivos del viaje', () {
    test('los tres estados en curso estan dentro', () {
      expect(estadosViajeVivos, contains('accepted'));
      expect(estadosViajeVivos, contains('driver_arrived'));
      expect(estadosViajeVivos, contains('in_progress'));
    });

    test('cancelado y completado NO son estados vivos', () {
      expect(estadosViajeVivos, isNot(contains('cancelled')));
      expect(estadosViajeVivos, isNot(contains('completed')));
      expect(estadosViajeVivos, isNot(contains('expired')));
    });
  });

  group('texto del boton', () {
    testWidgets('muestra las que quedan', (tester) async {
      final s = CancellationService(
        httpPost: (ruta, cuerpo) async => {'ok': true},
        httpGet: (ruta) async => null,
      );
      await s.cargar(driverId: 'c1', hoy: _hoy);
      expect(s.etiquetaBoton, contains('3/3'));
      expect(s.etiquetaBoton, isNot(contains('Límite alcanzado')));
      s.dispose();
    });

    testWidgets('avisa cuando ya no queda ninguna', (tester) async {
      SharedPreferences.setMockInitialValues({
        'chofer_cancelaciones_2026-10-02': 3,
      });
      final s = CancellationService(
        httpPost: (ruta, cuerpo) async => {'ok': true},
        httpGet: (ruta) async => null,
      );
      await s.cargar(driverId: 'c1', hoy: _hoy);
      expect(s.etiquetaBoton, contains('Límite alcanzado'));
      expect(s.puedeCancelar, isFalse);
      s.dispose();
    });
  });

  group('dialogo de confirmacion', () {
    testWidgets('no cancela si se pulsa "No, continuar viaje"',
        (tester) async {
      bool? resultado;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                resultado = await CancelTripDialog.mostrar(context, restantes: 3);
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('¿Cancelar este viaje?'), findsOneWidget);

      await tester.tap(find.text('No, continuar viaje'));
      await tester.pumpAndSettle();

      expect(resultado, isFalse, reason: 'volver al viaje no es cancelar');
    });

    testWidgets('confirma con "Sí, cancelar"', (tester) async {
      bool? resultado;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                resultado =
                    await CancelTripDialog.mostrar(context, restantes: 2);
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sí, cancelar'));
      await tester.pumpAndSettle();

      expect(resultado, isTrue);
    });

testWidgets('el aviso menciona las que quedan', (tester) async {
      // El texto cambia a singular cuando solo queda una, para que no suene a
      // error: "te queda 1" y no "te quedan 1".
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CancelTripDialog(restantes: 1),
          ),
        ),
      );
      // El texto va partido en dos lineas en el codigo, asi que se comprueba
      // por??: la cadena completa no existe como un solo widget de texto.
      expect(find.textContaining('te queda 1'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CancelTripDialog(restantes: 2),
          ),
        ),
      );
      expect(find.textContaining('te quedan 2'), findsOneWidget);
    });

    testWidgets('cerrar con el boton de atras NO cuenta como cancelar',
        (tester) async {
      bool? resultado = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                resultado = await CancelTripDialog.mostrar(context, restantes: 3);
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();

      // Escape cierra el dialogo.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(resultado, isFalse, reason: 'darse atras no es confirmar');
    });
  });

  group('dialogo de motivo', () {
    testWidgets('exige un motivo antes de confirmar', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CancelReasonDialog())),
      );

      // Sin motivo, el boton esta deshabilitado.
      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmar'),
      );
      expect(btn.onPressed, isNull);

      await tester.tap(find.text('Pasajero no aparece'));
      await tester.pumpAndSettle();

      final btn2 = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmar'),
      );
      expect(btn2.onPressed, isNotNull);
    });

    testWidgets('"Otro" exige texto', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CancelReasonDialog())),
      );
      await tester.tap(find.text('Otro'));
      await tester.pumpAndSettle();

      var btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmar'),
      );
      expect(btn.onPressed, isNull, reason: 'con el campo vacio no puede');

      await tester.enterText(find.byType(TextField), 'se rompió el carro');
      await tester.pumpAndSettle();

      btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmar'),
      );
      expect(btn.onPressed, isNotNull);
    });

    testWidgets('se puede cancelar sin dar motivo', (tester) async {
      String? resultado = 'sin tocar';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                resultado = await CancelReasonDialog.mostrar(context);
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar sin motivo'));
      await tester.pumpAndSettle();

      expect(resultado, isNull);
    });

    test('los motivos del enum son los que se pintan', () {
      expect(MotivoCancelacion.values.length, 5);
      expect(MotivoCancelacion.values.first.etiqueta, 'Pasajero no aparece');
      expect(MotivoCancelacion.values.last.etiqueta, 'Otro');
    });
  });
}