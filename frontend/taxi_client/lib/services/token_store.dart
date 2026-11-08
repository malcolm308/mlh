import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guarda la sesion del cliente: access y refresh token.
///
/// El access token vive en el almacenamiento seguro del sistema (Keystore en
/// Android) y ademas se copia a `SharedPreferences` como `client_token`, que es
/// de donde lo lee el resto de la app y cualquier isolate. El refresh token
/// solo existe en el almacenamiento seguro: no hace falta fuera del proceso
/// principal y no conviene dejarlo en un XML legible.
class TokenStore {
  TokenStore._();

  static final TokenStore instance = TokenStore._();

  static const FlutterSecureStorage _seguro = FlutterSecureStorage();

  static const String _kAccess = 'taxi_client_access';
  static const String _kRefresh = 'taxi_client_refresh';

  /// Espejo del access en SharedPreferences (compatibilidad con el resto).
  static const String _kEspejo = 'client_token';

  Future<void> guardarSesion({
    required String accessToken,
    required String refreshToken,
  }) async {
    await guardarAccess(accessToken);
    try {
      await _seguro.write(key: _kRefresh, value: refreshToken);
    } catch (e) {
      debugPrint('TokenStore: no se pudo guardar el refresh token: $e');
    }
  }

  Future<void> guardarAccess(String accessToken) async {
    try {
      await _seguro.write(key: _kAccess, value: accessToken);
    } catch (e) {
      debugPrint('TokenStore: no se pudo guardar el access token: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEspejo, accessToken);
  }

  /// Access actual. Si el almacenamiento seguro falla, cae al espejo de
  /// SharedPreferences (instalaciones anteriores al refresh token).
  Future<String?> leerAccess() async {
    try {
      final valor = await _seguro.read(key: _kAccess);
      if (valor != null && valor.isNotEmpty) return valor;
    } catch (e) {
      debugPrint('TokenStore: no se pudo leer el access token: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kEspejo);
  }

  Future<String?> leerRefresh() async {
    try {
      final valor = await _seguro.read(key: _kRefresh);
      if (valor != null && valor.isNotEmpty) return valor;
    } catch (e) {
      debugPrint('TokenStore: no se pudo leer el refresh token: $e');
    }
    return null;
  }

  /// Borra los dos tokens y el espejo. Se usa al cerrar sesion y cuando el
  /// refresh caduca o el backend lo rechaza.
  Future<void> limpiar() async {
    try {
      await _seguro.delete(key: _kAccess);
      await _seguro.delete(key: _kRefresh);
    } catch (e) {
      debugPrint('TokenStore: no se pudieron borrar los tokens: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kEspejo);
  }
}
