import 'dart:async';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/models.dart';

/// Avisa al chofer de que hay una oferta de viaje.
///
/// Dos cosas a la vez, y solo dos:
///
///  * Una notificacion en el panel del telefono, con el tono `spacebell` y
///    vibracion. Tocar la notificacion abre la app, donde esta la tarjeta de
///    oferta con su cuenta atras y sus botones.
///  * Un contador en el icono del launcher.
///
/// No ocupa la pantalla ni la despierta. Antes se intento presentar la oferta
/// como llamada entrante a pantalla completa, pero en la practica no era
/// fiable: depende de permisos que Android 14 no concede solo y hay fabricantes
/// que la bloquean. El panel de notificaciones no depende de nada de eso.
///
/// Decisiones que condicionan el diseno:
///
///  * **El reloj es un [Stopwatch], nunca `DateTime.now()`.** El plazo de la
///    oferta llega como `expires_in_secs` (segundos, relativo), asi que un
///    cambio de hora del movil o de zona horaria no puede acortar ni alargar
///    el plazo.
///
///  * **La tarjeta de la app sigue siendo la principal.** Este servicio no
///    decide si se abre la tarjeta ni llama al backend: solo avisa. Asi, si el
///    panel falla por lo que sea, el flujo de ofertas sigue exactamente como
///    estaba.
///
///  * **No sondea nada.** El servicio consume lo que el sondeo existente de la
///    pantalla principal ya trae, para no duplicar trafico ni gasto de bateria.
class TripNotificationService {
  TripNotificationService._({AppBadgePort? badge, NotificationPort? notifier})
      : _badgePort = badge ?? AppBadgePort.launcher(),
        _notifier = notifier ?? NotificationPort.platform();

  /// Instancia normal, con la notificacion y el badge reales.
  static TripNotificationService create({
    AppBadgePort? badge,
    NotificationPort? notifier,
  }) =>
      TripNotificationService._(badge: badge, notifier: notifier);

  /// Segundos de vida por defecto si el backend no manda `expires_in_secs`.
  ///
  /// Coincide con el `OFFER_TTL_SECS` del backend. Es red de seguridad: es
  /// preferible retirar el aviso a dejarlo sonando sin limite.
  static const int fallbackExpiresSecs = 60;

  /// Canal de las notificaciones de oferta.
  static const String channelId = 'trip_offers';
  static const String channelName = 'Ofertas de viaje';

  /// Timbres en `android/app/src/main/res/raw`. Sin el prefijo `android.resource`
  /// el plugin lo resuelve como recurso de la app, que es lo que se quiere.
  static const String ringtone = 'spacebell';

  /// Temporizador de expiracion por oferta.
  final Map<String, Timer> _timers = {};

  /// Reloj monotono de cada oferta.
  final Map<String, Stopwatch> _clocks = {};

  /// Segundos de vida originales de cada oferta, para calcular lo que queda.
  final Map<String, int> _ttls = {};

  /// Ofertas con el aviso puesto. Es el estado de referencia del contador.
  final Set<String> _active = {};

  /// Ofertas sin resolver. Alimenta el badge del icono.
  int _unread = 0;

  bool _badgeSupported = false;
  bool _badgeChecked = false;
  bool _initialized = false;

  final AppBadgePort _badgePort;
  final NotificationPort _notifier;

  final StreamController<TripNoticeEvent> _events =
      StreamController<TripNoticeEvent>.broadcast();

  /// Hechos que la UI debe reflejar. El servicio no dibuja nada: solo avisa.
  Stream<TripNoticeEvent> get events => _events.stream;

  int get unreadCount => _unread;
  Set<String> get activeTripIds => Set.unmodifiable(_active);

  /// La UI avisa aqui cuando el conductor toca la notificacion. El servicio NO
  /// llama al backend: de eso se encarga la pantalla, que ya tiene el
  /// `driver_id` y el manejo de sesion.
  void Function(TripOffer offer)? onOpened;

  /// La oferta se agoto sin respuesta.
  void Function(TripOffer offer)? onExpired;

