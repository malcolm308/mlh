import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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

  /// Esperas entre reintentos de fallos de red (1 s y 3 s).
  static const List<Duration> _reintentos = [
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  /// Token JWT que se manda como `Authorization: Bearer <token>`.
  static String? token;

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
        if (d != null) return d.toString();
      }
    } catch (_) {}
    return 'Error ${r.statusCode}';
  }

  /// Ejecuta [accion] con timeout y reintentos de fallos de red.
  ///
  /// [timeout] sobreescribe el de 15 s por peticion. Lo usa OSRM, que desde
  /// una red movil normal puede tardar mas que el backend propio en devolver
  /// la ruta: con 15 s por intento el trayecto caia al fallback en linea
  /// recta.
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

  static Future<dynamic> _request(
    String method,
    String url, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final r = await _ejecutar(() {
      final uri = Uri.parse(url);
      switch (method) {
        case 'GET':
          return http.get(uri, headers: _headers(headers));
        case 'POST':
          return http.post(uri,
              headers: _headers(headers),
              body: body == null ? null : jsonEncode(body));
        case 'PUT':
          return http.put(uri,
              headers: _headers(headers),
              body: body == null ? null : jsonEncode(body));
        case 'PATCH':
          return http.patch(uri,
              headers: _headers(headers),
              body: body == null ? null : jsonEncode(body));
        case 'DELETE':
          return http.delete(uri, headers: _headers(headers));
        default:
          throw ApiException('Método HTTP no soportado: $method');
      }
    }, timeout: timeout);
    if (r.statusCode >= 200 && r.statusCode < 300) return _descodificar(r);
    throw ApiException(
      '${_errorLegible(r)} (HTTP ${r.statusCode})',
      statusCode: r.statusCode,
    );
  }

  static Future<dynamic> get(String url,
          {Map<String, String>? headers, Duration? timeout}) =>
      _request('GET', url, headers: headers, timeout: timeout);

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
    final r = await _ejecutar(() => http.post(
          Uri.parse(url),
          headers: _headers(headers),
          body: jsonEncode(body),
        ));
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
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(url));
    req.fields.addAll(fields);
    files?.forEach((campo, ruta) {
      final f = File(ruta);
      req.files.add(http.MultipartFile.fromBytes(
        'doc_$campo',
        f.readAsBytesSync(),
        filename: f.uri.pathSegments.last,
      ));
    });
    if (token != null && token!.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    if (headers != null) req.headers.addAll(headers);
    try {
      final streamed = await req.send().timeout(_timeout);
      final r = await http.Response.fromStream(streamed);
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