import 'package:flutter/material.dart';

import '../services/asistente_ruta.dart';

/// Formatea "en 220 m" / "en 1.4 km".
String distanciaLegible(double metros) {
  if (metros <= 0) return 'ahora';
  if (metros < 950) {
    final redondeo = (metros / 10).round() * 10;
    if (redondeo < 10) return 'ahora';
    return 'en $redondeo m';
  }
  return 'en ${(metros / 1000).toStringAsFixed(metros < 9500 ? 1 : 0)} km';
}

/// Icono por tipo de maniobra de OSRM.
IconData iconoPorManiobra(String tipo, {String? instr}) {
  final texto = instr ?? '';
  if (tipo == 'arrive' || texto.toLowerCase().contains('llegó')) {
    return Icons.flag;
  }
  switch (tipo) {
    case 'turn':
    case 'end of road':
      if (texto.toLowerCase().contains('izquierda')) {
        return Icons.turn_slight_left;
      }
      return Icons.turn_slight_right;
    case 'roundabout':
    case 'rotary':
      return Icons.roundabout_right;
    case 'off ramp':
      return Icons.subdirectory_arrow_right;
    case 'on ramp':
      return Icons.subdirectory_arrow_left;
    case 'merge':
      return Icons.call_merge;
    case 'uturn':
      return Icons.u_turn_right;
    case 'fork':
      return Icons.alt_route;
    case 'depart':
      return Icons.trip_origin;
    default:
      return Icons.straight;
  }
}

/// El banner del asistente de ruta, arriba y centrado en la pantalla del
/// mapa del chofer.
///
/// El `SafeArea` es CRUCIAL: la app dibuja edge-to-edge y sin el inset top el
/// banner queda bajo la hora y la bateria (mismo bug que los botones
/// flotantes del cliente).
///
/// La altura del icono (28) busca que se lea desde el asiento del conductor sin
/// necesitar gafas; el contenedor negro garantiza contraste con todo el estilo
/// del mapa.
class AsistenteRutaWidget extends StatelessWidget {
  final EstadoAsistente estado;

  const AsistenteRutaWidget({super.key, required this.estado});

  @override
  Widget build(BuildContext context) {
    if (!estado.activa) return const SizedBox.shrink();
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Material(
            color: const Color(0xE6111118),
            borderRadius: BorderRadius.circular(16),
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    iconoPorManiobra(estado.tipoManiobra,
                        instr: estado.instruccion),
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: '${distanciaLegible(estado.distanciaMetros)} · ',
                        style: const TextStyle(
                          color: Color(0xFFFFC107),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                        children: [
                          TextSpan(
                            text: estado.instruccion,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