  /// Otro conductor se llevo el viaje que estabamos viendo.
  void Function(TripOffer offer)? onTakenByOther;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _badgeSupported = await _isBadgeSupported();
  }

  /// Pide al sistema permiso para notificar.
  ///
  /// En Android 13 o superior sin este permiso el aviso no suena ni aparece,
  /// aunque el codigo este bien. Se pide al arrancar la pantalla y no antes de
  /// cada oferta: un dialogo en medio de un turno de trabajo molesta.
  ///
  /// Devuelve si el sistema va a dejar notificar. Que sea `false` no es un
  /// fallo: la tarjeta de oferta de la app sigue funcionando igual.
  Future<bool> requestPermission() async {
    try {
      return await _notifier.requestPermission();
    } catch (e) {
      debugPrint('[NOTIF] no se pudo pedir el permiso de avisos: $e');
      return false;
    }
  }

  /// Si el sistema permite mostrar notificaciones ahora mismo.
  Future<bool> areEnabled() async {
    try {
      return await _notifier.areEnabled();
    } catch (_) {
      return false;
    }
  }

  // ============================ BADGE ============================

  /// Si el launcher admite contador numerico.
  ///
  /// El plugin deduce el launcher activo y trae implementaciones para Samsung,
  /// MIUI, Huawei, Vivo, OPPO, Asus, ZTE y mas. Si ninguno encaja devuelve
  /// `false` y la app sigue igual, solo que sin numero en el icono.
  Future<bool> _isBadgeSupported() async {
    if (_badgeChecked) return _badgeSupported;
    try {
      _badgeSupported = await _badgePort.isSupported();
    } catch (_) {
      // Un launcher raro puede lanzar aqui. No es motivo para tumbar el
      // servicio de notificaciones.
      _badgeSupported = false;
    }
    _badgeChecked = true;
    return _badgeSupported;
  }

  Future<void> _incrementBadge() async {
    _unread++;
    await _applyBadge();
  }

  /// Resta una oferta sin dejar que el contador baje de cero.
  Future<void> _decrementBadge() async {
    _unread = _unread > 0 ? _unread - 1 : 0;
    await _applyBadge();
  }

  /// Pone el contador a cero. Se usa al abrir la pantalla de solicitudes.
  Future<void> resetBadge() async {
    if (_unread == 0) return;
    _unread = 0;
    await _applyBadge();
  }

  /// El chofer abrio la app: lo que hubiera sin resolver ya lo vio.
  Future<void> markAllRead() => resetBadge();

  Future<void> _applyBadge() async {
    if (!_badgeSupported) return;
    try {
      // El plugin no expone `removeBadge`: pasar 0 es lo que quita el contador,
      // y es justo lo que el propio plugin hace internamente al sondear.
      await _badgePort.update(_unread);
    } catch (_) {
      // El badge es cosmetico. Que falle no debe llevar por delante al
      // servicio de notificaciones.
      _badgeSupported = false;
    }
  }

  // ============================ FLUJO ============================

  /// Avisa de una oferta nueva.
  ///
  /// Si ya hay una con el mismo `trip_id`, no hace nada: el sondeo de cuatro
  /// segundos devuelve la misma oferta mientras siga viva y no puede sonar el
  /// timbre una vez cada cuatro segundos.
  ///
  /// Si el plazo ya vencio, no se avisa: ensenar un aviso que se retira al
  /// instante es peor que no avisar.
  Future<void> showTripRequest(TripOffer offer) async {
    await init();

    if (_active.contains(offer.tripId)) return;

    final segs = _expiresIn(offer);
    if (segs <= 0) {
      debugPrint('[NOTIF] ${offer.tripId} llego expirada, no se avisa');
      return;
    }

    _active.add(offer.tripId);
    _offersById[offer.tripId] = offer;
    await _incrementBadge();
    _startClock(offer.tripId, segs);

    try {
      await _notifier.show(offer);
    } catch (e) {
      // Si el panel falla, el badge y el aviso interno siguen. La tarjeta de
      // la app es la que manda: perderla seria peor que un aviso sin sonido.
      debugPrint('[NOTIF] no se pudo mostrar el aviso de ${offer.tripId}: $e');
      _events.add(TripNoticeEvent.showFailed(offer));
    }
  }

  /// Segundos de vida que quedaban al recibir la oferta.
  ///
  /// `offerExpiresInSecs` ya viene calculado por el backend respecto al
  /// instante de la solicitud. Si no viene, se usa el valor de respaldo.
  ///
  /// Un `0` explicito si significa "ya vencio", asi que se respeta; solo el
  /// `null` (campo ausente) dispara el respaldo.
  int _expiresIn(TripOffer offer) {
    final v = offer.offerExpiresInSecs;
    if (v == null) return fallbackExpiresSecs;
    return v;
  }

  // ============================ RELOJES ============================

  /// Arranca el reloj monotono y el temporizador de expiracion de una oferta.
  ///
  /// El [Stopwatch] queda disponible para consultar cuanto lleva viva, y el
  /// [Timer] es lo que dispara el retiro del aviso. No hay ningun
  /// `DateTime.now()` en el camino: el plazo es relativo y el reloj es
  /// monotonico.
  void _startClock(String tripId, int segs) {
    _stopClock(tripId);

    _ttls[tripId] = segs;
    _clocks[tripId] = (Stopwatch()..start());

    _timers[tripId] = Timer(Duration(seconds: segs), () {
      unawaited(handleTripExpired(tripId));
    });
  }

  void _stopClock(String tripId) {
    _timers.remove(tripId)?.cancel();
    _clocks.remove(tripId)?.stop();
  }

  /// Cuanto lleva viva una oferta segun el reloj monotonico.
  Duration elapsedOf(String tripId) => _clocks[tripId]?.elapsed ?? Duration.zero;

  /// Segundos que le quedan a una oferta. Para la interfaz. Nunca negativo.
  int secondsLeft(String tripId) {
    final sw = _clocks[tripId];
    if (sw == null) return 0;
    final left = (_ttls[tripId] ?? 0) - sw.elapsed.inSeconds;
    return left > 0 ? left : 0;
  }

  // ============================ ACCIONES ============================

  /// El conductor toco la notificacion: se abre la app. Aqui solo se cuenta.
  void notifyOpened(String tripId) {
    final offer = _offerOf(tripId);
    if (offer == null) return;
    unawaited(markAllRead());
    onOpened?.call(offer);
  }

  /// El conductor respondio desde la tarjeta de la app.
  Future<void> resolveTrip(String tripId) => _retire(tripId);

  /// La oferta se agoto sin respuesta.
  ///
  /// Retira el aviso del panel y avisa a la UI, que informa al backend.
  Future<void> handleTripExpired(String tripId) async {
    if (!_active.contains(tripId)) return;
    final offer = _offerOf(tripId);
    await _retire(tripId);
    if (offer != null) {
      onExpired?.call(offer);
      _events.add(TripNoticeEvent(TripNoticeKind.expired, offer));
    }
  }

  /// Otro conductor se llevo el viaje que estabamos viendo.
  ///
  /// Para este chofer ya no existe: el aviso se retira y no se abre nada.
  Future<void> handleTripTakenByOther(String tripId) async {
    if (!_active.contains(tripId)) return;
    final offer = _offerOf(tripId);
    await _retire(tripId);
    if (offer != null) {
      onTakenByOther?.call(offer);
      _events.add(TripNoticeEvent(TripNoticeKind.takenByOther, offer));
    }
  }

  /// El pasajero cancelo: se retira el aviso sin avisar, no hay nada que decidir.
  Future<void> handleTripCancelled(String tripId) async {
    if (!_active.contains(tripId)) return;
    await _retire(tripId);
  }

  /// Una oferta que teniamos deja de venir en el sondeo.
  ///
  /// El sondeo no dice por que se fue una oferta, asi que se consulta el estado
  /// real en la pantalla y se llama a [handleTripTakenByOther],
  /// [handleTripCancelled] o [handleTripExpired] segun corresponda. Aqui, a
  /// falta de mas datos, se retira el aviso sin dar un veredicto.
  Future<void> handleOfferGone(String tripId) async {
    if (!_active.contains(tripId)) return;
    await _retire(tripId);
  }

  /// Retira el aviso y limpia el estado. No avisa a nadie.
  Future<void> _retire(String tripId) async {
    _stopClock(tripId);
    _ttls.remove(tripId);

    try {
      await _notifier.cancel(tripId);
    } catch (e) {
      debugPrint('[NOTIF] no se pudo retirar el aviso de $tripId: $e');
    }

    if (_active.remove(tripId)) {
      await _decrementBadge();
    }
  }

  TripOffer? _offerOf(String tripId) => _offersById[tripId];

  /// Ofertas vivas por `trip_id`. Se guarda para poder nombrar la oferta en
  /// los avisos y resolver [notifyOpened] sin depender de la pantalla.
  final Map<String, TripOffer> _offersById = {};

  /// Cierra todo. Para cuando el conductor deja de aceptar viajes.
  Future<void> shutdown() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _clocks.clear();
    _ttls.clear();
    _offersById.clear();
    _active.clear();
    try {
      await _notifier.cancelAll();
    } catch (_) {
      // Nada que hacer: ya se va a cerrar igual.
    }
    _unread = 0;
    await _applyBadge();
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    unawaited(_events.close());
  }
}

