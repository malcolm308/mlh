import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taxi_driver/main.dart';

void main() {
  testWidgets('App de chofer muestra pantalla de login',
      (WidgetTester tester) async {
    await tester.pumpWidget(const TaxiDriverApp());
    await tester.pump();

    // El titulo "RapiTaxi Chofer" ya no se pinta: ahora viene impreso en la
    // imagen de fondo del login. Lo que tiene que estar en pantalla son los
    // dos campos y los dos botones, que es lo que el chofer usa.
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('Iniciar sesión'), findsOneWidget);
    expect(find.text('Registrarse'), findsOneWidget);
  });
}