import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_config.dart';

/// Tipo de actualizacion que devuelve `GET /app/version`.
enum UpdateKind { none, patch, apk }

/// Actualizaciones OTA de la app del chofer.
///
/// El backend decide con `version_actual` + `version_codigo`:
///
///  * `patch`: descarga en segundo plano y la aplica el plugin. El parche se
///    activa en el siguiente arranque en frio, sin molestar al chofer.
///  * `apk`: la version esta demasiado atrasada. Se muestra un dialogo
///    BLOQUEANTE que abre la descarga del APK completo.
///
/// Regla de oro: si hay un viaje activo (`viajeActivo = true`) no se
/// interrumpe NUNCA. El aviso queda pendiente y se muestra cuando el viaje
/// pasa a `completed`/`cancelled` (o `expired`).
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// Identificador que entiende el backend: `client` o `driver`.
  static const String appId = 'driver';

  bool _consultando = false;
  bool _dialogoAbierto = false;

  /// Contexto que abrio el dialogo. Se guarda para poder cerrarlo si una
  /// reconsulta dice que ya no hace falta actualizar.
  BuildContext? _dialogoContexto;

  /// `PopScope.canPop` del dialogo. Se pone en true antes de hacer `pop()`
  /// porque con `canPop: false` Flutter bloquea tambien el pop programatico.
  ValueNotifier<bool>? _puedeCerrarDialogo;

  /// Un viaje esta en curso: no se puede tapar la pantalla con el dialogo.
  bool viajeActivo = false;

  /// URL del APK pendiente. `null` si no hace falta actualizacion forzada.
  String? _apkPendiente;

  /// Parches ya intentados en esta ejecucion (evita descargas repetidas al
  /// recuperar la app o al reconsultar tras un viaje).
  final Set<String> _parchesIntentados = <String>{};

  /// Hay una actualizacion obligatoria esperando a que termine el viaje.
  bool get hayActualizacionPendiente => _apkPendiente != null;

  /// Solo para pruebas: fija el APK pendiente sin consultar la red.
  @visibleForTesting
  void depurarApkPendiente(String? url) => _apkPendiente = url;

  /// Solo para pruebas: olvida el estado del dialogo entre casos.
  @visibleForTesting
  void depurarReiniciarDialogo() {
    _dialogoAbierto = false;
    _dialogoContexto = null;
    _puedeCerrarDialogo = null;
  }

  /// Solo para pruebas: simula que el backend dejo de pedir actualizacion.
  @visibleForTesting
  void depurarSinActualizacion() {
    _apkPendiente = null;
    _cerrarDialogoSiNoHaceFalta();
  }

  /// Consulta el backend y aplica lo que corresponda.
  ///
  /// Nunca lanza: un fallo de red deja la app funcionando con la version que
  /// tiene. Se puede llamar al iniciar, al recuperar sesion y al volver del
  /// segundo plano.
  Future<void> revisar() async {
    // Build de Google Play: las actualizaciones las gestiona Play. No se
    // descargan parches ni se ofrece un APK externo (Device and Network Abuse).
    if (ApiConfig.playStoreBuild) return;
    if (_consultando) return;
    _consultando = true;
    try {
      final info = await PackageInfo.fromPlatform();
      final codigo = int.tryParse(info.buildNumber) ?? 0;
      // ABI real del telefono: el backend elige el APK de 32 o 64 bits sin
      // depender de deducirlo del versionCode.
      final abi = await FlutterPatcher.deviceAbi;
      final parametros = <String, String>{
        'version_actual': info.version,
        'version_codigo': '$codigo',
        'app': appId,
      };
      if (abi.isNotEmpty) parametros['abi'] = abi;
      final uri = Uri.parse(
        ApiConfig.appVersion(),
      ).replace(queryParameters: parametros);
      final respuesta = await http
          .get(uri)
          .timeout(const Duration(seconds: 25));
      if (respuesta.statusCode != 200) {
        debugPrint('[OTA] /app/version respondio ${respuesta.statusCode}');
        return;
      }
      final datos = jsonDecode(respuesta.body);
      if (datos is! Map<String, dynamic>) return;

      final tipo = (datos['tipo_actualizacion'] ?? '').toString();
      switch (tipo) {
        case 'patch':
          // Si venia un APK pendiente de un viaje anterior y el backend ya
          // sirve un parche, el parche lo resuelve: se descarta el aviso.
          _apkPendiente = null;
          await _aplicarParche(datos, codigo);
        case 'apk':
          final url = (datos['url_apk'] ?? datos['url'] ?? '').toString();
          _apkPendiente = url.isEmpty ? null : url;
        default:
          _apkPendiente = null;
      }
      if (_apkPendiente == null) _cerrarDialogoSiNoHaceFalta();
    } catch (e) {
      // Sin red, con Render dormido o con un JSON raro: se reintenta en la
      // proxima apertura. No se molesta al chofer.
      debugPrint('[OTA] no se pudo consultar la version: $e');
    } finally {
      _consultando = false;
    }
  }

  /// Aplica el parche en segundo plano (efecto en el proximo arranque).
  Future<void> _aplicarParche(
    Map<String, dynamic> datos,
    int codigoInstalado,
  ) async {
    final bloque = datos['patch'];
    final parche = bloque is Map<String, dynamic> ? bloque : datos;

    final version = (parche['version'] ?? datos['patch_version'] ?? '')
        .toString();
    final url = (parche['patch_url'] ?? datos['patch_url'] ?? '').toString();
    final md5 = (parche['md5'] ?? datos['patch_md5'] ?? '').toString();
    final destinoCrudo =
        parche['target_version_code'] ?? datos['target_version_code'];

    if (version.isEmpty || url.isEmpty) return;

    // Un parche solo vale para el APK base exacto con el que se compilo. Si
    // el backend se equivoca de destino, se ignora: jamas se corrompe la app.
    final destino = destinoCrudo is num
        ? destinoCrudo.toInt()
        : int.tryParse('$destinoCrudo');
    if (destino != null && destino != codigoInstalado) {
      debugPrint(
        '[OTA] parche $version es para vc=$destino, '
        'instalado vc=$codigoInstalado: ignorado',
      );
      return;
    }
    if (_parchesIntentados.contains(version)) return;
    if (await FlutterPatcher.currentVersion == version) return;

    _parchesIntentados.add(version);
    final resultado = await FlutterPatcher.applyPatch(
      PatchInfo(
        version: version,
        patchUrl: url,
        md5: md5,
        targetVersionCode: codigoInstalado,
      ),
    );
    if (resultado.ok) {
      debugPrint(
        '[OTA] parche $version instalado. '
        'Se aplicara al reabrir la app.',
      );
    } else {
      // Plan B: si el parche no se puede instalar (md5, base distinta o fallo
      // del plugin), se avisa con el APK completo que ya manda el backend
      // para esta ABI. Sin esto la app se quedaba atascada en silencio.
      final urlApk = (datos['url_apk'] ?? '').toString();
      if (urlApk.isNotEmpty) _apkPendiente = urlApk;
      debugPrint(
        '[OTA] parche $version fallo: '
        '${resultado.error?.name} ${resultado.message ?? ''} '
        '-> APK de respaldo: $urlApk',
      );
    }
  }

  /// Muestra el dialogo bloqueante si hace falta y no hay viaje en curso.
  ///
  /// El dialogo no se puede cerrar con el boton atras ni tocando fuera: la
  /// unica salida es instalar la version nueva, salvo que una reconsulta
  /// demuestre que el backend ya no la exige ([_cerrarDialogoSiNoHaceFalta]).
  Future<void> mostrarSiHaceFalta(BuildContext context) async {
    final url = _apkPendiente;
    if (url == null || viajeActivo || _dialogoAbierto) return;
    if (!context.mounted) return;

    final puedeCerrar = ValueNotifier<bool>(false);
    _puedeCerrarDialogo = puedeCerrar;
    _dialogoContexto = context;
    _dialogoAbierto = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (ctx) => ValueListenableBuilder<bool>(
          valueListenable: puedeCerrar,
          builder: (contextoDialogo, permitir, child) => PopScope(
            canPop: permitir,
            child: AlertDialog(
              title: const Text('Actualización requerida'),
              content: const Text(
                'Tu versión ya no es compatible con el servicio. '
                'Instala la nueva versión para seguir recibiendo viajes. '
                'Tu cuenta y tus ganancias no se pierden.',
              ),
              actions: [
                FilledButton(
                  onPressed: () => _abrirDescarga(contextoDialogo, url),
                  child: const Text('Actualizar ahora'),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      _dialogoAbierto = false;
      _dialogoContexto = null;
      _puedeCerrarDialogo = null;
      puedeCerrar.dispose();
    }
  }

  /// Cierra el aviso si una reconsulta (`none` o `patch`) dejo sin efecto la
  /// exigencia de actualizar.
  ///
  /// Hace falta porque el dialogo se queda montado aunque `_apkPendiente` pase
  /// a null: el chofer podia instalar el APK por su cuenta y volver a la
  /// pantalla antigua, y el cartel seguia ahi. Con `canPop: false` Flutter
  /// bloquea incluso el `pop()` programatico, asi que primero se habilita el
  /// cierre y se espera al siguiente frame para que PopScope se reconstruya.
  void _cerrarDialogoSiNoHaceFalta() {
    final contexto = _dialogoContexto;
    final puedeCerrar = _puedeCerrarDialogo;
    if (!_dialogoAbierto || contexto == null || puedeCerrar == null) return;
    if (!contexto.mounted) return;

    puedeCerrar.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!contexto.mounted || !_dialogoAbierto) return;
      Navigator.of(contexto, rootNavigator: true).pop();
    });
  }

  Future<void> _abrirDescarga(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final abierto = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!abierto && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('No se pudo abrir el navegador. Descarga: $url'),
        ),
      );
    }
  }
}
