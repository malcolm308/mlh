import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../api_config.dart';

/// Camara del mapa en eventos discretos: cambio de fase, encuadre de trayecto y
/// boton de recentrar.
///
/// El seguimiento continuo con heading-up y tilt NO vive aqui, sino en
/// `NavigationModeService`, que necesita interpolar por frame y conocer el
/// rumbo. Esta clase solo mueve la camara cuando hay una orden puntual.
///
/// Cambio respecto a la version con `flutter_map`: los tres metodos que movian
/// la camara usan ahora `MapLibreMapController` y un unico `CameraUpdate`
/// composed. En `flutter_map` el offset del look-ahead obligaba a llamar a
/// `move` y a `rotate` por separado, porque `move` no admitia rotacion y
/// `moveAndRotate` no admitia offset. Con maplibre, [CameraPosition] lleva
/// target, zoom, tilt y bearing en el mismo objeto, asi que van juntos y no hay
/// ningun estado intermedio visible.
class NavCamera {
  NavCamera._();

  static String? _faseAplicada;
  static double _zoom = ApiConfig.defaultZoom;
  static double _rotacion = 0.0;

  static double get zoom => _zoom;

  /// Rotacion actual que el mapa tiene aplicada.
  static double get rotacion => _rotacion;

  /// Olvida la fase aplicada y vuelve al zoom general.
  static void reset() {
    _faseAplicada = null;
    _zoom = ApiConfig.defaultZoom;
  }

  /// Acerca el mapa segun la fase del viaje.
  ///
  /// Devuelve `false` si no cambio nada, que es el caso normal: el GPS no mueve
  /// la camara, solo lo hace un cambio de fase. Sin este guardado el mapa
  /// reencuadraria en cada fix.
  static bool aplicarFase(
    MapLibreMapController controller,
    LatLng centro, {
    String? status,
  }) {
    if (status == _faseAplicada) return false;
    _faseAplicada = status;

    final z = ApiConfig.zoomParaFase(status: status)
        .clamp(ApiConfig.minZoom.toDouble(), ApiConfig.maxZoom.toDouble());
    _zoom = z;

    // Sin viaje activo el mapa se orienta al norte: la rotacion de conduccion
    // no tiene sentido cuando no hay trayecto.
    final rotacion = status == null ? 0.0 : _rotacion;
    _rotacion = rotacion;

    controller.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: centro,
          zoom: z,
          // En un cambio de fase el mapa queda plano: la inclinacion es cosa
          // del modo navegacion, no de la vista de un evento puntual.
          tilt: 0,
          bearing: rotacion,
        ),
      ),
    );
    return true;
  }

  /// Vuelve a poner el vehiculo en el centro, en la orientacion que toque.
  ///
  /// Se usa por el boton de recentrar. Con [seguir] se mantiene el heading-up
  /// (el chofer acaba de pedir volver al modo navegacion); sin el, el mapa
  /// vuelve a norte arriba, que es lo esperable cuando ya no esta navegando.
  ///
  /// [tilt] va aparte del resto a proposito: recentrar debe dejar el mapa
  /// inclinado, no plano. Sin esto el boton de "mi ubicacion" devolvia la
  /// vista a 2D, que es justo lo contrario de lo que se le pide.
  static void centrar(
    MapLibreMapController controller,
    LatLng centro, {
    bool seguir = false,
    double tilt = 0.0,
  }) {
    final z = _zoom
        .clamp(ApiConfig.minZoom.toDouble(), ApiConfig.maxZoom.toDouble());
    final rotacion = seguir ? _rotacion : 0.0;
    _rotacion = rotacion;

    controller.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: centro,
          zoom: z,
          // El clamp de 60 es el tope del motor; sin el, pedir mas de lo que
          // soporta el zoom actual se recorta solo y de forma invisible.
          tilt: tilt.clamp(0.0, 60.0),
          bearing: rotacion,
        ),
      ),
    );
  }

  /// Encuadra un conjunto de puntos (por ejemplo el trayecto completo).
  ///
  /// Devuelve el norte arriba siempre: es la vista de "echar un vistazo al
  /// barrio", no la de conduccion.
  static void encuadrar(
    MapLibreMapController controller,
    List<LatLng> puntos, {
    EdgeInsets? padding,
  }) {
    if (puntos.isEmpty) return;

    if (puntos.length == 1) {
      centrar(controller, puntos.first);
      return;
    }

    var sur = puntos.first.latitude;
    var norte = puntos.first.latitude;
    var oeste = puntos.first.longitude;
    var este = puntos.first.longitude;
    for (final p in puntos) {
      sur = math.min(sur, p.latitude);
      norte = math.max(norte, p.latitude);
      oeste = math.min(oeste, p.longitude);
      este = math.max(este, p.longitude);
    }

    final centro = LatLng((sur + norte) / 2, (oeste + este) / 2);

    // Tamano real del area en metros. Se necesita para decidir si merece la
    // pena alejar el mapa: un tramo de calle de 120 m no se distingue de un
    // punto, y alejarlo solo haria que el chofer perdiera el detalle de la via.
    const metrosPorGrado = 111320.0;
    final anchoM = (este - oeste) *
        metrosPorGrado *
        math.cos(centro.latitude * math.pi / 180.0);
    final altoM = (norte - sur) * metrosPorGrado;

    if (math.max(anchoM, altoM) < 120) {
      centrar(controller, centro);
      return;
    }

    // Norte arriba: es una vista de conjunto, no de conduccion.
    _rotacion = 0.0;

    final pad = padding ?? const EdgeInsets.fromLTRB(52, 104, 52, 200);
    // `newLatLngBounds` toma los insets como numeros sueltos, no como
    // `EdgeInsets`, y deja tilt y bearing a 0 por su cuenta, que es justo lo
    // que quiere esta vista de conjunto.
    controller.moveCamera(
      CameraUpdate.newLatLngBounds(
        // `LatLngBounds` de maplibre toma las esquinas con nombre. La de
        // latlong2 las llevaba como argumentos posicionales.
        LatLngBounds(
          southwest: LatLng(sur, oeste),
          northeast: LatLng(norte, este),
        ),
        left: pad.left.toDouble(),
        top: pad.top.toDouble(),
        right: pad.right.toDouble(),
        bottom: pad.bottom.toDouble(),
      ),
    );

    // El zoom resultante no lo calcula MapLibre de forma sincrona, asi que se
    // deja el anterior: lo actualiza el servicio en su siguiente tic. Guardar
    // aqui un valor inventado haria que [centrar] usara un zoom equivocado.
  }

  /// Marca la rotacion que el mapa tiene realmente aplicada.
  ///
  /// Lo llama el servicio de navegacion en cada frame, para que [centrar] y
  /// [encuadrar] sepan si deben respetar el heading-up vigente o anularlo.
  static void confirmarRotacion(double grados) {
    _rotacion = normalizarGrados(grados);
  }

  static double _normalizar(double g) {
    var d = g % 360.0;
    if (d < 0) d += 360.0;
    return d;
  }

  /// Atajo de la normalizacion, sin importar el filtro de rumbo.
  static double normalizarGrados(double g) => _normalizar(g);
}
