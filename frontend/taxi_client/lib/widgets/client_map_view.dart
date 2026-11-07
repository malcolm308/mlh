import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as mlib;

import '../api_config.dart';

/// Un punto que se dibuja encima del mapa.
///
/// Los marcadores de color (recogida, destino, vehiculo, mi ubicacion) se
/// pintan como circulos con borde blanco mediante una `CircleLayer` del estilo.
class MapPin {
  final LatLng point;
  final Color color;

  /// Radio en pixeles en pantalla.
  final double radius;

  /// Radio del halo translucido. `0` para no dibujarlo.
  final double haloRadius;
  final Color haloColor;

  const MapPin(
    this.point, {
    required this.color,
    this.radius = 19,
    this.haloRadius = 0,
    this.haloColor = const Color(0x2E007AFF),
  });
}

/// Fotograma pendiente de la vista 3D (ver [ClientMapController.animar3D]).
class _Peticion3D {
  final LatLng destino;
  final double rumbo;
  final double zoom;
  final double tilt;
  final int durationMs;

  const _Peticion3D(
    this.destino,
    this.rumbo, {
    required this.zoom,
    required this.tilt,
    required this.durationMs,
  });
}

/// Envoltorio de la camara que usan las pantallas.
///
/// Sustituye a `MapController` de `flutter_map`. Se expone con los mismos
/// metodos que usaba el cliente (`move`, `fitPoints`, `contains`, `zoom`,
/// `center`) para que las pantallas cambien lo minimo.
class ClientMapController {
  mlib.MapLibreMapController? _ctl;
  double _zoom = ApiConfig.defaultZoom;
  LatLng? _center;

  /// Peticion de vista 3D que llego mientras otra animacion estaba en vuelo.
  ///
  /// MapLibre no tolera dos `animateCamera` solapadas sobre el mismo mapa:
  /// la segunda puede dejar el PlatformView a medio redimensionar y tumbar la
  /// app. Se guarda solo la ultima (la posicion mas reciente) y se lanza al
  /// terminar la actual.
  _Peticion3D? _anim3DPendiente;
  bool _animando3D = false;

  /// Ventana durante la cual se ignoran los gestos, para que el `onCameraMove`
  /// que provoca un `moveCamera` propio no se confunda con un arrastre.
  DateTime _ignorarGestosHasta = DateTime.fromMillisecondsSinceEpoch(0);

  bool get listo => _ctl != null;

  double get zoom => _zoom;

  LatLng? get center => _center;

  /// `true` mientras un movimiento pedido por la propia pantalla este en curso.
  ///
  /// MapLibre 0.27.1 no expone ningun callback de "el usuario ha empezado a
  /// tocar el mapa" (`onCameraMoveStarted` no existe), asi que se distingue por
  /// tiempo: los `onCameraMove` de un `moveCamera` sin animacion llegan de
  /// inmediato, mientras que los de un arrastre se reparten en el tiempo.
  bool get enMovimientoPropio =>
      DateTime.now().isBefore(_ignorarGestosHasta);

  void _anotarCamara(mlib.CameraPosition cam) {
    _zoom = cam.zoom;
    _center = LatLng(cam.target.latitude, cam.target.longitude);
  }

  /// Centra la camara en [p] con el zoom indicado.
  void move(LatLng p, double zoom) {
    final ctl = _ctl;
    if (ctl == null) return;
    // Se anota de inmediato: la pantalla puede leer `center` justo despues de
    // pedir el movimiento, antes de que llegue el primer `onCameraMove`.
    _center = p;
    _zoom = zoom;
    _ignorarGestosHasta = DateTime.now().add(const Duration(milliseconds: 400));
    ctl.moveCamera(
      mlib.CameraUpdate.newCameraPosition(
        mlib.CameraPosition(target: _ml(p), zoom: zoom),
      ),
    );
  }

  /// Encuadra todos los puntos con el margen indicado.
  void fitPoints(
    List<LatLng> puntos, {
    EdgeInsets padding = const EdgeInsets.fromLTRB(40, 80, 40, 140),
    double maxZoom = ApiConfig.defaultZoom,
  }) {
    final ctl = _ctl;
    if (ctl == null || puntos.length < 2) return;
    final sur = puntos.reduce(
      (a, b) => LatLng(
        a.latitude < b.latitude ? a.latitude : b.latitude,
        a.longitude < b.longitude ? a.longitude : b.longitude,
      ),
    );
    final norte = puntos.reduce(
      (a, b) => LatLng(
        a.latitude > b.latitude ? a.latitude : b.latitude,
        a.longitude > b.longitude ? a.longitude : b.longitude,
      ),
    );
    _ignorarGestosHasta = DateTime.now().add(const Duration(milliseconds: 400));
    ctl.moveCamera(
      mlib.CameraUpdate.newLatLngBounds(
        mlib.LatLngBounds(southwest: _ml(sur), northeast: _ml(norte)),
        left: padding.left.toDouble(),
        top: padding.top.toDouble(),
        right: padding.right.toDouble(),
        bottom: padding.bottom.toDouble(),
      ),
    );
  }

