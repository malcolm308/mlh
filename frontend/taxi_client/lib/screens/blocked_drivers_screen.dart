import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/glass_sheet.dart';
import '../widgets/ui/warning_box.dart';

/// Choferes bloqueados por el pasajero.
///
/// El backend devuelve los bloqueos de ESTE usuario con el nombre del chofer
/// (`driver_name`) ya resuelto; nunca se muestra el id de Mongo.
class BlockedDriversScreen extends StatefulWidget {
  final ApiService api;

  const BlockedDriversScreen({super.key, required this.api});

  @override
  State<BlockedDriversScreen> createState() => _BlockedDriversScreenState();
}

class _BlockedDriversScreenState extends State<BlockedDriversScreen> {
  List<Map<String, dynamic>> _bloqueos = [];
  bool _loading = true;
  String? _error;

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
      if (!mounted) return;
      setState(() {
        _bloqueos = lista;
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
      appBar: AppBar(title: const Text('Chóferes bloqueados')),
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
            'No has bloqueado chóferes',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.tinta,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Cuando bloquees a un chófer desde un viaje, lo verás aquí.',
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
            message:
                'Estos chóferes no volverán a emparejarse contigo. '
                'Si crees que fue un error, escribe a soporte.',
            icon: Icons.shield_outlined,
          );
        }

        final b = _bloqueos[i - 1];
        final nombre = (b['driver_name'] ?? '').toString().trim();
        final etiqueta = nombre.isNotEmpty ? nombre : 'Chófer bloqueado';
        final motivo = (b['motivo'] ?? '').toString().trim();
        final fecha = _fechaCorta((b['fecha'] ?? '').toString());

        return SoftCard(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.acentoSuave,
                child: Icon(Icons.person_off_outlined, color: AppColors.tinta),
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
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: const ShapeDecoration(
                  color: AppColors.acentoSuave,
                  shape: StadiumBorder(),
                ),
                child: const Text(
                  'Bloqueado',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ambar,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// ISO de Mongo -> `dd/mm/aaaa` corto; vacio si la fecha no es legible.
  String _fechaCorta(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}
