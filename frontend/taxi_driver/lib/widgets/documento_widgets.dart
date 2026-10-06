import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Los 10 documentos que debe subir el chofer para que el administrador lo apruebe.
class DocumentoRequerido {
  const DocumentoRequerido(this.campo, this.etiqueta, this.icono, {this.ayuda});

  final String campo;
  final String etiqueta;
  final IconData icono;
  final String? ayuda;
}

const kDocumentosRequeridos = <DocumentoRequerido>[
  DocumentoRequerido('rostro', 'Foto frontal de la cara', Icons.face_retouching_natural,
      ayuda: 'Sin lentes ni sombrero, bien iluminada'),
  DocumentoRequerido('carnet_frente', 'Carnet de identidad (por delante)', Icons.badge_outlined,
      ayuda: 'Se leen los datos completos'),
  DocumentoRequerido('carnet_atras', 'Carnet de identidad (por detras)', Icons.badge_outlined,
      ayuda: 'Foto del reverso'),
  DocumentoRequerido('licencia_frente', 'Licencia de conducir (por delante)', Icons.drive_eta_outlined,
      ayuda: 'La licencia completa y legible'),
  DocumentoRequerido('licencia_atras', 'Licencia de conducir (por detras)', Icons.drive_eta_outlined,
      ayuda: 'Foto del reverso'),
  DocumentoRequerido('circulacion', 'Circulación del vehículo', Icons.description_outlined,
      ayuda: 'Registro de circulación o matrícula'),
  DocumentoRequerido('vehiculo_interior_frente', 'Vehículo por dentro (alante)', Icons.airline_seat_recline_normal,
      ayuda: 'Interior: dash, volante y butaca delantera'),
  DocumentoRequerido('vehiculo_interior_atras', 'Vehículo por dentro (atrás)', Icons.airline_seat_recline_normal,
      ayuda: 'Interior: butaca trasera'),
  DocumentoRequerido('vehiculo_exterior_frente', 'Vehículo por fuera (delante)', Icons.directions_car,
      ayuda: 'Fachada frontal completa'),
  DocumentoRequerido('vehiculo_exterior_atras', 'Vehículo por fuera (atrás)', Icons.directions_car,
      ayuda: 'Fachada trasera completa'),
];

/// Tarjeta para elegir o volver a tomar una foto de un documento.
class TarjetaDocumento extends StatelessWidget {
  const TarjetaDocumento({
    super.key,
    required this.documento,
    required this.ruta,
    required this.onPick,
  });

  final DocumentoRequerido documento;
  final String? ruta;
  final Future<void> Function(ImageSource source) onPick;

  @override
  Widget build(BuildContext context) {
    final tiene = ruta != null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: tiene ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: tiene ? const Color(0xFF2ECC71) : const Color(0xFFDDDDDD),
          width: tiene ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Miniatura(ruta: ruta, icono: documento.icono),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(documento.etiqueta,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  if (documento.ayuda != null) ...[
                    const SizedBox(height: 2),
                    Text(documento.ayuda!,
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  ],
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        tiene ? Icons.check_circle : Icons.error_outline,
                        size: 14,
                        color: tiene ? const Color(0xFF2ECC71) : Colors.grey.shade500,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        tiene ? 'Foto lista' : 'Falta esta foto',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: tiene ? const Color(0xFF2ECC71) : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BotonFoto(
                  icono: Icons.photo_camera_outlined,
                  etiqueta: 'Cámara',
                  onTap: () => onPick(ImageSource.camera),
                ),
                const SizedBox(height: 4),
                _BotonFoto(
                  icono: Icons.photo_library_outlined,
                  etiqueta: 'Galería',
                  onTap: () => onPick(ImageSource.gallery),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Miniatura extends StatelessWidget {
  const _Miniatura({required this.ruta, required this.icono});

  final String? ruta;
  final IconData icono;

  @override
  Widget build(BuildContext context) {
    if (ruta == null) {
      return Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icono, color: Colors.grey.shade500, size: 26),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(ruta!),
        width: 54,
        height: 54,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => Container(
          width: 54,
          height: 54,
          color: Colors.grey.shade200,
          child: const Icon(Icons.broken_image, size: 22),
        ),
      ),
    );
  }
}

class _BotonFoto extends StatelessWidget {
  const _BotonFoto({required this.icono, required this.etiqueta, required this.onTap});

  final IconData icono;
  final String etiqueta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 68,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF007AFF).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Icon(icono, size: 18, color: const Color(0xFF007AFF)),
            const SizedBox(height: 2),
            Text(etiqueta,
                style: const TextStyle(fontSize: 10, color: Color(0xFF007AFF))),
          ],
        ),
      ),
    );
  }
}
