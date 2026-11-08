import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api_config.dart';
import 'token_store.dart';

/// Error de red o de respuesta HTTP, con mensaje legible para el usuario.
class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Capa de transporte única de la app contra el backend de TaxiRapid.
///
/// - Timeout de 15 s por petición.
/// - Reintenta SOLO los fallos de red (sin conexión, timeout, cierre de
///   socket) con backoff: espera 1 s y reintenta, y si vuelve a fallar espera
///   3 s para un tercer intento. Los errores HTTP (4xx/5xx) NO se reintentan:
///   ya son respuesta del servidor.
/// - Manda `Content-Type: application/json; charset=utf-8` y el token Bearer
///   cuando [token] está disponible.
/// - Codifica a UTF-8 y descodifica JSON (`Map` o `List`).
/// - Lanza [ApiException] con un mensaje legible.
class ApiClient {
  ApiClient._();

  static const Duration _timeout = Duration(seconds: 15);

  /// Cliente HTTP PERSISTENTE (Keep-Alive).
  ///
  /// Antes se usaban las funciones de nivel superior de `package:http`
  /// (`http.get/post/...`): un `HttpClient` nuevo y cerrado POR PETICION,
  /// lo que obligaba a negociar TLS con Render cada vez. Con el mismo
  /// cliente las conexiones ociosas se reutilizan y se declara
  /// `Accept-Encoding: gzip`, que dart:io descomprime por si solo.
  static http.Client _cliente = http.Client();

  /// Permite inyectar un cliente falso en las pruebas.
  @visibleForTesting
  static set clienteDePruebas(http.Client cliente) => _cliente = cliente;

  /// Caché de lecturas GET por prefijo (solo datos que no cambian a
  /// cada rato). El garaje y los descuentos NO se cachean.
  static const Map<String, Duration> _ttlCacheGET = {
    '/vehiculos/tipos': Duration(minutes: 30),
    '/admin/promociones/tarifas-espera': Duration(seconds: 60),
  };

  static final Map<String, (DateTime, dynamic)> _cacheGET = {};

  static Duration? _ttlPorCache(String url) {
    final ruta = Uri.parse(url).path;
    for (final e in _ttlCacheGET.entries) {
      if (ruta.startsWith(e.key)) return e.value;
    }
    return null;
  }

  /// Esperas entre reintentos de fallos de red (1 s y 3 s).
  static const List<Duration> _reintentos = [
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  /// Token JWT que se manda como `Authorization: Bearer <token>`.
  static String? token;

  // ---------------- SESION / REFRESH ----------------
  //
  // Ganchos sobreescribibles para las pruebas. En produccion apuntan a
  // [TokenStore]; asi el test del interceptor no necesita el plugin nativo.

  static Future<String?> Function() leerRefreshToken =
      () => TokenStore.instance.leerRefresh();
  static Future<void> Function(String) guardarAccessToken =
      (t) => TokenStore.instance.guardarAccess(t);
  static Future<void> Function() limpiarSesion =
      () => TokenStore.instance.limpiar();

  /// Se invoca UNA vez cuando el refresh es rechazado (sesion caducada).
  static void Function()? alExpirarSesion;

  static Future<bool>? _refreshEnCurso;
  static bool _sesionCerrada = false;

  /// La llama el login tras guardar tokens: reactiva el aviso de expiracion.
  static void marcarSesionActiva() {
    _sesionCerrada = false;
  }

  /// `/login` y `/auth/refresh` pueden devolver 401 de forma legitima (datos
  /// incorrectos); nunca deben disparar otro refresh ni cerrar la sesion.
  static bool _esRutaSinRefresh(String url) {
    final ruta = Uri.parse(url).path;
    return ruta.endsWith('/login') || ruta.endsWith('/auth/refresh');
  }

  /// Ejecuta la peticion y, si responde 401, refresca el access y la repite
  /// UNA vez. Si el refresh falla, devuelve el 401 original.
  static Future<http.Response> _ejecutarConAuth(
    Future<http.Response> Function() accion, {
    required String url,
    Duration? timeout,
  }) async {
    final r = await _ejecutar(accion, timeout: timeout);
    if (r.statusCode != 401 || _esRutaSinRefresh(url)) return r;
    if (!await _renovarAccess()) return r;
    return _ejecutar(accion, timeout: timeout);
  }

  /// Single-flight: varias peticiones que fallan a la vez comparten el mismo
  /// refresh en lugar de lanzar uno cada una.
  static Future<bool> _renovarAccess() {
    final enCurso = _refreshEnCurso;
    if (enCurso != null) return enCurso;
    final futuro = _hacerRefresh();
    _refreshEnCurso = futuro;
    return futuro.whenComplete(() {
      if (identical(_refreshEnCurso, futuro)) _refreshEnCurso = null;
    });
  }

  static Future<bool> _hacerRefresh() async {
    final refresh = await leerRefreshToken();
    if (refresh == null || refresh.isEmpty) {
      if (token != null && token!.isNotEmpty) await _cerrarSesion();
      return false;
    }

    http.Response r;
    try {
      r = await _cliente
          .post(
            Uri.parse('${ApiConfig.baseUrl}/auth/refresh'),
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({'refresh_token': refresh}),
          )
          .timeout(_timeout);
    } catch (_) {
      // Fallo de red: NO se borra la sesion. Se reintentara en otra peticion.
      return false;
    }

    if (r.statusCode == 401 || r.statusCode == 403) {
      await _cerrarSesion();
      return false;
    }
    if (r.statusCode < 200 || r.statusCode >= 300) return false;

    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final nuevo = j is Map ? j['access_token']?.toString() : null;
      if (nuevo == null || nuevo.isEmpty) return false;
      token = nuevo;
      await guardarAccessToken(nuevo);
      _sesionCerrada = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _cerrarSesion() async {
    if (_sesionCerrada) return;
    _sesionCerrada = true;
    token = null;
    try {
      await limpiarSesion();
    } catch (_) {}
    alExpirarSesion?.call();
  }

  static Map<String, String> _headers(Map<String, String>? extra) => {
        'Content-Type': 'application/json; charset=utf-8',
        if (token != null && token!.isNotEmpty)
          'Authorization': 'Bearer $token',
        ...?extra,
      };

  static String _errorLegible(http.Response r) {
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) {
        final d = j['detail'] ?? j['message'] ?? j['error'];
        if (d != null) {
          // Algunos endpoints anidan el texto: `detail` llega como objeto con
          // `detail`, `code` y datos del caso (por ejemplo el saldo). Sin esto
          // el usuario veria el mapa entero impreso en pantalla.
          if (d is Map && d['detail'] != null) return d['detail'].toString();
          return d.toString();
        }
      }
    } catch (_) {}
    return 'Error ${r.statusCode}';
  }