  /// `true` si [p] cae dentro de la region visible.
  Future<bool> contains(LatLng p) async {
    final ctl = _ctl;
    if (ctl == null) return true;
    try {
      return (await ctl.getVisibleRegion()).contains(_ml(p));
    } catch (_) {
      return true;
    }
  }

  /// Anima la camara al estilo "vista 3D": target en el vehiculo, bearing con
  /// su rumbo, tilt fijo y zoom cerca. Es la emulacion en el cliente de la
  /// camara de navegacion del chofer.
  ///
  /// La animacion va con [duration] para que no sea un salto seco, y mientras
  /// corre se ignora el `onCameraMove` que provoca del propio movimiento
  /// (misma ventana que usa `move`), de modo que la pantalla no confunda el
  /// seguimiento automatico con un arrastre del usuario.
  Future<void> animar3D(LatLng destino, double rumbo,
      {double zoom = 16.0,
      double tilt = 50.0,
      int durationMs = 1000}) async {
    final ctl = _ctl;
    if (ctl == null) return;
    if (_animando3D) {
      // Ya hay una animacion en marcha: solo se recuerda la ultima peticion.
      _anim3DPendiente = _Peticion3D(
        destino,
        rumbo,
        zoom: zoom,
        tilt: tilt,
        durationMs: durationMs,
      );
      return;
    }
    _animando3D = true;
    _ignorarGestosHasta =
        DateTime.now().add(Duration(milliseconds: durationMs + 200));
    try {
      await ctl.animateCamera(
        mlib.CameraUpdate.newCameraPosition(
          mlib.CameraPosition(
            target: _ml(destino),
            zoom: zoom,
            bearing: rumbo % 360,
            tilt: tilt,
          ),
        ),
        duration: Duration(milliseconds: durationMs),
      );
    } catch (_) {
      // Un fallo de animacion no debe tumbar el seguimiento.
    } finally {
      _animando3D = false;
    }
    final siguiente = _anim3DPendiente;
    _anim3DPendiente = null;
    if (siguiente != null && _ctl != null) {
      await animar3D(
        siguiente.destino,
        siguiente.rumbo,
        zoom: siguiente.zoom,
        tilt: siguiente.tilt,
        durationMs: siguiente.durationMs,
      );
    }
  }

  void dispose() {
    _anim3DPendiente = null;
    _animando3D = false;
    _ctl = null;
  }

  static mlib.LatLng _ml(LatLng p) => mlib.LatLng(p.latitude, p.longitude);
}

/// Mapa del cliente sobre MapLibre, con teselas vectoriales servidas por Martin.
///
/// A diferencia de `flutter_map`, aqui no hay widgets `Marker` ni `Polyline`:
/// maplibre_gl 0.27.1 los elimino. Todo se pinta con fuentes GeoJSON y capas
/// del estilo (`addGeoJsonSource` + `addLineLayer` / `addCircleLayer`), que es
/// el mismo patron que usa la app del chofer.
class ClientMapView extends StatefulWidget {
  final ClientMapController controller;

  final LatLng initialCenter;
  final double initialZoom;
  final double minZoom;
  final double maxZoom;

  /// Trazado a pintar. Si tiene menos de dos puntos se usa [straightLine].
  final List<LatLng> route;

  /// Recta entre origen y destino, usada mientras no hay trazado de carretera.
  final List<LatLng> straightLine;

  final Color routeColor;
  final Color routeHaloColor;
  final double routeWidth;
  final Color straightColor;

  final List<MapPin> pins;
  final Color haloColor;

  /// Puntos que llevan el marcador 3D "rayo" (recogida y destino ya fijados).
  ///
  /// Se pintan como una capa de simbolos con la imagen
  /// `assets/icons/rayo_3d.png`, anclada por la punta inferior.
  final List<LatLng> rayoPins;

  /// Tap en una zona sin pin.
  final void Function(LatLng point)? onTap;

  /// El usuario ha tocado o arrastrado el mapa.
  final VoidCallback? onGesture;

  /// La cámara se ha detenido (fin de arrastre o de animación).
  final VoidCallback? onCameraIdle;

