import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../api_config.dart';

/// Mapa del conductor sobre MapLibre, con inclinacion y rotacion NATIVAS.
///
/// Este widget sustituye a la version anterior, que simulaba la perspectiva con
/// un `Transform` de `Matrix4`. La diferencia es de fondo:
///
///  * Antes el tilt era falso. `flutter_map` no lo tiene: habia que inclinar el
///    plano con una matriz, y eso obligaba a tres apanes para que no se notara.
///    Con un angulo de 55 grados, la altura proyectada del mapa se multiplica
///    por `cos(55) = 0.57`, asi que la mitad superior se encogia y hacia falta
///    ampliar 1.74 veces para que el plano siguiera llenando la pantalla. De
///    ahi salian el factor `1/cos` y su `Transform.scale`.
///
///  * Ahora `tilt` (o `pitch`) es un atributo de la camara de MapLibre. El
///    motor de render aplica la proyeccion y dibuja el terreno lejano que hace
///    falta, sin ampliar nada y sin que aparezca el hueco. No hay `Transform`,
///    ni `Matrix4`, ni compensacion por coseno, ni `ClipRect`.
///
/// Lo que queda aqui es el contenedor: el mapa y la sincronizacion de la camara
/// con el servicio de navegacion. La UI flotante va en el `Stack` de la
/// pantalla, como hermana de este widget, nunca dentro.
class NavigationMapView extends StatefulWidget {
  /// Tilt actual en GRADOS, 0 = mapa plano. Lo provee el servicio.
  final double tilt;

  /// Rumbo actual en GRADOS, medido en sentido horario desde el norte.
  final double bearing;

  /// Centro de la camara, o `null` mientras no haya posicion del GPS.
  final LatLng? center;

  /// Zoom de la camara.
  final double zoom;

  /// Ruta a dibujar como lista de coordenadas, en orden.
  ///
  /// Se convierte a GeoJSON aqui y se manda a una capa del estilo. Va por
  /// parametro y no se fija una vez, porque cambia con cada recalculo de ruta
  /// de OSRM: lo que se hace es comparar con lo ya enviado para no reenviar la
  /// misma geometria.
  final List<LatLng> ruta;

  /// Posicion del vehiculo, para el marcador propio.
  ///
  /// Se dibuja con una capa de circulos, no con `myLocationEnabled`. El punto
  /// azul nativo depende de los permisos de localizacion que pide el motor
  /// MapLibre por su cuenta, y aqui el GPS ya lo gestiona el `MethodChannel`
  /// propio de Kotlin, asi que se dibuja a mano con la posicion que llega del
  /// servicio.
  final LatLng? posicionVehiculo;

  /// Rumbo del vehiculo en GRADOS, para orientar la flecha.
  ///
  /// Lo consume icon-rotate. Va como propiedad del Feature y no como
  /// setLayoutProperty de la capa, porque asi cambiar el rumbo cuesta lo
  /// mismo que cambiar la posicion: solo reenviar el source.
  final double? rumboVehiculo;

/// Se invoca en cuanto el estilo ha cargado y las capas estan listas.
  final VoidCallback? onListo;

  /// Se invoca en cuanto el controlador del mapa existe.
  ///
  /// Lo necesita la pantalla para los movimentos puntuales de camara (cambio de
  /// fase, encuadrar el trayecto), que no son cosa del widget. El controlador
  /// lo crea `MapLibreMap` y no se puede pasar por parametro, asi que se entrega
  /// aqui en lugar de construirse a mano.
  final void Function(MapLibreMapController)? onControlador;

  const NavigationMapView({
    super.key,
    required this.tilt,
    required this.bearing,
    required this.center,
    required this.zoom,
    this.ruta = const [],
    this.posicionVehiculo,
this.rumboVehiculo,
    this.onListo,
    this.onControlador,
  });

@override
  State<NavigationMapView> createState() => _NavigationMapViewState();

