import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api_config.dart';

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
}

/// Punto de entrada del isolate background. El icono `@pragma` evita que
/// AOT lo elimine, que es el error tipico de "el servicio arranca vacio".
@pragma('vm:entry-point')
Future<void> onStartOfertas(ServiceInstance servicio) async {
  DartPluginRegistrant.ensureInitialized();

  // Contexto desde SharedPreferences: token, driver_id, tipo activo y la
  // ultima posicion que la pantalla guardo con cada fix del GPS.
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('driver_token') ?? '';
  final driverId = prefs.getString('driver_id') ?? '';

  final aviso = _AvisosService();
  await aviso.init();

  // Estado local del servicio: ofertas que avisaron y a la que hay que
  // retirar al caducar. Vive SOLO en este isolate.
  final Map<String, Timer> timers = {};
  final Set<String> avisadas = {};

  void retirar(String tripId) {
    timers.remove(tripId)?.cancel();
    if (avisadas.remove(tripId)) {
      unawaited(aviso.cancelar(tripId));
    }
  }

  // Marca de corte: si el latido de la pantalla corre, no sondeamos.
  const corteLatido = Duration(seconds: 15);
  Future<bool> latidoFresco() async {
    final p = await SharedPreferences.getInstance();
    final ts = p.getInt(OfertasBackgroundService._prefPollTs) ?? 0;
    final ms = DateTime.now().millisecondsSinceEpoch;
    return (ms - ts) < corteLatido.inMilliseconds;
  }

  Timer.periodic(const Duration(seconds: 4), (_) async {
    try {
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
  return 60;
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
  }

  int _idDe(String tripId) => tripId.hashCode & 0x7fffffff;

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
}
