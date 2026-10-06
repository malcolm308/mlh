import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/vehicle_types_service.dart';
import '../services/api_service.dart';
import '../widgets/documento_widgets.dart';

/// Formulario de registro de conductor.
///
/// Crea la cuenta en `POST /documentos/registro` enviando los datos del
/// chofer y del vehiculo junto con las 10 fotos obligatorias. El administrador
/// revisa las fotos desde el panel y decide si lo habilita.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _apellidos = TextEditingController();
  final _email = TextEditingController();
  final _telefono = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  final _marca = TextEditingController();
  final _model = TextEditingController();
  final _year = TextEditingController(text: '2020');
  final _chapa = TextEditingController();
  final _color = TextEditingController();
  /// Tipo de servicio elegido. Va en `String?` porque todavia no se ha
  /// escogido; el valor es el identificador de la tabla `tariffs`.
  String? _tipo;

  /// Tipos que publica el backend, cacheados para la pantalla.
  final VehicleTypesService _vehiculos = VehicleTypesService();
  final _maxPassengers = TextEditingController(text: '4');

  final _picker = ImagePicker();
  final Map<String, String> _fotos = {};

  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Los tipos vienen del backend. Se piden al abrir y se cachean: son cuatro
    // filas de configuracion y no cambian mientras el chofer rellena el
    // formulario. Si no hay red, el servicio deja la lista de respaldo para que
    // el registro siga siendo posible.
    WidgetsBinding.instance.addPostFrameCallback((_) => _vehiculos.cargar());
    _vehiculos.addListener(_alCambiarTipos);
  }

  @override
  void dispose() {
    _vehiculos.removeListener(_alCambiarTipos);
    _vehiculos.dispose();
    for (final c in [
      _nombre, _apellidos, _email, _telefono, _password, _confirm,
      _marca, _model, _year, _chapa, _color,
      _maxPassengers,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Llego la lista de tipos del backend: repinta el selector.
  void _alCambiarTipos() {
    if (mounted) setState(() {});
  }

  String? _validEmail(String? v) {
    if (v == null || v.trim().isEmpty) return 'Ingresa tu email';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) {
      return 'Email no válido';
    }
    return null;
  }

  /// Toma una foto del documento con la camara o la galeria.
  Future<void> _tomarFoto(DocumentoRequerido doc, ImageSource origen) async {
    try {
      final img = await _picker.pickImage(
        source: origen,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
      );
      if (img == null) return;
      setState(() {
        _fotos[doc.campo] = img.path;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'No se pudo abrir la cámara o la galería: $e');
    }
  }

  InputDecoration _dec(String label, IconData icon,
          {String? helper}) =>
      InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        helperText: helper,
        isDense: true,
      );

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Las contraseñas no coinciden');
      return;
    }

    // Todas las fotos son obligatorias para poder registrarse
    final faltantes = kDocumentosRequeridos
        .where((d) => !_fotos.containsKey(d.campo))
        .map((d) => d.etiqueta)
        .toList();
    if (faltantes.isNotEmpty) {
      setState(() {
        _error = 'Te faltan ${faltantes.length} foto(s) obligatorias:\n'
            '${faltantes.join("\n")}';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ApiService();
      await api.registerChoferConFotos(
        nombre: _nombre.text.trim(),
        apellidos: _apellidos.text.trim(),
        email: _email.text.trim(),
        telefono: _telefono.text.trim(),
        password: _password.text,
        marca: _marca.text.trim(),
        model: _model.text.trim(),
        year: int.tryParse(_year.text.trim()) ?? 2020,
        chapa: _chapa.text.trim(),
        color: _color.text.trim(),
        servicio: _tipo ?? 'basico',
        maxPassengers: int.tryParse(_maxPassengers.text.trim()) ?? 4,
        fotos: _fotos,
      );

      if (!mounted) return;
      await _mostrarPendiente();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// El registro se completo pero la cuenta queda pendiente de aprobacion:
  /// avisa y regresa al login en vez de entrar a la app.
  Future<void> _mostrarPendiente() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.hourglass_top, size: 44, color: Color(0xFFF39C12)),
        title: const Text('Solicitud recibida'),
        content: const Text(
          'Tus 10 documentos se enviaron correctamente.\n\n'
          'El administrador los va a revisar y, si todo está en orden, '
          'habilitará tu cuenta. Te avisaremos cuando puedas entrar.',
          textAlign: TextAlign.center,
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Crear cuenta de chofer')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.directions_car, size: 56, color: Color(0xFF007AFF)),
                const SizedBox(height: 8),
                const Text(
                  'Regístrate como conductor',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF333333)),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _nombre,
                  textCapitalization: TextCapitalization.words,
                  decoration: _dec('Nombre', Icons.person_outline),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Ingresa tu nombre' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _apellidos,
                  textCapitalization: TextCapitalization.words,
                  decoration: _dec('Apellidos', Icons.person_outline),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Ingresa tus apellidos'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: _dec('Email', Icons.email_outlined),
                  validator: _validEmail,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _telefono,
                  keyboardType: TextInputType.phone,
                  decoration: _dec('Teléfono', Icons.phone_outlined),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Ingresa tu teléfono'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  decoration: _dec('Contraseña', Icons.lock_outline),
                  validator: (v) => (v == null || v.length < 4)
                      ? 'Mínimo 4 caracteres'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: _dec('Confirmar contraseña', Icons.lock_outline),
                  validator: (v) => (v == null || v.isEmpty)
                      ? 'Confirma tu contraseña'
                      : null,
                ),
                const SizedBox(height: 20),
                const Text('Datos del vehículo',
                    style: TextStyle(
                        color: Color(0xFF007AFF),
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
                const Divider(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _marca,
                        textCapitalization: TextCapitalization.words,
                        decoration: _dec('Marca', Icons.badge_outlined),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty)
                                ? 'Requerido'
                                : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _model,
                        textCapitalization: TextCapitalization.words,
                        decoration: _dec('Modelo', Icons.directions_car),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty)
                                ? 'Requerido'
                                : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _year,
                        keyboardType: TextInputType.number,
                        decoration: _dec('Año', Icons.date_range),
                        validator: (v) =>
                            (int.tryParse(v ?? '') == null)
                                ? 'Año inválido'
                                : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _maxPassengers,
                        keyboardType: TextInputType.number,
                        decoration: _dec('Pasajeros', Icons.group_outlined),
                        validator: (v) =>
                            (int.tryParse(v ?? '') == null)
                                ? 'Inválido'
                                : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _chapa,
                  textCapitalization: TextCapitalization.characters,
                  decoration: _dec('Chapa / matrícula', Icons.confirmation_number),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Requerido'
                      : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _color,
                        textCapitalization: TextCapitalization.words,
                        decoration: _dec('Color', Icons.palette_outlined),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Requerido'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      // Selector de tipo, no campo de texto.
                      //
                      // Los tipos vienen de la tabla `tariffs` de PostgreSQL
                      // via `/vehiculos/tipos`, de modo que lo que el chofer
                      // elige es exactamente lo que el backend tiene tarifa
                      // para. Con un campo libre se podia escribir cualquier
                      // cosa y el backend no encontraba la tarifa al calcular.
                      child: DropdownButtonFormField<String>(
                        initialValue: _tipo,
                        isExpanded: true,
                        decoration: _dec('Tipo de servicio',
                            Icons.support_outlined),
                        hint: Text(_vehiculos.cargando
                            ? 'Cargando…'
                            : 'Elige un tipo'),
                        items: _vehiculos.tipos
                            .map((t) => DropdownMenuItem<String>(
                                  value: t.tipo,
                                  child: Text(t.etiqueta),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _tipo = v ?? _tipo),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? 'Requerido' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const SizedBox(height: 22),
                const Text('Documentos para la aprobación',
                    style: TextStyle(
                        color: Color(0xFF007AFF),
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                  'Sube las ${kDocumentosRequeridos.length} fotos solicitadas. '
                  'El administrador las revisará antes de habilitarte.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                ),
                const Divider(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: _fotos.length / kDocumentosRequeridos.length,
                        minHeight: 6,
                        backgroundColor: Colors.grey.shade300,
                        valueColor: AlwaysStoppedAnimation(
                          _fotos.length == kDocumentosRequeridos.length
                              ? const Color(0xFF2ECC71)
                              : const Color(0xFF007AFF),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${_fotos.length}/${kDocumentosRequeridos.length}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final doc in kDocumentosRequeridos)
                  TarjetaDocumento(
                    documento: doc,
                    ruta: _fotos[doc.campo],
                    onPick: (origen) => _tomarFoto(doc, origen),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, fontSize: 13)),
                ],
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: _loading ? null : _register,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.app_registration),
                  label: Text(_loading ? 'Enviando documentos...' : 'Registrarse'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _loading ? null : () => Navigator.of(context).pop(),
                  child: const Text('¿Ya tienes cuenta? Inicia sesión'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}