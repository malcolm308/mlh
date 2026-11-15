import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_client/widgets/ui/pill_button.dart';
import 'package:taxi_client/widgets/vehicle_selector_sheet.dart';

/// Regresion del bug visual reportado en el BottomSheet de seleccion de
/// vehiculo: al elegir "Transferencia" aparece el aviso del 10 % y el
/// desglose de la campana, el contenido crece y el boton "Viajar ahora"
/// quedaba por debajo del borde inferior de la pantalla.
///
/// La hoja debe limitar su alto al 92 % de la pantalla, desplazar el
/// contenido y dejar el boton FUERA del scroll, siempre visible al pie.
void main() {
  VehicleOption vehiculo() => VehicleOption(
        type: 'basico',
        price: 1200,
        priceTransferencia: 1320,
        precioOriginal: 1200,
        campanaPromocional: true,
        saldoPromocionalUsado: 1000,
        montoRestante: 200,
        montoRestanteTransferencia: 320,
        bonoChoferCampana: 1000,
        iconPath: 'assets/icons/basico_lada.png',
        displayName: 'Basico',
      );

  Widget hoja({
    required String metodo,
    required VoidCallback onConfirm,
    double walletBalance = 100,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: VehicleSelectorSheet(
            pickupAddress: 'Calle 23 #456, Vedado',
            dropoffAddress: 'Aeropuerto Jose Marti, Terminal 3',
            distanceKm: 18.4,
            durationMin: 32,
            etaText: '32 min',
            paymentMethod: metodo,
            onPaymentMethodChanged: (_) {},
            walletBalance: walletBalance,
            promoBalance: 1000,
            promoActive: true,
            vehicles: [vehiculo()],
            selectedIndex: 0,
            numPasajes: 2,
            equipaje: true,
            mascota: false,
            onPasajerosChanged: (_) {},
            onEquipajeChanged: (_) {},
            onMascotaChanged: (_) {},
            onVehicleSelected: (_) {},
            onConfirmTrip: onConfirm,
          ),
        ),
      ),
    );
  }

  /// Deja la ventana como un movil pequeno (360 x 640 logicos), que es donde
  /// se reporto el boton cortado.
  void pantallaPequena(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('con Transferencia el boton Viajar ahora queda visible al pie',
      (tester) async {
    pantallaPequena(tester);
    var confirmado = false;

    await tester.pumpWidget(
      hoja(metodo: 'Transferencia', onConfirm: () => confirmado = true),
    );
    await tester.pump();

    // El aviso del recargo esta en pantalla: es el caso que empujaba el boton
    // fuera del area visible.
    expect(
      find.textContaining('Al pagar por transferencia'),
      findsOneWidget,
    );

    final boton = find.widgetWithText(PillButton, 'Viajar ahora');
    expect(boton, findsOneWidget);

    final rect = tester.getRect(boton);
    final alto = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(
      rect.bottom,
      lessThanOrEqualTo(alto),
      reason: 'El boton no puede quedar por debajo del borde inferior',
    );

    // Estructural: el boton NO vive dentro del scroll; si alguien lo vuelve a
    // meter ahi, el contenido largo lo empuja fuera de la pantalla otra vez.
    expect(
      find.ancestor(of: boton, matching: find.byType(SingleChildScrollView)),
      findsNothing,
    );

    await tester.tap(boton);
    await tester.pump();
    expect(confirmado, isTrue);
  });

  testWidgets('el desglose cuadra con Transferencia y sin descuento comercial',
      (tester) async {
    pantallaPequena(tester);
    await tester.pumpWidget(
      hoja(metodo: 'Transferencia', onConfirm: () {}),
    );
    await tester.pump();

    expect(find.text('Subtotal'), findsOneWidget);
    expect(find.text('Saldo Promocional'), findsOneWidget);
    expect(find.text('A pagar por Transferencia'), findsOneWidget);

    // Subtotal con el 10 % de recargo: 1200 * 1.10 = 1320.
    expect(find.text('1320 CUP'), findsWidgets);
    // La bolsa cubre 1000 del precio con recargo.
    expect(find.text('-1000 CUP'), findsOneWidget);
    // Y solo quedan 320 de excedente.
    expect(find.text('320 CUP'), findsOneWidget);
  });

  testWidgets('el desglose muestra el descuento referido y sigue cuadrando',
      (tester) async {
    pantallaPequena(tester);
    final conDescuento = VehicleOption(
      type: 'basico',
      price: 1080,
      priceTransferencia: 1188,
      precioOriginal: 1200,
      descuentoAplicado: true,
      descuentoReferidoAplicado: true,
      descuentoPorcentaje: 0.10,
      campanaPromocional: true,
      saldoPromocionalUsado: 500,
      saldoPromocionalUsadoTransferencia: 500,
      montoRestante: 580,
      montoRestanteTransferencia: 688,
      bonoChoferCampana: 500,
      iconPath: 'assets/icons/basico_lada.png',
      displayName: 'Basico',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: VehicleSelectorSheet(
              pickupAddress: 'Calle 23 #456, Vedado',
              dropoffAddress: 'Aeropuerto Jose Marti, Terminal 3',
              distanceKm: 18.4,
              durationMin: 32,
              etaText: '32 min',
              paymentMethod: 'Transferencia',
              onPaymentMethodChanged: (_) {},
              walletBalance: 100,
              promoBalance: 500,
              promoActive: true,
              vehicles: [conDescuento],
              selectedIndex: 0,
              numPasajes: 1,
              equipaje: false,
              mascota: false,
              onPasajerosChanged: (_) {},
              onEquipajeChanged: (_) {},
              onMascotaChanged: (_) {},
              onVehicleSelected: (_) {},
              onConfirmTrip: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Subtotal'), findsOneWidget);
    expect(find.text('Descuento Referido'), findsOneWidget);
    expect(find.text('Saldo Promocional'), findsOneWidget);
    expect(find.text('A pagar por Transferencia'), findsOneWidget);

    // 1320 de subtotal con recargo - 132 de descuento - 500 de bolsa = 688.
    expect(find.text('1320 CUP'), findsWidgets);
    expect(find.text('-132 CUP'), findsOneWidget);
    expect(find.text('-500 CUP'), findsOneWidget);
    expect(find.text('688 CUP'), findsOneWidget);
  });

  testWidgets('con Billetera sin saldo el boton sigue visible y deshabilitado',
      (tester) async {
    pantallaPequena(tester);
    var confirmado = false;

    await tester.pumpWidget(
      hoja(
        metodo: 'Billetera',
        walletBalance: 50,
        onConfirm: () => confirmado = true,
      ),
    );
    await tester.pump();

    expect(find.textContaining('Saldo insuficiente'), findsOneWidget);

    final boton = find.widgetWithText(PillButton, 'Viajar ahora');
    final rect = tester.getRect(boton);
    final alto = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(rect.bottom, lessThanOrEqualTo(alto));

    await tester.tap(boton);
    await tester.pump();
    expect(confirmado, isFalse);
  });
}