  /// Rumbo, en grados, del punto [a] al [b].
  ///
  /// Es el rumbo inicial de la flecha cuando arranca un viaje: el primer tramo
  /// de la ruta indica por donde va a salir el coche, que es mas fiable que el
  /// sensor, porque con el vehiculo parado apuntando a otro lado el sensor dice
  /// otra cosa.
  ///
  /// Vive en el widget y no en el `State` porque lo consulta la pantalla, que
  /// es quien decide que rumbo pasarle.
  ///
  /// [a] y [b] son [LatLng], que toma (latitud, longitud).
  static double bearingEntre(LatLng a, LatLng b) {
    const grados = 180.0 / math.pi;
    final dLon = (b.longitude - a.longitude) / grados;
    final lat1 = a.latitude / grados;
    final lat2 = b.latitude / grados;

    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    return (math.atan2(y, x) * grados + 360.0) % 360.0;
  }
}

class _NavigationMapViewState extends State<NavigationMapView> {
  /// El controlador lo crea `MapLibreMap` y lo entrega en `onMapCreated`.
  ///
  /// No se puede pasar por parametro: el constructor de
  /// `MapLibreMapController` exige `maplibrePlatform`, que es interno del
  /// paquete. Por eso se guarda en un campo al crearse el mapa, y todos los
  /// metodos de este State comprueban que no sea null antes de usarlo.
  MapLibreMapController? _controlador;

  /// `true` cuando el estilo ya cargo y se pueden tocar sources y layers.
  bool _estiloListo = false;

  /// Ultima geometria enviada, para no reenviarla si no cambia.
  ///
  /// La ruta cambia cuando OSRM recalcula, no en cada tic del GPS. Comparar
  /// evita ponerla otra vez cuando el numero de puntos es el mismo.
int _puntosRutaEnviados = -1;

  /// Ultima posicion del vehiculo enviada al estilo.
  ///
  /// Se compara por valor, no por numero: el GPS se mueve en cada fix, asi que
  /// aqui no sirve un contador como en la ruta. El umbral descarta las
  /// variaciones de centimas de grado, que son las que hacen parpadear el punto
  /// sin aportarle nada.
  LatLng? _vehiculoEnviado;

  /// Ultimo rumbo enviado, para no reenviar la fuente si no ha girado.
  double _rumboEnviado = -1;

  /// Ultima camara aplicada, para no repetirla en cada actualizacion.
  ///
  /// `moveCamera` con los mismos valores provoca parpadeo, y el GPS manda
  /// centimas de grado en cada fix.
  LatLng? _centroAplicado;
  double? _zoomAplicado;
  double? _tiltAplicado;
  double? _bearingAplicado;

  @override
  void didUpdateWidget(NavigationMapView old) {
    super.didUpdateWidget(old);

    // La camara se actualiza aqui y no en `build`, porque `moveCamera` es
    // asincrono y solo tiene sentido cuando el mapa ya esta montado.
    if (!_estiloListo) return;
_aplicarCamara();
    _aplicarRuta();
    _aplicarVehiculo();
  }

  /// Aplica la camara solo si algo ha cambiado de verdad.
  ///
  /// Los umbrales de tolerancia evitan que el mapa se mueva por variaciones de
  /// centimas del GPS, que se ven como un temblor.
  void _aplicarCamara() {
    final ctl = _controlador;
    final centro = widget.center;
    if (ctl == null || centro == null) return;

    final c = _centroAplicado;
    final z = _zoomAplicado;
    final t = _tiltAplicado;
    final b = _bearingAplicado;

    final cambiaCentro = c == null ||
        (c.latitude - centro.latitude).abs() > 1e-6 ||
        (c.longitude - centro.longitude).abs() > 1e-6;
    final cambiaZoom = z == null || (z - widget.zoom).abs() > 0.01;
    final cambiaTilt = t == null || (t - widget.tilt).abs() > 0.5;
    // El bearing se compara en el camino angular mas corto: de 350 a 10 son
    // +20 grados, no -340, y sin esto la camara daria la vuelta en cada cruce.
    final deltaBearing =
        ((((b ?? 0) - widget.bearing) % 360) + 540) % 360 - 180;
    final cambiaBearing = b == null || deltaBearing.abs() > 0.5;

    if (!cambiaCentro && !cambiaZoom && !cambiaTilt && !cambiaBearing) return;

    _centroAplicado = centro;
    _zoomAplicado = widget.zoom;
    _tiltAplicado = widget.tilt;
    _bearingAplicado = widget.bearing;

// Sin animacion: la camara la manda el GPS, y una transicion de 500 ms
    // llegaria tarde a cada fix, dejando el vehiculo desfasado del mapa.
    ctl.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: centro,
          zoom: widget.zoom,
          // `tilt` nativo. El motor aplica su propia proyeccion y dibuja el
          // fondo lejano: no hace falta ni `Transform` ni compensar el coseno.
          tilt: widget.tilt.clamp(0.0, 60.0),
          bearing: widget.bearing,
        ),
      ),
    );
  }

