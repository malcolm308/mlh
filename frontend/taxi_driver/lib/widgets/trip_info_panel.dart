import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Panel inferior del viaje en curso, recogible con el dedo.
///
/// Antes el panel de "VIAJE EN CURSO" era un `Card` fijo pegado abajo: ocupaba
/// la parte baja entera de la pantalla y tapaba la flecha (chevron) del mapa
/// justo cuando el chofer más la necesita, para saber hacia dónde va. Este
/// widget lo convierte en una hoja con TRES estados, con `snap` para que
/// siempre aterrice en uno de ellos y nunca se quede a medias:
///
///  * Mínimo ([CollapsibleTripPanel.minimo]): solo el asa, por si el chofer
///    quiere casi todo el mapa para conducir. Sin contenido.
///  * Colapsado (por defecto, [CollapsibleTripPanel.encogido]): solo se ve el
///    resumen con el destino y el precio. El mapa queda libre y la flecha
///    visible.
///  * Expandido ([CollapsibleTripPanel.desplegado]): aparece la ficha entera,
///    con recogida, destino, botones de WhatsApp y la acción del viaje.
///
/// Se llega de un estado a otro arrastrando o tocando el asa (de expandido
/// se recoge a colapsado; de los otros dos se despliega directo).
///
/// El estado se guarda en `SharedPreferences` asociado al [tripId]: al aceptar
/// un viaje nuevo el panel arranca COLAPSADO, y si la app se reabre a mitad de
/// un viaje se recupera como estaba.
///
/// La hoja no es modal: queda anclada al borde inferior y el mapa detrás
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

  /// Fracción mínima de la pantalla que ocupa el panel (solo el asa).
  static const double minimo = 0.05;

  /// Fracción máxima: nunca se come más del 45 % de la pantalla.
  static const double maximo = 0.45;

  /// Fracción inicial: colapsado, solo el resumen.
  static const double encogido = 0.15;

  /// Fracción a la que se abre al tocarlo o arrastrarlo.
  static const double desplegado = 0.45;

  const CollapsibleTripPanel({
    super.key,
    required this.tripId,
    required this.collapsed,
    required this.expanded,
  });

  @override
  State<CollapsibleTripPanel> createState() => _CollapsibleTripPanelState();
}

/// Los tres estados del panel, en función de la fracción de pantalla que
/// ocupa la hoja.
enum _EstadoPanel { minimo, colapsado, expandido }

class _CollapsibleTripPanelState extends State<CollapsibleTripPanel> {
  static const String _prefTrip = 'panel_viaje_trip';
  static const String _prefEstado = 'panel_viaje_estado';

