import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/config.dart';
import 'package:taxi_driver/services/navigation_mode_service.dart';

/// Posicion del conductor que NO es el punto fijo por defecto.
///
/// Importa: [AppConfig.defaultDriverLocation] esta en el centro de La Habana,
/// asi que una asercion que compare con el tambien pasaria aunque el servicio
/// ignorase la posicion sembrada.
const _posReal = LatLng(23.1412, -82.3564);

/// Monta un widget que aporta un [TickerProvider] real y devuelve el servicio.
///
/// [NavigationModeService.activar] arranca su ticker y se engancha a las medidas
/// de frame del scheduler. Un `TickerProvider` a pelo no basta: hace falta un
/// arbol montado para que el binding exista y para que corran frames.
Future<NavigationModeService> _servicio(WidgetTester tester) async {
  late NavigationModeService nav;
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: _HostTicker(
        onListo: (TickerProvider vsync) =>
            nav = NavigationModeService(vsync: vsync),
      ),
    ),
  );
  return nav;
}

class _HostTicker extends StatefulWidget {
  final void Function(TickerProvider vsync) onListo;

  const _HostTicker({required this.onListo});

  @override
  State<_HostTicker> createState() => _EstadoHostTicker();
}

class _EstadoHostTicker extends State<_HostTicker>
    with SingleTickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    widget.onListo(this);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  group('activar siembra la posicion del conductor', () {
    testWidgets('sin sembrar arranca en el punto fijo del config',
        (tester) async {
      final nav = await _servicio(tester);

      expect(nav.posicion.latitude,
          closeTo(AppConfig.defaultDriverLocation.latitude, 1e-9));

      nav.dispose();
    });

    testWidgets('al activar usa la posicion pasada y no el punto fijo',
        (tester) async {
      final nav = await _servicio(tester);

      nav.activar('accepted', posicionConocida: _posReal);

      // Este es el fallo corregido: al aceptar un viaje el mapa y el marcador
      // del vehiculo saltaban al centro de La Habana, y desde ahi la flecha
      // parecia haber desaparecido.
      expect(nav.posicion.latitude, closeTo(_posReal.latitude, 1e-9));
      expect(nav.posicion.longitude, closeTo(_posReal.longitude, 1e-9));

      nav.dispose();
    });

    testWidgets('la posicion que se dibuja es exactamente la sembrada',
        (tester) async {
      final nav = await _servicio(tester);

      nav.activar('in_progress', posicionConocida: _posReal);

      // Lo que pinta el mapa sale de aqui, asi que tiene que coincidir.
      expect(nav.posicion, _posReal);
      nav.dispose();
    });

    testWidgets('un cambio de fase sin sembrar no pierde la posicion',
        (tester) async {
      final nav = await _servicio(tester);

      nav.activar('accepted', posicionConocida: _posReal);
      // Cambio de fase sin pasar posicion: no se debe volver al punto fijo.
      nav.activar('in_progress');

      expect(nav.posicion, _posReal);
      nav.dispose();
    });

    test('la posicion por defecto NO es la del conductor', () {
      // Guarda contra una regresion silenciosa: si alguien cambiara el default
      // por la posicion del conductor, este test lo diria.
      expect(_posReal.latitude,
          isNot(closeTo(AppConfig.defaultDriverLocation.latitude, 0.001)));
    });
  });

  group('activar sin viaje', () {
    testWidgets('con fase nula apaga el modo', (tester) async {
      final nav = await _servicio(tester);

      nav.activar('accepted', posicionConocida: _posReal);
      nav.activar(null, posicionConocida: _posReal);

      // Sin viaje el mapa lo lleva `NavCamera`, no el servicio.
      expect(nav.debeSeguir, isFalse);
      nav.dispose();
    });
  });
}