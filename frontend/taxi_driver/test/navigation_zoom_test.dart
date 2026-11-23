import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_driver/api_config.dart';
import 'package:taxi_driver/services/camara_libre.dart';

/// El zoom del chofer debe ser 19 siempre: con viaje, sin viaje, al acelerar y
/// estando lejos del objetivo. Fija el requisito de la publicacion en Play para
/// que un cambio futuro en la tabla de zooms no lo revierta sin que falle el test.
void main() {
  group('zoom de la app del chofer', () {
    test('accepted, arrived e in_progress usan zoom 19', () {
      expect(ApiConfig.zoomParaFase(status: 'accepted'), 19.0);
      expect(ApiConfig.zoomParaFase(status: 'driver_on_the_way'), 19.0);
      expect(ApiConfig.zoomParaFase(status: 'driver_arrived'), 19.0);
      expect(ApiConfig.zoomParaFase(status: 'in_progress'), 19.0);
    });

    test('sin viaje tambien se ve la calle a zoom 19', () {
      expect(ApiConfig.zoomParaFase(), ApiConfig.zoomIdle);
      expect(ApiConfig.zoomIdle, 19.0);
      expect(ApiConfig.defaultZoom, 19.0);
    });

    test('el techo, el suelo y el recentrar son 19', () {
      expect(ApiConfig.zoomTechoNavegacion, 19.0);
      expect(ApiConfig.zoomSueloNavegacion, 19.0);
      expect(ApiConfig.zoomRecentrar, 19.0);
      expect(ApiConfig.maxZoom, greaterThanOrEqualTo(19));
    });

    test('ni la velocidad ni la distancia alejan el mapa', () {
      for (final v in [0.0, 5.0, 30.0, 80.0]) {
        expect(CamaraLibre.zoomParaVelocidad(v), 19.0);
      }
      for (final m in [0.0, 300.0, 2000.0, 50000.0]) {
        expect(ApiConfig.zoomPorDistancia(m), 19.0);
      }
    });
  });
}
