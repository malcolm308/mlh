import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'reset_password_screen.dart';

/// Paso 1 de la recuperacion: el chofer escribe el correo de su cuenta.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  String? _validEmail(String? v) {
    if (v == null || v.trim().isEmpty) return 'Ingresa tu correo';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) {
      return 'Correo no válido';
    }
    return null;
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ApiService();
      final r = await api.forgotPassword(_email.text);
      if (!mounted) return;
      setState(() => _loading = false);
      final mensaje = (r['mensaje'] ?? 'Te enviamos un código a tu correo.').toString();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.mark_email_read_outlined,
              size: 44, color: AppColors.ambar),
          title: const Text('Correo enviado'),
          content: Text(
            '$mensaje\n\nSi no lo ves, revisa la carpeta de spam.',
            textAlign: TextAlign.center,
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Continuar'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResetPasswordScreen(email: _email.text.trim()),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Recuperar contraseña')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_reset, size: 64, color: AppColors.ambar),
                const SizedBox(height: 12),
                const Text(
                  '¿Olvidaste tu contraseña?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.tinta),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Escribe el correo con el que te registraste. Te enviaremos '
                  'un código de 6 dígitos para crear una contraseña nueva.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.secundario, height: 1.4),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Correo electrónico',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: _validEmail,
                  onFieldSubmitted: (_) => _send(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, fontSize: 13)),
                ],
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: _loading ? null : _send,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_outlined),
                  label: Text(_loading ? 'Enviando...' : 'Enviar código'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 14),
                TextButton(
                  onPressed: _loading ? null : () => Navigator.of(context).pop(),
                  child: const Text('Volver al inicio de sesión'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Soporte: rapitaxicuba@gmail.com',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.secundario, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
