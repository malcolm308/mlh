import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as mlib;

import '../api_config.dart';

/// Un punto que se dibuja encima del mapa.
///
/// Los marcadores de color (recogida, destino, vehiculo, mi ubicacion) se
/// pintan como circulos con borde blanco mediante una `CircleLayer` del estilo.
/// Los que llevan [onTap] (los POIs) se resuelven por proximity: MapLibre
/// 0.27.1 no expone `project()` para superponer widgets, asi que se calcula el
/// POI mas cercano al punto tocado.
class MapPin {
  final LatLng point;
  final Color color;

  /// Radio en pixeles en pantalla.
  final double radius;

  /// Radio del halo translucido. `0` para no dibujarlo.
  final double haloRadius;
  final Color haloColor;

  /// Callback opcional. Si es `null` el pin no es interactivo.
  final VoidCallback? onTap;

  const MapPin(
    this.point, {
    required this.color,
    this.radius = 19,
    this.haloRadius = 0,
    this.haloColor = const Color(0x2E007AFF),
    this.onTap,
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

  void dispose() {
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

  /// Tap en una zona sin pin.
  final void Function(LatLng point)? onTap;

  /// El usuario ha tocado o arrastrado el mapa.
  final VoidCallback? onGesture;

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
    this.onTap,
    this.onGesture,
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

  /// Capa del estilo sobre la que se dibuja la ruta. Las carreteras estan por
  /// debajo y los rotulos por encima, que es lo que quiere el cliente.
  static const _debajoDe = 'nombres-carretera';

  bool _estiloListo = false;

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

  /// Convierte un `Color` a `#rrggbb`, que es lo que espera MapLibre.
  static String _hex(Color c) =>
      '#${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
          '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
          '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}';

  /// Se invoca cuando el estilo finishes de cargar. MapLibre lo llama sin
  /// argumentos, asi que el controlador se toma del que guardo `onMapCreated`.
  Future<void> _onStyleLoaded() async {
    _estiloListo = true;
    try {
      await _pintarRuta(crearCapas: true);
      await _pintarPins(crearCapas: true);
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

      // La recta es provisional, mientras OSRM no responde: sin halo y con el
      // negro translucido que se usaba antes.
      await ctl.addGeoJsonSource(_srcRecta, _geojsonLineaSegura(const []));
      await ctl.addLineLayer(
        _srcRecta,
        _layerRecta,
        mlib.LineLayerProperties(
          lineColor: _hex(widget.straightColor),
          lineWidth: _grosor(widget.routeWidth - 1),
          lineOpacity: 1,
          lineJoin: 'round',
          lineCap: 'round',
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
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 3,
        ),
        belowLayerId: _layerRuta,
      );
      return;
    }

    await ctl.setGeoJsonSource(_srcPins, _geojsonPins());
    await ctl.setGeoJsonSource(_srcPinsHalo, _geojsonHalos());
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

  /// Resuelve el pin interactivo mas cercano al punto tocado.
  ///
  /// MapLibre 0.27.1 no expone `project()`, asi que no se puede comparar en
  /// pixeles. Se usa la distancia real en metros escalada por el zoom: a cada
  /// zoom un tile de 256 px cubre menos metros, asi que el margen util tambien
  /// se encoge.
  void _gestionarTap(mlib.LatLng punto) {
    final objetivo = LatLng(punto.latitude, punto.longitude);
    MapPin? mejor;
    double mejorMetros = double.infinity;

final zoom = widget.controller.zoom;
    // Metros por pixel aproximado: 156543 * cos(lat) / 2^zoom.
    final metrosPorPx =
        156543.03 *
            math.cos(objetivo.latitude * math.pi / 180) /
            (1 << zoom.clamp(0, 22).round());
    final margen = (metrosPorPx * 46).clamp(12.0, 400.0);

    for (final pin in widget.pins) {
      if (pin.onTap == null) continue;
      final d = _distanciaMetros(objetivo, pin.point);
      if (d <= margen && d < mejorMetros) {
        mejorMetros = d;
        mejor = pin;
      }
    }

    if (mejor != null) {
      mejor.onTap!();
      return;
    }
    widget.onTap?.call(objetivo);
  }

  /// Distancia en metros entre dos puntos (haversine).
  static double _distanciaMetros(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = _aRad(b.latitude - a.latitude);
    final dLon = _aRad(b.longitude - a.longitude);
    final s = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_aRad(a.latitude)) *
            math.cos(_aRad(b.latitude)) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(s)));
  }

  static double _aRad(double g) => g * math.pi / 180;

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
        // El estilo puede haber cargado antes de llegar aqui; sin esta
        // comprobacion las capas nunca se crearian y el mapa se quedaria sin
        // ruta ni marcadores.
        if (_estiloListo) {
          unawaited(_pintarRuta(crearCapas: true));
          unawaited(_pintarPins(crearCapas: true));
        }
      },
      onStyleLoadedCallback: () => unawaited(_onStyleLoaded()),
      onCameraMove: (cam) {
        widget.controller._anotarCamara(cam);
        // Un arrastre del usuario llega aqui sin que la pantalla haya pedido
        // nada: es la unica senal de que deja de seguir al vehiculo.
        if (!widget.controller.enMovimientoPropio) widget.onGesture?.call();
      },
      onMapClick: (_, punto) => _gestionarTap(punto),
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
      trackCameraPosition: false,
    );
  }
}