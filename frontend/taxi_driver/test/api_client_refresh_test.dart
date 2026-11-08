import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:taxi_driver/services/api_client.dart';

/// Pruebas del interceptor de refresh: un 401 debe renovar el access y repetir
/// la peticion sin que el usuario vea nada; si el refresh es rechazado, se
/// limpia la sesion una sola vez.
void main() {
  late int refreshLlamadas;
  late int limpiezas;
  late int expiraciones;
  late String? refreshGuardado;
  late String? accessGuardado;

  void preparar(Future<http.Response> Function(http.Request) handler) {
    refreshLlamadas = 0;
    limpiezas = 0;
    expiraciones = 0;
    refreshGuardado = 'refresh-viejo';
    accessGuardado = null;
    ApiClient.token = 'access-viejo';
    ApiClient.marcarSesionActiva();
    ApiClient.clienteDePruebas = MockClient(handler);
    ApiClient.leerRefreshToken = () async => refreshGuardado;
    ApiClient.guardarAccessToken = (t) async => accessGuardado = t;
    ApiClient.limpiarSesion = () async {
      limpiezas++;
      refreshGuardado = null;
    };
    ApiClient.alExpirarSesion = () => expiraciones++;
  }

  tearDown(() {
    ApiClient.token = null;
    ApiClient.marcarSesionActiva();
  });

  test('401 -> refresh -> reintento transparente', () async {
    preparar((req) async {
      if (req.url.path.endsWith('/auth/refresh')) {
        refreshLlamadas++;
        return http.Response(jsonEncode({'access_token': 'access-nuevo'}), 200);
      }
      if (req.headers['Authorization'] == 'Bearer access-nuevo') {
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('{"detail":"Token expirado"}', 401);
    });

    final r = await ApiClient.get('https://test.local/perfil');

    expect(r, {'ok': true});
    expect(refreshLlamadas, 1);
    expect(accessGuardado, 'access-nuevo');
    expect(ApiClient.token, 'access-nuevo');
    expect(limpiezas, 0);
    expect(expiraciones, 0);
  });

  test('refresh rechazado -> limpia sesion y avisa una vez', () async {
    preparar((req) async {
      if (req.url.path.endsWith('/auth/refresh')) {
        refreshLlamadas++;
        return http.Response('{"detail":"refresh expirado"}', 401);
      }
      return http.Response('{"detail":"Token expirado"}', 401);
    });

    await expectLater(
      ApiClient.get('https://test.local/perfil'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 401)),
    );

    expect(refreshLlamadas, 1);
    expect(limpiezas, 1);
    expect(expiraciones, 1);
    expect(ApiClient.token, isNull);
  });

  test('varios 401 a la vez comparten un solo refresh', () async {
    preparar((req) async {
      if (req.url.path.endsWith('/auth/refresh')) {
        refreshLlamadas++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return http.Response(jsonEncode({'access_token': 'access-nuevo'}), 200);
      }
      if (req.headers['Authorization'] == 'Bearer access-nuevo') {
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('{"detail":"Token expirado"}', 401);
    });

    await Future.wait([
      ApiClient.get('https://test.local/perfil'),
      ApiClient.get('https://test.local/viajes'),
      ApiClient.get('https://test.local/tarifas'),
    ]);

    expect(refreshLlamadas, 1);
    expect(limpiezas, 0);
    expect(ApiClient.token, 'access-nuevo');
  });

  test('un 401 del login NO dispara refresh ni cierra sesion', () async {
    preparar((req) async {
      if (req.url.path.endsWith('/auth/refresh')) {
        refreshLlamadas++;
        return http.Response('{"access_token":"x"}', 200);
      }
      return http.Response('{"detail":"Contrasena incorrecta"}', 401);
    });

    await expectLater(
      ApiClient.post('https://test.local/login',
          body: {'email': 'a@b.c', 'password': 'mala'}),
      throwsA(isA<ApiException>()),
    );

    expect(refreshLlamadas, 0);
    expect(limpiezas, 0);
    expect(expiraciones, 0);
  });
}
