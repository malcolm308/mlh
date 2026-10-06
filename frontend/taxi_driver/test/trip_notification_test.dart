import 'package:taxi_driver/models/models.dart';
import 'package:taxi_driver/services/trip_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Puerto de notificaciones falso. Cuenta lo que se le pidio para poder
/// comprobar que el ciclo de vida del aviso es el esperado sin depender de
/// Android ni de que el plugin este disponible en el host.
class FakeNotificationPort extends NotificationPort {
  final List<String> shown = [];
  final List<String> cancelled = [];
  int cancelAllCalls = 0;
  int permissionRequests = 0;
  bool permissionResult = true;
  Object? failOnShow;

  @override
  Future<void> show(TripOffer offer) async {
    if (failOnShow != null) throw failOnShow!;
    shown.add(offer.tripId);
  }

  @override
  Future<void> cancel(String tripId) async => cancelled.add(tripId);

  @override
  Future<void> cancelAll() async => cancelAllCalls++;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionResult;
  }

  @override
  Future<bool> areEnabled() async => permissionResult;
}

/// Puerto de badge falso. `app_badge_plus` depende del launcher activo del
/// dispositivo, asi que en un test hay que poder sustituirlo.
class FakeBadgePort extends AppBadgePort {
  final List<int> updates = [];
  bool supported = true;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> update(int count) async => updates.add(count);
}

TripOffer _oferta({
  String tripId = 't1',
  int? expiresInSecs = 60,
  String? destino = 'Habana Vieja',
  double? fare = 350,
  String currency = 'CUP',
}) =>
    TripOffer(
      tripId: tripId,
      requestAddress: destino,
      dropoffAddress: destino,
      totalFare: fare,
      currency: currency,
      offerExpiresInSecs: expiresInSecs,
    );

TripNotificationService _servicio({
  required FakeNotificationPort noti,
  required FakeBadgePort badge,
}) =>
    TripNotificationService.create(badge: badge, notifier: noti);