/// Lo que el servicio necesita del panel de notificaciones.
///
/// Se aisla detras de un puerto para que los tests puedan comprobar el ciclo de
/// vida del aviso (mostrar, expirar, retirar) sin depender de Android, y para
/// que un fallo del panel no se lleve por delante el badge.
abstract class NotificationPort {
  const NotificationPort();

  /// Muestra el aviso de una oferta, con sonido y vibracion.
  Future<void> show(TripOffer offer);

  /// Retira el aviso de una oferta.
  Future<void> cancel(String tripId);

  /// Retira todos los avisos de oferta.
  Future<void> cancelAll();

  /// Pide el permiso de notificaciones (Android 13+).
  Future<bool> requestPermission();

  /// Si el sistema permite mostrar notificaciones.
  Future<bool> areEnabled();

  /// Puerto real sobre `flutter_local_notifications`.
  factory NotificationPort.platform() => const PlatformNotificationPort();
}

/// Quien avisa que se toco la notificacion. Lo pone la implementacion real.
typedef NotificationTapCallback = void Function(String tripId);

class PlatformNotificationPort extends NotificationPort {
  const PlatformNotificationPort();

  static final _plugin = FlutterLocalNotificationsPlugin();

  /// Se inyecta desde el servicio para no tener un global en el plugin.
  static NotificationTapCallback? onTap;

