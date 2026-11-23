import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../api_config.dart';
import 'location_service.dart';

/// Rumbo calculado SOLO con el movimiento real del GPS.
///
/// Es la ÚNICA fuente de orientación del mapa, tanto cuando el chófer circula
/// libre (`_activeTrip == null`) como durante un viaje (`accepted`,
/// `driver_arrived` e `in_progress`). La geometría de la ruta de OSRM ya no
/// orienta la cámara ni el rumbo que se publica al pasajero.
///
/// Reglas:
///
///  * La medición es el `bearing` matemático entre la posición GPS anterior y
///    la actual. No se usa la brújula del teléfono.
///  * Por debajo de [velocidadMinimaKmh] se conserva el último rumbo válido:
///    parado en un semáforo el GPS no tiene dirección fiable y el mapa no debe
///    girar solo.
///  * El ángulo se suaviza con un **filtro de Kalman 1D circular**. El error de
///    medición se calcula por el camino angular más corto, así que el salto de
///    359° a 1° cuenta como +2° y no como -358°.
class RumboMovimiento {
  /// Por debajo de esta velocidad no se actualiza el rumbo.
  ///
  /// Era 5 km/h. A 1 Hz eso son 1,4 m y, con el mínimo de 1,5 m de entonces, la
  /// dirección quedaba congelada en tráfico lento precisamente cuando el coche
  /// morenea para doblar. 2,5 km/h sigue descartando el baile del GPS parado.
  static const double velocidadMinimaKmh = 2.5;

  /// Desplazamiento mínimo entre dos fixes para que la dirección tenga sentido.
  static const double distanciaMinimaM = 0.8;

  /// Si el ancla es más vieja que esto (por ejemplo el GPS estuvo pausado
  /// parado), se descarta y se vuelve a sembrar con el fix actual. Evita medir
  /// el rumbo contra una posición de hace minutos.
  static const int _maxEdadAnclaMs = 30000;

  /// Ruido del proceso: cuánto puede cambiar el rumbo entre dos muestras.
  ///
  /// Con Q=4 y R=25 la ganancia en régimen era 0,29: un giro de 90° necesitaba
  /// siete fixes (7 s a 1 Hz) para asimilarse. Con Q=45/R=16 la ganancia es
  /// ~0,82, así que la curva se sigue en uno o dos fixes.
  static const double _ruidoProceso = 45.0;

  /// Ruido de la medición: varianza del bearing GPS en grados².
  static const double _ruidoMedicion = 16.0;

  /// Si la medición se aparta tanto del rumbo anterior, es un giro real: se le
  /// hace caso casi en seguida en vez de esperar a que el Kalman lo digiera.
  static const double _giroBruscoGrados = 25.0;
  static const double _gananciaGiroBrusco = 0.85;

  double? _rumbo;
  double _varianza = _ruidoMedicion;
  LatLng? _ancla;
  int? _anclaMs;

  /// Rumbo suavizado en grados, 0 = norte, o `null` si todavía no hay medición.
  double? get rumbo => _rumbo;

  /// Olvida el estado. Se usa al volver a seguir el GPS tras mover el pin.
  void reiniciar() {
    _rumbo = null;
    _varianza = _ruidoMedicion;
    _ancla = null;
    _anclaMs = null;
  }

  /// Siembra el filtro con el último rumbo conocido.
  ///
  /// Se usa al aceptar un viaje: el chófer venía circulando en modo libre y el
  /// mapa no debe saltar al norte mientras el GPS junta dos fixes con
  /// desplazamiento suficiente. El filtro lo sigue corrigiendo con cada muestra.
  void sembrar(double? grados) {
    if (grados == null) return;
    _rumbo = _normalizar360(grados);
    _varianza = _ruidoMedicion;
  }

  /// Procesa un fix y devuelve el rumbo suavizado vigente.
  ///
  /// [ahoraMs] es un reloj monotónico en milisegundos; solo se usa para medir
  /// la antigüedad del ancla, no para calcular el ángulo.
  double? actualizar({
    required LatLng posicion,
    required double velocidadKmh,
    required int ahoraMs,
  }) {
    final ancla = _ancla;
    final anclaMs = _anclaMs;

    // Hay equipos que devuelven `speed` a 0 aunque el coche se mueva. En ese
    // caso la velocidad se deduce del propio desplazamiento entre fixes, que
    // es justo la magnitud que interesa aquí.
    var velocidad = velocidadKmh;
    if (velocidad <= 0 && ancla != null && anclaMs != null) {
      final dtS = (ahoraMs - anclaMs) / 1000.0;
      if (dtS > 0.2) {
        velocidad =
            LocationService.distanceBetween(ancla, posicion) / dtS * 3.6;
      }
    }

    // Parado o casi parado: se mantiene la última orientación buena.
    if (velocidad < velocidadMinimaKmh) return _rumbo;

    if (ancla == null ||
        anclaMs == null ||
        ahoraMs - anclaMs > _maxEdadAnclaMs) {
      _ancla = posicion;
      _anclaMs = ahoraMs;
      return _rumbo;
    }

    final distancia = LocationService.distanceBetween(ancla, posicion);
    if (distancia < distanciaMinimaM) return _rumbo;

    final medicion = LocationService.bearingBetween(ancla, posicion);

    // El ancla avanza con cada muestra válida, de modo que la próxima medición
    // es siempre el tramo recorrido desde el fix anterior.
    _ancla = posicion;
    _anclaMs = ahoraMs;

    final actual = _rumbo;
    if (actual == null) {
      _rumbo = _normalizar360(medicion);
      _varianza = _ruidoMedicion;
      return _rumbo;
    }

    // Kalman 1D: predecir (el rumbo no tiene modelo de velocidad) y corregir.
    _varianza += _ruidoProceso;
    var ganancia = _varianza / (_varianza + _ruidoMedicion);
    final error = _deltaAngular(medicion, actual);
    if (error.abs() >= _giroBruscoGrados) {
      ganancia = math.max(ganancia, _gananciaGiroBrusco);
    }
    _rumbo = _normalizar360(actual + ganancia * error);
    _varianza = (1.0 - ganancia) * _varianza;
    return _rumbo;
  }

  /// Diferencia angular firmada en (-180, 180].
  @visibleForTesting
  static double deltaAngular(double a, double b) => _deltaAngular(a, b);

  /// Normaliza un ángulo a [0, 360).
  @visibleForTesting
  static double normalizar360(double grados) => _normalizar360(grados);

  static double _deltaAngular(double a, double b) =>
      ((((a - b) % 360.0) + 540.0) % 360.0) - 180.0;

  static double _normalizar360(double grados) =>
      ((grados % 360.0) + 360.0) % 360.0;
}

/// Parámetros de la cámara cuando el chófer circula libre.
class CamaraLibre {
  CamaraLibre._();

  /// Inclinación pedida para la vista libre.
  static const double pitch = 45.0;

  /// Duración de la transición entre fixes del GPS (1 Hz).
  ///
  /// Algo menos que el intervalo entre muestras para que la cámara termine de
  /// llegar antes del siguiente fix y el movimiento se vea continuo.
  static const Duration animacion = Duration(milliseconds: 900);

  /// Zoom de la cámara libre: 19, el mismo que con viaje.
  ///
  /// Antes la velocidad alejaba la vista (16 parado, 14,5 circulando). El
  /// requisito de publicación pide vista de calle también sin viaje, así que la
  /// tabla por velocidad desaparece. Se conserva el parámetro por compatibilidad
  /// con los llamadores y con futuros ajustes.
  static double zoomParaVelocidad(double velocidadKmh) => ApiConfig.zoomIdle;
}
