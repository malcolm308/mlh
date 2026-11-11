import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl_phone_field/country_picker_dialog.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../services/token_store.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import 'driver_home_screen.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.mensaje});

  /// Mensaje que se muestra al abrir, por ejemplo tras enviar el registro.
  final String? mensaje;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  /// Numero en E.164 (`+5359295207`) con el prefijo del pais elegido.
  ///
  /// Antes se enviaba lo tecleado a mano: con un movil que incluya el `+53`
  /// el login funcionaba, pero sin prefijo dependia de las variantes del
  /// backend. Con el selector, siempre sale completo y canonico.
  String? _telefonoCompleto;

  @override
  void initState() {
    super.initState();
    final aviso = widget.mensaje;
    if (aviso != null && aviso.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(aviso),
          duration: const Duration(seconds: 6),
        ));
      });
    }
    _restore();
    // OTA: se consulta al abrir la app, antes incluso de iniciar sesion. Un
    // parche se baja solo; si la version ya no es compatible, el aviso
    // bloqueante sale aqui. No hay viaje posible en esta pantalla.
    unawaited(_revisarActualizacion());
  }

  /// Estados en los que el chofer aun no puede entrar a la app.
  static const _estadosPendientes = {
    'pending',
    'pending_review',
    'pendiente',
    'pending_documents',
  };

  bool _esPendiente(String? estado) =>
      estado != null && _estadosPendientes.contains(estado.toLowerCase());

  /// Deja el telefono limpio y muestra un aviso sin dejar el spinner activo.
  void _avisar(String mensaje) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensaje), duration: const Duration(seconds: 6)),
    );
  }

  /// Borra tokens y datos locales de una cuenta que no puede entrar.
  Future<void> _limpiarSesionLocal(SharedPreferences prefs) async {
    await TokenStore.instance.limpiar();
    await prefs.remove('driver_id');
    await prefs.remove('driver_telefono');
    await prefs.remove('missing_fields');
  }

  /// Texto entendible para los fallos de red.
  String _mensajeError(Object e) {
    final s = e.toString();
    if (s.contains('conexión') ||
        s.contains('conectar') ||
        s.contains('tarda demasiado')) {
      return 'No se pudo conectar. Revisa tu conexión e inténtalo de nuevo.';
    }
    return s;
  }

  /// Consulta la version al backend y muestra el aviso si es obligatorio.
  Future<void> _revisarActualizacion() async {
    final update = UpdateService.instance;
    update.viajeActivo = false;
    await update.revisar();
    if (!mounted) return;
    await update.mostrarSiHaceFalta(context);
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    // Access y refresh viven en el almacenamiento seguro; el access se
    // conserva ademas en SharedPreferences para el servicio de ofertas.
    final token = await TokenStore.instance.leerAccess();
    final id = prefs.getString('driver_id');
    if (token == null || id == null) return;
    final api = ApiService();
    api.token = token;
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final profile = await api.getChofer(id);
      if (!mounted) return;
      if (_esPendiente(profile.status)) {
        // Una cuenta pendiente no puede quedarse dentro de la app.
        await _limpiarSesionLocal(prefs);
        _avisar('Tu registro está en revisión. Te contactaremos pronto.');
      } else if (profile.status == 'needs_correction' ||
          profile.status == 'rejected') {
        final guardados = prefs.getStringList('missing_fields') ?? const [];
        _goCorrection(profile, guardados);
      } else {
        _goHome(api, profile, id);
      }
    } catch (_) {
      // Sin red o perfil invalido: se queda en el login, sin spinner.
      if (!mounted) return;
      setState(() => _loading = false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    final telefono = _telefonoCompleto;
    if (telefono == null || telefono.trim().length < 8) {
      setState(() => _error = 'Ingresa tu teléfono con su prefijo');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ApiService();
      final token = await api.login(telefono.trim(), _password.text);
      final id = api.jwtId(token);
      if (id == null) throw ApiException('No se pudo obtener el id del token');
      final profile = await api.getChofer(id);
      if (profile.email.isEmpty) {
        throw ApiException('Esta cuenta no existe como chofer');
      }

      final prefs = await SharedPreferences.getInstance();
      if (_esPendiente(profile.status)) {
        // Respaldo por si el backend deja entrar a un pendiente.
        await _limpiarSesionLocal(prefs);
        _avisar('Tu registro está en revisión. Te contactaremos pronto.');
        return;
      }

      // `api.login` ya guardo access + refresh en TokenStore.
      await prefs.setString('driver_id', id);
      // Se guarda el E.164 completo: es el mismo formato en que se registró.
      await prefs.setString('driver_telefono', telefono.trim());
      // Se conserva lo que dijo el login para el proximo arranque de la app
      // (el perfil puede no traer `missing_fields` en un backend viejo).
      await prefs.setStringList('missing_fields', api.loginMissingFields);

      if (!mounted) return;
      if (profile.status == 'needs_correction' || profile.status == 'rejected') {
        _goCorrection(profile, api.loginMissingFields);
      } else {
        _goHome(api, profile, id);
      }
    } catch (e) {
      if (!mounted) return;
      final texto = e.toString();
      if (texto.toLowerCase().contains('pendiente')) {
        // El backend rechaza con 403 a las cuentas en revisión.
        _avisar('Tu registro está en revisión. Te contactaremos pronto.');
      } else {
        setState(() => _error = _mensajeError(e));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _goHome(ApiService api, DriverProfile profile, String driverId) {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => DriverHomeScreen(
        api: api,
        profile: profile,
        driverId: driverId,
      ),
    ));
  }

  void _goCorrection(DriverProfile profile, [List<String>? faltantes]) {
    // `push` (no `pushReplacement`): al terminar de corregir se vuelve al
    // login, que es la pantalla base, y alli se avisa que sigue en revision.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RegisterScreen(
        isCorrectionMode: true,
        driverData: {
          '_id': profile.id,
          'Nombre': profile.nombre,
          'Apellidos': profile.apellidos,
          'email': profile.email,
          'numero_de_telefono': profile.telefono,
          'vehicle': profile.vehicleData.isNotEmpty
              ? profile.vehicleData
              : {
                  'model': profile.vehicleModel,
                  'servicio': profile.vehicleType,
                },
          'max_passengers': profile.maxPassengers,
        },
        rejectedFields:
            (faltantes != null && faltantes.isNotEmpty)
                ? faltantes
                : profile.missingFields,
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
                              color: Colors.white.withValues(alpha: 0.94),
                              borderRadius: BorderRadius.circular(26),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 24,
                                  offset: Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                IntlPhoneField(
                                  initialCountryCode: 'CU',
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                    labelText: 'Número de teléfono',
                                    hintText: 'Número con prefijo',
                                    prefixIcon: Icon(Icons.phone_iphone),
                                  ),
                                  invalidNumberMessage:
                                      'Número inválido para el país seleccionado',
                                  disableLengthCheck: false,
                                  pickerDialogStyle: PickerDialogStyle(
                                    searchFieldInputDecoration:
                                        const InputDecoration(
                                      hintText: 'Buscar país',
                                    ),
                                  ),
                                  onCountryChanged: (_) {
                                    setState(() => _telefonoCompleto = null);
                                  },
                                  onChanged: (phone) {
                                    setState(() {
                                      _telefonoCompleto = phone.completeNumber;
                                    });
                                  },
                                ),
                                const SizedBox(height: 14),
                                TextFormField(
                                  controller: _password,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Contraseña',
                                    prefixIcon: Icon(Icons.lock_outline),
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
                                    minimumSize: const Size.fromHeight(52),
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 16),
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
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 14),
                                    foregroundColor: AppColors.tinta,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          TextButton(
                            onPressed: _loading
                                ? null
                                : () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const ForgotPasswordScreen(),
                                      ),
                                    ),
                            child: const Text(
                              '¿Olvidaste tu contraseña?',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Soporte: rapitaxicuba@gmail.com',
                            textAlign: TextAlign.center,
                            style: TextStyle(
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
    _password.dispose();
    super.dispose();
  }
}