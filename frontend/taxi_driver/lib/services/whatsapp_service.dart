import 'package:url_launcher/url_launcher.dart';

/// Excepción lanzada cuando una acción de WhatsApp no puede ejecutarse.
///
/// [message] está pensado para mostrarse directamente al usuario (SnackBar,
/// Toast, etc.).
class WhatsAppException implements Exception {
  final String message;

  const WhatsAppException(this.message);

  @override
  String toString() => message;
}

/// Servicio reutilizable para abrir WhatsApp (mensaje y chat de llamada).
///
/// Flujo:
/// 1. Si WhatsApp está instalado (comprobado con `canLaunchUrl` sobre el
///    esquema nativo `whatsapp://`), se abre la app directamente.
/// 2. Si no está instalado (o la plataforma no soporta el esquema, ej. web),
///    se abre el enlace público `https://wa.me/<numero>` que en móvil abre
///    WhatsApp (si está) y en escritorio la WhatsApp Web.
///
/// Uso en Android/iOS:
///   - AndroidManifest.xml  → etiqueta `<queries>` con el paquete de WhatsApp.
///   - Info.plist (iOS)     → `LSApplicationQueriesSchemes` con "whatsapp".
/// Ver los entregables adjuntos a este servicio.
class WhatsAppService {
  /// Mínimo de dígitos (país + número) para considerar el número válido.
  static const int _minDigitos = 8;

  /// Longitud máxima razonable (ej. +53 5 12... Cuba: 8 dígitos base).
  static const int _maxDigitos = 15;

  /// Normaliza un número a solo dígitos (formato internacional sin "+").
  ///
  /// - Elimina espacios, guiones, paréntesis, puntos y signos "+".
  /// - Retorna `null` si tras limpiar no quedan suficientes dígitos.
  String? _normalizarNumero(String numero) {
    final limpio = numero.replaceAll(RegExp(r'[^\d]'), '');
    if (limpio.length < _minDigitos || limpio.length > _maxDigitos) {
      return null;
    }
    return limpio;
  }

  /// URI público `https://wa.me/<numero>` usado como fallback.
  Uri _waMeUri(String numero, {String? mensaje}) {
    return Uri(
      scheme: 'https',
      host: 'wa.me',
      path: '/$numero',
      queryParameters: {
        if (mensaje != null && mensaje.isNotEmpty) 'text': mensaje,
      },
    );
  }

  /// URI nativa `whatsapp://send?phone=...` (solo cuando la app está instalada).
  Uri _nativeUri(String numero, {String? mensaje}) {
    return Uri(
      scheme: 'whatsapp',
      path: 'send',
      queryParameters: {
        'phone': numero,
        if (mensaje != null && mensaje.isNotEmpty) 'text': mensaje,
      },
    );
  }

  /// Comprueba si WhatsApp está instalado en el dispositivo.
  ///
  /// En web siempre devuelve `false` (el esquema no está soportado), lo que
  /// deriva automáticamente hacia la WhatsApp Web.
  Future<bool> _whatsappInstalado(String numero) async {
    try {
      return await canLaunchUrl(_nativeUri(numero));
    } catch (_) {
      return false;
    }
  }

  /// Abre WhatsApp con un mensaje predefinido hacia [numero].
  ///
  /// [mensaje] se inserta como texto inicial del chat usando el parámetro
  /// `text` de wa.me / whatsapp://.
  ///
  /// Lanza [WhatsAppException] si el número es inválido o no se pudo abrir.
  Future<void> enviarMensaje({
    required String numero,
    required String mensaje,
  }) async {
    await _abrir(numero, mensaje: mensaje);
  }

  /// Abre el chat de WhatsApp con el contacto para que el usuario toque el
  /// icono de llamada.
  ///
  /// NOTA: no existe una URL pública oficial para iniciar una llamada de voz o
  /// vídeo de forma automática con `url_launcher`. La mejor alternativa es
  /// abrir el chat: el pasajero/chofer pulsa el icono de llamada él mismo.
  ///
  /// Lanza [WhatsAppException] si el número es inválido o no se pudo abrir.
  Future<void> abrirChatParaLlamada({required String numero}) async {
    await _abrir(numero, mensaje: null);
  }

  Future<void> _abrir(String numero, {required String? mensaje}) async {
    final n = _normalizarNumero(numero);
    if (n == null) {
      throw const WhatsAppException(
        'Número de teléfono inválido. Usa formato internacional (ej. 5351234567).',
      );
    }

    // 1) Intento nativo (mejor experiencia: abre la app directa).
    if (await _whatsappInstalado(n)) {
      final ok = await launchUrl(
        _nativeUri(n, mensaje: mensaje),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        throw const WhatsAppException('No se pudo abrir WhatsApp.');
      }
      return;
    }

    // 2) Fallback: wa.me → WhatsApp Web (o la app si el SO lo redirige).
    final ok = await launchUrl(
      _waMeUri(n, mensaje: mensaje),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) {
      throw const WhatsAppException(
        'WhatsApp no está disponible. Instálalo o inicia sesión en WhatsApp Web.',
      );
    }
  }
}