  final DraggableScrollableController _ctl = DraggableScrollableController();
  _EstadoPanel _estado = _EstadoPanel.colapsado;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_alCambiarTamano);
    _restaurarEstado();
  }

  @override
  void didUpdateWidget(covariant CollapsibleTripPanel old) {
    super.didUpdateWidget(old);
    // Viaje nuevo: el panel se abre COLAPSADO de forma predeterminada, como
    // se pide (arrastrar para desplegarlo es una acción del chofer, no el
    // estado inicial de cada carrera).
    if (old.tripId != widget.tripId) {
      _estado = _EstadoPanel.colapsado;
      _guardarEstado();
      if (_ctl.isAttached) _ctl.jumpTo(CollapsibleTripPanel.encogido);
    }
  }

  /// Traduce la fracción de pantalla que ocupa la hoja a su estado.
  ///
  /// Los umbrales dejan margen de arrastre entre estados: un arrastre a
  /// medias no cambia el contenido de golpe, y con el `snap` la hoja acaba
  /// aterrizar siempre en una fracción que cae sin ambigüedad en un estado.
  static _EstadoPanel _estadoDe(double fraccion) {
    if (fraccion < 0.10) return _EstadoPanel.minimo;
    if (fraccion < 0.32) return _EstadoPanel.colapsado;
    return _EstadoPanel.expandido;
  }

  /// Fracción de la hoja asociada a cada estado (tamaño con el que se abre).
  static double _fraccionDe(_EstadoPanel estado) {
    switch (estado) {
      case _EstadoPanel.minimo:
        return CollapsibleTripPanel.minimo;
      case _EstadoPanel.colapsado:
        return CollapsibleTripPanel.encogido;
      case _EstadoPanel.expandido:
        return CollapsibleTripPanel.desplegado;
    }
  }

  static String _codigoDe(_EstadoPanel estado) {
    switch (estado) {
      case _EstadoPanel.minimo:
        return 'min';
      case _EstadoPanel.colapsado:
        return 'col';
      case _EstadoPanel.expandido:
        return 'exp';
    }
  }

  static _EstadoPanel _estadoDeCodigo(String? codigo) {
    switch (codigo) {
      case 'min':
        return _EstadoPanel.minimo;
      case 'exp':
        return _EstadoPanel.expandido;
      default:
        return _EstadoPanel.colapsado;
    }
  }

  /// Recupera de `SharedPreferences` cómo estaba el panel de este mismo
  /// viaje. El estado por defecto (colapsado) no necesita restaurarse.
  Future<void> _restaurarEstado() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (prefs.getString(_prefTrip) != widget.tripId) return;
    final estado = _estadoDeCodigo(prefs.getString(_prefEstado));
    if (estado == _EstadoPanel.colapsado) return;
    setState(() => _estado = estado);
    _irA(estado, animado: false);
  }

  /// Guarda el estado solo cuando cambia, asociado a su viaje.
  Future<void> _guardarEstado() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTrip, widget.tripId ?? '');
    await prefs.setString(_prefEstado, _codigoDe(_estado));
  }

  /// Sigue la hoja para decidir qué contenido se muestra y persistirlo.
  void _alCambiarTamano() {
    if (!_ctl.isAttached) return;
    final nuevo = _estadoDe(_ctl.size);
    if (nuevo == _estado) return;
    setState(() => _estado = nuevo);
    _guardarEstado();
  }

  /// Tocar el asa: si está desplegado se recoge a colapsado; si no, se
  /// despliega. Del mínimo salta directo a desplegado, porque hacer el
  /// recorrido completo a mano en marcha sería molesto.
  void _toggle() {
    final destino = _estado == _EstadoPanel.expandido
        ? _EstadoPanel.colapsado
        : _EstadoPanel.expandido;
    _irA(destino);
  }

  /// Lleva la hoja a la fracción del estado.
  ///
  /// Si el controlador aún no está enganchado (restauración durante el
  /// primer frame) se espera al siguiente para moverlo.
  void _irA(_EstadoPanel estado, {bool animado = true}) {
    void aplicar() {
      if (!mounted || !_ctl.isAttached) return;
      final destino = _fraccionDe(estado);
      if ((destino - _ctl.size).abs() < 0.005) return;
      if (animado) {
        _ctl.animateTo(
          destino,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      } else {
        _ctl.jumpTo(destino);
      }
    }

    if (_ctl.isAttached) {
      aplicar();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => aplicar());
    }
  }

  @override
  void dispose() {
    _ctl.removeListener(_alCambiarTamano);
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // La hoja es un `DraggableScrollableSheet`, que necesita una altura
    // ACOTADA para calcular sus fracciones. Un padre que monte este widget en
    // un `Positioned` de `Stack` con solo `bottom` entrega `maxHeight:
    // infinito` y la hoja degenera (no se pinta y el mapa acumula errores de
    // transformación). Se acota la altura aquí para que el panel funcione en
    // cualquier contexto.
    final hoja = DraggableScrollableSheet(
      controller: _ctl,
      minChildSize: CollapsibleTripPanel.minimo,
      maxChildSize: CollapsibleTripPanel.maximo,
      initialChildSize: CollapsibleTripPanel.encogido,
      // Con snap la hoja siempre aterriza en uno de los tres tamaños: sin
      // él, el arrastre queda suelto a medias y no hay contenido definido
      // para esa fracción.
      snap: true,
      snapSizes: const [
        CollapsibleTripPanel.minimo,
        CollapsibleTripPanel.encogido,
        CollapsibleTripPanel.desplegado,
      ],
      // No se cierra al arrastrar hasta el mínimo: siempre queda el asa para
      // volver a abrir la ficha.
      shouldCloseOnMinExtent: false,
      builder: (context, scrollController) {
        // Estado mínimo: SOLO el asa. El resumen no entra en una tira de
        // pantalla tan baja y solo estorbaría.
        final soloAsa = _estado == _EstadoPanel.minimo;
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
                if (!soloAsa) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: _estado == _EstadoPanel.expandido
                        ? widget.expanded
                        : widget.collapsed,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedHeight) return hoja;
        // El padre no acotó la altura: se acota con la pantalla real para que
        // la hoja siga pudiendo calcular su fracción.
        return SizedBox(
          width: constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width,
          height: MediaQuery.sizeOf(context).height,
          child: hoja,
        );
      },
    );
  }
}
