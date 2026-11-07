import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui/pill_button.dart';

class FavoriteLocationsScreen extends StatefulWidget {
  final ApiService api;
  final String clientId;

  const FavoriteLocationsScreen({
    super.key,
    required this.api,
    required this.clientId,
  });

  @override
  State<FavoriteLocationsScreen> createState() =>
      _FavoriteLocationsScreenState();
}

class _FavoriteLocationsScreenState extends State<FavoriteLocationsScreen> {
  List<Map<String, dynamic>> _favorites = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final favorites = await widget.api.getFavorites();
      if (!mounted) return;
      setState(() {
        _favorites = favorites;
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

  Future<void> _deleteFavorite(String id) async {
    try {
      await widget.api.deleteFavorite(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Favorito eliminado')),
      );
      _loadFavorites();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  void _showAddDialog() {
    final aliasController = TextEditingController();
    final addressController = TextEditingController();
    final latController = TextEditingController();
    final lngController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Añadir favorito'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aliasController,
              decoration: const InputDecoration(labelText: 'Alias (ej: Casa)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: addressController,
              decoration: const InputDecoration(labelText: 'Dirección'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: latController,
                    decoration: const InputDecoration(
                      labelText: 'Latitud (Opcional)',
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(signed: true, decimal: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: lngController,
                    decoration: const InputDecoration(
                      labelText: 'Longitud (Opcional)',
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(signed: true, decimal: true),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () async {
              final alias = aliasController.text.trim();
              final direccion = addressController.text.trim();
              final latTxt = latController.text.replaceAll(',', '.').trim();
              final lngTxt = lngController.text.replaceAll(',', '.').trim();
              final lat = latTxt.isEmpty ? null : double.tryParse(latTxt);
              final lng = lngTxt.isEmpty ? null : double.tryParse(lngTxt);

              String? problema;
              if (alias.isEmpty) {
                problema = 'Escribe un alias (ej: Casa)';
              } else if (direccion.isEmpty) {
                problema = 'Escribe la dirección';
              } else if (latTxt.isNotEmpty != lngTxt.isNotEmpty) {
                problema = 'Indica latitud y longitud, o deja ambas vacías';
              } else if (latTxt.isNotEmpty && (lat == null || lng == null)) {
                problema = 'Latitud y longitud deben ser números';
              } else if (lat != null &&
                  lng != null &&
                  (lat < -90 || lat > 90 || lng < -180 || lng > 180)) {
                problema = 'Las coordenadas están fuera de rango';
              }
              if (problema != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(problema)),
                );
                return;
              }

              try {
                await widget.api.createFavorite(
                  alias: alias,
                  direccion: direccion,
                  lat: lat,
                  lng: lng,
                  userId: widget.clientId,
                );
                // `mounted` del State no garantiza que el dialog (y su ctx)
                // siga vivo: se valida el propio ctx antes de hacer el pop.
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _loadFavorites();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ubicación favorita guardada')),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('No se pudo guardar: $e')),
                );
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ubicaciones Favoritas'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showAddDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const SizedBox(height: 30),
                    const Icon(Icons.error_outline,
                        size: 52, color: AppColors.error),
                    const SizedBox(height: 12),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.secundario)),
                    const SizedBox(height: 16),
                    Center(
                      child: OutlinedButton(
                        onPressed: _loadFavorites,
                        child: const Text('Reintentar'),
                      ),
                    ),
                  ],
                )
              : _favorites.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                      children: [
                        const SizedBox(height: 36),
                        const Icon(Icons.favorite_border_rounded,
                            size: 56, color: AppColors.secundario),
                        const SizedBox(height: 12),
                        const Text(
                          'No tienes favoritos',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.tinta,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Guarda tus direcciones de siempre (casa, trabajo...) '
                          'para no escribirlas cada vez.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AppColors.secundario, height: 1.4),
                        ),
                        const SizedBox(height: 18),
                        Center(
                          child: PillButton(
                            label: 'Añadir favorito',
                            icon: Icons.add_rounded,
                            expand: false,
                            onPressed: _showAddDialog,
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _favorites.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final fav = _favorites[index];
                        return Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          clipBehavior: Clip.antiAlias,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: AppColors.borde),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: const BoxDecoration(
                                    color: AppColors.acentoSuave,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.favorite_rounded,
                                      color: AppColors.ambar, size: 18),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        fav['alias'] ?? 'Sin nombre',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.tinta,
                                        ),
                                      ),
                                      if (fav['direccion'] != null)
                                        Text(
                                          fav['direccion'],
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: AppColors.secundario,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Eliminar',
                                  icon: const Icon(Icons.delete_outline_rounded,
                                      color: AppColors.error, size: 20),
                                  onPressed: () => _deleteFavorite(fav['id']),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
