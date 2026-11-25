import 'package:flutter/material.dart';

import '../../models/estado_red.dart';
import '../../theme/app_theme.dart';

/// Banner flotante del estado de la red.
///
/// Tres estados, tal como los vive el chofer:
///  * [EstadoRed.sinSenal]: fondo oscuro, parpadeo intenso y botón REINTENTAR;
///  * [EstadoRed.debil]: fondo amarillo, parpadeo suave y sin botón;
///  * [EstadoRed.buena]: el widget desaparece por completo.
///
/// Los dos estados con problema parpadean para que el chofer los note de reojo
/// sin dejar de mirar el mapa. El de señal débil lo hace más despacio y con
/// menos contraste: avisa sin resultar molesto. La animación se detiene en
/// [didUpdateWidget] cuando el estado pasa a bueno, así no consume frames de
/// más.
class WidgetRed extends StatefulWidget {
  const WidgetRed({
    super.key,
    required this.estado,
    this.onReintentar,
  });

  final EstadoRed estado;

  /// Solo se usa en «sin señal». Si es `null`, el botón no se pinta.
  final VoidCallback? onReintentar;

  @override
  State<WidgetRed> createState() => _WidgetRedState();
}

class _WidgetRedState extends State<WidgetRed>
    with SingleTickerProviderStateMixin {
  late final AnimationController _parpadeo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  );

  /// Opacidad mínima del parpadeo. Sin señal baja más (aviso urgente); señal
  /// débil se queda en un pulso suave para no cansar la vista.
  double get _opacidadMinima =>
      widget.estado == EstadoRed.sinSenal ? 0.42 : 0.62;

  @override
  void initState() {
    super.initState();
    _sincronizarAnimacion();
  }

  @override
  void didUpdateWidget(covariant WidgetRed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.estado != widget.estado) _sincronizarAnimacion();
  }

  void _sincronizarAnimacion() {
    if (widget.estado == EstadoRed.buena) {
      _parpadeo.stop();
      _parpadeo.value = 0;
      return;
    }
    _parpadeo
      ..stop()
      ..duration = Duration(
        milliseconds: widget.estado == EstadoRed.sinSenal ? 850 : 1500,
      )
      ..value = 0
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _parpadeo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.estado == EstadoRed.buena) return const SizedBox.shrink();
    final sinSenal = widget.estado == EstadoRed.sinSenal;

    final banner = _Banner(
      sinSenal: sinSenal,
      onReintentar: sinSenal ? widget.onReintentar : null,
    );

    return AnimatedBuilder(
      animation: _parpadeo,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_parpadeo.value);
        final min = _opacidadMinima;
        return Opacity(opacity: min + (1.0 - min) * t, child: child);
      },
      child: banner,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.sinSenal, this.onReintentar});

  final bool sinSenal;
  final VoidCallback? onReintentar;

  @override
  Widget build(BuildContext context) {
    final fondo = sinSenal ? const Color(0xF224272B) : AppColors.acento;
    final titulo = sinSenal ? Colors.white : AppColors.tinta;
    final subtitulo =
        sinSenal ? const Color(0xFFBFC3CA) : const Color(0xB31C1E21);

    return Container(
      // Tarjeta compacta: vive en el borde derecho, a media altura, sin
      // invadir el centro del mapa ni el marcador del vehiculo.
      width: 164,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: sinSenal ? 0.42 : 0.22),
            blurRadius: 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _IconoEstado(sinSenal: sinSenal),
              if (!sinSenal) const _BarrasDebiles(),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (sinSenal) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE8333B),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  sinSenal ? 'SIN SEÑAL MÓVIL' : 'SEÑAL DÉBIL',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                    color: titulo,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            sinSenal
                ? 'No recibirás solicitudes de viaje hasta recuperar la señal.'
                : 'Conexión inestable: puedes tardar en recibir viajes.',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              height: 1.25,
              fontWeight: FontWeight.w500,
              color: subtitulo,
            ),
          ),
          if (sinSenal) ...[
            const SizedBox(height: 9),
            _BotonReintentar(onTap: onReintentar),
          ],
        ],
      ),
    );
  }
}

/// Círculo superior: amarillo con el icono oscuro sin señal, o blanco con las
/// barras bajas cuando la señal es débil.
class _IconoEstado extends StatelessWidget {
  const _IconoEstado({required this.sinSenal});

  final bool sinSenal;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: sinSenal ? AppColors.acento : Colors.white,
        shape: BoxShape.circle,
        boxShadow: sinSenal
            ? [
                BoxShadow(
                  color: AppColors.acento.withValues(alpha: 0.45),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Icon(
        sinSenal ? Icons.signal_cellular_off : Icons.signal_cellular_alt_1_bar,
        size: 19,
        color: AppColors.tinta,
      ),
    );
  }
}

class _BotonReintentar extends StatelessWidget {
  const _BotonReintentar({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: AppColors.acento,
        borderRadius: BorderRadius.circular(16),
        elevation: 4,
        shadowColor: AppColors.acento.withValues(alpha: 0.5),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 9),
            child: Text(
              'REINTENTAR',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                color: AppColors.tinta,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cuatro barras de cobertura: la primera oscura y el resto translúcidas, como
/// en el diseño de referencia. Es decorativo; no anima.
class _BarrasDebiles extends StatelessWidget {
  const _BarrasDebiles();

  @override
  Widget build(BuildContext context) {
    const alturas = [6.0, 9.0, 12.0, 15.0];
    return SizedBox(
      width: 26,
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < alturas.length; i++)
            Container(
              width: 4,
              height: alturas[i],
              decoration: BoxDecoration(
                color: AppColors.tinta.withValues(alpha: i == 0 ? 1.0 : 0.35),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      ),
    );
  }
}
