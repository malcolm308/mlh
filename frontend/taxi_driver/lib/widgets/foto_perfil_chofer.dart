import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api_config.dart';
import '../services/api_client.dart';
import '../services/api_service.dart';

/// Avatar del chofer con SU foto de rostro del registro.
///
/// La foto vive en `/documentos/chofer/{id}/foto/rostro` y solo puede verla
/// su dueno (con el token). Si no hay foto, falla la red o la subida sigue en
/// revision, el avatar muestra una letra inicial: no rompe nada.
///
/// El futuro se guarda una vez en `initState` para que un rebuild del panel
/// (ofertas, socket, ...) no dispare otra descarga; con `version` distinta se
/// vuelve a pedir (tras subir una foto).
class FotoPerfilChofer extends StatefulWidget {
  final ApiService api;
  final String driverId;
  final double radius;

  /// Texto del respaldo si no hay foto (una letra del nombre).
  final String iniciales;

  /// Incrementa esto (o crea otra instanca con datos nuevos) para refetch.
  final int version;

  const FotoPerfilChofer({
    super.key,
    required this.api,
    required this.driverId,
    this.radius = 28,
    this.iniciales = 'C',
    this.version = 0,
  });

  @override
  State<FotoPerfilChofer> createState() => _FotoPerfilChoferState();
}

class _FotoPerfilChoferState extends State<FotoPerfilChofer> {
  Future<List<int>?>? _foto;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void didUpdateWidget(FotoPerfilChofer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version != widget.version) _cargar();
  }

  void _cargar() {
    final url =
        '${ApiConfig.baseUrl}/documentos/chofer/${widget.driverId}/foto/rostro';
    _foto = ApiClient.descargarImagen(url);
  }

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: const Color(0xFF007AFF),
      child: ClipOval(
        child: FutureBuilder<List<int>?>(
          future: _foto,
          builder: (ctx, snap) {
            final datos = snap.data;
            if (!snap.hasData || datos == null || datos.isEmpty) {
              return _respaldo();
            }
            final bytes = Uint8List.fromList(datos);
            return Image.memory(
              bytes,
              width: widget.radius * 2,
              height: widget.radius * 2,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _respaldo(),
            );
          },
        ),
      ),
    );
  }

  Widget _respaldo() {
    final letra = widget.iniciales.trim();
    return Text(
      letra.isNotEmpty ? letra[0].toUpperCase() : 'C',
      style: TextStyle(
        color: Colors.white,
        fontSize: widget.radius * 0.9,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