  static bool _initialized = false;

  /// Id numerico de la notificacion. Android no admite cadenas como id, asi que
  /// se deriva del `trip_id` de forma estable entre arranques.
  static int idOf(String tripId) => tripId.hashCode & 0x7fffffff;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (resp) {
        final id = resp.payload;
        if (id != null && id.isNotEmpty) onTap?.call(id);
      },
    );

    // El canal es lo que fija el sonido y la vibrate en Android 8+. Se crea con
    // `RawResourceAndroidNotificationSound` para que suene el `spacebell` de
    // `res/raw` en lugar del tono por defecto del sistema. Sin esto, Android
    // ignora el sonido de la notificacion y usa el del canal.
    final canal = AndroidNotificationChannel(
      TripNotificationService.channelId,
      TripNotificationService.channelName,
      description: 'Aviso de una nueva oferta de viaje.',
      importance: Importance.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound(TripNotificationService.ringtone),
      enableVibration: true,
      vibrationPattern: _vibracion,
      enableLights: true,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(canal);
  }

  /// Patrón de vibracion: dos golpes separados por una pausa corta.
  ///
  /// El tipo es `Int64List` porque es el que espera el plugin: no es lo mismo
  /// que una `List<int>` aunque contenga los mismos numeros.
  static final Int64List _vibracion = Int64List.fromList([0, 700, 400, 700]);

  @override
  Future<void> show(TripOffer offer) async {
    await _ensureInitialized();

    // `timeoutAfter` va en milisegundos. Sin esto el aviso se queda en el panel
    // aunque la oferta ya haya caducado y el conductor la de por perdida.
    final segs = offer.offerExpiresInSecs;
    final ms = (segs == null || segs <= 0
            ? TripNotificationService.fallbackExpiresSecs
            : segs) *
        1000;

    final detalles = AndroidNotificationDetails(
      TripNotificationService.channelId,
      TripNotificationService.channelName,
      channelDescription: 'Aviso de una nueva oferta de viaje.',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound(TripNotificationService.ringtone),
      enableVibration: true,
      vibrationPattern: _vibracion,
      enableLights: true,
      visibility: NotificationVisibility.public,
      timeoutAfter: ms,
      // Se manda el `trip_id` como payload para que, al tocarla, la pantalla
      // sepa que oferta es sin tener que adivinarlo.
      styleInformation: BigTextStyleInformation(
        '${offer.dropoffAddress ?? 'otro destino'} · ${offer.totalFare?.toStringAsFixed(0) ?? ''} ${offer.currency}',
      ),
    );

    await _plugin.show(
      idOf(offer.tripId),
      'Oferta de viaje nueva',
      _subtitulo(offer),
      NotificationDetails(android: detalles),
      payload: offer.tripId,
    );
  }

  /// Linea de abajo: el destino es lo unico que de verdad distingue una
  /// oferta de otra cuando hay varias en el panel.
  static String _subtitulo(TripOffer offer) {
    final d = offer.dropoffAddress ?? offer.requestAddress;
    if (d == null || d.trim().isEmpty) return 'Toca para ver el detalle';
    return d.trim();
  }

  @override
  Future<void> cancel(String tripId) =>
      _plugin.cancel(idOf(tripId));

  @override
  Future<void> cancelAll() => _plugin.cancelAll();

  @override
  Future<bool> requestPermission() async {
    await _ensureInitialized();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? true;
  }

  @override
  Future<bool> areEnabled() async {
    await _ensureInitialized();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? true;
  }
}

