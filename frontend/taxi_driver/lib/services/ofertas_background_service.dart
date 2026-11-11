import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_config.dart';

/// Crea el canal del SERVICIO (no confundir con el de ofertas).
///
/// flutter_background_service publica su notificacion persistente en este
/// canal. Android exige que el canal EXISTA antes de que el servicio entre
/// en primer plano: si no existe, `startForeground` muere con
/// "Bad notification for startForeground" y la app se cierra en el instante
/// de activar "En linea". Se crea con importancia `low`: silencioso y
/// silencio, solo el "RapiTaxi: Buscando viajes..."; las ofertas usan el
/// canal `trip_offers_v3` con el tono spacebell.
Future<void> crearCanalServicio() async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(AndroidNotificationChannel(
        'rapitaxi_service_v1',
        'Servicio de solicitudes',
        description: 'Mantiene la busqueda de viajes activa en segundo plano.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ));
}

/// Servicio en primer plano del chofer "En linea".
///
/// Sin FCM a proposito (no es fiable en Cuba), el aviso de ofertas depende de
/// sondear el backend. Mientras la app esta abierta lo hace la pantalla; el
/// problema es al pasar a segundo plano: Android congela el proceso y el
/// chofe deja de recibir ofertas sin enterarse.
///
/// [flutter_background_service] resuelve eso con un MOTOR PROPIO de Flutter
/// que vive dentro de un servicio foreground de Android:
///
///  * Mantiene viva la notificacion persistente "RapiTaxi: Buscando viajes...":
///    para Android el proceso deja de ser "candidato a matar".
///  * Vigila el sondeo de la pantalla principal por medio de un latido en
///    `SharedPreferences` ([_prefPollTs]). Si el latido se congela (app
///    cerrada o proceso despedida), el servicio TOMA EL SONDEO: consulta las
///    ofertas con la ultima posicion conocida y muestra los avisos
///    "¡Nuevo Viaje!" en el panel.
///  * Mientras el latido corre (app viva), el servicio no consulta nada: una
///    sola maquina sondea, sin peticiones duplicadas ni avisos dobles.
///
/// Los avisos usan el MISMO canal (`trip_offers_v3`) y el mismo id numérico
/// que los de la pantalla (hash del `trip_id`), de modo que si llegan a
/// solaparse, Android reemplaza uno por otro en lugar de acumular dos.
class OfertasBackgroundService {
  OfertasBackgroundService._();

  static final OfertasBackgroundService instancia = OfertasBackgroundService._();

  final FlutterBackgroundService _service = FlutterBackgroundService();

  static const _prefPollTs = 'bg_poll_ts';
  static const _prefLastLat = 'bg_last_lat';
  static const _prefLastLng = 'bg_last_lng';
  static const _prefTipo = 'bg_tipo_vehiculo';

  /// Esta la app VISIBLE (lifecycle `resumed`)? La escribe la pantalla.
  ///
  /// El servicio solo muestra la notificacion de "viaje asignado" cuando la
  /// app no esta en primer plano: si el chofer la tiene abierta, el panel del
  /// viaje es suficiente y una notificacion del sistema seria ruido.
  static const _prefForeground = 'bg_foreground';

  /// Viaje asignado por el administrador que hay que recuperar al volver a la
  /// app (segundo plano o notificacion tocada). Lo escribe el servicio.
  static const String prefViajeAsignado = 'bg_force_trip';

  /// Ultimo viaje asignado que YA se notifico, para no repetir el aviso en
  /// cada ciclo del sondeo de respaldo.
  static const _prefForceNotified = 'bg_force_notified';

  /// Id del proceso de arranque de la app: el servicio ignora una oferta
  /// detectada mas de `ttlAviso` seg antes, y programa su retiro igual que la
  /// pantalla principal.
  static const int ttlAviso = 60;

  bool _configurado = false;

  Future<bool> activo() => _service.isRunning();

  /// Configura el servicio una vez. Sin autoStart: solo arranca con el
  /// toggle "En linea" del chofer.
  Future<void> configurar() async {
    if (_configurado) return;
    // El canal del servicio debe existir ANTES de configure()/startService():
    // sin canal, el `startForeground` muere ("Bad notification") y la app se
    // cierra justo al ponerse en linea.
    if (defaultTargetPlatform == TargetPlatform.android) {
      await crearCanalServicio();
    }
    _configurado = true;
    // La notificacion persistente usa su propio canal sin sonido ni
    // vibracion: SOLO avisa de que el servicio vive. Las ofertas usan el
    // canal `trip_offers_v3` del plugin de notificaciones, con el tono
    // `spacebell`.
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStartOfertas,
        isForegroundMode: true,
        autoStart: false,
        autoStartOnBoot: false,
        notificationChannelId: 'rapitaxi_service_v1',
        initialNotificationTitle: 'RapiTaxi',
        initialNotificationContent: 'Buscando viajes...',
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        onForeground: onStartOfertas,
        autoStart: false,
      ),
    );
  }

  /// Arranca el servicio. Todo el contexto viaja por `SharedPreferences`
  /// (token, driver_id, ultima posicion y tipo activo): esta version del
  /// plugin no accepts argumentos en `startService`.
  Future<void> arrancar({
    required String driverId,
    required String token,
    String? tipoVehiculo,
  }) async {
    await configurar();
    await OfertasBackgroundService.guardarTipo(tipoVehiculo);
    if (!await _service.isRunning()) {
      await _service.startService();
    }
  }

  Future<void> detener() async {
    try {
      if (await _service.isRunning()) {
        _service.invoke('stopService');
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    } catch (_) {
      // El servicio ya se va a cerrar solo cuando se apague el proceso.
    }
  }

  // ------------------- escritura de latidos desde la UI -------------------

  /// Guarda la ultima posicion conocida. La llama la pantalla con cada fix
  /// del modo flota; el servicio la usa para sondear si tiene que tomar el
  /// relevo.
  static Future<void> guardarUltimaPosicion(double lat, double lng) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefLastLat, lat);
      await prefs.setDouble(_prefLastLng, lng);
    } catch (_) {}
  }

  /// Marca que el sondeo de la pantalla principal corrio hace nada. Es el
  /// indicador que el servicio lee para decidir si apoyar el sondeo o
  /// reservar.
  static Future<void> latido() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefPollTs, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<void> guardarTipo(String? tipo) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (tipo == null || tipo.isEmpty) {
        await prefs.remove(_prefTipo);
      } else {
        await prefs.setString(_prefTipo, tipo);
      }
    } catch (_) {}
  }

  /// La pantalla avisa cuando pasa a primer plano o a segundo plano.
  ///
  /// El servicio lo usa para decidir si debe mostrar la notificacion de viaje
  /// asignado o si la UI ya se esta encargando.
  static Future<void> marcarPrimerPlano(bool activo) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefForeground, activo);
    } catch (_) {}
  }

  /// Viaje asignado que el servicio detecto y la UI debe montar al volver.
  static Future<String?> leerViajeAsignado() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(prefViajeAsignado);
    } catch (_) {
      return null;
    }
  }

  /// La UI ya monto el viaje: no hay que recuperarlo otra vez.
  static Future<void> limpiarViajeAsignado() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefViajeAsignado);
    } catch (_) {}
  }
}

