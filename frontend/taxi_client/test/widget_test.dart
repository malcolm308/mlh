import 'package:flutter_test/flutter_test.dart';

import 'package:taxi_client/main.dart';

void main() {
  testWidgets('App de cliente muestra pantalla de login',
      (WidgetTester tester) async {
    await tester.pumpWidget(const TaxiClientApp());
    await tester.pump();

    expect(find.text('RapiTaxi'), findsOneWidget);
    expect(find.text('App de cliente'), findsOneWidget);
    expect(find.text('Iniciar sesión'), findsOneWidget);
  });
}