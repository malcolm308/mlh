import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taxi_client/main.dart';

void main() {
  testWidgets('App de cliente muestra pantalla de login',
      (WidgetTester tester) async {
    await tester.pumpWidget(const TaxiClientApp());
    await tester.pump();

    // El titulo "RapiTaxi" ya no se pinta: ahora viene impreso en la imagen
    // de fondo del login. Lo que tiene que estar en pantalla son los dos
    // campos y los dos botones, que es lo que el pasajero usa.
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('Iniciar sesión'), findsOneWidget);
    expect(find.text('Registrarse'), findsOneWidget);
  });
}