void main() {
  group('TripNotificationService - aviso en el panel', () {
    late FakeNotificationPort noti;
    late FakeBadgePort badge;
    late TripNotificationService s;

    setUp(() {
      noti = FakeNotificationPort();
      badge = FakeBadgePort();
      s = _servicio(noti: noti, badge: badge);
    });

    tearDown(() => s.dispose());

    test('una oferta nueva muestra aviso y sube el contador', () async {
      await s.showTripRequest(_oferta());

      expect(noti.shown, ['t1']);
      expect(s.activeTripIds, {'t1'});
      expect(s.unreadCount, 1);
      expect(badge.updates.last, 1);
    });

    test('la misma oferta no vuelve a sonar cada cuatro segundos', () async {
      await s.showTripRequest(_oferta());
      await s.showTripRequest(_oferta());
      await s.showTripRequest(_oferta());

      expect(noti.shown.length, 1, reason: 'el sondeo repite la oferta viva');
      expect(s.unreadCount, 1);
    });

    test('ofertas distintas suenan por separado', () async {
      await s.showTripRequest(_oferta(tripId: 't1'));
      await s.showTripRequest(_oferta(tripId: 't2'));

      expect(noti.shown, ['t1', 't2']);
      expect(s.unreadCount, 2);
      expect(badge.updates.last, 2);
    });

    test('una oferta ya vencida no se avisa', () async {
      await s.showTripRequest(_oferta(expiresInSecs: 0));

      expect(noti.shown, isEmpty);
      expect(s.activeTripIds, isEmpty);
      expect(s.unreadCount, 0);
    });

    test('sin expires_in_secs se usa el plazo de respaldo', () async {
      await s.showTripRequest(_oferta(expiresInSecs: null));

      expect(s.activeTripIds, {'t1'});
      expect(
        s.secondsLeft('t1'),
        lessThanOrEqualTo(TripNotificationService.fallbackExpiresSecs),
      );
      expect(s.secondsLeft('t1'), greaterThan(0));
    });

    test('el plazo baja con el reloj y nunca es negativo', () async {
      await s.showTripRequest(_oferta(expiresInSecs: 60));
      expect(s.secondsLeft('t1'), inInclusiveRange(55, 60));

      await s.showTripRequest(_oferta(tripId: 't2', expiresInSecs: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(s.secondsLeft('t2'), 0, reason: 'nunca negativo');
    });

    test('el aviso se retira al expirar y avisa a la UI', () async {
      TripOffer? expirada;
      s.onExpired = (o) => expirada = o;

      await s.showTripRequest(_oferta(expiresInSecs: 1));
      expect(s.activeTripIds, {'t1'});

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(noti.cancelled, contains('t1'));
      expect(s.activeTripIds, isEmpty);
      expect(expirada?.tripId, 't1');
      expect(s.unreadCount, 0);
      expect(badge.updates.last, 0);
    });

    test('otro conductor se lleva el viaje: se retira y se avisa', () async {
      TripOffer? tomada;
      s.onTakenByOther = (o) => tomada = o;

      await s.showTripRequest(_oferta());
      await s.handleTripTakenByOther('t1');

      expect(noti.cancelled, ['t1']);
      expect(tomada?.tripId, 't1');
      expect(s.activeTripIds, isEmpty);
      expect(s.unreadCount, 0);
    });

    test('cancelacion del pasajero retira el aviso sin veredicto', () async {
      await s.showTripRequest(_oferta());
      await s.handleTripCancelled('t1');

      expect(noti.cancelled, ['t1']);
      expect(s.activeTripIds, isEmpty);
      expect(s.unreadCount, 0);
    });

    test('responder desde la tarjeta retira el aviso y el contador', () async {
      await s.showTripRequest(_oferta());
      await s.resolveTrip('t1');

      expect(noti.cancelled, ['t1']);
      expect(s.activeTripIds, isEmpty);
      expect(s.unreadCount, 0);
    });

    test('retirar una oferta que ya no esta activa no hace nada', () async {
      await s.handleTripExpired('no-existe');
      await s.handleTripTakenByOther('no-existe');
      await s.handleTripCancelled('no-existe');
      await s.handleOfferGone('no-existe');

      expect(noti.cancelled, isEmpty);
    });

    test('el toque en el panel abre la oferta y limpia el contador', () async {
      TripOffer? abierta;
      s.onOpened = (o) => abierta = o;

      await s.showTripRequest(_oferta());
      s.notifyOpened('t1');

      expect(abierta?.tripId, 't1');
      expect(s.unreadCount, 0);
      expect(badge.updates.last, 0);
    });

    test('el toque de una oferta desconocida no inventa nada', () async {
      TripOffer? abierta;
      s.onOpened = (o) => abierta = o;

      s.notifyOpened('no-existe');

      expect(abierta, isNull);
    });

    test('si el panel falla, el badge y la tarjeta siguen', () async {
      noti.failOnShow = StateError('sin canal');

      await s.showTripRequest(_oferta());

      // La oferta sigue viva: la tarjeta de la app es la que manda.
      expect(s.activeTripIds, {'t1'});
      expect(s.unreadCount, 1);
      expect(badge.updates.last, 1);
    });

    test('shutdown limpia avisos, temporizadores y contador', () async {
      await s.showTripRequest(_oferta(tripId: 't1'));
      await s.showTripRequest(_oferta(tripId: 't2'));
      await s.shutdown();

      expect(noti.cancelAllCalls, 1);
      expect(s.activeTripIds, isEmpty);
      expect(s.activeTripIds, isEmpty);
      expect(s.unreadCount, 0);
      expect(badge.updates.last, 0);

      // Y no queda ningun temporizador vivo que dispare despues.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(noti.cancelled, isEmpty);
    });

    test('el permiso se pide una vez y su fallo no rompe nada', () async {
      noti.permissionResult = false;

      expect(await s.requestPermission(), isFalse);
      await s.showTripRequest(_oferta());

      expect(noti.shown, ['t1']);
      expect(s.activeTripIds, {'t1'});
    });

    test('sin soporte de badge el servicio sigue avisando', () async {
      badge.supported = false;

      await s.showTripRequest(_oferta());

      expect(noti.shown, ['t1']);
      expect(s.unreadCount, 1);
      expect(badge.updates, isEmpty);
    });

    test('un fallo del badge apaga el contador pero no el aviso', () async {
      final s2 = TripNotificationService.create(
        notifier: noti,
        badge: _BadgeQueFalla(),
      );
      addTearDown(s2.dispose);

      await s2.showTripRequest(_oferta());

      expect(noti.shown, ['t1']);
      expect(s2.unreadCount, 1);
    });
  });

  group('PlatformNotificationPort - ids y payload', () {
    test('el id numerico es estable y positivo', () {
      final a = PlatformNotificationPort.idOf('trip-123');
      final b = PlatformNotificationPort.idOf('trip-123');

      expect(a, b);
      expect(a, greaterThanOrEqualTo(0));
    });

    test('ids distintos no se pisan', () {
      expect(PlatformNotificationPort.idOf('t1'),
          isNot(PlatformNotificationPort.idOf('t2')));
    });
  });
}

class _BadgeQueFalla extends AppBadgePort {
  @override
  Future<bool> isSupported() async => true;

  @override
  Future<void> update(int count) async => throw StateError('sin permiso');
}
