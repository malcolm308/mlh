import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api_config.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/vehicle_types_service.dart';

/// Las fotos del registro del vehiculo, con su etiqueta. Solo las dos
/// exteriores y la circulacion "cuentan" para moto y triciclo (la decision
/// administrativa); los autos (basico/confort) exigen ademas las 2 interiores.
const List<(String, String)> fotosVehiculoRequeridas = [
  ('vehiculo_exterior_frente', 'Exterior (delante)'),
  ('vehiculo_exterior_atras', 'Exterior (atrás)'),
  ('vehiculo_interior_frente', 'Interior (delante)'),
  ('vehiculo_interior_atras', 'Interior (atrás)'),
  ('circulacion', 'Circulación'),
];

/// ¿El tipo de vehiculo usa fotos de interior? Mascara de los tipos sin
/// habitáculo de pasajeros.
bool tipoUsaInterior(String? tipo) {
  if (tipo == null) return true;
  final limpio = tipo
      .trim()
      .toLowerCase();
  const sinInterior = {'moto', 'triciclo'};
  return !sinInterior.contains(limpio);
}

/// Fotos que el registro exige para este tipo (moto/triciclo: 3).
List<(String, String)> fotosRequeridasDe(String? tipoVehiculo) =>
    tipoUsaInterior(tipoVehiculo)
        ? fotosVehiculoRequeridas
        : fotosVehiculoRequeridas
            .where((f) => !f.$1.startsWith('vehiculo_interior'))
            .toList();

/// Mi Garaje: lista de vehiculos del chofer, alta de uno nuevo y eleccion del
/// vehiculo activo.
///
/// Un vehiculo entra `pendiente` y solo el administrador lo aprueba. Solo un
/// `aprobado` puede marcarse como activo ("Usar este vehiculo"), y elegirlo
/// afecta inmediatamente a las ofertas que llegan. Al activar uno la pantalla
/// devuelve su [DriverVehicle] al pop, para que la pantalla principal refresque
/// el tipo sin reiniciar la app.
class GarageScreen extends StatefulWidget {
  final ApiService api;
  final String driverId;

  /// Tipo del vehiculo activo con el que la app sondea ahora mismo, para
  /// marcar de entrada el "Usar este vehiculo" correcto.
  final String? tipoActivo;

  const GarageScreen({
    super.key,
    required this.api,
    required this.driverId,
    required this.tipoActivo,
  });

  @override
  State<GarageScreen> createState() => _GarageScreenState();
}

class _GarageScreenState extends State<GarageScreen> {
  final VehicleTypesService _tipos = VehicleTypesService();

  List<DriverVehicle> _vehiculos = [];
  bool _loading = true;
  String? _error;

  /// Id del vehiculo cuya activacion esta en vuelo, para que el boton no se
  /// mande doble (mismo tratamiento que "Aceptar" en la pantalla principal).
  String? _seleccionandoId;

  /// Id del vehiculo cuya eliminacion esta en vuelo.
  String? _eliminandoId;

  @override
  void initState() {
    super.initState();
    _tipos.cargar();
    _cargar();
  }

  @override
  void dispose() {
    _tipos.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lista = await widget.api.getMyVehicles();
      if (!mounted) return;
      setState(() {
        _vehiculos = lista;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _aviso(String mensaje) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(mensaje),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ));
  }