/// Coloca el vehiculo en el tercio inferior de la pantalla.
  ///
  /// El padding de MapLibre NO centra el objetivo en el rectangulo que queda
  /// libre: lo DESPLAZA desde el centro de la pantalla, y el sentido lo decide
  /// la arista, no el lado contrario:
  ///
  ///   - `padding.top` sube el objetivo.
  ///   - `padding.bottom` lo baja.
  ///
  /// Medido en el movil con `top: 0.14` la flecha salio al 36.4 % del alto,
  /// que es exactamente `50 % - 14 %`. Esa medicion es la que fija este
  /// comentario: antes se creia que el objetivo se centraba en el hueco
  /// restante y se uso `top`, con lo que el vehiculo acababa en el tercio
  /// superior, justo al reves de lo pedido.
  ///
  /// El destino es el 64 %: el tercio inferior, pero con margen antes del panel
  /// del viaje, que empieza hacia el 70 %. A mas bajo, la flecha queda detras
  /// del panel.
  void _aplicarPaddingConduccion() {
    final ctl = _controlador;
    if (ctl == null) return;
    if (_paddingAplicado) return;
    _paddingAplicado = true;
    // Proporcion del alto, medida con el tamano real de la pantalla y no con un
    // literal: en un movil pequeno y en una tablet la proporcion que se busca
    // es la misma.
    final alto = MediaQuery.sizeOf(context).height;
    if (alto <= 0) return;
    ctl.setPadding(top: alto * 0.28);
  }

  /// `true` cuando el padding de conduccion ya se aplico una vez.
  bool _paddingAplicado = false;

  /// Zoom con el que se construyeron los vertices de la flecha por ultima vez.
  double? _zoomEnviado;

  /// Flecha del vehiculo como poligono GeoJSON.
  ///
  /// Se construye en coordenadas geograficas a partir de la posicion, el rumbo
  /// y el zoom, y se pinta con un `FillLayer`, que es la misma primitiva que ya
  /// usan la ruta y el halo (y que si dibujan).
  ///
  /// El tamano se fija en PIXELES DE PANTALLA y se traduce a metros con los
  /// metros por pixel del zoom actual. Asi la flecha mide lo mismo de cerca que
  /// de lejos, que es lo que se ve en las apps de navegacion: el simbolo no
  /// crece con el zoom, lo que lo haria desaparecer en cuanto se aleja un poco.
  ///
  /// Marco local de la figura: `x` hacia delante segun el rumbo, `y` hacia la
  /// derecha.
