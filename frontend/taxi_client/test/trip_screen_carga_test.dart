import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_client/models/models.dart';
import 'package:taxi_client/screens/trip_screen.dart';
import 'package:taxi_client/services/api_service.dart';

/// Antes, si el primer `GET /trips/{id}` fallaba, la pantalla se quedaba con
/// un spinner eterno: `_error` se guardaba pero solo se pintaba dentro del
/// panel de detalles, al que nunca se llegaba porque `_trip` seguía a null.
class _ApiQueFalla extends ApiService {
  int llamadas = 0;

  @override
  Future<ClientTrip> getTrip(String tripId) async {
    llamadas++;
    throw Exception('HTTP 500');
  }
}

void main() {
  testWidgets('un fallo al cargar muestra error y permite reintentar',
      (tester) async {
    final api = _ApiQueFalla();

    await tester.pumpWidget(
      MaterialApp(
        home: TripScreen(
          api: api,
          clientId: 'cliente-1',
          tripId: 'viaje-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No se pudo cargar el viaje'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    final llamadasAntes = api.llamadas;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();

    expect(api.llamadas, greaterThan(llamadasAntes));
  });
}
