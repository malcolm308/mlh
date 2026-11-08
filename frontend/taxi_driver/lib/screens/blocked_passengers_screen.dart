import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';
import '../widgets/ui/warning_box.dart';

/// Pasajeros bloqueados por el chofer.
///
/// Es la misma coleccion que usa el pasajero para bloquear choferes, vistas
/// desde el otro lado: aqui `passenger_name` llega ya resuelto y el id interno
/// de Mongo nunca se muestra.
class BlockedPassengersScreen extends StatefulWidget {
  final ApiService api;

  const BlockedPassengersScreen({super.key, required this.api});

  @override
  State<BlockedPassengersScreen> createState() =>
      _BlockedPassengersScreenState();
}

class _BlockedPassengersScreenState extends State<BlockedPassengersScreen> {
  List<Map<String, dynamic>> _bloqueos = [];
  bool _loading = true;
  String? _error;
  bool _desbloqueando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lista = await widget.api.getBloqueos();
      // Solo los bloqueos de PASAJEROS: un chofer no puede tener choferes
      // bloqueados, y si el mismo usuario existiera en los dos roles con
      // bloqueos mezclaos, aqui se filtra.
      final propios = lista
          .whereType<Map<String, dynamic>>()
          .where((b) =>
              (b['passenger_id'] ?? '').toString().isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _bloqueos = propios;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceAll(RegExp(r'\s*\(HTTP \d+\)$'), '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pasajeros bloqueados')),
      body: RefreshIndicator(
        onRefresh: _cargar,
        child: _cuerpo(),
      ),
    );
  }

  Widget _cuerpo() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 30),
          const Icon(Icons.error_outline, size: 52, color: AppColors.error),
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.secundario)),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton(
              onPressed: _cargar,
              child: const Text('Reintentar'),
            ),
          ),
        ],
      );
    }

    if (_bloqueos.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: const [
          SizedBox(height: 36),
          Icon(Icons.block_outlined, size: 56, color: AppColors.secundario),
          SizedBox(height: 12),
          Text(
            'No has bloqueado pasajeros',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.tinta,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Si un pasajero cancela tu viaje ya aceptado, la app te offrecera '
            'bloquearlo para no volver a emparejarte con el.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.secundario, height: 1.4),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _bloqueos.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return const WarningBox(
            title: 'Bloqueos activos',
            message: 'Estos pasajeros no volverán a emparejarse con tu '
                'vehiculo. Puedes desbloquearlos cuando quieras con el '
                'candado abierto.',
            icon: Icons.shield_outlined,
          );
        }

        final b = _bloqueos[i - 1];
        final nombre = (b['passenger_name'] ?? '').toString().trim();
        final etiqueta = nombre.isNotEmpty ? nombre : 'Pasajero bloqueado';
        final motivo = (b['motivo'] ?? '').toString().trim();
        final fecha = _fechaCorta((b['fecha'] ?? '').toString());

        return SoftCard(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.acentoSuave,
                child:
                    Icon(Icons.person_off_outlined, color: AppColors.tinta),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      etiqueta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.tinta,
                      ),
                    ),
                    if (motivo.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        motivo,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.secundario),
                      ),
                    ],
                    if (fecha.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        fecha,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.secundario),
                      ),
                    ],
                  ],
                ),
              ),
              // Desbloqueo: el chofer se arrepiente sin soporte de por medio.
              IconButton(
                tooltip: 'Desbloquear',
                onPressed: _desbloqueando
                    ? null
                    : () => unawaited(_confirmarDesbloqueo(b)),
                icon: const Icon(
                  Icons.lock_open_rounded,
                  size: 20,
                  color: AppColors.secundario,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmarDesbloqueo(Map<String, dynamic> b) async {
    final nombre = (b['passenger_name'] ?? '').toString().trim();
    final etiqueta = nombre.isNotEmpty ? nombre : 'a este pasajero';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Desbloquear?'),
        content: Text(
          'Volverías a recibir las solicitudes de $etiqueta como '
          'cualquier otro pasajero.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desbloquear'),
          ),
        ],
      ),
    );
    if (ok == true) await _desbloquear(b);
  }

  Future<void> _desbloquear(Map<String, dynamic> b) async {
    final passengerId = (b['passenger_id'] ?? '').toString();
    if (passengerId.isEmpty) return;
    setState(() => _desbloqueando = true);
    try {
      await widget.api.desbloquearPasajero(passengerId);
      if (!mounted) return;
      setState(() {
        _bloqueos.remove(b);
        _desbloqueando = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Pasajero desbloqueado'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _desbloqueando = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('$e'),
      ));
    }
  }

  /// ISO de Mongo -> `dd/mm/aaaa` corto.
  String _fechaCorta(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}
