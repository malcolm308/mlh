import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
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

  /// Posicion + rumbo + velocidad del chofer, en el mismo contrato que el
  /// endpoint HTTP. La velocidad (km/h) la usa el cliente para el zoom 3D.
  void posicion(double lat, double lng, double? bearing, {double? speed}) {
    _enviar({
      'posicion': {
        'lat': lat,
        'lng': lng,
        'bearing': ?bearing,
        'speed': ?speed,
      },
    });
  }

  /// Ruta completa del viaje activo (el DUEÑO de la ruta la comparte): la
  /// geometry es el mismo LineString que consume el asistente, para que el
  /// cliente replique la ruta exacta del chofer.
  ///
  /// Si el socket esta medio muerto se pide reconexion y de todos modos se
  /// intenta: el siguiente fix (o el refresco de 60 s del asistente) repite.
  void rutaViaje(String tripId, List<LatLng> puntos) {
    if (puntos.length < 2) return;
    final c = _canal;
    if (c == null || c.closeCode != null) {
      // Canal caido: sin esto la recalculacion llega solo a los suscritos en
      // ese instante, y el pasajero puede quedarse con la ruta vieja horas.
      // Si ya hay una reconexion pendiente, no se duplica.
      if (_reconexion == null) _conectar();
    }
    _enviar({
      'ruta_viaje': {
        'trip_id': tripId,
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in puntos) [p.longitude, p.latitude],
          ],
        },
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