static Map<String, dynamic> _flechaGeoJson(
    LatLng? pos,
    double rumbo,
    double zoom, {
    double escala = 1.0,
  }) {
    if (pos == null) {
      return {'type': 'FeatureCollection', 'features': <dynamic>[]};
    }

    final latRad = pos.latitude * math.pi / 180.0;
    // Metros por pixel en esta latitud y este zoom. El coseno de la latitud es
    // lo que estira el eje este-oeste: sin el, a 23 grados la flecha sale
    // achaparrada.
    final metrosPorPixel =
        156543.03392 * math.cos(latRad) / math.pow(2.0, zoom);
    // Alto total de la figura, de la punta a la base.
    //
    // El tamano se fija en pixeles DE PANTALLA y no en metros fijos. Con la
    // camara inclinada el suelo que hay por debajo del punto de mira esta mucho
    // mas cerca que el del centro, y ahi un metro por pixel vale bastante menos:
    // una flecha medida en el centro sale de mas del doble abajo. El recorte es
    // el freno: sin el, en un zoom bajo la flecha se comia media pantalla.
    //
    // `escala` multiplica el resultado y es lo que dibuja el borde: el mismo
    // poligono un poco mayor, en blanco, debajo del azul.
    final alto = (metrosPorPixel * 7.2 * escala).clamp(1.0, 40.0);

    // Proporciones medidas sobre la silueta de referencia. En ese dibujo la
    // base es tan ancha como el alto (1.005) y la muesca sube un 28 % desde
    // la base, que es lo que hace que se lea como una flecha y no como un
    // triángulo.
    final mediaBase = alto * 0.5025;
    final muesca = alto * 0.28;

    final rad = rumbo * math.pi / 180.0;
    // Ejes locales girados al rumbo: `adelante` y `derecha`.
    final ax = math.sin(rad);
    final ay = math.cos(rad);
    final dx = math.cos(rad);
    final dy = -math.sin(rad);

    // Un grado de longitud vale menos metros que uno de latitud, y cada vez
    // menos al alejarse del ecuador.
    final metrosPorGradoLng = 111320.0 * math.cos(latRad).abs();
    final metrosPorGradoLat = 110574.0;

    List<double> punto(double adelante, double derecha) {
      final este = ax * adelante + dx * derecha;
      final norte = ay * adelante + dy * derecha;
      return <double>[
        pos.longitude + este / metrosPorGradoLng,
        pos.latitude + norte / metrosPorGradoLat,
      ];
    }

    // Silueta de la referencia: chevron de cuatro vertices con la base
    // CONCAVA. Es lo que la diferencia de un simple triangulo: la muesca
    // central hace que se lea como "voy hacia ahi" y no como "estoy ahi".
    //
    // El vertice no se pone en la punta sino a un 55 % del alto: el vehiculo
    // queda bajo el centro de masa de la figura. Asi, al pintar el borde
    // blanco con la misma figura un 45 % mayor, el escalado separa los cuatro
    // vertices por igual. Con la punta en el origen, el borde no se separaria
    // de ella y la flecha quedaria con el punta sin contornear.
    final anillo = <List<double>>[
      punto(alto * 0.55, 0.0), // punta, al frente
      punto(-alto * 0.45, mediaBase), // punta trasera derecha
      punto(-alto * 0.45 + muesca, 0.0), // muesca, concave
      punto(-alto * 0.45, -mediaBase), // punta trasera izquierda
    ];
    anillo.add(anillo.first);

    return {
      'type': 'FeatureCollection',
      'features': <dynamic>[
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': <List<List<double>>>[anillo],
          },
          'properties': <String, dynamic>{},
        },
      ],
    };
  }

  /// Anade sources y layers al estilo recien cargado.
  ///
  /// **CRITICO**: esto va en `onStyleLoadedCallback`, y no en `initState` ni en
  /// un `onMapCreated` propio. Android recrea la actividad al rotar o al volver
  /// del segundo plano, y MapLibre recarga el estilo entero en ese momento. Los
  /// sources y layers que se habian anadido antes se pierden con el estilo, y el
  /// mapa se queda en blanco aunque la app no haya crasheado. Este es el unico
  /// momento en el que el estilo existe de verdad.
  Future<void> _onStyleLoaded() async {
    final ctl = _controlador;
    if (ctl == null) return;

    _estiloListo = true;

    try {
      // Capa de la ruta.
      //
      // `belowLayerId` marca la capa POR DEBAJO de la cual se inserta esta. Lo
      // que hay que evitar es 'edificios', que es la capa 5 de 12 del estilo:
      // las carreteras son la 7, con lo que la ruta quedaba tapada por la
      // calzada y solo se veian los tramos en que se salia de la calle.
      // Con 'nombres-carretera' (la 8) la ruta va encima de las carreteras y
      // los rotulos siguen escribiendose por encima.
      await ctl.addGeoJsonSource(_idRuta, _lineaGeoJson(widget.ruta));
      await ctl.addLineLayer(
        _idRuta,
        _capaRutaHalo,
        LineLayerProperties(
          // Halo blanco: separa la ruta de las aceras y los edificios. Sin el,
          // la linea azul se mezcla con la calzada, que tambien es blanca.
          //
          // Va mas ancho que el azul por los dos lados, con lo que queda un
          // margen blanco que dibuja el borde de la calle pintada. Crece con
          // el zoom igual que el azul.
          lineColor: '#ffffff',
          lineWidth: [
            'interpolate',
            ['exponential', 1.6],
            ['zoom'],
            12,
            12.0,
            14,
            17.0,
            16,
            22.0,
            18,
            30.0,
          ],
          lineOpacity: 0.85,
          lineJoin: 'round',
        ),
        belowLayerId: 'nombres-carretera',
      );
      await ctl.addLineLayer(
        _idRuta,
        _capaRuta,
        LineLayerProperties(
// Azul fuerte de ruta, del ancho de la calzada para que la calle
          // por la que pasa se vea pintada entera en vez de como una raya.
          //
          // El grosor crece con el zoom porque la calzada tambien: si fuera
          // fijo, a zoom 18 la calle seria mas ancha que la linea y se verian
          // las aceras a los lados, que es justo el efecto que se quiere quitar.
          // A zoom 17 quedan unos 19 px de ancho.
          lineColor: '#1E88E5',
          lineWidth: [
            'interpolate',
            ['exponential', 1.6],
            ['zoom'],
            12,
            8.0,
            14,
            12.0,
            16,
            16.0,
            18,
            22.0,
          ],
          lineOpacity: 0.85,
          lineJoin: 'round',
        ),
        belowLayerId: 'nombres-carretera',
      );

// Flecha de ubicacion del chofer.
      //
      // Se dibuja como POLIGONO en coordenadas geograficas, no como icono ni
      // como glifo. Los dos caminos anteriores fallaron en silencio:
      //
      //  * `text-field: 'â–²'` depende de la pila de fuentes que declara el
      //    servidor de tiles. Si ese caracter no esta, MapLibre no dibuja nada
      //    y la capa se crea sin error.
      //  * `addImage` + `icon-image` tampoco llego a pintarse, con el halo
      //    dibujandose bien al lado.
      //
      // Un `FillLayer` sobre un poligono calculado aqui no depende ni del
      // servidor de tiles ni del registro de imagenes: es la misma primitiva que
      // ya usan la ruta y el halo, que si dibujan. Ademas el tamano lo controlo
      // yo en metros, de modo que la flecha mide lo mismo en pantalla a
      // cualquier zoom.
      // El borde blanco es un SEGUNDO poligono, un 45 % mas grande, pintado
      // debajo del azul. La via rapida habria sido `fill-outline-color`, pero
      // maplibre_gl 0.27 no expone `fill-outline-width`: solo el color, con el
      // ancho por defecto en 0, o sea un contorno de medio pixel que no se ve.
      // Dos poligonos superuestos dan un borde de verdad y con el grosor que
      // se quiera.
      await ctl.addGeoJsonSource(
        _idFlechaBorde,
        _flechaGeoJson(
          widget.posicionVehiculo,
          widget.rumboVehiculo ?? 0.0,
          widget.zoom,
          escala: _escalaBorde,
        ),
      );
      await ctl.addFillLayer(
        _idFlechaBorde,
        _capaVehiculoBorde,
        FillLayerProperties(
          fillColor: '#ffffff',
          fillOpacity: 1.0,
        ),
        belowLayerId: 'nombres-carretera',
      );

      await ctl.addGeoJsonSource(
        _idFlecha,
        _flechaGeoJson(
          widget.posicionVehiculo,
          widget.rumboVehiculo ?? 0.0,
          widget.zoom,
        ),
      );
      await ctl.addFillLayer(
        _idFlecha,
        _capaVehiculo,
        FillLayerProperties(
          // Interior azul de marca.
          fillColor: '#1A73E8',
          fillOpacity: 1.0,
        ),
        belowLayerId: 'nombres-carretera',
      );
    } catch (e) {
      // Si el estilo se recarga mientras se anaden las capas, la excepcion es
      // esperable: se pierde parte del grafico, pero la app no cae. Lo
      // imprescindible (el mapa) ya esta.
      //
      // Se registra igual: con `catch (_)` silencioso, una capa que no se puede
      // crear por un motivo real (una imagen que no se encontro, un id repetido)
      // se confundia con un estilo que se recargo, y se perdia el vehiculo sin
      // dejar rastro. Asi el fallo se ve en el log.
      debugPrint('[MAPA] capas no completas: $e');
      return;
    }

_puntosRutaEnviados = widget.ruta.length;
    _vehiculoEnviado = widget.posicionVehiculo;

    _aplicarCamara();
    _aplicarPaddingConduccion();
    widget.onListo?.call();
  }

  /// Envia la ruta al estilo si ha cambiado.
  void _aplicarRuta() {
    final ctl = _controlador;
    if (ctl == null) return;
    if (widget.ruta.length == _puntosRutaEnviados) return;
    _puntosRutaEnviados = widget.ruta.length;
    ctl.setGeoJsonSource(_idRuta, _lineaGeoJson(widget.ruta));
  }

