import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guarda la sesion del cliente: access y refresh token.
///
/// Los tokens se almacenan exclusivamente en el almacenamiento seguro del sistema
/// (Keystore en Android / Keychain en iOS). Se migra y elimina cualquier espejo
/// previo en `SharedPreferences` (`client_token`) para cumplir con el hardening.
class TokenStore {
  TokenStore._();

  static final TokenStore instance = TokenStore._();

  static const FlutterSecureStorage _seguro = FlutterSecureStorage();

  static const String _kAccess = 'taxi_client_access';
  static const String _kRefresh = 'taxi_client_refresh';

  /// Clave legacy en SharedPreferences (solo para migración/eliminación).
  static const String _kEspejoLegacy = 'client_token';

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
    // Asegura que no quede ninguna copia en SharedPreferences.
    await _eliminarEspejoLegacy();
  }

  /// Access actual. Migra desde el espejo legacy si existe y luego lo elimina.
  Future<String?> leerAccess() async {
    try {
      final valor = await _seguro.read(key: _kAccess);
      if (valor != null && valor.isNotEmpty) {
        await _eliminarEspejoLegacy();
        return valor;
      }
    } catch (e) {
      debugPrint('TokenStore: no se pudo leer el access token: $e');
    }
    // Migración única desde instalaciones anteriores.
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_kEspejoLegacy);
      if (legacy != null && legacy.isNotEmpty) {
        try {
          await _seguro.write(key: _kAccess, value: legacy);
        } catch (_) {}
        await prefs.remove(_kEspejoLegacy);
        return legacy;
      }
    } catch (_) {}
    return null;
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

  /// Borra los tokens del almacenamiento seguro y cualquier resto legacy.
  Future<void> limpiar() async {
    try {
      await _seguro.delete(key: _kAccess);
      await _seguro.delete(key: _kRefresh);
    } catch (e) {
      debugPrint('TokenStore: no se pudieron borrar los tokens: $e');
    }
    await _eliminarEspejoLegacy();
  }

  Future<void> _eliminarEspejoLegacy() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_kEspejoLegacy)) {
        await prefs.remove(_kEspejoLegacy);
      }
    } catch (_) {}
  }
}
