import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_driver/services/heading_filter.dart';

void main() {
  group('Normalizacion de angulos', () {
    test('normalizarGrados mete en [0, 360)', () {
      expect(normalizarGrados(-10), closeTo(350, 1e-9));
      expect(normalizarGrados(370), closeTo(10, 1e-9));
      expect(normalizarGrados(0), closeTo(0, 1e-9));
      expect(normalizarGrados(720), closeTo(0, 1e-9));
      expect(normalizarGrados(-370), closeTo(350, 1e-9));
    });

    test('deltaCorto toma siempre el camino angular mas corto', () {
      // El caso critico: de 350 a 10 son +20 grados, no -340.
      expect(deltaCorto(350, 10), closeTo(20, 1e-9));
      expect(deltaCorto(10, 350), closeTo(-20, 1e-9));
      expect(deltaCorto(0, 180), closeTo(180, 1e-9));
      expect(deltaCorto(350, 190), closeTo(-160, 1e-9));
      expect(deltaCorto(90, 90), closeTo(0, 1e-9));
    });
  });

  group('Media circular', () {
    // Este es EL test que hay que pasar: el caso en el que la media aritmetica
    // falla y da justo el rumbo contrario al real.
    test('[350,355,5,10] promedia ~0 y NO ~180', () {
      final rumbos = [350.0, 355.0, 5.0, 10.0];
      final media = mediaCircularGrados(rumbos);

      // La media aritmetica ingenua daria (350+355+5+10)/4 = 180.
      expect(media, closeTo(0.0, 1.0));

      // Y debe quedar lejos del resultado incorrecto.
      expect((media - 180.0).abs(), greaterThan(170.0));

      // Noroeste real: el rumbo debe caer en el entorno del norte.
      final desdeNorte = media > 180 ? media - 360 : media;
      expect(desdeNorte.abs(), lessThan(10.0));
    });

    test('se comporta con dos rumbos opuestos', () {
      final media = mediaCircularGrados([90.0, 270.0]);
      expect(media, greaterThanOrEqualTo(0.0));
      expect(media, lessThan(360.0));
    });

    test('lista vacia devuelve 0 sin fallar', () {
      expect(mediaCircularGrados([]), closeTo(0.0, 1e-9));
    });

    test('concentrados da el propio rumbo', () {
      expect(mediaCircularGrados([45.0, 46.0, 44.0]), closeTo(45.0, 0.5));
    });

    test('norte se mantiene en 0 y no salta a 360', () {
      final media = mediaCircularGrados([359.0, 0.5, 1.0]);
      expect(media, lessThan(180.0));
      expect(media, closeTo(0.0, 2.0));
    });
  });

  group('Buffer circular N=5', () {
    test('capacity es 5 como se pide', () {
      expect(BufferCircularRumbo.capacidad, 5);
    });

    test('descarta la muestra mas antigua al llenarse', () {
      final b = BufferCircularRumbo();
      for (var i = 0; i < 8; i++) {
        b.add(rumbo: i.toDouble(), velocidadMps: 10.0, tiempoMs: i * 1000);
      }
      expect(b.length, 5);
      // Tras 8 escrituras solo quedan las 5 ultimas: 3,4,5,6,7.
      final rumbos = b.muestras.map((e) => e.rumbo).toList();
      expect(rumbos, [3.0, 4.0, 5.0, 6.0, 7.0]);
    });

    test('no reordena la lista (orden cronologico correcto)', () {
      final b = BufferCircularRumbo();
      for (var i = 0; i < 5; i++) {
        b.add(rumbo: i * 10.0, velocidadMps: 10.0, tiempoMs: i * 1000);
      }
      expect(b.muestras.map((e) => e.rumbo).toList(),
          [0.0, 10.0, 20.0, 30.0, 40.0]);
    });

    test('la ultima muestra es la mas reciente', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 10.0, velocidadMps: 5.0, tiempoMs: 1000);
      b.add(rumbo: 20.0, velocidadMps: 5.0, tiempoMs: 2000);
      expect(b.ultima!.rumbo, 20.0);
      expect(b.ultimoTiempoMs, 2000);
    });

    test('clear vacia el buffer', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 10.0, velocidadMps: 5.0, tiempoMs: 1000);
      b.clear();
      expect(b.vacio, isTrue);
      expect(b.ultima, isNull);
      expect(b.rumboFiltrado(), isNull);
    });

    test('velocidad negativa se satura a 0', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 0.0, velocidadMps: -5.0, tiempoMs: 1000);
      expect(b.ultima!.velocidadMps, 0.0);
    });
  });

  group('Filtro de saltos imposibles por aceleracion', () {
    // El requerimiento es filtrar por aceleracion (>15 m/s^2), no por distancia
    // bruta: dos fixes a 300 m pueden ser un tunnel real o un salto del GPS.
    test('descarta salto de velocidad con aceleracion > 15 m/s^2', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 0.0, velocidadMps: 10.0, tiempoMs: 0);      // 10 m/s
      b.add(rumbo: 5.0, velocidadMps: 60.0, tiempoMs: 1000);    // +50 m/s en 1 s
      final creibles = b.muestrasCreibles;

      // La primera se conserva (no tiene con que compararse), la segunda no.
      expect(creibles.length, 1);
      expect(creibles.first.rumbo, 0.0);
    });

    test('conserva aceleracion plausible', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 0.0, velocidadMps: 10.0, tiempoMs: 0);
      // De 10 a 12 m/s en 1 s son 2 m/s^2: totalmente creible en ciudad.
      b.add(rumbo: 5.0, velocidadMps: 12.0, tiempoMs: 1000);
      expect(b.muestrasCreibles.length, 2);
    });

    test('frenada fuerte pero creible se conserva', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 0.0, velocidadMps: 25.0, tiempoMs: 0);
      // De 25 a 8 m/s en 1 s son 17 m/s^2: por encima del limite.
      // Con margen de tiempo de 2 s son 8.5 m/s^2: debe conservarse.
      b.add(rumbo: 5.0, velocidadMps: 8.0, tiempoMs: 2000);
      expect(b.muestrasCreibles.length, 2);
    });

    test('descarta por deceleracion imposible', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 0.0, velocidadMps: 30.0, tiempoMs: 0);
      b.add(rumbo: 5.0, velocidadMps: 0.0, tiempoMs: 500); // -60 m/s^2
      expect(b.muestrasCreibles.length, 1);
    });

    test('muestreo demasiado rapido no se juzga', () {
      final b = BufferCircularRumbo();
      // Sensor a 50 Hz: 20 ms entre muestras. dv/dt no es confiable aqui.
      b.add(rumbo: 0.0, velocidadMps: 10.0, tiempoMs: 0);
      b.add(rumbo: 5.0, velocidadMps: 12.0, tiempoMs: 20);
      expect(b.muestrasCreibles.length, 2);
    });

    test('el rumbo filtrado ignora el salto y no se orienta con el', () {
      final b = BufferCircularRumbo();
      // Rumbo consistente al este, en marcha a 10 m/s.
      b.add(rumbo: 90.0, velocidadMps: 10.0, tiempoMs: 0);
      b.add(rumbo: 91.0, velocidadMps: 10.0, tiempoMs: 1000);
      b.add(rumbo: 90.0, velocidadMps: 10.0, tiempoMs: 2000);
      // Salto: 80 m/s en medio de la secuencia.
      b.add(rumbo: 270.0, velocidadMps: 90.0, tiempoMs: 3000);
      b.add(rumbo: 89.0, velocidadMps: 10.0, tiempoMs: 4000);

      final r = b.rumboFiltrado()!;
      // El resultado debe seguir siendo este-oeste, no norte-sur.
      expect(r, closeTo(90.0, 10.0));
    });
  });

  group('Velocidad suavizada', () {
    test('EMA sigue a la velocidad real', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 0.0, velocidadMps: 20.0, tiempoMs: 0);
      b.add(rumbo: 0.0, velocidadMps: 20.0, tiempoMs: 1000);
      b.add(rumbo: 0.0, velocidadMps: 20.0, tiempoMs: 2000);
      expect(b.velocidadFiltrada(), closeTo(20.0, 0.01));
    });

    test('buffer vacio devuelve 0', () {
      expect(BufferCircularRumbo().velocidadFiltrada(), 0.0);
    });
  });

  group('Rumbo retenido con vehiculo parado', () {
    test('parado devuelve el ultimo rumbo estable, no ruido', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 90.0, velocidadMps: 10.0, tiempoMs: 0);
      b.add(rumbo: 90.0, velocidadMps: 10.0, tiempoMs: 1000);
      // Ahora se para y la brujula se llena de ruido.
      b.add(rumbo: 10.0, velocidadMps: 0.0, tiempoMs: 2000);
      b.add(rumbo: 200.0, velocidadMps: 0.0, tiempoMs: 3000);

      final r = b.rumboFiltrado()!;
      // Debe seguir en el este, no saltar por el ruido.
      expect(r, closeTo(90.0, 5.0));
    });

    test('vuelve a orientar en cuanto arranca', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 90.0, velocidadMps: 10.0, tiempoMs: 0);
      b.add(rumbo: 0.0, velocidadMps: 0.0, tiempoMs: 1000);
      expect(b.rumboFiltrado()!, closeTo(90.0, 5.0));

      b.add(rumbo: 180.0, velocidadMps: 12.0, tiempoMs: 2000);
      b.add(rumbo: 181.0, velocidadMps: 12.0, tiempoMs: 3000);
      expect(b.rumboFiltrado()!, closeTo(180.0, 5.0));
    });
  });

  group('Caso real extremo: giro sobre el norte', () {
    test('buffer completo cerca del norte promedia en el norte', () {
      final b = BufferCircularRumbo();
      b.add(rumbo: 358.0, velocidadMps: 11.0, tiempoMs: 0);
      b.add(rumbo: 359.0, velocidadMps: 11.0, tiempoMs: 1000);
      b.add(rumbo: 1.0, velocidadMps: 11.0, tiempoMs: 2000);
      b.add(rumbo: 2.0, velocidadMps: 11.0, tiempoMs: 3000);
      b.add(rumbo: 3.0, velocidadMps: 11.0, tiempoMs: 4000);

      final r = b.rumboFiltrado()!;
      // Cerca de 0/360, nunca cerca de 180.
      expect(r > 350 || r < 10, isTrue,
          reason: 'rumbo $r deberia estar junto al norte');
    });
  });
}