
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Configuración central de la app de chofer.
///
/// Por defecto apunta a los servicios desplegados en Render (backend FastAPI
/// y servidor de tiles Martin). Se puede sobreescribir por línea de comandos
/// con --dart-define, por ejemplo para desarrollo local:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 --dart-define=MARTIN_URL=http://localhost:8010
class ApiConfig {
  ApiConfig._();

  /// URL base del backend FastAPI desplegado en Render.
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://rapitaxi-api-fws6.onrender.com',
  );

  /// URL base del servidor de tiles Martin (del que se sirve el estilo).
  static const String martinUrl = String.fromEnvironment(
    'MARTIN_URL',
    defaultValue: 'https://mlh-tdyg.onrender.com',
  );

  /// URL del estilo de MapLibre, servido por Martin desde el MBTiles.
  /// Se sirve de [martinUrl] y no admite override aparte.
  static String get mapStyleUrl => '$martinUrl/styles/taxi';

  // ---------------- Endpoints del backend ----------------

  /// Timeout por peticion de ruta al proxy del backend.
  ///
  /// 30 s. El proxy ([recalculate]) sale del backend a OSRM, que esta en otro
  /// pais y desde una red movil normal puede tardar. Con 30 s por intento (y
  /// los reintentos de red del cliente) queda margen de sobra sin bloquear la
  /// interfaz.
  static const Duration osrmTimeout = Duration(seconds: 30);

  /// Ruta por carretera calculada por el backend (proxy contra OSRM,
  /// `routers/routing.py`, que monta el prefix `/api/routing`).
  ///
  /// La ruta inicial tambien va por aqui, no directo al servidor publico de
  /// OSRM: desde Cuba ese host es inestable y el fallo dejaba el mapa en linea
  /// recta. Es el mismo canal fiable que ya usa el recalculo de desvios.
  static String recalculate() => '$baseUrl/api/routing/recalculate';

  /// Cancelación de un viaje por el pasajero.
  static String cancelTrip(String tripId) => '$baseUrl/trips/$tripId/cancel';

  /// Cambio de estado (online/offline) de un chofer.
  static String driverStatus(String driverId) =>
      '$baseUrl/drivers/$driverId/status';

  /// Health check del backend.
  static String health() => '$baseUrl/health';

  /// Posición inicial/por defecto del chofer (Centro de La Habana).
  static const LatLng defaultDriverLocation = LatLng(23.1136, -82.3666);

  static const double defaultZoom = 14;
  /// Zoom minimo que se le pide a la camara.
  ///
  /// 10 es lo que habia antes, pero el MBTiles se genero desde z8 (asi lo
  /// produce planetiler con `--minzoom=8`). Se sube el minimo a 10 para no dejar
  /// al conductor en un zoom donde el extracto casi no tiene detalle; el z8 y z9
  /// existen igual y sirven de relleno mientras se aleja.
  static const int minZoom = 10;

  /// Zoom maximo del mapa y de la navegacion: 17.
  ///
  /// Las teselas del servidor de tiles llegan a z16: en z17 (solo la fase de
  /// traslado parada/lenta) MapLibre estira las de z16 ~15 %, un overzoom
  /// aceptable en urbano. Antes el tope era 16 y no dejaba llegar a la tabla
  /// de zooms de navegacion; con 18 las teselas salian muy pixeladas.
  static const int maxZoom = 17;

  /// Zooms del "modo navegación": cada fase del viaje acerca el mapa lo justo
  /// para que el chofer vea la calle por la que va sin perder el contexto.
  ///
  /// - [idle] sin viaje: vista general para ver las ofertas de la zona.
  /// - [recogida] yendo al pasajero: hay que buscar la puerta, se acerca.
  /// - [esperando] ya en el punto: la calle esta justo debajo.
  /// - [traslado] con pasajero a bordo: maximo detalle de calle.
  static const double zoomIdle = 15;
  static const double zoomRecogida = 16;
  static const double zoomEsperando = 16;
  static const double zoomTraslado = 17;

  /// Suelo de zoom del modo navegacion: 14.
  ///
  /// Al pasar de 30 km/h el mapa se ALEJA un nivel (filosofia tipo Google
  /// Maps/Waze: con velocidad hace falta horizonte, no detalle de calle). Este
  /// es el limite de esa salida: ningun zoom de navegacion baja de 14.
  static const double zoomSueloNavegacion = 14;

  /// Techo de zoom del modo navegacion: 17.
  ///
  /// Lo fija la fase de traslado parada/lenta ([zoomTraslado]). Por encima las
  /// teselas de z16 (maximo real del servidor de tiles) se estirarian
  /// demasiado. Coincide con [maxZoom], el tope de la camara del mapa.
  static const double zoomTechoNavegacion = 17.0;

  /// Zoom al que recentra el boton de GPS.
  ///
  /// 18, por encima del techo del modo navegacion (17): recentrar debe acercar
  /// mas que la tabla de fases. Es lo que se ve realmente alrededor del
  /// vehiculo, justo para lo que sirve recentrar: situarse ahi. Sin esto el
  /// boton reutiliza el zoom de la fase (15 sin viaje, 16 yendo a recoger) y
  /// el vehiculo queda pequeno en un mapa demasiado abierto.
  static const double zoomRecentrar = 18.0;

  /// Tilt que se aplica al recentrar, en grados.
  ///
  /// 55, el de ciudad. Recentrar solo mueve la camara: no cambia la velocidad,
  /// asi que el tilt adaptativo se quedaria en 0 por estar parado y el mapa
  /// saldria plano justo cuando el chofer quiere ver la calle de cerca. Forzar
  /// aqui el angulo de ciudad compensa eso.
  ///
  /// Solo se aplica si hay viaje activo: sin trayecto no hay sentido de
  /// conduccion, y una perspective en un mapa sin ruta parece un fallo.
  static const double tiltRecentrar = 55.0;

  /// Velocidad (m/s) a partir de la cual el modo navegacion se ALEJA un nivel
  /// de zoom.
  ///
  /// 8.3 m/s son 30 km/h. Por debajo se mantiene el zoom de la fase.
  static const double velocidadParaZoomRapido = 8.3;

  // ---------------- PARAMETROS DEL MODO NAVEGACION ----------------

  /// Tilt en grados de la vista de conduccion.
  ///
  /// Este es solo el TECHO. El tilt real es adaptativo y se calcula en
  /// [NavigationModeService] segun la velocidad, porque un unico angulo fijo se
  /// ve mal en los dos extremos: a 40 km/h en ciudad una perspectiva de 58
  /// degrees esconde las esquinas, y a 100 km/h un plano de 30 se siente un
  /// mapa plano. Ver [tiltObjetivoParaVelocidad].
  static const double tiltNavegacion = 45.0;

  /// Tilt con el vehiculo inmovil.
  ///
  /// 0. Apoyado en un semaforo, inclinar el mapa solo mete ruido de brujula.
  static const double tiltQuieto = 0.0;

  /// Tilt cuando la perspectiva se degrada por rendimiento.
  ///
  /// 0. El mapa se ve plano y la navegacion sigue funcionando: es preferible
  /// un mapa plano a uno que tironea.
  static const double tiltDegradado = 0.0;


  /// Tilt en ciudad (velocidad baja).
  ///
  /// 55 grados, que es el punto en el que el efecto 3D ya se lee de un vistazo
  /// sin que las calles estrechas de La Habana resulten ilegibles.
  static const double tiltCiudad = 55.0;

  /// Tilt en velocidad de carretera.
  ///
  /// 65 grados. Cuanto mas rapido se va, mas angulo hace falta para llegar a
  /// ver lo que viene: con poca perspectiva el horizonte se queda fuera de
  /// pantalla.
  static const double tiltAutopista = 65.0;

  /// Velocidad (m/s) a partir de la cual se considera carretera y no ciudad.
  ///
  /// 16.7 m/s son 60 km/h.
  static const double velocidadTiltCarretera = 16.7;

  /// Tilt efectivo a partir de la velocidad.
  ///
  /// Interpolacion lineal entre 0 (umbral de ciudad) y [tiltCiudad], y entre
  /// [tiltCiudad] y [tiltAutopista] (umbral de carretera).
  ///
  /// Por debajo de [velocidadMinimaTilt] devuelve [anterior], es decir, el
  /// angulo que ya tenia, en vez de aplanarse a 0. Un mapa que se aplana al
  /// frenar y vuelve a inclinarse al acelerar da dos saltos visibles en cada
  /// semaforo, y mientras esta parado es cuando mas falta hace la
  /// perspectiva: hay que leer la calle y la interseccion que viene.
  ///
  /// El llamante guarda ese valor, porque aqui no hay estado.
  static double tiltObjetivoParaVelocidad(double mps, {double anterior = 0}) {
    if (mps < velocidadMinimaTilt) return anterior;
    if (mps <= velocidadTiltCiudad) {
      final t = (mps - velocidadMinimaTilt) /
          (velocidadTiltCiudad - velocidadMinimaTilt);
      return tiltQuieto + (tiltCiudad - tiltQuieto) * t;
    }
    if (mps >= velocidadTiltCarretera) return tiltAutopista;
    final t = (mps - velocidadTiltCiudad) /
        (velocidadTiltCarretera - velocidadTiltCiudad);
    return tiltCiudad + (tiltAutopista - tiltCiudad) * t;
  }

  /// Tilt con el que ENTRA el mapa al activarse la navegacion, en grados.
  ///
  /// 55, el angulo de ciudad. Antes el mapa arrancaba plano y se inclinaba
  /// solo al primer fix con velocidad, de modo que al recoger un viaje
  /// parado se veía un salto de 0 a 55 grados en plena calle. Entrar ya
  /// inclinado es lo que hace una app de navegacion y ademas es cuando mas
  /// hace falta: quieto en un sitio desconocido, mirando alrededor.
  ///
  /// No se usa [tiltAutopista] porque al arrancar nunca se va a 60 km/h de
  /// golpe, y ese angulo esconde las esquinas de las calles.
  static const double tiltEntradaNavegacion = 55.0;

  /// Velocidad (m/s) a partir de la cual el tilt se mueve.
  ///
  /// 1.4 m/s son 5 km/h. Es el umbral para INICIAR la inclinacion, no para
  /// quitarla: por debajo el mapa conserva el angulo que ya tenia.
  static const double velocidadMinimaTilt = 1.4;

  /// Umbral alto del tramo "ciudad", en m/s (45 km/h).
  static const double velocidadTiltCiudad = 12.5;

  /// Cambio maximo de tilt por segundo, en grados.
  ///
  /// 30 grados/s. Un cambio mas rapido se ve como un tirón, sobre todo al salir
  /// de un semaforo. El objetivo de [tiltObjetivoParaVelocidad] se persigue con
  /// esta rampa en lugar de saltar.
  static const double rampaTiltGradosPorSegundo = 30.0;

  /// Duracion de la animacion del tilt al entrar y al salir del modo.
  ///
  /// 500 ms. Solo se anima en esas transiciones, nunca por tic del GPS.
  static const Duration duracionTilt = Duration(milliseconds: 500);

  /// FPS por debajo del cual se degrada la perspectiva.
  static const int fpsMinimoTilt = 30;

  /// Tiempo que hay que estar por debajo de [fpsMinimoTilt] para degradar.
  ///
  /// 2 s. Evita que un tirón puntual (una llamada, la apertura de otra app)
  /// apague la perspectiva y la vuelva a encender.
  static const Duration antiguedadDegradacion = Duration(seconds: 2);

  /// FPS por encima del cual se recupera la perspectiva.
  ///
  /// 45. Con margen sobre [fpsMinimoTilt]: si el dispositivo esta justo en el
  /// limite, oscilar entre tilt y plano seria peor que quedarse en plano.
  static const int fpsRecuperacionTilt = 45;

  /// Tiempo por encima de [fpsRecuperacionTilt] para recuperar la perspectiva.
  ///
  /// 3 s.
  static const Duration antiguedadRecuperacion = Duration(seconds: 3);


  /// Margen angular (grados) bajo el cual no se toca la rotacion.
  ///
  /// Sin este margen, cada micro-variacion del GPS redibuja los tiles y el
  /// mapa tiembla.
  static const double deadbandRotacion = 0.7;

  // ---------------- RECALCULO DE RUTA POR DESVIO ----------------

  /// Distancia a la ruta a partir de la cual se considera desvio, en ciudad.
  ///
  /// 40 m. El GPS urbano tiene ruido de 10-30 m por los edificios y las calles
  /// estrechas, asi que un umbral mas bajo daria recambios falsos en cada
  /// esquina. Con 40 y tres muestras seguidas, un fix suelto脱出 nunca llega a
  /// disparar.
  static const double desvioUmbralCiudadMetros = 40.0;

  /// Distancia de desvio en carretera, en metros.
  ///
  /// 80. Fuera de la ciudad la carretera es mas ancha y el GPS mas limpio, asi
  /// que se puede exigir mas antes de dar por bueno un desvio.
  static const double desvioUmbralCarreteraMetros = 80.0;

  /// Muestras consecutivas fuera de umbral que confirman un desvio.
  ///
  /// 3. A 1 Hz son 3 segundos: tiempo de sobra para que un fix erroneo se
  /// desmienta solo, y lo justo para no tardar en corregir cuando el giro se
  /// ha de hecho de verdad.
  static const int desvioMuestrasConsecutivas = 3;

  /// Velocidad (m/s) a partir de la cual se considera carretera.
  ///
  /// 16.7 m/s son 60 km/h. El mismo umbral que usa el resto del modo
  /// navegacion, para que la idea de "carretera" sea una sola en toda la app.
  static const double desvioVelocidadCarreteraMps = 16.7;

  /// Silencio tras pedir un recalculo, antes de volver a detectar desvio.
  ///
  /// 5 s. El conductor no corrige en el instante: hasta que no haya girado, su
  /// posicion sigue sobre la calle vieja y volver a medir daria un segundo
  /// recalculo nada mas. Sin esto se encadena un recalculo cada tres segundos.
  static const Duration desvioPausaMsTrasRecalculo = Duration(seconds: 5);

  /// Enfriamiento tras recibir una ruta correcta.
  ///
  /// 10 s. Si el recalculo fue bien pero el conductor sigue lejos de la ruta
  /// nueva (destino inalcanzable, obra en la calle) da tiempo a que se
  /// asiente antes de volver a intentarlo.
  static const Duration desvioEnfriamientoMs = Duration(seconds: 10);

  /// Primer intervalo de reintento tras un fallo.
  static const Duration desvioBackoffInicial = Duration(seconds: 5);

  /// Intentos con fallo antes de rendirse.
  ///
  /// 4. Con el backoff del primer intento salen 5, 10, 20 y 40 segundos. Pasado
  /// el cuarto se para: seguir intentando sin parar no aporta nada y el
  /// conductor sigue viendo la ruta anterior.
  static const int desvioIntentosMaximos = 4;

  /// Velocidad (m/s) por debajo de la cual puede entrar la pausa por parado.
  ///
  /// 0.28 m/s son 1 km/h.
  static const double pausaVelocidadBajaMps = 0.28;

  /// Muestras a este ritmo para considerar que el vehiculo esta realmente
  /// parado.
  ///
  /// 10. A 1 Hz son 10 segundos. Frenar en un semaforo no debe pausar nada: solo
  /// una parada de verdad, con el motor al ralenti.
  static const int pausaMuestrasParado = 10;

  /// Velocidad (m/s) por encima de la cual se sale de la pausa.
  ///
  /// 0.83 m/s son 3 km/h. El margen respecto a la entrada evita que el GPS
  /// oscilando en el umbral entre y salga de la pausa varias veces seguidas.
  static const double pausaVelocidadAltaMps = 0.83;

  /// Duracion de las transiciones de camara.
  ///
  /// 400 ms queda dentro del rango pedido de 300-500 ms y se siente suelto sin
  /// quedarse a medio camino en un cruce.
  static const Duration duracionTransicion = Duration(milliseconds: 400);

  /// Velocidad (m/s) por debajo de la cual se vuelve al norte arriba.
  ///
  /// 0.7 m/s son ~2.5 km/h. Coincide con el umbral del filtro de rumbo, para
  /// que el mapa no se ponga a girar en un semaforo.
  static const double velocidadMinimaHeading = 0.7;


  /// Velocidad (m/s) que reactiva el modo follow si el usuario lo habia
  /// interrumpido moviendo el mapa.
  ///
  /// 5 km/h.
  static const double velocidadReactivarFollow = 1.39;

  /// Tiempo por encima de [velocidadReactivarFollow] necesario para volver al
  /// follow automatico.
  static const Duration antiguedadReactivar = Duration(seconds: 3);

  /// Zoom segun la distancia al objetivo.
  ///
  /// El cliente no rota el mapa, asi que su unica referencia para decidir cuanto
  /// acercar es lo lejos que esta el vehiculo. Tabla unica, compartida por las
  /// dos apps para que el pasajero y el chofer vean el mismo encuadre.
  static double zoomPorDistancia(double metros) {
    if (metros <= 300) return 17;
    if (metros <= 800) return 16;
    if (metros <= 2000) return 15;
    if (metros <= 5000) return 14;
    return 13;
  }

  /// Zoom de la fase actual del viaje, para establishes el modo navegación.
  ///
  /// Devuelve [zoomIdle] si no hay viaje en curso.
  static double zoomParaFase({String? status}) {
    switch (status) {
      case 'accepted':
        return zoomRecogida;
      case 'driver_arrived':
        return zoomEsperando;
      case 'in_progress':
        return zoomTraslado;
      default:
        return zoomIdle;
    }
  }

  /// Área cubierta por los tiles locales del mapa (La Habana, Artemisa,
  /// Mayabeque y Pinar del Río).
  ///
  /// Solo se muestran direcciones de calles que caen dentro de esta zona,
  /// es decir, las que existen en el mapa de la app.
  static const double mapSouth = 21.85;
  static const double mapNorth = 23.55;
  static const double mapWest = -84.30;
  static const double mapEast = -81.80;

  /// `true` si el punto está dentro del área cartografiada del mapa.
  static bool inMapArea(LatLng p) =>
      p.latitude >= mapSouth &&
      p.latitude <= mapNorth &&
      p.longitude >= mapWest &&
      p.longitude <= mapEast;
}
