import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Paso 2 de la recuperacion: codigo recibido por correo + contrasena nueva.
class ResetPasswordScreen extends StatefulWidget {
  final String email;

  const ResetPasswordScreen({super.key, required this.email});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codigo = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _codigo.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    if (!_formKey.currentState!.validate()) return;
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Las contraseñas no coinciden');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ApiService();
      await api.resetPassword(
        email: widget.email,
        codigo: _codigo.text,
        nuevaPassword: _password.text,
      );
      if (!mounted) return;
      setState(() => _loading = false);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline,
              size: 44, color: Color(0xFF2ECC71)),
          title: const Text('Contraseña actualizada'),
          content: const Text(
            'Ya puedes iniciar sesión con tu contraseña nueva.',
            textAlign: TextAlign.center,
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Iniciar sesión'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
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
      appBar: AppBar(title: const Text('Nueva contraseña')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.password, size: 64, color: AppColors.ambar),
                const SizedBox(height: 12),
                Text(
                  'Código enviado a\n${widget.email}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.tinta),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Escribe el código de 6 dígitos del correo y tu contraseña nueva.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppColors.secundario, height: 1.4),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _codigo,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 8),
                  decoration: const InputDecoration(
                    labelText: 'Código de 6 dígitos',
                    prefixIcon: Icon(Icons.pin_outlined),
                    counterText: '',
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.length != 6 || int.tryParse(t) == null) {
                      return 'Escribe los 6 dígitos';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Contraseña nueva',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  validator: (v) => (v == null || v.length < 4)
                      ? 'Mínimo 4 caracteres'
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirmar contraseña nueva',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  validator: (v) => (v == null || v.isEmpty)
                      ? 'Confirma tu contraseña'
                      : null,
                  onFieldSubmitted: (_) => _reset(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, fontSize: 13)),
                ],
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: _loading ? null : _reset,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: Text(_loading ? 'Guardando...' : 'Cambiar contraseña'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _loading ? null : () => Navigator.of(context).pop(),
                  child: const Text('Solicitar otro código'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
