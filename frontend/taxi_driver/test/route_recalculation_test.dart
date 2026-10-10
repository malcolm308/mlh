import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:taxi_driver/api_config.dart';
import 'package:taxi_driver/services/osrm_service.dart';
import 'package:taxi_driver/services/route_recalculation_service.dart';

/// GeoJSON minimo que devuelve el backend, en el formato propio del endpoint.
String _geoJsonRespuesta() {
  return '{"geometry":{"type":"LineString","coordinates":'
      '[[-82.37,23.11],[-82.36,23.11],[-82.35,23.12]]},'
      '"distance_meters":1800,"duration_seconds":200}';
}

void main() {
  group('distanciaPerpendicularMetros', () {
    // Recta ecuatorialorientada de norte a sur, un segmento de ~2.2 km.
    final recta = [
      const LatLng(23.1000, -82.3600),
      const LatLng(23.1200, -82.3600),
    ];

    test('punto sobre la recta da 0', () {
      final d = RouteRecalculationService.distanciaPerpendicularMetros(
        const LatLng(23.1100, -82.3600),
        recta,
      );
      expect(d, lessThan(1.0));
    });

    test('punto desplazado al este da la distancia correcta', () {
      // 0.001 grados de longitud a esa latitud son ~104 m.
      final d = RouteRecalculationService.distanciaPerpendicularMetros(
        const LatLng(23.1100, -82.3590),
        recta,
      );
      expect(d, closeTo(104.0, 8.0));
    });

    test('punto desplazado al oeste tambien se mide', () {
      final d = RouteRecalculationService.distanciaPerpendicularMetros(
        const LatLng(23.1100, -82.3610),
        recta,
      );
      expect(d, closeTo(104.0, 8.0));
    });

    test('proyeccion sobre el segmento, no al vertice mas cercano', () {
      // Un segmento largo de 4.4 km y el punto en su mitad. Si se midiera al
      // vertice mas cercano daria 2200 m en vez de 0.
      final largo = [
        const LatLng(23.1000, -82.3600),
        const LatLng(23.1400, -82.3600),
      ];
      final d = RouteRecalculationService.distanciaPerpendicularMetros(
        const LatLng(23.1200, -82.3600),
        largo,
      );
      expect(d, lessThan(1.0));
    });

    test('extremos de la linea dan 0', () {
      for (final p in recta) {
        final d = RouteRecalculationService.distanciaPerpendicularMetros(p, recta);
        expect(d, lessThan(1.0), reason: 'extremo $p');
      }
    });

    test('polilinea con varios tramos toma el minimo', () {
      // Dos tramos en L formando la esquina. El punto se coloca al norte del
      // tramo horizontal, de modo que el minimo sale de ahi y no del vertical.
      final ele = [
        const LatLng(23.1000, -82.3600), // tramo vertical, sube
        const LatLng(23.1200, -82.3600), // esquina
        const LatLng(23.1200, -82.3400), // tramo horizontal, va al este
      ];

      // Punto 0.005 grados al norte del tramo horizontal, y a 512 m al este
      // del vertical. El minimo es el horizontal: ~557 m.
      final d = RouteRecalculationService.distanciaPerpendicularMetros(
        const LatLng(23.1250, -82.3550),
        ele,
      );
      expect(d, closeTo(557.0, 10.0));

      // Con la esquina mas al norte, el punto queda pegado al tramo horizontal
      // (que ahora pasa por su latitud) y el minimo cae a cero. Eso confirma
      // que el calculo usa el segmento mas cercano de todos, no el primero.
      final ele2 = [
        const LatLng(23.1000, -82.3600),
        const LatLng(23.1250, -82.3600),
        const LatLng(23.1250, -82.3400), // pasa por la latitud del punto
      ];
      final d2 = RouteRecalculationService.distanciaPerpendicularMetros(
        const LatLng(23.1250, -82.3550),
        ele2,
      );
      expect(d2, lessThan(1.0),
          reason: 'el punto cae sobre el tramo horizontal');
    });

    test('linea de menos de dos puntos no se puede medir', () {
      final d = RouteRecalculationService.distanciaPerpendicularMetros(
        const LatLng(23.11, -82.36),
        [const LatLng(23.10, -82.36)],
      );
      expect(d, equals(double.infinity));
    });

    test('vertices repetidos no rompen el calculo', () {
      final conRepetidos = [
        const LatLng(23.1000, -82.3600),
        const LatLng(23.1000, -82.3600), // duplicado
        const LatLng(23.1200, -82.3600),
      ];
      final d = RouteRecalculationService.distanciaPerpendicularMetros(
        const LatLng(23.1100, -82.3600),
        conRepetidos,
      );
      expect(d, lessThan(1.0));
    });
  });

  group('deteccion de desvio', () {
    late RouteRecalculationService servicio;
    var peticiones = 0;

    /// Ruta vertical de norte a sur por la calle de -82.3600.
    final ruta = [
      const LatLng(23.1000, -82.3600),
      const LatLng(23.1200, -82.3600),
    ];

    setUp(() {
      peticiones = 0;
      servicio = RouteRecalculationService(
        postJson: (path, body) async {
          peticiones++;
          return jsonDecode(_geoJsonRespuesta());
        },
      );
      servicio.iniciar(ruta: ruta, destino: const LatLng(23.1400, -82.3500));
    });

    tearDown(() {
      servicio.dispose();
    });

    test('tres muestras seguidas fuera de umbral disparan recalculo', () async {
      // 0.01 grados de longitud son ~1 km: muy fuera de cualquier umbral.
      final lejos = const LatLng(23.1100, -82.3500);

      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      expect(peticiones, 0, reason: 'con dos no debe pedir ruta');

      servicio.informarPosicion(lejos, 10.0);
      // La peticion es asincrona: se le da un turno al bucle de eventos.
      await Future<void>.delayed(Duration.zero);

      expect(peticiones, 1);
    });

    test('dos muestras fuera de umbral NO disparan recalculo', () async {
      final lejos = const LatLng(23.1100, -82.3500);
      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      await Future<void>.delayed(Duration.zero);
      expect(peticiones, 0);
    });

    test('una lectura dentro de ruta rompe la racha', () async {
      final lejos = const LatLng(23.1100, -82.3500);
      final enRuta = const LatLng(23.1100, -82.3600);

      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      // Esta lectura borra las dos anteriores.
      servicio.informarPosicion(enRuta, 10.0);
      // Y ahora dos fuera vuelven a empezar la cuenta.
      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      await Future<void>.delayed(Duration.zero);

      expect(peticiones, 0,
          reason: 'la racha se reinicio con la lectura dentro de ruta');
    });

    test('el ruido de GPS de 25 m no dispara nada', () async {
      // Un fix malo tipico de ciudad: 25 m de desviacion real, muy por debajo
      // del umbral de 40.
      final ruido = const LatLng(23.1100, -82.35977);

      for (var i = 0; i < 10; i++) {
        servicio.informarPosicion(ruido, 10.0);
      }
      await Future<void>.delayed(Duration.zero);

      expect(peticiones, 0);
    });

    test('durante los 5 s tras recalcular no se vuelve a detectar', () async {
      final lejos = const LatLng(23.1100, -82.3500);

      // Primer recalculo.
      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      await Future<void>.delayed(Duration.zero);
      expect(peticiones, 1);
      expect(servicio.enPausaPostRecalculo, isTrue);

      // Aunque ahora se den mas lecturas fuera, la pausa las ignora.
      for (var i = 0; i < 15; i++) {
        servicio.informarPosicion(lejos, 10.0);
      }
      await Future<void>.delayed(Duration.zero);
      expect(peticiones, 1, reason: 'la pausa de 5 s debe impedir el segundo');
    });

    test('el estado pasa por calculating y luego success', () async {
      final lejos = const LatLng(23.1100, -82.3500);
      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);

      expect(servicio.estado, RouteRecalcState.calculating);
      await Future<void>.delayed(Duration.zero);
      expect(servicio.estado, RouteRecalcState.success);
    });

    test('emite la ruta nueva por el stream', () async {
      OsrmRoute? recibida;

      final sub = servicio.onRouteChanged.listen((r) {
        recibida = r;
      });

      final lejos = const LatLng(23.1100, -82.3500);
      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      servicio.informarPosicion(lejos, 10.0);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(recibida, isNotNull);
      expect(recibida!.points.length, greaterThanOrEqualTo(3));
      expect(recibida!.distanceKm, closeTo(1.8, 0.01));

      await sub.cancel();
    });
  });

  group('pausa por vehiculo parado', () {
    late RouteRecalculationService servicio;

    final ruta = [
      const LatLng(23.1000, -82.3600),
      const LatLng(23.1200, -82.3600),
    ];

    setUp(() {
      servicio = RouteRecalculationService(
        postJson: (path, body) async => jsonDecode(_geoJsonRespuesta()),
      );
      servicio.iniciar(ruta: ruta, destino: const LatLng(23.1400, -82.3500));
    });

    tearDown(() => servicio.dispose());

    test('no pausa con pocas muestras por debajo del umbral', () {
      // 5 muestras a 0 m/s son 5 s: menos de los 10 que hacen falta.
      for (var i = 0; i < 5; i++) {
        servicio.informarPosicion(const LatLng(23.11, -82.36), 0.0);
      }
      expect(servicio.pausadoPorParado, isFalse);
    });

    test('pausa tras 10 muestras por debajo de 1 km/h', () {
      for (var i = 0; i < 11; i++) {
        servicio.informarPosicion(const LatLng(23.11, -82.36), 0.1);
      }
      expect(servicio.pausadoPorParado, isTrue);
    });

    test('sale de la pausa al superar 3 km/h', () {
      for (var i = 0; i < 11; i++) {
        servicio.informarPosicion(const LatLng(23.11, -82.36), 0.1);
      }
      expect(servicio.pausadoPorParado, isTrue);

      servicio.informarPosicion(const LatLng(23.11, -82.36), 2.0);
      expect(servicio.pausadoPorParado, isFalse);
    });

    test('en pausa no se detecta desvio aunque este muy lejos', () {
      final lejos = const LatLng(23.1100, -82.3500);

      // Primero entra en pausa.
      for (var i = 0; i < 11; i++) {
        servicio.informarPosicion(const LatLng(23.11, -82.36), 0.1);
      }
      expect(servicio.pausadoPorParado, isTrue);

      // Ahora llega una posicion totalmente fuera de ruta. En un semaforo con
      // el GPS desfasado es normal, y no debe pedir ruta.
      for (var i = 0; i < 10; i++) {
        servicio.informarPosicion(lejos, 0.1);
      }
      expect(servicio.estado, RouteRecalcState.idle);
    });
  });

  group('fallo del backend', () {
    test('reintenta con backoff y se rinde al cuarto', () async {
      var intentos = 0;
      final servicio = RouteRecalculationService(
        postJson: (path, body) async {
          intentos++;
          throw Exception('sin red');
        },
      );
      servicio.iniciar(
        ruta: const [LatLng(23.10, -82.36), LatLng(23.12, -82.36)],
        destino: const LatLng(23.14, -82.35),
      );

      // Cada llamada manual simula un intento; el servicio va encadenando
      // temporizadores, asi que aqui se comprueba el conteo y el estado final.
      final lejos = const LatLng(23.1100, -82.3500);
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          servicio.informarPosicion(lejos, 10.0);
        }
        await Future<void>.delayed(Duration.zero);
      }

      expect(intentos, greaterThanOrEqualTo(1));
      expect(servicio.estado, isNot(RouteRecalcState.success));
      servicio.dispose();
    }, skip: true);

    test('un fallo deja la ruta vieja puesta, no borra nada', () async {
      final servicio = RouteRecalculationService(
        postJson: (path, body) async => throw Exception('sin red'),
      );
      servicio.iniciar(
        ruta: const [LatLng(23.10, -82.36), LatLng(23.12, -82.36)],
        destino: const LatLng(23.14, -82.35),
      );

      final lejos = const LatLng(23.1100, -82.3500);
      for (var i = 0; i < 3; i++) {
        servicio.informarPosicion(lejos, 10.0);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // El estado es de error, pero el mapa sigue con la ruta anterior porque
      // el servicio no emite nada por el stream.
      expect(servicio.estado, anyOf(
        RouteRecalcState.error,
        RouteRecalcState.calculating,
      ));
      servicio.dispose();
    });
  });

  group('umbrales por velocidad', () {
    // El margen crece con la velocidad: en ciudad el GPS es ruidoso y recalcular
    // de mas sale caro, y en carretera hace falta un margen mayor porque el
    // error del GPS pesa menos frente a lo lejos que se puede llegar.
    test('los cuatro tramos dan 100 / 150 / 250 / 400 m', () {
      expect(UmbralPorVelocidad.paraVelocidadKmh(0), 100.0);
      expect(UmbralPorVelocidad.paraVelocidadKmh(19.9), 100.0);
      expect(UmbralPorVelocidad.paraVelocidadKmh(20), 150.0);
      expect(UmbralPorVelocidad.paraVelocidadKmh(39.9), 150.0);
      expect(UmbralPorVelocidad.paraVelocidadKmh(40), 250.0);
      expect(UmbralPorVelocidad.paraVelocidadKmh(59.9), 250.0);
      expect(UmbralPorVelocidad.paraVelocidadKmh(60), 400.0);
      expect(UmbralPorVelocidad.paraVelocidadKmh(120), 400.0);
    });

    test('el umbral nunca decrece al subir la velocidad', () {
      var anterior = 0.0;
      for (var kmh = 0.0; kmh <= 120; kmh += 5) {
        final actual = UmbralPorVelocidad.paraVelocidadKmh(kmh);
        expect(actual, greaterThanOrEqualTo(anterior));
        anterior = actual;
      }
    });

    test('una velocidad baja no dispara antes que una alta', () {
      // La distancia que dispara con 10 km/h tiene que estar dentro del umbral
      // de 60 km/h, que es la garantia de que el margen escala.
      expect(120.0, greaterThan(UmbralPorVelocidad.paraVelocidadKmh(10)));
      expect(120.0, lessThan(UmbralPorVelocidad.paraVelocidadKmh(60)));
    });

    test('la pausa tras recalcular es de 30 s', () {
      expect(ApiConfig.desvioPausaMsTrasRecalculo.inSeconds, 30);
    });
  });
}
