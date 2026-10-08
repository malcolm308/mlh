import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Panel inferior del viaje en curso, recogible con el dedo.
///
/// Antes el panel de "VIAJE EN CURSO" era un `Card` fijo pegado abajo: ocupaba
/// la parte baja entera de la pantalla y tapaba la flecha (chevron) del mapa
/// justo cuando el chofer mas la necesita, para saber hacia donde va. Este
/// widget lo convierte en una hoja que se puede arrastrar:
///
///  * Colapsado (por defecto, [CollapsibleTripPanel.encogido]): solo se ve el
///    resumen con el destino y el precio. El mapa queda libre y la flecha
///    visible.
///  * Expandido ([CollapsibleTripPanel.desplegado]): aparece la ficha entera,
///    con recogida, destino, botones de WhatsApp y la accion del viaje.
///  * El minimo ([CollapsibleTripPanel.minimo]) deja solo el asa, por si el
///    chofer quiere casi todo el mapa para conducir.
///
/// El estado se guarda en `SharedPreferences` asociado al [tripId]: al aceptar
/// un viaje nuevo el panel arranca COLAPSADO, y si la app se reabre a mitad de
/// un viaje se recupera como estaba.
///
/// La hoja no es modal: queda anclada al borde inferior y el mapa de detras
/// sigue siendo el fondo interactivo.
class CollapsibleTripPanel extends StatefulWidget {
  /// Identificador del viaje al que pertenece el contenido.
  ///
  /// Se usa para resetear el panel a colapsado cuando cambia el viaje y para
  /// no restaurar el estado de un viaje distinto al reabrir la app.
  final String? tripId;

  /// Contenido que se ve CON el panel recogido (resumen: destino + precio).
  final Widget collapsed;

  /// Contenido que se ve CON el panel desplegado (ficha completa + botones).
  final Widget expanded;

  /// Fraccion minima de la pantalla que ocupa el panel (solo el asa).
  static const double minimo = 0.05;

  /// Fraccion maxima: nunca se come mas del 45 % de la pantalla.
  static const double maximo = 0.45;

  /// Fraccion inicial: colapsado, solo el resumen.
  static const double encogido = 0.15;

  /// Fraccion a la que se abre al tocarlo.
  static const double desplegado = 0.42;

  const CollapsibleTripPanel({
    super.key,
    required this.tripId,
    required this.collapsed,
    required this.expanded,
  });

  @override
  State<CollapsibleTripPanel> createState() => _CollapsibleTripPanelState();
}

class _CollapsibleTripPanelState extends State<CollapsibleTripPanel> {
  static const String _prefTrip = 'panel_viaje_trip';
  static const String _prefExpandido = 'panel_viaje_expandido';

  /// Por encima de esta fraccion se considera el panel desplegado.
  static const double _umbral = 0.32;

  final DraggableScrollableController _ctl = DraggableScrollableController();
  late bool _expandido;

  @override
  void initState() {
    super.initState();
    _expandido = false;
    _ctl.addListener(_alArrastrar);
    _restaurarEstado();
  }

  @override
  void didUpdateWidget(covariant CollapsibleTripPanel old) {
    super.didUpdateWidget(old);
    // Viaje nuevo: el panel se abre COLAPSADO de forma predeterminada, como
    // se pide (arrastrar para desplegarlo es una accion del chofer, no el
    // estado inicial de cada carrera).
    if (old.tripId != widget.tripId) {
      _expandido = false;
      _guardarEstado(false);
      if (_ctl.isAttached) _ctl.jumpTo(CollapsibleTripPanel.encogido);
    }
  }

  /// Recupera de `SharedPreferences` como estaba el panel de este mismo viaje.
  Future<void> _restaurarEstado() async {
    final prefs = await SharedPreferences.getInstance();
    final tripGuardado = prefs.getString(_prefTrip);
    final estabaExpandido = prefs.getBool(_prefExpandido) ?? false;
    if (!mounted ||
        tripGuardado != widget.tripId ||
        !estabaExpandido ||
        _expandido) {
      return;
    }
    // La app se reabrio a mitad de viaje: se restaura la posicion anterior si
    // es el mismo viaje. Si es otro viaje, `tripId` no coincide y se queda
    // colapsado, que es el comportamiento por defecto.
    setState(() => _expandido = true);
    if (_ctl.isAttached) {
      _ctl.animateTo(
        CollapsibleTripPanel.desplegado,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _guardarEstado(bool expandido) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTrip, widget.tripId ?? '');
    await prefs.setBool(_prefExpandido, expandido);
  }

  /// Sigue el arrastre para decidir que contenido se muestra.
  void _alArrastrar() {
    if (!_ctl.isAttached) return;
    final ex = _ctl.size > _umbral;
    if (ex == _expandido) return;
    setState(() {
      _expandido = ex;
      _guardarEstado(ex);
    });
  }

  /// Tocar el asa alterna entre colapsado y desplegado.
  void _toggle() {
    final vaExpandida = !_expandido;
    setState(() => _expandido = vaExpandida);
    _guardarEstado(vaExpandida);
    if (_ctl.isAttached) {
      _ctl.animateTo(
        vaExpandida
            ? CollapsibleTripPanel.desplegado
            : CollapsibleTripPanel.encogido,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _ctl.removeListener(_alArrastrar);
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: _ctl,
      minChildSize: CollapsibleTripPanel.minimo,
      maxChildSize: CollapsibleTripPanel.maximo,
      initialChildSize: CollapsibleTripPanel.encogido,
      // No se cierra al arrastrar hasta el minimo: siempre queda el asa para
      // volver a abrir la ficha.
      shouldCloseOnMinExtent: false,
      builder: (context, scrollController) {
        return Material(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          elevation: 12,
          shadowColor: Colors.black26,
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            controller: scrollController,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                // Asa de arrastre: gris, 4 px de alto por 40 de ancho.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggle,
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD0D0D0),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: _expandido ? widget.expanded : widget.collapsed,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}