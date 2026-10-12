import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Registro de traza en un fichero del propio telefono.
///
/// Nace porque no hay forma de depender de `adb logcat` para capturar un viaje:
/// el proceso de captura es externo a la app y en cuanto se cierra la sesion de
/// adb (o el sistema mata el proceso) se pierde justo lo que habia que mirar.
/// Un `logcat` _$ a lado se murio tres veces seguidas_ en el mismo viaje.
///
/// Aqui la escritura la hace la propia app, dentro de su proceso, que vive
/// mientras la app esta abierta. No hay nada externo que pueda morir.
///
/// El fichero va en el directorio externo de la app
/// (`getExternalFilesDir`), que en Android 11 y superior se escribe sin pedir
/// permiso y que `adb shell` si puede leer, asi que despues se descarga con un
/// `adb pull` normal.
///
/// Solo escribe en modo debug o cuando [forzado] se activa. En release sin
/// [forzado] no toca disco: una traza por frame en un viaje entero son varios
/// megabytes que no sirven de nada al usuario final.
class TrazaFichero {
  TrazaFichero._();

  static final TrazaFichero instancia = TrazaFichero._();

  static const MethodChannel _canal = MethodChannel('taxirapid/location');

  /// Fuerza la escritura en release. Se activa con un viaje en marcha para poder
  /// diagnosticar sin tener queuir a una build debug.
  static bool forzado = false;

  File? _fichero;
  IOSink? _sink;
  bool _intentado = false;

  /// Abre el fichero. Es idempotente y no lanza: si falla, la traza sigue yendo
  /// a `debugPrint`, que es lo que de verdad importa para el diagnostico.
  Future<void> abrir() async {
    if (_intentado) return;
    _intentado = true;
    if (!kDebugMode && !forzado) return;
    try {
      final ruta = await _canal.invokeMethod<String>('logPath');
      if (ruta == null || ruta.isEmpty) return;
      final f = File(ruta);
      await f.parent.create(recursive: true);
      // `openWrite` y no `writeAsStringSync`: se escribe linea a linea segun
      // van llegando y no hace falta reopen el fichero cada vez. Se anexa, no se
      // pisa: si la app se reinicia a mitad de un viaje se quiere el principio de
      // ese viaje tambien.
      _sink = f.openWrite(mode: FileMode.append);
      _fichero = f;
      _escribir('--- traza abierta ${DateTime.now().toIso8601String()} ---');
      iniciarLatido();
    } catch (e) {
      debugPrint('[TRAZA] no se pudo abrir el fichero: $e');
    }
  }

  void _escribir(String linea) {
    final sink = _sink;
    if (sink == null) return;
    try {
      sink.writeln('${DateTime.now().toIso8601String()} $linea');
    } catch (_) {
      // Si el disco falla a mitad del viaje no se cae la app: lo que se pierde
      // es la traza, no el GPS ni el mapa.
    }
  }

  /// Escribe una linea en el logcat y, si procede, tambien en el fichero.
  void escribir(String linea) {
    debugPrint(linea);
    _escribir(linea);
  }

  /// Linea de latido, una por segundo mientras haya un viaje activo.
  ///
  /// Sin esto no hay forma de saber si el fichero se esta escribiendo sin
  /// arrancar un viaje: la traza de camara solo emite cuando el modo navegacion
  /// esta activo, y sin latido el unico modo de comprobar que el registro
  /// funciona es gastando un recorrido entero para descubrir que no escribia
  /// nada.
  Timer? _latido;

  /// Arranca el latido. Idempotente.
  void iniciarLatido() {
    if (_latido != null) return;
    if (!kDebugMode && !forzado) return;
    _latido = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_sink == null) return;
      _escribir('[LATIDO] vivo');
    });
  }

  /// Para el latido.
  void pararLatido() {
    _latido?.cancel();
    _latido = null;
  }

  /// Ruta del fichero, o `null` si no se pudo abrir. Para mostrar en el menu.
  String? get ruta => _fichero?.path;

  /// Cierra y reabre dejando un marcador de fecha. Util para separar viajes.
  Future<void> marcar(String texto) async {
    if (_sink == null) return;
    _escribir('--- $texto ---');
  }
}