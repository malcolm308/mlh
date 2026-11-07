import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/models.dart';
import '../services/vehicle_types_service.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/foto_perfil_chofer.dart';
import '../widgets/ui/glass_sheet.dart';

/// Campos que se editan desde el perfil: SOLO documentos personales.
/// El vehiculo (interiores, exteriores, circulacion) se gestiona en Mi Garaje
/// para no tener el mismo cambio en dos sitios.
const Set<String> camposPersonales = {
  'rostro',
  'carnet_frente',
  'carnet_atras',
  'licencia_frente',
  'licencia_atras',
};

bool campoEsPersonal(String campo) => camposPersonales.contains(campo);

/// Etiquetas de los documentos del registro, por campo. Deben coincidir con
/// las que el backend devuelve en `/documentos/chofer/{id}/estado`.
const Map<String, String> etiquetasDocumentos = {
  'rostro': 'Foto frontal de la cara',
  'carnet_frente': 'Carnet de identidad (por delante)',
  'carnet_atras': 'Carnet de identidad (por detrás)',
  'licencia_frente': 'Licencia de conducir (por delante)',
  'licencia_atras': 'Licencia de conducir (por detrás)',
  'circulacion': 'Registro de circulación',
  'vehiculo_interior_frente': 'Vehículo por dentro (delante)',
  'vehiculo_interior_atras': 'Vehículo por dentro (atrás)',
  'vehiculo_exterior_frente': 'Vehículo por fuera (delante)',
  'vehiculo_exterior_atras': 'Vehículo por fuera (atrás)',
};

/// Perfil completo del conductor (opción del menú hamburguesa).
class DriverProfileScreen extends StatefulWidget {
  final ApiService api;
  final String driverId;
  final DriverProfile initialProfile;

  const DriverProfileScreen({
    super.key,
    required this.api,
    required this.driverId,
    required this.initialProfile,
  });

  @override
  State<DriverProfileScreen> createState() => _DriverProfileScreenState();
}

class _DriverProfileScreenState extends State<DriverProfileScreen> {
  late DriverProfile _profile;
  DriverEarnings? _earnings;
  DriverEarnings? _today;
  DriverEarnings? _week;
  int _dailyTrips = 0;
  bool _loading = false;
  String? _error;

  /// Tipos de vehiculo del backend, para las etiquetas.
  final VehicleTypesService _tiposVehiculo = VehicleTypesService();

  final ImagePicker _picker = ImagePicker();

  /// Estado de los documentos (segun el backend): campo -> fila del estado.
  Map<String, dynamic> _docs = const {};

  /// Campo cuya foto se esta subiendo (para deshabilitar el boton).
  String? _subiendoCampo;

