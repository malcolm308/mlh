import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../api_config.dart';
import '../models/estado_red.dart';

/// Vigila la conectividad real contra el backend, no solo la interfaz.
///
/// No se usa `connectivity_plus` para no añadir un plugin que solo dice si hay
/// Wi-Fi/datos: lo que importa es si el backend responde. La sonda es un GET
/// pequeño a `/health` con timeout corto, espaciado de forma adaptativa:
///
///  * red buena: una comprobación cada 15 s;
///  * red débil o sin señal: cada 5 s, para recuperarse rápido;
///  * en segundo plano no corre ninguna: se reanuda al volver a la app.
///
/// Además comprueba la lista de interfaces del sistema: si no hay ninguna
/// (modo avión, datos apagados), marca «sin señal» sin gastar una petición.
class ConectividadService extends ChangeNotifier with WidgetsBindingObserver {
  ConectividadService({
    Future<bool> Function()? sonda,
    Future<bool> Function()? hayInterfaz,
  })  : _sonda = sonda ?? _sondaHttp,
        _hayInterfaz = hayInterfaz ?? _hayInterfazReal;

  final Future<bool> Function() _sonda;
  final Future<bool> Function() _hayInterfaz;

  static const Duration _timeoutSonda = Duration(seconds: 4);
  static const Duration _intervaloBueno = Duration(seconds: 15);
  static const Duration _intervaloMalo = Duration(seconds: 5);

  /// Por encima de esto la red se considera lenta aunque responda.
  static const int _latenciaDebilMs = 1500;

  EstadoRed _estado = EstadoRed.buena;
  EstadoRed get estado => _estado;

  Timer? _timer;
  bool _activo = false;
  bool _enCurso = false;
  int _fallos = 0;

  bool get activo => _activo;

  /// Arranca el vigilante. Idempotente.
  void iniciar() {
    if (_activo) return;
    _activo = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(comprobar());
  }

  /// Lo apaga del todo. Se llama al cerrar la pantalla.
  void detener() {
    _activo = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (!visible) {
      _activo = false;
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_activo) return;
    _activo = true;
    unawaited(comprobar());
  }

  /// Fuerza una comprobación inmediata (botón REINTENTAR).
  void reintentar() {
    _fallos = 0;
    _timer?.cancel();
    _timer = null;
    _cambiar(EstadoRed.debil);
    unawaited(comprobar());
  }

  /// Una comprobación. Nunca lanza y nunca solapa dos sondas.
  Future<void> comprobar() async {
    if (_enCurso) return;
    _enCurso = true;
    final reloj = Stopwatch()..start();
    try {
      final hayRed = await _hayInterfaz();
      if (!hayRed) {
        _fallos = 2;
        _cambiar(EstadoRed.sinSenal);
        return;
      }

      final ok = await _sonda().timeout(_timeoutSonda);
      final ms = reloj.elapsedMilliseconds;
      if (ok) {
        _fallos = 0;
        _cambiar(ms > _latenciaDebilMs ? EstadoRed.debil : EstadoRed.buena);
      } else {
        _fallos++;
        _cambiar(_fallos >= 2 ? EstadoRed.sinSenal : EstadoRed.debil);
      }
    } catch (_) {
      _fallos++;
      _cambiar(_fallos >= 2 ? EstadoRed.sinSenal : EstadoRed.debil);
    } finally {
      _enCurso = false;
      if (_activo) _programar();
    }
  }

  void _cambiar(EstadoRed nuevo) {
    if (_estado == nuevo) return;
    _estado = nuevo;
    notifyListeners();
  }

  void _programar() {
    _timer?.cancel();
    final intervalo =
        _estado == EstadoRed.buena ? _intervaloBueno : _intervaloMalo;
    _timer = Timer(intervalo, () => unawaited(comprobar()));
  }

  static Future<bool> _hayInterfazReal() async {
    try {
      final interfaces =
          await NetworkInterface.list(includeLoopback: false, includeLinkLocal: false);
      return interfaces.isNotEmpty;
    } catch (_) {
      // Si el sistema no deja enumerar interfaces no se puede concluir nada:
      // se deja decidir a la sonda HTTP.
      return true;
    }
  }

  static Future<bool> _sondaHttp() async {
    final respuesta = await http
        .get(Uri.parse(ApiConfig.health()))
        .timeout(_timeoutSonda);
    return respuesta.statusCode >= 200 && respuesta.statusCode < 300;
  }
}