  void _mostrarFormulario() {
    showDialog<AltaVehiculo>(
      context: context,
      builder: (ctx) => FormularioVehiculoDialog(
        tipos: _tipos,
        tipoInicial: (widget.tipoActivo ?? '').isNotEmpty
            ? widget.tipoActivo
            : 'basico',
      ),
    ).then((alta) async {
      if (alta == null) return;
      try {
        final v = await widget.api.addVehicle(
          tipoVehiculo: alta.tipo,
          marca: alta.marca,
          modelo: alta.modelo,
          matricula: alta.matricula,
        );
        // El vehiculo solo sirve al administrador si trae las fotos del
        // registro y de la circulacion: se suben justo después de crearlo.
        await widget.api.addVehicleFotos(v.id, alta.fotos);
        if (!mounted) return;
        _aviso('Vehículo enviado a revisión con sus fotos');
        await _cargar();
      } catch (e) {
        if (!mounted) return;
        _aviso('$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), ''));
      }
    });
  }

  /// Sube (o reemplaza) fotos de un vehiculo que ya existe en el garaje.
  Future<void> _anadirFotos(DriverVehicle v) async {
    _aviso(
        'Si el vehículo estaba aprobado volverá a revisión y quedará en '
        'reposo hasta la nueva aprobación');
    final alta = await showDialog<AltaVehiculo>(
      context: context,
      builder: (ctx) => FormularioVehiculoDialog(
        tipos: _tipos,
        tipoInicial: v.tipoVehiculo,
        soloFotos: true,
      ),
    );
    if (alta == null || alta.fotos.isEmpty) return;
    try {
      final resultado = await widget.api.addVehicleFotos(v.id, alta.fotos);
      final mensaje = (resultado['message'] ?? 'Fotos guardadas').toString();
      _aviso(mensaje);
      await _cargar();
    } catch (e) {
      _aviso('$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), ''));
    }
  }

  /// Edita los datos (marca/modelo/tipo/matricula) de un vehiculo.
  ///
  /// El backend vuelve el vehiculo a revision si estaba aprobado y actualiza
  /// el vehiculo embebido del chofer si era el activo. La lista se queda
  /// sincronizada con `setState`: no hace falta recargar la pantalla.
  Future<void> _editarVehiculo(DriverVehicle v) async {
    final datos = await showDialog<AltaVehiculo>(
      context: context,
      builder: (ctx) => FormularioVehiculoDialog(
        tipos: _tipos,
        tipoInicial: v.tipoVehiculo,
        soloDatos: true,
        marcaInicial: v.marca ?? '',
        modeloInicial: v.modelo ?? '',
        matriculaInicial: v.matricula ?? '',
      ),
    );
    if (datos == null) return;
    try {
      final resultado = await widget.api.updateVehicle(
        v.id,
        tipoVehiculo: datos.tipo,
        marca: datos.marca,
        modelo: datos.modelo,
        matricula: datos.matricula,
      );
      final mensaje = (resultado['message'] ?? 'Datos guardados').toString();
      _aviso(mensaje);
      await _cargar();
    } catch (e) {
      _aviso('$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), ''));
    }
  }

  /// Marca el vehiculo como el activo. Pide confirmacion: cambiar de coche
  /// cambia las ofertas que van a llegar.
  Future<void> _usarVehiculo(DriverVehicle v) async {
    if (_seleccionandoId != null) return;
    if (!v.esAprobado) {
      _aviso('Solo puedes usar un vehículo aprobado por el administrador');
      return;
    }
    if (v.esActivo) return;
    setState(() => _seleccionandoId = v.id);
    try {
      await widget.api.selectVehicle(v.id);
      if (!mounted) return;
      setState(() => _seleccionandoId = null);
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      Navigator.pop(context, v);
      // La pantalla principal ya recibe el resultado y refresca el tipo; aqui
      // el mensaje no se necesita.
    } catch (e) {
      if (!mounted) return;
      setState(() => _seleccionandoId = null);
      _aviso('$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), ''));
    }
  }

  /// Pide confirmacion y elimina el vehiculo del garaje.
  ///
  /// El backend valida contra el token que el vehiculo sea del chofer; si era
  /// el activo, se queda sin vehiculo en uso. La lista se actualiza en
  /// caliente con `setState`, sin recargar toda la pantalla.
  Future<void> _eliminarVehiculo(DriverVehicle v) async {
    if (_eliminandoId != null) return;
    final nombre = '${v.marca ?? '—'} ${v.modelo ?? ''}'.trim();
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar vehículo'),
        content: Text(
          '¿Seguro que quieres eliminar "$nombre" '
          '(${v.matricula ?? 'sin matrícula'})?\n\n'
          'Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmado != true || !mounted) return;

    setState(() => _eliminandoId = v.id);
    try {
      await widget.api.deleteVehicle(v.id);
      if (!mounted) return;
      setState(() {
        _vehiculos = _vehiculos.where((x) => x.id != v.id).toList();
        _eliminandoId = null;
      });
      _aviso('Vehículo eliminado');
    } catch (e) {
      if (!mounted) return;
      setState(() => _eliminandoId = null);
      _aviso('$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mi Garaje')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _mostrarFormulario,
        icon: const Icon(Icons.add),
        label: const Text('Añadir vehículo'),
      ),
      body: _cuerpo(),
    );
  }

  Widget _cuerpo() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 60, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(_error!),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _cargar, child: const Text('Reintentar')),
          ],
        ),
      );
    }
    if (_vehiculos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_car, size: 60, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('No tienes vehículos en tu garaje'),
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Añade uno con el botón de abajo. El administrador lo '
                'revisará y, cuando lo apruebe, podrás ponerlo en línea.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF6B7280)),
              ),
            ),
          ],
        ),
      );
    }

    final hayAprobado =
        _vehiculos.any((v) => v.esAprobado);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: _vehiculos.length,
      itemBuilder: (context, i) => _tarjeta(_vehiculos[i], hayAprobado),
    );
  }

  /// Estado de las 5 fotos del registro: chip verde (aprobada), ámbar
  /// (pendiente), rojo (rechazada) y gris (sin subir). Con faltantes o
  /// rechazadas, botón "Añadir fotos" que reabre el selector.
  Widget _seccionFotos(DriverVehicle v) {
    final hayRechazadas = v.fotos.values
        .any((f) => f.estado == 'rechazado');
    final hayFaltantes = v.fotosFaltantes.isNotEmpty;
    final accionNecesaria = hayFaltantes || hayRechazadas;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Text('Fotos del registro (las revisa el administrador):',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            // Chips de las fotos que este tipo exige, y ademas las ya subidas
            // que quedan fuera de esa lista (p.ej. interiores subidas a un
            // auto cuyo tipo cambio despues).
            for (final chip in _chipsDe(v)) _chipFoto(chip.$1, chip.$2, v),
          ],
        ),
        if (accionNecesaria) ...[
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => _anadirFotos(v),
            icon: const Icon(Icons.add_a_photo, size: 18),
            label: Text(hayFaltantes ? 'Añadir fotos faltantes' : 'Repetir foto rechazada'),
          ),
        ],
      ],
    );
  }

  /// (campo, etiqueta) de las fotos que se pintan en la tarjeta: las exigidas
  /// por el tipo del vehiculo, y las que ya estan subidas aunque el tipo no
  /// las pida.
  List<(String, String)> _chipsDe(DriverVehicle v) {
    final exigidas = fotosRequeridasDe(v.tipoVehiculo);
    final chips = List<(String, String)>.of(exigidas);
    for (final campo in v.fotos.keys) {
      if (exigidas.any((e) => e.$1 == campo)) continue;
      chips.add((
        campo,
        fotosVehiculoRequeridas
                .firstWhere((f) => f.$1 == campo, orElse: () => (campo, campo))
                .$2
      ));
    }
    return chips;
  }

  Widget _chipFoto(String campo, String etiqueta, DriverVehicle v) {
    final f = v.fotos[campo];
    final Color color;
    final IconData icono;
    final String texto;
    if (f == null) {
      color = const Color(0xFF6B7280);
      icono = Icons.image_not_supported_outlined;
      texto = '$etiqueta: falta';
    } else {
      switch (f.estado) {
        case 'aprobado':
          color = const Color(0xFF2E7D32);
          icono = Icons.check_circle_outline;
          texto = '$etiqueta: aprobada';
        case 'rechazado':
          color = const Color(0xFFC62828);
          icono = Icons.cancel_outlined;
          texto = '$etiqueta: rechazada';
        default:
          color = const Color(0xFFB26A00);
          icono = Icons.hourglass_top;
          texto = '$etiqueta: en revisión';
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 14, color: color),
          const SizedBox(width: 4),
          Text(texto, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }

  /// URL absoluta de la foto exterior del vehiculo (el backend la publica
  /// como ruta relativa `/garaje/imagen/{archivo}`).
  String? _urlFoto(DriverVehicle v) {
    final raw = v.fotoExteriorUrl?.trim();
    if (raw != null && raw.isNotEmpty) {
      return raw.startsWith('http') ? raw : '${ApiConfig.baseUrl}$raw';
    }
    // Respaldo mientras el backend no manda `foto_exterior_url`: el nombre del
    // archivo ya viene en `fotos`, asi que la miniatura no depende de un
    // despliegue nuevo. Se prefiere la foto delantera y luego la trasera.
    for (final campo in const [
      'vehiculo_exterior_frente',
      'vehiculo_exterior_atras',
    ]) {
      final archivo = v.fotos[campo]?.archivo.trim();
      if (archivo != null && archivo.isNotEmpty) {
        return '${ApiConfig.baseUrl}/garaje/imagen/$archivo';
      }
    }
    return null;
  }

  /// Miniatura de la foto exterior, con borde redondeado y respaldo si aun no
  /// hay foto o la descarga falla (el vehiculo puede estar pendiente).
  Widget _miniatura(DriverVehicle v) {
    final url = _urlFoto(v);
    final token = widget.api.token;
    const respaldo = Icon(Icons.directions_car_outlined,
        size: 30, color: Color(0xFF9CA3AF));
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 76,
        height: 76,
        color: const Color(0xFFF3F4F6),
        child: url == null
            ? respaldo
            : Image.network(
                url,
                fit: BoxFit.cover,
                headers: (token == null || token.isEmpty)
                    ? null
                    : {'Authorization': 'Bearer $token'},
                errorBuilder: (_, _, _) => respaldo,
                loadingBuilder: (ctx, child, progreso) => progreso == null
                    ? child
                    : const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
              ),
      ),
    );
  }

  Widget _tarjeta(DriverVehicle v, bool hayAprobado) {
    final colorDeEstado = switch (v.estado) {
      'aprobado' => const Color(0xFF2E7D32),
      'rechazado' => const Color(0xFFC62828),
      _ => const Color(0xFFB26A00),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _miniatura(v),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${v.marca ?? '—'} ${v.modelo ?? ''}'.trim(),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: colorDeEstado.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(v.estadoEtiqueta,
                                style: TextStyle(
                                    color: colorDeEstado,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Tipo: ${_tipos.etiquetaDe(v.tipoVehiculo)} · '
                        'Matrícula: ${v.matricula ?? '—'}',
                        style: const TextStyle(color: Color(0xFF6B7280)),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Editar vehículo',
                  onPressed: () => _editarVehiculo(v),
                  icon: const Icon(Icons.edit_outlined,
                      color: Color(0xFF111827)),
                ),
                IconButton(
                  tooltip: 'Eliminar vehículo',
                  onPressed: _eliminandoId == null
                      ? () => _eliminarVehiculo(v)
                      : null,
                  icon: _eliminandoId == v.id
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline,
                          color: Color(0xFFC62828)),
                ),
              ],
            ),
            _seccionFotos(v),
            if (v.motivo != null && v.motivo!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Motivo: ${v.motivo}',
                  style: const TextStyle(
                      color: Color(0xFFB26A00), fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  v.esActivo ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 18,
                  color: v.esActivo ? const Color(0xFF111827) : Colors.grey,
                ),
                const SizedBox(width: 4),
                Text(v.esActivo ? 'Vehículo en uso' : 'No está en uso',
                    style: const TextStyle(fontSize: 13)),
                const Spacer(),
                FilledButton.icon(
                  // Unindexado en vuelo: mismo bloqueo que "Aceptar" en la
                  // pantalla principal, para no mandar dos selects.
                  onPressed: (_seleccionandoId != null || !v.esAprobado)
                      ? null
                      : () => _usarVehiculo(v),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(40),
                    backgroundColor: v.esActivo
                        ? const Color(0xFFE5E7EB)
                        : const Color(0xFF111827),
                    foregroundColor: v.esActivo ? const Color(0xFF6B7280) : Colors.white,
                  ),
                  icon: _seleccionandoId == v.id
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check, size: 18),
                  label: Text(v.esActivo ? 'En uso' : 'Usar este vehículo'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Resultado del formulario del garaje.
class AltaVehiculo {
  final String tipo;
  final String marca;
  final String modelo;
  final String matricula;

  /// campo -> ruta local de la foto.
  final Map<String, String> fotos;

  const AltaVehiculo({
    required this.tipo,
    required this.marca,
    required this.modelo,
    required this.matricula,
    required this.fotos,
  });
}

/// Formulario de alta (y solo-fotos) de un vehiculo del garaje.
///
/// Las 5 fotos del registro son OBLIGATORIAS para dar de alta un vehiculo:
/// sin ellas el administrador no puede revisar nada. En modo `soloFotos`
/// (vehiculo ya creado) se sube la que haga falta y con eso se reabre la
/// revision del administrador. En modo `soloDatos` sirve para EDITAR los
/// datos (marca/modelo/tipo/matricula) de un vehiculo existente.
class FormularioVehiculoDialog extends StatefulWidget {
  final VehicleTypesService tipos;
  final String? tipoInicial;

  /// `true` al abrir desde un vehiculo existente: solo pide fotos.
  final bool soloFotos;

  /// `true` al abrir para EDITAR datos: solo marca/modelo/tipo/matricula.
  final bool soloDatos;

  /// Valores de partida en modo `soloDatos`.
  final String? marcaInicial;
  final String? modeloInicial;
  final String? matriculaInicial;

  const FormularioVehiculoDialog({
    super.key,
    required this.tipos,
    this.tipoInicial,
    this.soloFotos = false,
    this.soloDatos = false,
    this.marcaInicial,
    this.modeloInicial,
    this.matriculaInicial,
  });

  @override
  State<FormularioVehiculoDialog> createState() =>
      _FormularioVehiculoDialogState();
}

class _FormularioVehiculoDialogState extends State<FormularioVehiculoDialog> {
  final ImagePicker _picker = ImagePicker();
  final Map<String, String> _fotos = {};
  late String _tipo;
  late final TextEditingController _marca;
  late final TextEditingController _modelo;
  late final TextEditingController _matricula;

  @override
  void initState() {
    super.initState();
    _tipo = widget.tipoInicial ?? 'basico';
    _marca = TextEditingController(text: widget.marcaInicial ?? '');
    _modelo = TextEditingController(text: widget.modeloInicial ?? '');
    _matricula = TextEditingController(text: widget.matriculaInicial ?? '');
  }

  @override
  void dispose() {
    _marca.dispose();
    _modelo.dispose();
    _matricula.dispose();
    super.dispose();
  }

  Future<void> _tomarFoto(String campo, ImageSource origen) async {
    try {
      final img = await _picker.pickImage(
        source: origen,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
      );
      if (img == null) return;
      setState(() => _fotos[campo] = img.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('No se pudo abrir la camara: $e'),
            behavior: SnackBarBehavior.floating));
      }
    }
  }

  void _pedirFoto(String campo) {
    showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Camara'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galeria'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    ).then((origen) {
      if (origen != null) _tomarFoto(campo, origen);
    });
  }

  Widget _tileFoto(String campo, String etiqueta) {
    final ruta = _fotos[campo];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 42,
            child: ruta != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(File(ruta),
                        fit: BoxFit.cover, width: 56, height: 42),
                  )
                : Container(
                    decoration: BoxDecoration(
                        color: const Color(0xFFEDEFF3),
                        borderRadius: BorderRadius.circular(6)),
                    child: const Icon(Icons.image_outlined,
                        size: 20, color: Color(0xFF9AA3AF)),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(etiqueta)),
          TextButton(
            onPressed: () => _pedirFoto(campo),
            child: Text(ruta == null ? 'Tomar foto' : 'Repetir'),
          ),
        ],
      ),
    );
  }

  void _validarYDevolver() {
    final soloFotos = widget.soloFotos;
    final soloDatos = widget.soloDatos;
    if (!soloFotos || soloDatos) {
      final marca = _marca.text.trim();
      final modelo = _modelo.text.trim();
      final matricula = _matricula.text.trim().toUpperCase();
      if (marca.isEmpty || modelo.isEmpty || matricula.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Escribe la marca, el modelo y la matricula.'),
            behavior: SnackBarBehavior.floating));
        return;
      }
      if (soloDatos) {
        // Solo se devuelven los datos: el backend reabre la revision si los
        // datos cambiaron y el admin vuelve a ver el vehiculo.
        Navigator.of(context).pop(AltaVehiculo(
          tipo: widget.tipos.esValido(_tipo)
              ? _tipo
              : (widget.tipos.tipos.isNotEmpty
                  ? widget.tipos.tipos.first.tipo
                  : 'basico'),
          marca: marca,
          modelo: modelo,
          matricula: matricula,
          fotos: const {},
        ));
        return;
      }
      final faltan = fotosRequeridasDe(_tipo)
          .where((f) => !_fotos.containsKey(f.$1))
          .toList();
      if (faltan.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Te faltan ${faltan.length} foto(s):\n${faltan.map((f) => f.$2).join(", ")}'),
            behavior: SnackBarBehavior.floating));
        return;
      }
      Navigator.of(context).pop(AltaVehiculo(
        tipo: widget.tipos.esValido(_tipo)
            ? _tipo
            : (widget.tipos.tipos.isNotEmpty
                ? widget.tipos.tipos.first.tipo
                : 'basico'),
        marca: marca,
        modelo: modelo,
        matricula: matricula,
        fotos: Map.of(_fotos),
      ));
      return;
    }
    if (_fotos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Toma al menos una foto.'),
          behavior: SnackBarBehavior.floating));
      return;
    }
    Navigator.of(context).pop(AltaVehiculo(
      tipo: widget.tipoInicial ?? 'basico',
      marca: '',
      modelo: '',
      matricula: '',
      fotos: Map.of(_fotos),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final nuevos = !widget.soloFotos && !widget.soloDatos;
    final sinFotos = widget.soloDatos;
    return AlertDialog(
      title: Text(
        nuevos
            ? 'Anadir vehiculo'
            : (sinFotos ? 'Editar vehiculo' : 'Fotos del vehiculo'),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!sinFotos) ...[
                DropdownButtonFormField<String>(
                  initialValue: widget.tipos.esValido(_tipo) ? _tipo : null,
                  decoration:
                      const InputDecoration(labelText: 'Tipo de vehiculo'),
                  items: [
                    for (final t in widget.tipos.tipos)
                      DropdownMenuItem(value: t.tipo, child: Text(t.etiqueta)),
                  ],
                  onChanged: (v) => setState(() => _tipo = v ?? _tipo),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _marca,
                  decoration:
                      const InputDecoration(labelText: 'Marca (ej: Lada)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _modelo,
                  decoration:
                      const InputDecoration(labelText: 'Modelo (ej: 2107)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _matricula,
                  decoration: const InputDecoration(
                      labelText: 'Matricula (ej: B 123456)'),
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 14),
              ],
              const Text('Fotos obligatorias:',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              for (final (campo, etiqueta) in fotosRequeridasDe(_tipo))
                _tileFoto(campo, etiqueta),
              if (!tipoUsaInterior(_tipo))
                const Text(
                  'Moto y triciclo no necesitan fotos del interior: exterior y '
                  'circulación bastan.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                ),
              const SizedBox(height: 8),
              Text(
                nuevos
                    ? 'El vehiculo entra pendiente. El administrador revisara '
                        'los datos y las fotos.'
                    : (sinFotos
                        ? 'Si el vehiculo estaba aprobado, vuelve a revision '
                            'cuando cambien los datos.'
                        : 'Si el vehiculo estaba aprobado, se desactiva y vuelve a '
                            'revision con las fotos nuevas.'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _validarYDevolver,
          child: Text(nuevos
              ? 'Guardar'
              : (sinFotos ? 'Guardar cambios' : 'Subir fotos')),
        ),
      ],
    );
  }
}