  /// Cambia al resubir una foto: fuerza el avatar a re-descargar la de rostro.
  int _fotoVersion = 0;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    // Las etiquetas de tipo salen de la configuracion del backend; si no
    // responde, el servicio deja la lista de respaldo y el perfil se ve igual.
    _tiposVehiculo.cargar();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.api.getChofer(widget.driverId);
      // Tres consultas distintas, no una: antes el endpoint devolvia siempre
      // el dia de hoy y la etiqueta "Ganancia total" mostraba solo la jornada
      // actual. Ahora el historico, hoy y los ultimos 7 dias van separados.
      final total = await widget.api.getEarnings(widget.driverId);
      final hoy = await widget.api.getTodayEarnings(widget.driverId);
      final semana = await widget.api.getEarningsLastDays(widget.driverId, days: 7);
      final day = await widget.api.getDailyTripCount(widget.driverId);
      Map<String, dynamic> docs = const {};
      try {
        final estado = await widget.api.getDocumentos(widget.driverId);
        final porCampo = (estado['documentos'] ?? const {}) as Map;
        docs = {
          for (final e in porCampo.entries)
            if (e.value is Map) e.key.toString(): e.value,
        };
      } catch (_) {
        // Sin el estado de documentos el perfil se ve igual, solo sin la
        // seccion de fotos. No bloquea nada.
      }
      if (!mounted) return;
      setState(() {
        _profile = p;
        _earnings = total;
        _today = hoy;
        _week = semana;
        _dailyTrips = (day['daily_trips'] ?? 0) as int;
        if (_dailyTrips == 0) _dailyTrips = hoy.totalTrips;
        _docs = docs;
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

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Perfil del conductor'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
          Center(
            child: FotoPerfilChofer(
              api: widget.api,
              driverId: widget.driverId,
              radius: 42,
              iniciales: p.fullName,
              version: _fotoVersion,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            p.fullName,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF333333)),
          ),
          const SizedBox(height: 4),
          Text(p.email, textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF888888))),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.star, color: Color(0xFFF5A623), size: 18),
              const SizedBox(width: 4),
              Text(p.raiting.toStringAsFixed(1),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 20),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          _section('Datos personales', [
            _info(Icons.phone_outlined, 'Teléfono',
                p.telefono.isNotEmpty ? p.telefono : 'No registrado'),
            _info(Icons.badge_outlined, 'Nombre', p.nombre),
            if (p.apellidos.isNotEmpty)
              _info(Icons.badge_outlined, 'Apellidos', p.apellidos),
            _info(Icons.email_outlined, 'Email', p.email.isEmpty ? '—' : p.email),
            // La licencia ya no se pide en el registro: se valida con el
            // documento. Aqui solo se muestra si el chofer ya la tenia puesta.
            if ((p.licenseNumber ?? '').isNotEmpty)
              _info(Icons.badge_outlined, 'Licencia', p.licenseNumber!),
            _info(Icons.group_outlined, 'Pasajeros permitidos',
                '${p.maxPassengers}'),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _editarDatos,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Editar datos personales'),
                ),
              ),
            ),
          ]),
          if (_docs.isNotEmpty)
            _section('Mis fotos y documentos', [
              const Text(
                'Solo tus documentos personales: toca "Cambiar" para volver a '
                'subir la foto que necesites. El administrador la vuelve a '
                'revisar de inmediato.',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 8),
              // En el perfil solo se gestionan los documentos PERSONALES
              // (rostro, carnet y licencia). Las fotos del vehiculo y la
              // circulacion se gestionan en Mi Garaje, para no duplicar.
              for (final campo in _docs.keys.where(campoEsPersonal))
                _filaDocumento(
                  campo,
                  _docEtiqueta(_docs[campo], campo.toString()),
                  _docSubido(_docs[campo]),
                  _subiendoCampo != null,
                ),
              const SizedBox(height: 6),
              Text(
                'Las fotos del vehículo (interiores, exteriores y '
                'circulación) se cambian en Mi Garaje.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ]),
          _section('Estadísticas', [
            _info(Icons.account_balance_wallet_outlined, 'Fondo',
                '${p.fondo.toStringAsFixed(2)} CUP'),
            if (_today != null)
              _info(Icons.today_outlined, 'Ganancia de hoy',
                  '${_today!.totalEarnings.toStringAsFixed(2)} CUP'),
            _info(Icons.event_available_outlined, 'Viajes de hoy', '$_dailyTrips'),
            if (_earnings != null) ...[
              _info(Icons.local_taxi_outlined, 'Viajes totales',
                  '${_earnings!.totalTrips}'),
              _info(Icons.paid_outlined, 'Ganancia total (histórico)',
                  '${_earnings!.totalEarnings.toStringAsFixed(2)} CUP'),
              _info(Icons.route_outlined, 'Distancia total',
                  '${_earnings!.totalDistanceKm.toStringAsFixed(1)} km'),
            ],
          ]),
          if (_week != null && _week!.byDay.isNotEmpty)
            _section('Ganancias por día (últimos 7)', [
              for (final d in _week!.byDay)
                _info(
                  Icons.calendar_today_outlined,
                  '${_fechaCorta(d.date)} · ${d.trips} '
                      'viaje${d.trips == 1 ? '' : 's'}',
                  '${d.earnings.toStringAsFixed(2)} CUP',
                ),
            ]),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      ),
    );
  }

  /// `2026-11-05` -> `05/11`.
  ///
  /// La fecha ya viene resuelta por el servidor en hora de Cuba; aqui solo se
  /// recorta para mostrarla. No se usa `DateTime.now()` ni la zona del movil.
  String _fechaCorta(String iso) {
    final p = iso.split('-');
    if (p.length != 3) return iso;
    return '${p[2]}/${p[1]}';
  }

  String _docEtiqueta(dynamic estado, String campo) {
    if (estado is Map) {
      final eta = (estado['etiqueta'] ?? '').toString();
      if (eta.isNotEmpty) return eta;
    }
    return etiquetasDocumentos[campo] ?? 'Documento';
  }

  bool _docSubido(dynamic estado) => (estado['subido'] ?? false) == true;  Widget _filaDocumento(String campo, String etiqueta, bool subido,
      bool inFlight) {
    final color = switch ((subido, _subiendoCampo == campo)) {
      (_, true) => const Color(0xFFB26A00),
      (true, false) => const Color(0xFF2E7D32),
      _ => const Color(0xFFC62828),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(subido ? Icons.check_circle : Icons.error_outline,
              size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              etiqueta.isNotEmpty ? etiqueta : 'Documento',
              style: const TextStyle(color: Color(0xFF374151)),
            ),
          ),
          TextButton.icon(
            onPressed: _subiendoCampo != null ? null : () => _cambiarFoto(campo),
            icon: _subiendoCampo == campo
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.photo_camera_outlined, size: 16),
            label: Text((subido ? 'Cambiar' : 'Subir')),
          ),
        ],
      ),
    );
  }

  /// Cambio de UNA foto del registro: camara o galeria y subida directa.
  Future<void> _cambiarFoto(String campo) async {
    final origen = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Cámara'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galería'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (origen == null || !mounted) return;
    try {
      final img = await _picker.pickImage(
        source: origen,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
      );
      if (img == null || !mounted) return;
      setState(() => _subiendoCampo = campo);
      try {
        await widget.api.updateDocumentos(widget.driverId, {campo: img.path});
        if (!mounted) return;
        setState(() {
          _subiendoCampo = null;
          if (campo == 'rostro') _fotoVersion++;
        });
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${etiquetasDocumentos[campo] ?? 'Foto'} enviada: vuelve a revisión'),
            backgroundColor: Colors.green.shade700,
            behavior: SnackBarBehavior.floating));
        await _load();
      } catch (e) {
        if (!mounted) return;
        setState(() => _subiendoCampo = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), '')),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No se pudo abrir la cámara: $e'),
          behavior: SnackBarBehavior.floating));
    }
  }

  /// Dialogo de edicion de datos personales (nombre, apellidos, telefono).
  Future<void> _editarDatos() async {
    final p = _profile;
    final nombre = TextEditingController(text: p.nombre);
    final apellidos = TextEditingController(text: p.apellidos);
    final telefono = TextEditingController(text: p.telefono);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar datos personales'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nombre,
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              TextField(
                controller: apellidos,
                decoration: const InputDecoration(labelText: 'Apellidos'),
              ),
              TextField(
                controller: telefono,
                decoration:
                    const InputDecoration(labelText: 'Teléfono (8 dígitos)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 8),
              const Text(
                'El email no se puede cambiar aquí: es tu usuario de acceso.',
                style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.api.updatePerfil(
        widget.driverId,
        nombre: nombre.text.trim(),
        apellidos: apellidos.text.trim(),
        telefono: telefono.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Datos actualizados'),
          behavior: SnackBarBehavior.floating));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), '')),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating));
    }
  }

  Widget _section(String title, List<Widget> rows) {
    return SoftCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: AppColors.ambar,
                    fontWeight: FontWeight.w800,
                    fontSize: 13)),
            const Divider(height: 18),
            ...rows,
          ],
        ),
      ),
    );
  }

  Widget _info(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.secundario),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Color(0xFF888888))),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Color(0xFF333333), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}