import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_config.dart';

/// WebSocket del CHOFER contra `/ws/chofer/{id}`.
///
/// Dos usos:
///
///  * Envia la POSICION con el rumbo ({"posicion": {...}}) para que el
///    pasajero la reciba empujada, sin su sondeo de 3 s.
///  * Recibe la oferta (`trip_offer`) en cuanto el despacho la publica:
///    la app re-polling al instante (`_tick`) para levantar el mismo flujo
///    de siempre con TODOS sus filtros.
///
/// El sondeo HTTP no se toca: es el respaldo si el canal cae.
class WsChofer {
  WebSocketChannel? _canal;
  Timer? _reconexion;
  String? _driverId;
  String? _token;
  bool _deseado = false;

  /// Eventos recibidos desde el backend: `(canal, datos)`.
  void Function(String canal, Map<String, dynamic> datos)? onDatos;

  Uri _uri() {
    final base = ApiConfig.baseUrl;
    final ws = base.startsWith('https://')
        ? base.replaceFirst('https://', 'wss://')
        : base.replaceFirst('http://', 'ws://');
    return Uri.parse(
        '$ws/ws/chofer/$_driverId?token=${Uri.encodeQueryComponent(_token ?? '')}');
  }

  void iniciar({required String driverId, required String token}) {
    _driverId = driverId;
    _token = token;
    _deseado = true;
    _conectar();
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

  /// Posicion + rumbo del chofer, en el mismo contrato que el endpoint HTTP.
  void posicion(double lat, double lng, double? bearing) {
    _enviar({
      'posicion': {
        'lat': lat,
        'lng': lng,
        'bearing': ?bearing,
      },
    });
  }

  void _conectar() {
    if (!_deseado || _driverId == null) return;
    try {
      final canal = WebSocketChannel.connect(_uri());
      _canal = canal;
      canal.stream.listen(
        (crudo) {
          try {
            final env = jsonDecode(crudo as String);
            if (env is Map) {
              final datos = env['datos'];
              if (datos is Map) {
                onDatos?.call((env['canal'] ?? '').toString(),
                    Map<String, dynamic>.from(datos));
              }
            }
          } catch (e) {
            debugPrint('[WS chofer] payload ilegible: $e');
          }
        },
        onDone: _reconectar,
        onError: (Object _) => _reconectar(),
      );
    } catch (e) {
      debugPrint('[WS chofer] no conectó: $e');
      _reconectar();
    }
  }

  void _enviar(Map<String, dynamic> datos) {
    try {
      _canal?.sink.add(jsonEncode(datos));
    } catch (_) {
      // El socket esta medio muerto: listener de Done disparando
      // reconexion. Que no tumbe la pantalla.
    }
  }

  void _reconectar() {
    if (!_deseado) return;
    _reconexion?.cancel();
    _reconexion = Timer(const Duration(seconds: 5), () {
      if (_deseado) _conectar();
    });
  }
}
