import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_config.dart';

/// WebSocket del PASAJERO contra `/ws/cliente/{id}`.
///
/// Empuja los eventos del viaje activo sin esperar al sondeo de 3 s:
///
///  * `driver_position` (lat, lng, bearing) para la vista 3D en tiempo real.
///  * `trip_accepted|trip_cancelled|...` para refrescar el estado al instante.
///
/// Si el canal cae (red cubana…), el sondeo HTTP que ya existe sigue
/// funcionando: esto NO es reemplazo, es el empujoncito encima.
class WsCliente {
  WebSocketChannel? _canal;
  Timer? _reconexion;
  String? _clienteId;
  String? _token;
  String? _viajeActual;
  bool _deseado = false;

  /// Eventos recibidos desde el backend: `(canal, datos)`.
  void Function(String canal, Map<String, dynamic> datos)? onDatos;

  Uri _uri() {
    final base = ApiConfig.baseUrl;
    final ws = base.startsWith('https://')
        ? base.replaceFirst('https://', 'wss://')
        : base.replaceFirst('http://', 'ws://');
    return Uri.parse(
        '$ws/ws/cliente/$_clienteId?token=${Uri.encodeQueryComponent(_token ?? '')}');
  }

  void iniciar({required String clienteId, required String token}) {
    _clienteId = clienteId;
    _token = token;
    _deseado = true;
    _conectar();
  }

  /// Suscribe el canal del viaje activo. Va tras conectar; si cayó, se
  /// reenvia al reconectar.
  void suscribirViaje(String tripId) {
    _viajeActual = tripId;
    _enviar({'suscribir_viaje': tripId});
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

  void _conectar() {
    if (!_deseado || _clienteId == null) return;
    try {
      final canal = WebSocketChannel.connect(_uri());
      _canal = canal;
      unawaited(canal.ready.then((_) {
        // Suscripcion pendiente tras reconectar.
        final viaje = _viajeActual;
        if (viaje != null) _enviar({'suscribir_viaje': viaje});
      }).catchError((Object _) {}));
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
            debugPrint('[WS cliente] payload ilegible: $e');
          }
        },
        onDone: _reconectar,
        onError: (Object _) => _reconectar(),
      );
    } catch (e) {
      debugPrint('[WS cliente] no conectó: $e');
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