/// Envia la posicion del vehiculo si ha cambiado de verdad.
  void _aplicarVehiculo() {
    final ctl = _controlador;
    if (ctl == null) return;
    final pos = widget.posicionVehiculo;
    final rumbo = widget.rumboVehiculo ?? 0.0;
    final prev = _vehiculoEnviado;
    final prevRumbo = _rumboEnviado;

    // El umbral esta en la posicion porque es la que mas salta. El rumbo se
    // compara aparte: gira con el vehiculo y en parado se queda quieto, asi
    // que no genera ruido, pero si hay que reenviarlo cuando cambia.
    //
    // El ZOOM tambien cuenta. La flecha no es un icono de tamano fijo: es un
    // poligono cuyos vertices se calculan en metros a partir de los metros por
    // pixel del zoom. Si solo se reenvia cuando se mueve el vehiculo, con el
    // coche parado el zoom cambia de fase y la flecha se queda con la geometria
    // del zoom viejo: medido en el movil, se quedaba con el tamano del zoom 14
    // y a 17 salia de 188 px de ancho en vez de unos 7, que es 26 veces mas.
    final sinCambios = pos == null && prev == null ||
        (pos != null &&
            prev != null &&
            (prev.latitude - pos.latitude).abs() < 1e-5 &&
            (prev.longitude - pos.longitude).abs() < 1e-5 &&
            (prevRumbo - rumbo).abs() < 1.0 &&
            (_zoomEnviado == null ||
                (_zoomEnviado! - widget.zoom).abs() < 0.01));
    if (sinCambios) return;

    _vehiculoEnviado = pos;
    _rumboEnviado = rumbo;
    _zoomEnviado = widget.zoom;
    // La flecha es geometria calculada en metros a partir del zoom, asi que
    // tambien hay que reenviarla cuando el zoom cambia, no solo cuando se mueve
    // el vehiculo. Sin esto se quedaba con el tamano del zoom con el que se
    // creo al entrar en modo navegacion.
    //
    // Se mandan las dos: el borde blanco es el mismo poligono con otra escala.
    ctl.setGeoJsonSource(
      _idFlecha,
      _flechaGeoJson(pos, rumbo, widget.zoom),
    );
    ctl.setGeoJsonSource(
      _idFlechaBorde,
      _flechaGeoJson(pos, rumbo, widget.zoom, escala: _escalaBorde),
    );
  }


  /// GeoJSON de una linea a partir de una lista de coordenadas.
  static Map<String, dynamic> _lineaGeoJson(List<LatLng> puntos) {
    if (puntos.length < 2) {
      return {
        'type': 'FeatureCollection',
        'features': <dynamic>[],
      };
    }
    final coords = puntos
        .map((p) => <double>[p.longitude, p.latitude])
        .toList(growable: false);
    return {
      'type': 'FeatureCollection',
      'features': <dynamic>[
        {
          'type': 'Feature',
          'geometry': {'type': 'LineString', 'coordinates': coords},
          'properties': <String, dynamic>{},
        },
      ],
    };
  }

