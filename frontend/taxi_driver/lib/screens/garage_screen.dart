import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../services/vehicle_types_service.dart';

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
  bool _agregando = false;
  String? _error;

  /// Id del vehiculo cuya activacion esta en vuelo, para que el boton no se
  /// mande doble (mismo tratamiento que "Aceptar" en la pantalla principal).
  String? _seleccionandoId;

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
    var tipo = (widget.tipoActivo ?? '').isNotEmpty
        ? widget.tipoActivo!
        : 'basico';
    final marca = TextEditingController();
    final modelo = TextEditingController();
    final matricula = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Añadir vehículo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _tipos.esValido(tipo) ? tipo : null,
              decoration: const InputDecoration(
                  labelText: 'Tipo de vehículo'),
              items: [
                for (final t in _tipos.tipos)
                  DropdownMenuItem(
                      value: t.tipo,
                      child: Text(t.etiqueta)),
              ],
              onChanged: (v) => tipo = v ?? tipo,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: marca,
              decoration: const InputDecoration(labelText: 'Marca (ej: Lada)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: modelo,
              decoration:
                  const InputDecoration(labelText: 'Modelo (ej: 2107)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: matricula,
              decoration: const InputDecoration(
                  labelText: 'Matrícula (ej: B 123456)'),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 8),
            const Text(
              'El vehículo entra pendiente hasta que el administrador lo '
              'revise.',
              style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: _agregando
                ? null
                : () async {
                    final tipoFinal = _tipos.esValido(tipo)
                        ? tipo
                        : (_tipos.tipos.isNotEmpty
                            ? _tipos.tipos.first.tipo
                            : 'basico');
                    final marcaTxt = marca.text.trim();
                    final modeloTxt = modelo.text.trim();
                    final matriculaTxt = matricula.text.trim().toUpperCase();
                    String? problema;
                    if (marcaTxt.isEmpty) {
                      problema = 'Escribe la marca';
                    } else if (modeloTxt.isEmpty) {
                      problema = 'Escribe el modelo';
                    } else if (matriculaTxt.isEmpty) {
                      problema = 'Escribe la matrícula';
                    }
                    if (problema != null) {
                      _aviso(problema);
                      return;
                    }
                    setState(() => _agregando = true);
                    try {
                      await widget.api.addVehicle(
                        tipoVehiculo: tipoFinal,
                        marca: marcaTxt,
                        modelo: modeloTxt,
                        matricula: matriculaTxt,
                      );
                      if (!mounted) return;
                      Navigator.pop(ctx);
                      _aviso('Vehículo enviado a revisión');
                      await _cargar();
                    } catch (e) {
                      if (!mounted) return;
                      setState(() => _agregando = false);
                      _aviso('$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), ''));
                    }
                  },
            child: Text(_agregando ? 'Enviando...' : 'Guardar'),
          ),
        ],
      ),
    );
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
              children: [
                Expanded(
                  child: Text(
                    '${v.marca ?? '—'} ${v.modelo ?? ''}'.trim(),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
