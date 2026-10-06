import 'package:flutter_test/flutter_test.dart';

import 'package:taxi_driver/main.dart';

void main() {
  testWidgets('App de chofer muestra pantalla de login',
      (WidgetTester tester) async {
    await tester.pumpWidget(const TaxiDriverApp());
    await tester.pump();

    expect(find.text('RapiTaxi Chofer'), findsOneWidget);
    expect(find.text('Iniciar sesión'), findsOneWidget);
  });
}