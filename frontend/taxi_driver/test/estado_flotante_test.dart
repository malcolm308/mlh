import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taxi_driver/models/estado_red.dart';
import 'package:taxi_driver/services/conectividad_service.dart';
import 'package:taxi_driver/services/estado_flotante_controller.dart';
import 'package:taxi_driver/widgets/estado_flotante/estado_flotante_overlay.dart';
import 'package:taxi_driver/widgets/estado_flotante/widget_red.dart';
import 'package:taxi_driver/widgets/estado_flotante/widget_saldo.dart';

/// Los widgets flotantes del chofer tienen dos reglas que no pueden romperse:
/// el saldo se esconde con viaje activo y el aviso de red solo aparece cuando
/// hay un problema (señal débil o sin señal).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('EstadoFlotanteController', () {
    test('el saldo se oculta con viaje activo y la red no', () {
      final c = EstadoFlotanteController();
      expect(c.saldoVisible, isTrue);
      expect(c.redVisible, isFalse);

      c.sincronizarEnViaje(true);
      expect(c.saldoVisible, isFalse);

      c.actualizarRed(EstadoRed.debil);
      expect(c.redVisible, isTrue);

      c.actualizarRed(EstadoRed.buena);
      expect(c.redVisible, isFalse);
    });

    test('el arco mide lo que queda de la última recarga', () {
      final c = EstadoFlotanteController();
      // Referencia por defecto: 5.00 CUP.
      c.actualizarSaldo(2.50);
      expect(c.progresoSaldo, closeTo(0.5, 1e-9));

      // Recarga: la referencia sube y el arco vuelve a llenarse.
      c.actualizarSaldo(10.0);
      expect(c.referenciaRecarga, 10.0);
      expect(c.progresoSaldo, 1.0);

      // Gasto: la referencia se conserva, el arco baja.
      c.actualizarSaldo(2.0);
      expect(c.referenciaRecarga, 10.0);
      expect(c.progresoSaldo, closeTo(0.2, 1e-9));

      // Sin saldo no se pinta arco (evita división por cero).
      c.actualizarSaldo(0);
      expect(c.progresoSaldo, 0.0);
    });

    test('la referencia de la recarga se recupera del teléfono', () async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'estado_flotante_referencia_recarga': 20.0},
      );
      final c = EstadoFlotanteController();
      await c.cargar();
      expect(c.referenciaRecarga, 20.0);

      c.actualizarSaldo(5.0);
      expect(c.progresoSaldo, closeTo(0.25, 1e-9));
    });
  });

  group('ConectividadService', () {
    test('sin interfaz no gasta sonda y marca sin señal', () async {
      var sondas = 0;
      final s = ConectividadService(
        hayInterfaz: () async => false,
        sonda: () async {
          sondas++;
          return true;
        },
      );

      await s.comprobar();
      expect(s.estado, EstadoRed.sinSenal);
      // Modo avión: no tiene sentido lanzar un HTTP que va a fallar.
      expect(sondas, 0);
    });

    test('un fallo es señal débil; el segundo, sin señal', () async {
      final s = ConectividadService(
        hayInterfaz: () async => true,
        sonda: () async => false,
      );

      await s.comprobar();
      expect(s.estado, EstadoRed.debil);

      await s.comprobar();
      expect(s.estado, EstadoRed.sinSenal);
    });

    test('el backend responde: red buena', () async {
      final s = ConectividadService(
        hayInterfaz: () async => true,
        sonda: () async => true,
      );

      await s.comprobar();
      expect(s.estado, EstadoRed.buena);
    });
  });

  group('WidgetSaldo', () {
    testWidgets('un saldo largo no desborda la tarjeta', (tester) async {
      // El saldo real de las cuentas de prueba llega a seis cifras con
      // decimales. Antes partía «CUP» a otra línea y empujaba el texto fuera
      // de la tarjeta; el FittedBox debe reducirlo sin desbordar.
      await tester.pumpWidget(host(Center(
        child: WidgetSaldo(
          saldo: 155371.65,
          progreso: 1,
          actualizando: false,
          onRefrescar: () {},
        ),
      )));

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('155371.65', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('CUP', findRichText: true), findsOneWidget);
    });
  });

  group('WidgetRed', () {
    testWidgets('sin señal: aviso, parpadeo y botón REINTENTAR',
        (tester) async {
      var tocado = 0;
      await tester.pumpWidget(host(WidgetRed(
        estado: EstadoRed.sinSenal,
        onReintentar: () => tocado++,
      )));

      expect(find.text('SIN SEÑAL MÓVIL'), findsOneWidget);
      expect(
        find.textContaining('No recibirás solicitudes'),
        findsOneWidget,
      );

      // Parpadea: la opacidad cambia entre frames.
      final primera = tester
          .widget<Opacity>(find.byType(Opacity).first)
          .opacity;
      await tester.pump(const Duration(milliseconds: 430));
      final segunda = tester
          .widget<Opacity>(find.byType(Opacity).first)
          .opacity;
      expect(segunda, isNot(closeTo(primera, 1e-3)));

      await tester.tap(find.text('REINTENTAR'));
      expect(tocado, 1);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('señal débil: fondo amarillo, parpadeo suave y sin botón',
        (tester) async {
      await tester.pumpWidget(
        host(const WidgetRed(estado: EstadoRed.debil)),
      );

      expect(find.text('SEÑAL DÉBIL'), findsOneWidget);
      expect(find.text('REINTENTAR'), findsNothing);
      expect(find.byType(Opacity), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text('SEÑAL DÉBIL'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('señal buena: no se pinta nada', (tester) async {
      await tester.pumpWidget(
        host(const WidgetRed(estado: EstadoRed.buena)),
      );
      expect(find.text('SEÑAL DÉBIL'), findsNothing);
      expect(find.text('SIN SEÑAL MÓVIL'), findsNothing);
    });
  });

  group('EstadoFlotanteOverlay', () {
    testWidgets('muestra saldo y red, y responde a los botones',
        (tester) async {
      final c = EstadoFlotanteController()
        ..actualizarSaldo(2.94)
        ..actualizarRed(EstadoRed.debil);
      var refrescos = 0;
      var reintentos = 0;

      await tester.pumpWidget(host(SizedBox(
        width: 360,
        height: 720,
        child: Stack(children: [
          EstadoFlotanteOverlay(
            controller: c,
            onRefrescarSaldo: () => refrescos++,
            onReintentarRed: () => reintentos++,
          ),
        ]),
      )));

      expect(find.text('SALDO DISPONIBLE'), findsOneWidget);
      expect(find.text('SEÑAL DÉBIL'), findsOneWidget);

      await tester.tap(find.byTooltip('Refrescar saldo'));
      expect(refrescos, 1);

      // La red débil no ofrece reintentar.
      expect(find.text('REINTENTAR'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('con viaje activo solo queda el aviso de red',
        (tester) async {
      final c = EstadoFlotanteController()
        ..actualizarSaldo(2.94)
        ..actualizarRed(EstadoRed.sinSenal)
        ..sincronizarEnViaje(true);

      await tester.pumpWidget(host(SizedBox(
        width: 360,
        height: 720,
        child: Stack(children: [
          EstadoFlotanteOverlay(
            controller: c,
            onRefrescarSaldo: () {},
            onReintentarRed: () {},
          ),
        ]),
      )));

      expect(find.text('SALDO DISPONIBLE'), findsNothing);
      expect(find.text('SIN SEÑAL MÓVIL'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('con señal buena no queda nada en pantalla', (tester) async {
      final c = EstadoFlotanteController()
        ..actualizarSaldo(2.94)
        ..actualizarRed(EstadoRed.buena)
        ..sincronizarEnViaje(true);

      await tester.pumpWidget(host(SizedBox(
        width: 360,
        height: 720,
        child: Stack(children: [
          EstadoFlotanteOverlay(
            controller: c,
            onRefrescarSaldo: () {},
            onReintentarRed: () {},
          ),
        ]),
      )));

      expect(find.text('SALDO DISPONIBLE'), findsNothing);
      expect(find.text('SIN SEÑAL MÓVIL'), findsNothing);
      expect(find.text('SEÑAL DÉBIL'), findsNothing);
    });
  });
}