/// Identificadores. El prefijo evita colisionar con las capas del estilo
  // (`carreteras`, `edificios`...), que son suyas y no se deben tocar.
  static const String _idRuta = 'taxi-ruta';
  static const String _capaRutaHalo = 'taxi-ruta-halo';
  static const String _capaRuta = 'taxi-ruta-linea';
static const String _idFlecha = 'taxi-flecha';
  static const String _capaVehiculo = 'taxi-vehiculo-capa';

  /// Source y capa del contorno blanco.
  ///
  /// Van aparte porque el borde es el MISMO poligono un poco mas grande, no una
  /// propiedad de la capa: maplibre_gl 0.27 no expone `fill-outline-width`.
  static const String _idFlechaBorde = 'taxi-flecha-borde';
  static const String _capaVehiculoBorde = 'taxi-vehiculo-borde-capa';

  /// Cuanto mayor es el poligono blanco respecto al azul.
  ///
  /// Con 1.45 el blanco asoma unos 2 px por lado a los zooms de navegacion:
  /// suficiente para separar la flecha del asfalto y de la ruta azul, sin que
  /// parezca un contorno gruboso.
  static const double _escalaBorde = 1.45;

  @override
  Widget build(BuildContext context) {
    // Centro de partida: La Habana. Solo se usa el primer frame, antes de que
    // llegue el primer fix del GPS.
    final centro = widget.center ?? const LatLng(23.1136, -82.3666);

    return MapLibreMap(
      // Estilo servido por Martin desde el MBTiles local. En el telefono
      // `127.0.0.1` es el propio movil, de ahi el `adb reverse tcp:8010`.
      styleString: ApiConfig.mapStyleUrl,
      initialCameraPosition: CameraPosition(
        target: centro,
        zoom: widget.zoom,
        tilt: widget.tilt.clamp(0.0, 60.0),
        bearing: widget.bearing,
      ),
      onMapCreated: (ctl) {
        _controlador = ctl;
        // Se entrega para los movimientos puntuales de camara de la pantalla.
        widget.onControlador?.call(ctl);
        // El estilo puede haber cargado antes de que llegara aqui. Es un caso
        // normal en mapas rapidos, y sin esta comprobacion las capas nunca se
        // anadirian y el mapa se quedaria sin ruta ni marcador.
        if (_estiloListo) _aplicarCamara();
      },
onStyleLoadedCallback: _onStyleLoaded,
      // Limite de zoom acorde a lo que hay en el MBTiles (z8-z16).
      //
      // Sin esto MapLibre usa `MinMaxZoomPreference.unbounded`, o sea de z0 a
      // z22, y las dos cosas se rompen:
      //
      //  * Por debajo de z8 no hay ni una tesela, asi que al alejar el mapa se
      //    queda en blanco. Es el sintoma de "se desaparece cuando lo alejo".
      //  * Por encima de z16 MapLibre estira las teselas de z16 en vez de
      //    pedir otras nuevas. Aguantan pixeladas, y ademas el mapa se ve mas
      //    borroso sin que nada avise de ello.
      minMaxZoomPreference: MinMaxZoomPreference(
        ApiConfig.minZoom.toDouble(),
        ApiConfig.maxZoom.toDouble(),
      ),
      // El marcador lo dibuja la capa propia, no el punto azul nativo: asi se
      // controla su aspecto y no depende de los permisos de localizacion.
      myLocationEnabled: false,
      myLocationTrackingMode: MyLocationTrackingMode.none,
      // La camara la lleva este widget de forma explicita. El seguimiento
      // automatico del motor lo pelea, porque el servicio tambien decide cuando
      // volver al norte arriba.
      trackCameraPosition: false,
    );
  }
}