  /// La cámara se ha movido (arrastre del usuario o animación propia).
  ///
  /// Se usa para reiniciar la espera de 2 s que dispara la geocodificación
  /// inversa del centro del mapa.
  final VoidCallback? onCameraMove;

  const ClientMapView({
    super.key,
    required this.controller,
    required this.initialCenter,
    required this.initialZoom,
    required this.minZoom,
    required this.maxZoom,
    this.route = const [],
    this.straightLine = const [],
    this.routeColor = const Color(0xFF007AFF),
    this.routeHaloColor = const Color(0xE6FFFFFF),
    this.routeWidth = 4,
    this.straightColor = const Color(0x66000000),
    this.pins = const [],
    this.haloColor = const Color(0x2E007AFF),
    this.rayoPins = const [],
    this.onTap,
    this.onGesture,
    this.onCameraIdle,
    this.onCameraMove,
  });

  @override
  State<ClientMapView> createState() => _ClientMapViewState();
}

class _ClientMapViewState extends State<ClientMapView> {
  static const _srcRuta = 'cliente-ruta';
  static const _layerRutaHalo = 'cliente-ruta-halo';
  static const _layerRuta = 'cliente-ruta-linea';
  static const _srcRecta = 'cliente-recta';
  static const _layerRecta = 'cliente-recta-linea';
  static const _srcPins = 'cliente-pins';
  static const _layerPins = 'cliente-pins-circulo';
  static const _srcPinsHalo = 'cliente-pins-halo';
  static const _layerPinsHalo = 'cliente-pins-halo-circulo';
  static const _srcRayos = 'cliente-rayos';
  static const _layerRayos = 'cliente-rayos-simbolo';
  static const _rayoImagen = 'rayo_pin';

  /// Capa del estilo sobre la que se dibuja la ruta. Las carreteras estan por
  /// debajo y los rotulos por encima, que es lo que quiere el cliente.
  static const _debajoDe = 'nombres-carretera';

  bool _estiloListo = false;

  /// La imagen del rayo ya se registro en el estilo del mapa.
  bool _rayoImagenLista = false;

  /// La fuente y la capa de simbolos del rayo ya existen.
  bool _rayosCreados = false;

  @override
  void initState() {
    super.initState();
    widget.controller._ctl = null;
  }

