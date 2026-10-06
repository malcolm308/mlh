import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Estados de un viaje que el backend considera vivos.
///
/// Todo lo demas (`cancelled`, `completed`, `expired`) significa que el chofer
/// ya no tiene nada que hacer con el.
const Set<String> estadosViajeVivos = {'accepted', 'driver_arrived', 'in_progress'};

/// Estado de la consulta al backend sobre el viaje en curso.
///
/// El backend es la fuente de verdad del limite de cancelaciones: el contador
/// local es solo para pintar el boton sin esperar a la red, y se rectify en cada
/// respuesta. Si los dos no coinciden, gana el backend.
enum EstadoConsultaLimite {
  /// Todavia no se ha consultado.
  desconocido,

  /// Consulta en vuelo.
  consultando,

  /// Se pudo consultar.
  obtenido,

  /// Fallo la consulta. Se conserva el valor local si lo hay.
  fallo,
}

/// Resultado de intentar cancelar un viaje.
enum ResultadoCancelacion {
  /// Se cancelo.
  ok,

  /// El backend dijo que el limite diario esta alcanzado.
  limiteAlcanzado,

  /// El viaje ya no se puede cancelar (completado o ya cancelado).
  viajeNoCancelable,

  /// Fallo de red o error del backend.
  error,
}

/// Lleva el conteo de cancelaciones del chofer.
///
/// Reglas, que son las que pediste:
///
///  * Cancelar un viaje YA ACEPTADO cuenta, con máximo 3 al día.
///  * Rechazar una oferta sin llegar a aceptarla NO cuenta y no tiene limite.
///
/// Por eso el contador vive aqui y no en el boton de rechazar: son dos acciones
/// distintas con dos reglas distintas.
///
/// El dia es el local del dispositivo. El backend lleva su propio conteo como
/// fuente de verdad, asi que un reloj desajustado no permite saltarse el limite:
/// el backend rechaza y el boton se deshabilita.
class CancellationService extends ChangeNotifier {
  CancellationService({
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
        httpPost,
    Future<Map<String, dynamic>?> Function(String)? httpGet,
  })  : _post = httpPost ?? _postPorDefecto,
        _get = httpGet ?? _getPorDefecto;

  final Future<Map<String, dynamic>> Function(
    String ruta,
    Map<String, dynamic> cuerpo,
  ) _post;
  final Future<Map<String, dynamic>?> Function(String ruta) _get;

  /// Maximo de cancelaciones por dia natural, por chofer.
  ///
  /// Es una constante y no un literal en el codigo porque aparece en el boton,
  /// en el dialogo y en la validacion. Si se escribe tres veces, un dia se
  /// desincronizan.
  static const int maximoPorDia = 3;

  /// Prefijo de la clave en `SharedPreferences`.
  ///
  /// La fecha va dentro de la clave para que un cambio de dia no dependa de
  /// ningun temporizador: al leer, si la clave de hoy no existe, el contador de
  /// hoy es cero. No hace falta borrar nada.
  static const String _prefijoClave = 'chofer_cancelaciones_';

  /// Identificador de la clave de hoy, `yyyy-MM-dd`.
  ///
  /// Encapsulado en un metodo para poder testearlo con una fecha fija: los tests
  /// no deben depender de la hora real de la maquina.
  @visibleForTesting
  static String claveDe(DateTime fecha) {
    final y = fecha.year.toString().padLeft(4, '0');
    final m = fecha.month.toString().padLeft(2, '0');
    final d = fecha.day.toString().padLeft(2, '0');
    return '$_prefijoClave$y-$m-$d';
  }

  /// Cuantas cancelaciones quedan hoy.
  int _restantes = maximoPorDia;
  EstadoConsultaLimite _estado = EstadoConsultaLimite.desconocido;
  bool _cancelando = false;
  String? _motivoDelError;

  /// Cuantas cancelaciones quedan hoy, de 0 a [maximoPorDia].
  int get restantes => _restantes;

  /// `true` si ya no se puede cancelar mas hoy.
  bool get limiteAlcanzado => _restantes <= 0;

  /// `true` mientras se envia una cancelacion.
  bool get cancelando => _cancelando;

  /// Texto para el boton, que muestra el contador.
  String get etiquetaBoton => limiteAlcanzado
      ? 'Cancelar viaje · Límite alcanzado ($maximoPorDia/$maximoPorDia)'
      : 'Cancelar viaje ($_restantes/$maximoPorDia restantes)';

  /// Estado de la ultima consulta al backend.
  ///
  /// Se expone para que la interfaz distinga "sin red" de "todavia no se ha
  /// consultado", que son cosas distintas para el conductor.
  EstadoConsultaLimite get estadoConsulta => _estado;

  /// Ultimo error, para poder mostrarlo y limpiarlo.
  String? get motivoDelError => _motivoDelError;

  /// `true` si se puede cancelar ahora mismo.
  bool get puedeCancelar => !limiteAlcanzado && !_cancelando;