  /// Ejecuta [accion] con timeout y reintentos de fallos de red.
  ///
  /// [timeout] sobreescribe el de 15 s por peticion. Lo usa OSRM, que desde
  /// una red movil normal puede tardar mas que el backend propio en devolver
  /// la ruta: con 15 s por intento el trayecto caia al fallback en linea recta.
  static Future<http.Response> _ejecutar(
    Future<http.Response> Function() accion, {
    Duration? timeout,
  }) async {
    var fallidos = 0;
    while (true) {
      try {
        return await accion().timeout(timeout ?? _timeout);
      } on SocketException {
        if (fallidos >= _reintentos.length) {
          throw ApiException(
              'No hay conexión con el servidor. Revisa tu internet.');
        }
      } on TimeoutException {
        if (fallidos >= _reintentos.length) {
          throw ApiException(
              'El servidor tarda demasiado en responder. Inténtalo de nuevo.');
        }
      } on http.ClientException {
        if (fallidos >= _reintentos.length) {
          throw ApiException('No se pudo conectar con el servidor.');
        }
      }
      await Future<void>.delayed(_reintentos[fallidos]);
      fallidos++;
    }
  }

  static dynamic _descodificar(http.Response r) {
    if (r.body.trim().isEmpty) return const {};
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// GET con cache por TTL (solo rutas declaradas en [_ttlCacheGET]).
  static Future<dynamic> _getConCache(String url, Map<String, String>? headers,
      Duration? timeout) async {
    final ttl = _ttlPorCache(url);
    if (ttl != null) {
      final r = _cacheGET[url];
      if (r != null && DateTime.now().difference(r.$1) < ttl) {
        return r.$2;
      }
    }
    final datos = await _ejecutarConAuth(
      () => _cliente.get(Uri.parse(url), headers: _headers(headers)),
      url: url,
      timeout: timeout,
    );
    if (datos.statusCode >= 200 && datos.statusCode < 300) {
      final decodificado = _descodificar(datos);
      if (ttl != null) _cacheGET[url] = (DateTime.now(), decodificado);
      return decodificado;
    }
    throw ApiException(
      '${_errorLegible(datos)} (HTTP ${datos.statusCode})',
      statusCode: datos.statusCode,
    );
  }

  static Future<dynamic> _request(
    String method,
    String url, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    if (method == 'GET') return _getConCache(url, headers, timeout);
    final r = await _ejecutarConAuth(
      () {
        final uri = Uri.parse(url);
        switch (method) {
          case 'POST':
            return _cliente.post(uri,
                headers: _headers(headers),
                body: body == null ? null : jsonEncode(body));
          case 'PUT':
            return _cliente.put(uri,
                headers: _headers(headers),
                body: body == null ? null : jsonEncode(body));
          case 'PATCH':
            return _cliente.patch(uri,
                headers: _headers(headers),
                body: body == null ? null : jsonEncode(body));
          case 'DELETE':
            return _cliente.delete(uri, headers: _headers(headers));
          default:
            throw ApiException('Método HTTP no soportado: $method');
        }
      },
      url: url,
      timeout: timeout,
    );
    if (r.statusCode >= 200 && r.statusCode < 300) return _descodificar(r);
    throw ApiException(
      '${_errorLegible(r)} (HTTP ${r.statusCode})',
      statusCode: r.statusCode,
    );
  }

  static Future<dynamic> get(String url,
          {Map<String, String>? headers, Duration? timeout}) =>
      _request('GET', url, headers: headers, timeout: timeout);

  /// Descarga los BYTES de una imagen (ej. la foto de rostro del chofer).
  ///
  /// Va con el token del chofer: `/documentos/chofer/{id}/foto/{campo}` solo
  /// sirve al dueno o al administrador. Devuelve null si no hay foto o si el
  /// servidor no esta accesible: el avatar pinta su respaldo.
  static Future<List<int>?> descargarImagen(String url) async {
    try {
      final r = await _ejecutarConAuth(
        () => _cliente.get(Uri.parse(url), headers: _headers(null)),
        url: url,
      );
      if (r.statusCode >= 200 && r.statusCode < 300) return r.bodyBytes;
    } catch (_) {
      // Sin foto: el avatar muestra el icono de respaldo.
    }
    return null;
  }

  static Future<dynamic> post(
    String url, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _request('POST', url, body: body, headers: headers, timeout: timeout);

  static Future<dynamic> put(
    String url, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) =>
      _request('PUT', url, body: body, headers: headers);

  static Future<dynamic> patch(
    String url, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) =>
      _request('PATCH', url, body: body, headers: headers);

  static Future<dynamic> delete(
    String url, {
    Map<String, String>? headers,
  }) =>
      _request('DELETE', url, headers: headers);

  /// POST que NO lanza en 4xx/5xx: devuelve el cuerpo descodificado con la
  /// clave extra `http_status` para que quien llama interprete el fallo.
  static Future<Map<String, dynamic>> postConEstatus(
    String url, {
    required Map<String, dynamic> body,
    Map<String, String>? headers,
  }) async {
    final r = await _ejecutarConAuth(
      () => _cliente.post(
        Uri.parse(url),
        headers: _headers(headers),
        body: jsonEncode(body),
      ),
      url: url,
    );
    final decoded = r.body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    decoded['http_status'] = r.statusCode;
    return decoded;
  }

  /// Multipart (registro con fotos): sube [fields] y los [files] (campo →
  /// ruta local). No reintenta automáticamente: releer los ficheros en cada
  /// reintento solo duplica el tiempo de un fallo de red.
  static Future<dynamic> multipart(
    String url,
    Map<String, String> fields, {
    Map<String, String>? files,
    Map<String, String>? headers,

    /// Prefijo de los campos de archivo. El registro de documentos del chofer
    /// espera `doc_rostro`, `doc_carnet_frente`, ... (prefijo por defecto) y
    /// las fotos de Mi Garaje esperan los campos SIN prefijo
    /// (`vehiculo_exterior_frente`, ...): ahi se manda `prefijo: ''`.
    String prefijo = 'doc_',
  }) async {
    Future<http.Response> enviar() async {
      final req = http.MultipartRequest('POST', Uri.parse(url));
      req.fields.addAll(fields);
      files?.forEach((campo, ruta) {
        final f = File(ruta);
        req.files.add(http.MultipartFile.fromBytes(
          '$prefijo$campo',
          f.readAsBytesSync(),
          filename: f.uri.pathSegments.last,
        ));
      });
      if (token != null && token!.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      if (headers != null) req.headers.addAll(headers);
      final streamed = await _cliente.send(req).timeout(_timeout);
      return http.Response.fromStream(streamed);
    }

    try {
      var r = await enviar();
      if (r.statusCode == 401 && !_esRutaSinRefresh(url)) {
        if (await _renovarAccess()) r = await enviar();
      }
      if (r.statusCode >= 200 && r.statusCode < 300) return _descodificar(r);
      throw ApiException(
        '${_errorLegible(r)} (HTTP ${r.statusCode})',
        statusCode: r.statusCode,
      );
    } on ApiException {
      rethrow;
    } on SocketException {
      throw ApiException('No hay conexión con el servidor. Revisa tu internet.');
    } on TimeoutException {
      throw ApiException(
          'El servidor tarda demasiado en responder. Inténtalo de nuevo.');
    } on http.ClientException {
      throw ApiException('No se pudo conectar con el servidor.');
    }
  }
}