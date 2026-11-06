import 'package:flutter/material.dart';

import '../services/api_service.dart';

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
          const Icon(Icons.error_outline, size: 48, color: Color(0xFFB3261E)),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton(onPressed: _cargar, child: const Text('Reintentar')),
          ),
        ],
      );
    }
    if (_bloqueos.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          SizedBox(height: 40),
          Icon(Icons.block_outlined, size: 56, color: Color(0xFF9AA3AF)),
          SizedBox(height: 12),
          Text(
            'No has bloqueado chóferes',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 6),
          Text(
            'Cuando bloquees a un chófer desde un viaje, lo verás aquí.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF6B6A70)),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _bloqueos.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        final b = _bloqueos[i];
        final nombre = (b['driver_name'] ?? '').toString().trim();
        final etiqueta = nombre.isNotEmpty ? nombre : 'Chófer bloqueado';
        final motivo = (b['motivo'] ?? '').toString().trim();
        final fecha = _fechaCorta((b['fecha'] ?? '').toString());
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 24,
                backgroundColor: Color(0xFFFFE9A8),
                child: Icon(Icons.person_off_outlined,
                    color: Color(0xFF1C1E21)),
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
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1C1E21)),
                    ),
                    if (motivo.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        motivo,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF6B6A70)),
                      ),
                    ],
                    if (fecha.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        fecha,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF9AA3AF)),
                      ),
                    ],
                  ],
                ),
              ),
              const Chip(
                label: Text('Bloqueado', style: TextStyle(fontSize: 11)),
                backgroundColor: Color(0xFFFFF4D6),
                visualDensity: VisualDensity.compact,
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