/// Lo que el servicio necesita del badge del launcher.
///
/// Se aisla por dos razones:
///
///  * `app_badge_plus` deduce el launcher con una lista de paquetes. En un
///    movil de pruebas puede no encontrar ninguno y responder `false`, con lo
///    que el contador nunca se veria en el test.
///  * Colibri, el launcher del dispositivo de pruebas, no esta en la lista del
///    plugin. En un dispositivo real se pierde el contador, pero el test debe
///    poder simular un launcher compatible para verificar la aritmetica.
abstract class AppBadgePort {
  const AppBadgePort();

  /// Si el launcher activo admite contador numerico.
  Future<bool> isSupported();

  /// Fija el contador. `0` lo quita.
  Future<void> update(int count);

  /// Puerto real sobre `app_badge_plus`.
  factory AppBadgePort.launcher() => const _LauncherAppBadgePort();
}

class _LauncherAppBadgePort extends AppBadgePort {
  const _LauncherAppBadgePort();

  @override
  Future<bool> isSupported() => AppBadgePlus.isSupported();

  @override
  Future<void> update(int count) => AppBadgePlus.updateBadge(count);
}

/// Hecho que la UI debe reflejar. El servicio no dibuja nada: solo avisa.
enum TripNoticeKind {
  /// Se agoto el plazo sin respuesta.
  expired,

  /// Otro conductor se llevo el viaje.
  takenByOther,

  /// El panel no acepto el aviso; la tarjeta de la app hace de respaldo.
  showFailed,
}

class TripNoticeEvent {
  TripNoticeEvent(this.kind, this.offer);

  /// El panel no acepto el aviso.
  factory TripNoticeEvent.showFailed(TripOffer offer) =>
      TripNoticeEvent(TripNoticeKind.showFailed, offer);

  final TripNoticeKind kind;
  final TripOffer offer;

  String get message => switch (kind) {
        TripNoticeKind.expired => 'La oferta expiró sin respuesta',
        TripNoticeKind.takenByOther => 'Otro conductor aceptó este viaje',
        TripNoticeKind.showFailed => 'No se pudo mostrar el aviso de la oferta',
      };
}