  /// Lee el contador local y consulta al backend.
  ///
  /// El local se lee primero para que el boton aparezca correcto de inmediato,
  /// y luego se corrige con lo que diga el backend.
  Future<void> cargar({required String driverId, DateTime? hoy}) async {
    final prefs = await SharedPreferences.getInstance();
    final clave = claveDe(hoy ?? DateTime.now());
    _restantes = maximoPorDia - (prefs.getInt(clave) ?? 0);
    if (_restantes < 0) _restantes = 0;
    notifyListeners();

    _estado = EstadoConsultaLimite.consultando;
    notifyListeners();

    try {
      final remoto = await _get('/chofer/$driverId/cancelaciones');
      if (remoto != null && remoto['restantes'] is num) {
        // El backend manda. Si el movil va con la hora cambiada, el puede
        // quedarse con el valor del servidor y no permitir de mas.
        final r = (remoto['restantes'] as num).toInt();
        _restantes = r < 0 ? 0 : r;
        // Se espeja el valor remoto para que un reinicio de la app no revierta
        // lo que ya sabe el servidor.
        await prefs.setInt(clave, maximoPorDia - _restantes);
      }
      _estado = EstadoConsultaLimite.obtenido;
    } catch (_) {
      // Sin red se queda el valor local. Es lo mejor que se puede hacer: el
      // backend sigue siendo quien rechaza si se pasa de la cuenta.
      _estado = EstadoConsultaLimite.fallo;
    }
    notifyListeners();
  }

  /// Cancela un viaje ya aceptado y descuenta una vez del limite diario.
  ///
  /// Rechazar una oferta NO pasa por aqui, y por eso no cuenta.
  Future<ResultadoCancelacion> cancelarViajeAceptado({
    required String tripId,
    required String driverId,
    String? motivo,
    DateTime? hoy,
  }) async {
    if (limiteAlcanzado) return ResultadoCancelacion.limiteAlcanzado;
    if (_cancelando) return ResultadoCancelacion.error;

    _cancelando = true;
    _motivoDelError = null;
    notifyListeners();

    try {
      final r = await _post('/trips/$tripId/cancel', {
        'driver_id': driverId,
        'reason': motivo,
        'cancelled_at':
            (hoy ?? DateTime.now()).toUtc().toIso8601String(),
      });

      final codigo = r['code'];
      if (codigo == 'limite_alcanzado') {
        // El backend tiene mas cuenta que el movil. Se sincroniza.
        _restantes = 0;
        _cancelando = false;
        notifyListeners();
        return ResultadoCancelacion.limiteAlcanzado;
      }
      if (codigo == 'no_cancelable') {
        _cancelando = false;
        notifyListeners();
        return ResultadoCancelacion.viajeNoCancelable;
      }
      if (r['ok'] != true) {
        _cancelando = false;
        _motivoDelError = (r['detail'] ?? 'No se pudo cancelar el viaje').toString();
        notifyListeners();
        return ResultadoCancelacion.error;
      }

      // Solo se descuenta si el backend acepto. Contar antes haria que un
      // fallo de red costara una cancelacion sin cancelar nada.
      final prefs = await SharedPreferences.getInstance();
      final clave = claveDe(hoy ?? DateTime.now());
      final usadas = (prefs.getInt(clave) ?? 0) + 1;
      await prefs.setInt(clave, usadas);
      _restantes = (maximoPorDia - usadas).clamp(0, maximoPorDia);

      _cancelando = false;
      notifyListeners();
      return ResultadoCancelacion.ok;
    } catch (e) {
      _cancelando = false;
      _motivoDelError = 'No se pudo cancelar, revisa la conexión';
      notifyListeners();
      return ResultadoCancelacion.error;
    }
  }

  /// Llamado cuando el backend avisa de que el viaje ya no esta vivo.
  ///
  /// El backend puede cancelar el viaje desde su lado (lo cancela el pasajero).
  /// En ese caso el boton no debe seguir mostrando que se puede cancelar.
  void sincronizarConBackend({int? restantesRemotos}) {
    if (restantesRemotos == null) return;
    _restantes = restantesRemotos < 0 ? 0 : restantesRemotos;
    notifyListeners();
  }

  // ---------------- Red ----------------

  static Future<Map<String, dynamic>> _postPorDefecto(
    String ruta,
    Map<String, dynamic> cuerpo,
  ) async {
    final uri = Uri.parse('${AppConfig.apiBase}$ruta');
    final r = await http.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(cuerpo),
    );
    final cuerpoResp = r.body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    // Un 4xx tambien trae cuerpo util (`code`), asi que se devuelve igual y lo
    // interpreta quien llama, en vez de tirar la exception aqui.
    cuerpoResp['http_status'] = r.statusCode;
    return cuerpoResp;
  }

  static Future<Map<String, dynamic>?> _getPorDefecto(String ruta) async {
    final uri = Uri.parse('${AppConfig.apiBase}$ruta');
    final r = await http.get(uri);
    if (r.statusCode < 200 || r.statusCode >= 300) return null;
    if (r.body.trim().isEmpty) return null;
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }
}