import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/widgets/navigation_map_view.dart';

/// El chevron del chofer creció un 20 % y lleva un disco blanco de fondo que
/// lo contiene. Se comprueba sobre la geometria real que se envia a MapLibre.
const _pos = LatLng(23.14, -82.36);

List<List<double>> _anillo(Map<String, dynamic> geo) {
  final features = geo['features'] as List;
  final geometry = features.first['geometry'] as Map;
  final anillo = (geometry['coordinates'] as List).first as List;
  return anillo.map((p) => (p as List).cast<double>()).toList();
}

/// Coordenadas en metros, con el mismo criterio que el widget.
List<double> _m(List<double> lngLat) => <double>[
  lngLat[0] * 111320.0 * math.cos(_pos.latitude * math.pi / 180.0),
  lngLat[1] * 110574.0,
];

double _dist(List<double> a, List<double> b) =>
    math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));

double _alto(List<List<double>> anillo) {
  final punta = _m(anillo[0]);
  final baseD = _m(anillo[1]);
  final baseI = _m(anillo[3]);
  final centroBase = <double>[
    (baseD[0] + baseI[0]) / 2,
    (baseD[1] + baseI[1]) / 2,
  ];
  return _dist(punta, centroBase);
}

void main() {
  test('el tamaño del chevron es exactamente un 20 % mayor', () {
    expect(NavigationMapView.escalaTamano, closeTo(1.2, 1e-9));

    for (final zoom in <double>[16, 17, 18, 19]) {
      final geo = NavigationMapView.flechaGeoJsonParaPrueba(_pos, 0, zoom);
      final alto = _alto(_anillo(geo));
      final metrosPorPixel =
          156543.03392 *
          math.cos(_pos.latitude * math.pi / 180.0) /
          math.pow(2.0, zoom);
      final altoAnterior = metrosPorPixel * 7.2;
      expect(alto / altoAnterior, closeTo(1.2, 1e-3), reason: 'zoom $zoom');
    }
  });

  test('el disco blanco contiene al chevron con borde en cualquier rumbo', () {
    expect(NavigationMapView.radioFondoPorAlto, greaterThanOrEqualTo(1.10));

    for (final rumbo in <double>[0, 45, 90, 135, 180, 270]) {
      final disco = _anillo(
        NavigationMapView.discoFondoGeoJsonParaPrueba(_pos, 19),
      );
      final centro = _m(<double>[_pos.longitude, _pos.latitude]);
      final radio = _dist(_m(disco.first), centro);

      final borde = _anillo(
        NavigationMapView.flechaGeoJsonParaPrueba(
          _pos,
          rumbo,
          19,
          escala: 1.45,
        ),
      );
      for (final vertice in borde) {
        expect(
          _dist(_m(vertice), centro),
          lessThanOrEqualTo(radio * 1.001),
          reason: 'rumbo $rumbo',
        );
      }
    }
  });
}
