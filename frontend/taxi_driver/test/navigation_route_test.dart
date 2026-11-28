import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/widgets/navigation_map_view.dart';

/// La ruta de recogida y la del destino pueden tener la misma cantidad de
/// puntos. Si el widget solo miraba `length`, no reenviaba el GeoJSON y el mapa
/// se quedaba dibujando la geometria anterior.
void main() {
  const recogida = <LatLng>[
    LatLng(23.1400, -82.3800),
    LatLng(23.1410, -82.3790),
    LatLng(23.1420, -82.3780),
  ];

  test('detecta cambio de ruta aunque el numero de puntos sea igual', () {
    const destino = <LatLng>[
      LatLng(23.1400, -82.3800),
      LatLng(23.1420, -82.3770),
      LatLng(23.1440, -82.3760),
    ];

    expect(
      NavigationMapView.rutaCambioParaPrueba(recogida, destino),
      isTrue,
    );
  });

  test('no reenvia la misma ruta solo porque sea otra lista', () {
    final copia = List<LatLng>.from(recogida);

    expect(
      NavigationMapView.rutaCambioParaPrueba(recogida, copia),
      isFalse,
    );
  });

  test('detecta cambio cuando cambia la longitud', () {
    expect(
      NavigationMapView.rutaCambioParaPrueba(
        recogida,
        recogida.sublist(0, 2),
      ),
      isTrue,
    );
  });
}