/// Punto de entrada del isolate background. El icono `@pragma` evita que
/// AOT lo elimine, que es el error tipico de "el servicio arranca vacio".
@pragma('vm:entry-point')
Future<void> onStartOfertas(ServiceInstance servicio) async {
  DartPluginRegistrant.ensureInitialized();

  // El servicio puede ser reiniciado por el sistema en CUALQUIER momento
  // (app cerrada, crash previo). Los canales de notificacion se crean aqui
  // otra vez por si este isolate es lo primero que corre del proceso: sin el
  // canal del servicio, el de ofertas y el de asignaciones, el primer
  // `startForeground`/`show` tumbaria el proceso.
  try {
    await crearCanalServicio();
  } catch (_) {}

  // Contexto desde SharedPreferences: token, driver_id, tipo activo y la
  // ultima posicion que la pantalla guardo con cada fix del GPS.
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('driver_token') ?? '';
  final driverId = prefs.getString('driver_id') ?? '';

  // Viaje que la app ya tenia cuando arranco el servicio. Cualquier otro
  // viaje vivo que aparezca despues es una asignacion NUEVA (force-assign) y
  // merece aviso.
  final marcadorAlArrancar = prefs.getString('viaje_activo_trip') ?? '';
  final yaNotificado = prefs.getString(OfertasBackgroundService._prefForceNotified);

  final aviso = _AvisosService();
  await aviso.init();

  // Estado local del servicio: ofertas que avisaron y a la que hay que
  // retirar al caducar. Vive SOLO en este isolate.
  final Map<String, Timer> timers = {};
  final Set<String> avisadas = {};

  // Asignaciones ya avisadas. Se siembra con la ultima persistida para que un
  // reinicio del servicio no repita la notificacion del mismo viaje.
  final Set<String> asignadasAvisadas = <String>{
    if (yaNotificado != null && yaNotificado.isNotEmpty) yaNotificado,
  };

  void retirar(String tripId) {
    timers.remove(tripId)?.cancel();
    if (avisadas.remove(tripId)) {
      unawaited(aviso.cancelar(tripId));
    }
  }

  // Marca de corte: si el latido de la pantalla corre, no sondeamos ofertas.
  const corteLatido = Duration(seconds: 15);
  Future<bool> latidoFresco() async {
    final p = await SharedPreferences.getInstance();
    final ts = p.getInt(OfertasBackgroundService._prefPollTs) ?? 0;
    final ms = DateTime.now().millisecondsSinceEpoch;
    return (ms - ts) < corteLatido.inMilliseconds;
  }

  /// La UI esta visible y atendiendo los eventos.
  ///
  /// Se exigen las dos cosas: el flag de lifecycle Y el latido del sondeo. Si
  /// el proceso de la app murio de golpe, el flag puede quedar obsoleto en
  /// `true`; el latido congelado lo delata y deja que el servicio avise.
  Future<bool> enPrimerPlano() async {
    final p = await SharedPreferences.getInstance();
    final visible =
        p.getBool(OfertasBackgroundService._prefForeground) ?? false;
    if (!visible) return false;
    return latidoFresco();
  }

  /// Notificacion local de alta prioridad: el viaje ya es de este chofer.
  Future<void> avisarAsignado(String tripId, String recogida) async {
    if (!asignadasAvisadas.add(tripId)) return;
    await aviso.mostrarAsignado(tripId, recogida);
    // El viaje ya no es una oferta: retirar el aviso de oferta del mismo id,
    // que se calcula con otro espacio numerico.
    await aviso.cancelar(tripId);
    final p = await SharedPreferences.getInstance();
    await p.setString(OfertasBackgroundService._prefForceNotified, tripId);
    await p.setString(OfertasBackgroundService.prefViajeAsignado, tripId);
  }

  // ---------------- Viaje asignado: WebSocket ----------------
  //
  // El canal `driver:{id}:offers` es el mismo de las ofertas. El backend
  // publica ahi `trip_force_assigned` con el viaje completo. Este isolate
  // mantiene su PROPIA conexion: la de la pantalla puede estar congelada o
  // muerta cuando el telefono esta bloqueado.
  final ws = _WsAsignaciones(
    driverId: driverId,
    tokenInicial: token,
    onAsignado: (tripId, datos) async {
      // Con la app visible manda la UI, que ademas detiene el radar.
      if (await enPrimerPlano()) return;
      await avisarAsignado(tripId, _recogidaDe(datos));
    },
  );
  ws.iniciar();

  // ---------------- Viaje asignado: respaldo HTTP ----------------
  //
  // En redes cubanas el WS puede tardar en reconectar. El historial del chofer
  // es barato y permite detectar la asignacion aunque el push no llegue.
  Future<void> revisarAsignacionPorHttp() async {
    if (token.isEmpty || driverId.isEmpty) return;
    try {
      final resp = await http
          .get(
            Uri.parse(
                '${ApiConfig.baseUrl}/trips/driver/$driverId?limit=5'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return;

      final list = jsonDecode(utf8.decode(resp.bodyBytes));
      if (list is! List) return;

      Map? viaje;
      for (final j in list) {
        if (j is Map && _estadosVivos.contains(j['status'])) {
          viaje = j;
          break;
        }
      }
      if (viaje == null) return;

      final tripId = viaje['trip_id']?.toString() ?? '';
      if (tripId.isEmpty) return;
      // Ese viaje ya lo tenia la app al arrancar el servicio: no es nuevo.
      if (tripId == marcadorAlArrancar) return;
      if (asignadasAvisadas.contains(tripId)) return;

      // Direccion legible: el historial no trae `request_address`.
      var recogida = 'Direccion pendiente de confirmar';
      try {
        final detalle = await http
            .get(
              Uri.parse('${ApiConfig.baseUrl}/trips/$tripId'),
              headers: {'Authorization': 'Bearer $token'},
            )
            .timeout(const Duration(seconds: 15));
        if (detalle.statusCode == 200) {
          final j = jsonDecode(utf8.decode(detalle.bodyBytes));
          if (j is Map) recogida = _recogidaDe(j);
        }
      } catch (_) {
        // Se avisa igual con la direccion pendiente.
      }

      if (await enPrimerPlano()) return;
      await avisarAsignado(tripId, recogida);
    } catch (_) {
      // El siguiente ciclo reintenta.
    }
  }

  servicio.on('stopService').listen((_) {
    ws.detener();
    servicio.stopSelf();
  });

  Timer.periodic(const Duration(seconds: 4), (_) async {
    try {
      // En segundo plano (o con la app congelada) se vigila la asignacion
      // manual aunque el latido siga fresco: un telefono minimizado no es un
      // telefono visible.
      if (!await enPrimerPlano()) {
        await revisarAsignacionPorHttp();
      }

      if (await latidoFresco()) return;

      final p = await SharedPreferences.getInstance();
      final lat = p.getDouble(OfertasBackgroundService._prefLastLat);
      final lng = p.getDouble(OfertasBackgroundService._prefLastLng);
      final tipo = p.getString(OfertasBackgroundService._prefTipo) ?? '';
      if (lat == null || lng == null) return;

      final query = StringBuffer()
        ..write('lat=$lat')
        ..write('lng=$lng')
        ..write('radius_km=5&limit=20');
      if (driverId.isNotEmpty) {
        query.write('&driver_id=$driverId');
      }
      if (tipo.isNotEmpty) {
        query.write('&vehicle_type=${Uri.encodeQueryComponent(tipo)}');
      }

      final resp = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/trips/requested-nearby'
                '?$query'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return;

      final List<dynamic> list = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
      final idsVivos = <String>{
        for (final j in list)
          if (j is Map && j['trip_id'] != null) j['trip_id'].toString(),
      };

      // Lo que dejo de venir: retirar el aviso.
      for (final id in List<String>.from(avisadas)) {
        if (!idsVivos.contains(id)) retirar(id);
      }

      // Lo nuevo: avisar.
      for (final j in list) {
        if (j is! Map) continue;
        final tripId = j['trip_id']?.toString();
        if (tripId == null || tripId.isEmpty || avisadas.contains(tripId)) {
          continue;
        }
        final rec = _recogidaDe(j);
        final segs = _expiresDe(j);
        await aviso.mostrar(tripId, rec);
        avisadas.add(tripId);
        timers[tripId] = Timer(Duration(seconds: segs), () => retirar(tripId));
      }
    } catch (_) {
      // Un ciclo que falle se reintenta en el siguiente; el chofer no debe
      // enterarse de un lapse de red.
    }
  });
}

/// Estados en los que el chofer ya tiene un viaje encima.
const Set<String> _estadosVivos = {
  'accepted',
  'driver_on_the_way',
  'driver_arrived',
  'in_progress',
};

/// WebSocket del isolate de segundo plano.
///
/// Es una conexion PROPIA, distinta de la de `WsChofer` en la pantalla. El
/// isolate de UI puede estar congelado o muerto cuando el telefono se bloquea;
/// esta conexion vive con el servicio en primer plano y recibe el empujon
/// `trip_force_assigned` aunque la app no se este dibujando.
class _WsAsignaciones {
  _WsAsignaciones({
    required this.driverId,
    required this.tokenInicial,
    required this.onAsignado,
  });

  final String driverId;
  final String tokenInicial;
  final Future<void> Function(String tripId, Map<String, dynamic> datos)
      onAsignado;

  WebSocketChannel? _canal;
  Timer? _reconexion;
  bool _deseado = false;

  void iniciar() {
    _deseado = true;
    unawaited(_conectar());
  }

  void detener() {
    _deseado = false;
    _reconexion?.cancel();
    _reconexion = null;
    try {
      _canal?.sink.close();
    } catch (_) {}
    _canal = null;
  }

  Future<void> _conectar() async {
    if (!_deseado || driverId.isEmpty) return;
    // El token se relee en cada reconexion: la pantalla puede haberlo
    // renovado mientras esta conexion estaba caida.
    String token = tokenInicial;
    try {
      final p = await SharedPreferences.getInstance();
      token = p.getString('driver_token') ?? tokenInicial;
    } catch (_) {}
    if (!_deseado) return;

    try {
      final base = ApiConfig.baseUrl;
      final ws = base.startsWith('https://')
          ? base.replaceFirst('https://', 'wss://')
          : base.replaceFirst('http://', 'ws://');
      final canal = WebSocketChannel.connect(Uri.parse(
          '$ws/ws/chofer/$driverId?token=${Uri.encodeQueryComponent(token)}'));
      _canal = canal;
      canal.stream.listen(
        (crudo) {
          try {
            final env = jsonDecode(crudo as String);
            if (env is! Map) return;
            final datos = env['datos'];
            if (datos is! Map) return;
            final evento = Map<String, dynamic>.from(datos);
            if ((evento['event'] ?? '') != 'trip_force_assigned') return;
            final tripId = (evento['trip_id'] ?? '').toString();
            if (tripId.isEmpty) return;
            unawaited(onAsignado(tripId, evento));
          } catch (_) {
            // Payload ilegible: se ignora, el respaldo HTTP lo cubre.
          }
        },
        onDone: _reconectar,
        onError: (Object _) => _reconectar(),
      );
    } catch (_) {
      _reconectar();
    }
  }

  void _reconectar() {
    if (!_deseado) return;
    _reconexion?.cancel();
    _reconexion = Timer(const Duration(seconds: 5), () {
      if (_deseado) unawaited(_conectar());
    });
  }
}

/// Campos que el aviso necesita, aislados del mapa JSON por si el backend
/// cambia una clave.
String _recogidaDe(Map j) {
  String? dir = j['request_address']?.toString();
  if (dir == null || dir.trim().isEmpty) {
    dir = j['request_location']?.toString();
  }
  return (dir == null || dir.trim().isEmpty)
      ? 'Direccion pendiente de confirmar'
      : dir.trim();
}

int _expiresDe(Map j) {
  final v = j['offer_expires_in_secs'];
  if (v is num && v > 0) return v.ceil();
  // Sin dato del servidor se usa la misma ventana unica de solicitud (240 s).
  // Antes eran 60 s y el aviso en segundo plano moria antes que el viaje.
  return 240;
}

/// Panel de notificaciones del isolate del servicio.
///
/// Se instancia aparte del `PlatformNotificationPort` de la pantalla a
/// proposito: cada isolate tiene su plugin. El canal y los ids coinciden con
/// los de la pantalla, asi que Android no crea dos escalones de notificacion.
class _AvisosService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _inicializado = false;

  Future<void> init() async {
    if (_inicializado) return;
    _inicializado = true;
    await _plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    final canal = AndroidNotificationChannel(
      'trip_offers_v3',
      'Ofertas de viaje',
      description: 'Aviso de una nueva oferta de viaje.',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('spacebell'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 700, 400, 700]),
      enableLights: true,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(canal);

    // Canal PROPIO del viaje asignado. No se reutiliza `trip_offers_v3`
    // porque Android fija la importancia y el texto del canal al crearlo, y
    // aqui el aviso es mas urgente y persistente que una oferta.
    final canalAsignado = AndroidNotificationChannel(
      'trip_assigned_v1',
      'Viajes asignados',
      description: 'Aviso de un viaje asignado manualmente por el administrador.',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('spacebell'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 900, 300, 900, 300, 900]),
      enableLights: true,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(canalAsignado);
  }

  int _idDe(String tripId) => tripId.hashCode & 0x7fffffff;

  /// Id de la notificacion de viaje asignado, en un espacio distinto al de la
  /// oferta del mismo viaje para que no se pisen.
  int _idAsignado(String tripId) =>
      ('force_$tripId').hashCode & 0x7fffffff;

  Future<void> mostrar(String tripId, String rec) async {
    await init();
    final detalles = AndroidNotificationDetails(
      'trip_offers_v3',
      'Ofertas de viaje',
      channelDescription: 'Aviso de una nueva oferta de viaje.',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('spacebell'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 700, 400, 700]),
      enableLights: true,
      visibility: NotificationVisibility.public,
      timeoutAfter: OfertasBackgroundService.ttlAviso * 1000,
      styleInformation:
          BigTextStyleInformation('Recogida en: $rec'),
    );
    await _plugin.show(
      _idDe(tripId),
      '¡Nuevo Viaje!',
      'Recogida en: $rec',
      NotificationDetails(android: detalles),
      payload: tripId,
    );
  }

  Future<void> cancelar(String tripId) => _plugin.cancel(_idDe(tripId));

  /// Aviso de alta prioridad: el administrador te asigno este viaje.
  ///
  /// El payload lleva el prefijo `force:` para que la pantalla principal
  /// distinga este toque de uno de oferta y navegue directo al viaje.
  Future<void> mostrarAsignado(String tripId, String rec) async {
    await init();
    final detalles = AndroidNotificationDetails(
      'trip_assigned_v1',
      'Viajes asignados',
      channelDescription:
          'Aviso de un viaje asignado manualmente por el administrador.',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('spacebell'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 900, 300, 900, 300, 900]),
      enableLights: true,
      visibility: NotificationVisibility.public,
      autoCancel: true,
      category: AndroidNotificationCategory.call,
      styleInformation: BigTextStyleInformation(
        'Recogida en: $rec\nToca para abrir el viaje.',
      ),
    );
    await _plugin.show(
      _idAsignado(tripId),
      '¡Viaje Asignado!',
      'Recogida en: $rec',
      NotificationDetails(android: detalles),
      payload: 'force:$tripId',
    );
  }

  Future<void> cancelarAsignado(String tripId) =>
      _plugin.cancel(_idAsignado(tripId));
}
