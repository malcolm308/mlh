import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import 'client_home_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('client_token');
    final id = prefs.getString('client_id');
    if (token != null && id != null) {
      final api = ApiService();
      api.token = token;
      if (!mounted) return;
      setState(() => _loading = true);
      try {
        final profile = await api.getCliente(id);
        if (!mounted) return;
        _goHome(api, profile, id);
      } catch (_) {
        if (!mounted) return;
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ApiService();
      final token = await api.login(_email.text.trim(), _password.text);
      final id = api.jwtId(token);
      if (id == null) throw ApiException('No se pudo obtener el id del token');
      final profile = await api.getCliente(id);
      if (profile.email.isEmpty) {
        throw ApiException('La cuenta no existe como cliente');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('client_token', token);
      await prefs.setString('client_id', id);
      await prefs.setString('client_email', _email.text.trim());

      if (!mounted) return;
      _goHome(api, profile, id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _goHome(ApiService api, ClientProfile profile, String clientId) {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ClientHomeScreen(
        api: api,
        profile: profile,
        clientId: clientId,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Fondo: la imagen ocupa la pantalla completa. Va con `cover` para
          // que llene el movil entero aunque el formato no coincida.
          Image.asset(
            'assets/images/login_bg.png',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),

          // Velo oscuro suave: sin esto los campos claros sobre una foto
          // nocturna pierden contraste y el texto de la imagen choca.
          Container(color: Colors.black.withValues(alpha: 0.25)),

          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: ConstrainedBox(
                    // El alto minimo mantiene el contenido centrado en
                    // pantallas altas, pero deja que scrollee si el teclado
                    // sube y no cabe todo.
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 40,
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Hueco para el logo, que ya viene impreso en la
                          // foto de fondo. Es proporcional al alto util para
                          // que en un movil normal quede arriba del formulario.
                          SizedBox(height: constraints.maxHeight * 0.30),
                          const SizedBox(height: 16),

                          // Tarjeta de credenciales. Fondo casi opaco para
                          // que el texto se lea de sobra sobre la foto.
                          Container(
                            padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.90),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextFormField(
                                  controller: _email,
                                  keyboardType: TextInputType.emailAddress,
                                  autocorrect: false,
                                  decoration: const InputDecoration(
                                    labelText: 'Email',
                                    prefixIcon: Icon(Icons.email_outlined),
                                    filled: true,
                                    fillColor: Colors.white,
                                    border: OutlineInputBorder(),
                                  ),
                                  validator: (v) => (v == null || v.trim().isEmpty)
                                      ? 'Ingresa tu email'
                                      : null,
                                ),
                                const SizedBox(height: 14),
                                TextFormField(
                                  controller: _password,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Contraseña',
                                    prefixIcon: Icon(Icons.lock_outline),
                                    filled: true,
                                    fillColor: Colors.white,
                                    border: OutlineInputBorder(),
                                  ),
                                  validator: (v) => (v == null || v.isEmpty)
                                      ? 'Ingresa tu contraseña'
                                      : null,
                                  onFieldSubmitted: (_) => _login(),
                                ),
                                if (_error != null) ...[
                                  const SizedBox(height: 12),
                                  Text(
                                    _error!,
                                    style: TextStyle(
                                      color: scheme.error,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                                const SizedBox(height: 20),
                                FilledButton.icon(
                                  onPressed: _loading ? null : _login,
                                  icon: _loading
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Icon(Icons.login),
                                  label: Text(
                                    _loading ? 'Ingresando...' : 'Iniciar sesión',
                                  ),
                                  style: FilledButton.styleFrom(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 16),
                                    backgroundColor: const Color(0xFF007AFF),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: _loading
                                      ? null
                                      : () => Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const RegisterScreen(),
                                            ),
                                          ),
                                  icon: const Icon(Icons.person_add_alt_1),
                                  label: const Text('Registrarse'),
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48),
                                    foregroundColor: const Color(0xFF007AFF),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Backend: ${ApiConfig.baseUrl}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }
}