  @override
  void didUpdateWidget(ClientMapView old) {
    super.didUpdateWidget(old);
    if (!_estiloListo) return;
    unawaited(_pintarRuta());
    unawaited(_pintarPins());
    unawaited(_pintarRayos());
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  Map<String, dynamic> _geojsonLinea(List<LatLng> pts) => {
        'type': 'Feature',
        'properties': {},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in pts) [p.longitude, p.latitude]
          ],
        },
      };

  /// Vacia en una unica cordenada no es valido en GeoJSON, asi que se degrada
  /// a la misma cordenada repetida. La capa queda sin pintar, que es lo que se
  /// busca cuando aun no hay trazado.
  Map<String, dynamic> _geojsonLineaSegura(List<LatLng> pts) {
    final seguras = pts.length >= 2 ? pts : const <LatLng>[];
    return _geojsonLinea(seguras);
  }

  Map<String, dynamic> _geojsonPins() => {
        'type': 'FeatureCollection',
        'features': [
          for (final pin in widget.pins)
            {
              'type': 'Feature',
              'properties': {
                'color': _hex(pin.color.withValues(alpha: 1)),
                'radio': pin.radius,
              },
              'geometry': {
                'type': 'Point',
                'coordinates': [pin.point.longitude, pin.point.latitude],
              },
            }
        ],
      };

  Map<String, dynamic> _geojsonHalos() => {
        'type': 'FeatureCollection',
        'features': [
          for (final pin in widget.pins)
            if (pin.haloRadius > 0)
              {
                'type': 'Feature',
                'properties': {
                  'color': _hex(pin.haloColor),
                  'radio': pin.haloRadius,
                },
                'geometry': {
                  'type': 'Point',
                  'coordinates': [pin.point.longitude, pin.point.latitude],
                },
              }
        ],
      };

  Map<String, dynamic> _geojsonRayos() => {
        'type': 'FeatureCollection',
        'features': [
          for (final punto in widget.rayoPins)
            {
              'type': 'Feature',
              'properties': const <String, dynamic>{},
              'geometry': {
                'type': 'Point',
                'coordinates': [punto.longitude, punto.latitude],
              },
            }
        ],
      };

  /// Convierte un `Color` a `#rrggbb`, que es lo que espera MapLibre.
  static String _hex(Color c) =>
      '#${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
          '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
          '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}';

  /// Se invoca cuando el estilo finishes de cargar. MapLibre lo llama sin
  /// argumentos, asi que el controlador se toma del que guardo `onMapCreated`.
  Future<void> _onStyleLoaded() async {
    _estiloListo = true;
    _rayoImagenLista = false;
    _rayosCreados = false;
    try {
      await _pintarRuta(crearCapas: true);
      await _pintarPins(crearCapas: true);
      await _pintarRayos(crearCapas: true);
    } catch (e) {
      debugPrint('Mapa del cliente: no se pudieron crear las capas: $e');
    }
  }

  Future<void> _pintarRuta({bool crearCapas = false}) async {
    final ctl = widget.controller._ctl;
    if (ctl == null) return;

    if (crearCapas) {
      await ctl.addGeoJsonSource(_srcRuta, _geojsonLineaSegura(const []));
      // Halo blanco: separa la ruta de las aceras, que tambien son blancas.
      // Va mas ancho que el azul y crece con el zoom, igual que el trazo azul.
      await ctl.addLineLayer(
        _srcRuta,
        _layerRutaHalo,
        mlib.LineLayerProperties(
          lineColor: _hex(widget.routeHaloColor),
          lineWidth: _grosor(widget.routeWidth + 4),
          lineOpacity: 1,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        belowLayerId: _debajoDe,
      );
      await ctl.addLineLayer(
        _srcRuta,
        _layerRuta,
        mlib.LineLayerProperties(
          lineColor: _hex(widget.routeColor),
          lineWidth: _grosor(widget.routeWidth),
          lineOpacity: 1,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        belowLayerId: _debajoDe,
      );

      // La recta es PROVISIONAL, mientras OSRM no responde: azul muy sutil y
      // PUNTEADA, para que nadie la confunda con la ruta real ni con la
      // recta negra que era antes.
      await ctl.addGeoJsonSource(_srcRecta, _geojsonLineaSegura(const []));
      await ctl.addLineLayer(
        _srcRecta,
        _layerRecta,
        mlib.LineLayerProperties(
          lineColor: _hex(widget.straightColor),
          lineWidth: _grosor(widget.routeWidth - 1),
          lineOpacity: 0.55,
          lineJoin: 'round',
          lineCap: 'round',
          lineDasharray: const [2.0, 2.5],
        ),
        belowLayerId: _layerRutaHalo,
      );
      return;
    }

    // El trazado de carretera tiene prioridad; la recta solo aparece si aun no
    // hay ninguno, para no dibujar las dos cosas encima.
    final hayRuta = widget.route.length >= 2;
    final hayRecta = !hayRuta && widget.straightLine.length >= 2;

    await ctl.setGeoJsonSource(
      _srcRuta,
      _geojsonLineaSegura(hayRuta ? widget.route : const []),
    );
    await ctl.setGeoJsonSource(
      _srcRecta,
      _geojsonLineaSegura(hayRecta ? widget.straightLine : const []),
    );
  }

  Future<void> _pintarPins({bool crearCapas = false}) async {
    final ctl = widget.controller._ctl;
    if (ctl == null) return;

    if (crearCapas) {
      await ctl.addGeoJsonSource(_srcPinsHalo, _geojsonHalos());
      await ctl.addCircleLayer(
        _srcPinsHalo,
        _layerPinsHalo,
        mlib.CircleLayerProperties(
          circleColor: ['get', 'color'],
          circleRadius: ['get', 'radio'],
          circleStrokeColor: 'rgba(0,0,0,0)',
          circleStrokeWidth: 0,
        ),
        belowLayerId: _layerRutaHalo,
      );

      await ctl.addGeoJsonSource(_srcPins, _geojsonPins());
      await ctl.addCircleLayer(
        _srcPins,
        _layerPins,
        mlib.CircleLayerProperties(
          circleColor: ['get', 'color'],
          circleRadius: ['get', 'radio'],
          // Borde blanco: es lo que hacia el marcador con `Container`.
          // Reducido un 25 % (era 3) junto con el radio del punto.
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 2.5,
        ),
        belowLayerId: _layerRuta,
      );
      return;
    }

    await ctl.setGeoJsonSource(_srcPins, _geojsonPins());
    await ctl.setGeoJsonSource(_srcPinsHalo, _geojsonHalos());
  }

  /// Pinta el marcador 3D "rayo" en los puntos ya fijados (recogida/destino).
  ///
  /// La imagen se registra una sola vez por estilo y la punta del PNG coincide
  /// con el centro-abajo del lienzo, por eso `iconAnchor: bottom` la deja
  /// exactamente sobre la coordenada.
  Future<void> _pintarRayos({bool crearCapas = false}) async {
    final ctl = widget.controller._ctl;
    if (ctl == null) return;

    if (crearCapas) {
      if (!_rayoImagenLista) {
        final data = await rootBundle.load('assets/icons/rayo_3d.png');
        await ctl.addImage(_rayoImagen, data.buffer.asUint8List());
        _rayoImagenLista = true;
      }
      if (!_rayosCreados) {
        await ctl.addGeoJsonSource(_srcRayos, _geojsonRayos());
        await ctl.addSymbolLayer(
          _srcRayos,
          _layerRayos,
          mlib.SymbolLayerProperties(
            iconImage: _rayoImagen,
            iconAnchor: 'bottom',
            iconSize: 0.25,
            iconAllowOverlap: true,
            iconIgnorePlacement: true,
          ),
        );
        _rayosCreados = true;
      }
      return;
    }

    if (!_rayosCreados) return;
    await ctl.setGeoJsonSource(_srcRayos, _geojsonRayos());
  }

  /// El grosor sigue al zoom para que la calle pintada se vea entera igual que
  /// en la app del chofer, en vez de quedarse en una raya al acercarse.
  static List<dynamic> _grosor(double anchoPx) => [
        'interpolate',
        ['exponential', 1.6],
        ['zoom'],
        12,
        anchoPx,
        14,
        anchoPx * 1.5,
        16,
        anchoPx * 2.0,
        18,
        anchoPx * 2.75,
      ];

  /// Coloca el pin en el punto tocado del mapa.
  ///
  /// MapLibre 0.27.1 no expone `project()`, asi que no se pueden superponer
  /// widgets sobre el mapa: toda la interaccion del toque se resuelve aqui.
  void _gestionarTap(mlib.LatLng punto) {
    widget.onTap?.call(LatLng(punto.latitude, punto.longitude));
  }

  @override
  Widget build(BuildContext context) {
    return mlib.MapLibreMap(
      styleString: ApiConfig.mapStyleUrl,
      initialCameraPosition: mlib.CameraPosition(
        target: ClientMapController._ml(widget.initialCenter),
        zoom: widget.initialZoom,
      ),
      onMapCreated: (ctl) {
        widget.controller._ctl = ctl;
        // Centro inicial conocido desde el primer frame: sin esto la pantalla
        // no puede geocodificar hasta que el usuario mueva el mapa.
        widget.controller._anotarCamara(mlib.CameraPosition(
          target: mlib.LatLng(
            widget.initialCenter.latitude,
            widget.initialCenter.longitude,
          ),
          zoom: widget.initialZoom,
        ));
        // El estilo puede haber cargado antes de llegar aqui; sin esta
        // comprobacion las capas nunca se crearian y el mapa se quedaria sin
        // ruta ni marcadores.
        if (_estiloListo) {
          unawaited(_pintarRuta(crearCapas: true));
          unawaited(_pintarPins(crearCapas: true));
          unawaited(_pintarRayos(crearCapas: true));
        }
      },
      onStyleLoadedCallback: () => unawaited(_onStyleLoaded()),
      onCameraMove: (cam) {
        widget.controller._anotarCamara(cam);
        // Un arrastre del usuario llega aqui sin que la pantalla haya pedido
        // nada: es la unica senal de que deja de seguir al vehiculo.
        if (!widget.controller.enMovimientoPropio) widget.onGesture?.call();
        widget.onCameraMove?.call();
      },
      onMapClick: (_, punto) => _gestionarTap(punto),
      onCameraIdle: widget.onCameraIdle,
      // Sin esto MapLibre usa MinMaxZoomPreference.unbounded y por debajo de z8
      // el mapa se queda en blanco, y por encima de z16 estira teselas.
      minMaxZoomPreference: mlib.MinMaxZoomPreference(
        widget.minZoom,
        widget.maxZoom,
      ),
      // El punto azul nativo no se usa: el marcador propio lo dibuja la capa.
      myLocationEnabled: false,
      myLocationTrackingMode: mlib.MyLocationTrackingMode.none,
      // La camara la lleva la pantalla de forma explicita; el seguimiento
      // automatico del motor pelea con ella.
      //
      // PERO el seguimiento de posicion SI debe estar activo: en MapLibre
      // Android `onCameraMove` retorna sin emitir nada si
      // `trackCameraPosition` es false, y `cameraPosition` se queda congelada.
      // Sin esto la pantalla nunca sabia donde estaba el rayo (geocodificaba
      // el centro inicial) y el destino acababa siendo el mismo punto que la
      // recogida (ruta de 0.0 km).
      trackCameraPosition: true,
    );
  }
}