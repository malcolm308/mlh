import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Acción principal por deslizamiento, estilo "Pro".
///
/// Sustituye al botón normal de "He llegado / Iniciar viaje / Completar viaje".
/// En una app que se usa con una mano y en marcha, un toque accidental en la
/// acción principal cuesta caro (marcar llegada antes de tiempo o cerrar el
/// viaje sin haberlo hecho). Aquí hay que arrastrar la perilla hasta el final;
/// si se suelta antes, vuelve sola y no dispara nada.
class SlideToConfirm extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final Color foregroundColor;
  final VoidCallback? onConfirmed;
  final bool enabled;

  /// Muestra un spinner y bloquea el gesto mientras se llama al backend.
  final bool loading;

  const SlideToConfirm({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.icon = Icons.arrow_forward_rounded,
    this.color = AppColors.acento,
    this.foregroundColor = AppColors.tinta,
    this.enabled = true,
    this.loading = false,
  });

  @override
  State<SlideToConfirm> createState() => _SlideToConfirmState();
}

class _SlideToConfirmState extends State<SlideToConfirm> {
  /// 0 = perilla a la izquierda, 1 = perilla al final (confirmado).
  double _drag = 0;

  /// La perilla se está moviendo sola (snap): se anima la posición.
  bool _animando = false;

  /// Se alcanzó el final y el botón espera a disparar la acción.
  bool _confirmado = false;

  static const double _alto = 56;
  static const double _margen = 4;

  bool get _activo => widget.enabled && !widget.loading;

  void _alArrastrar(DragUpdateDetails d, double recorrido) {
    if (!_activo || recorrido <= 0) return;
    setState(() {
      _animando = false;
      _drag = (_drag + d.delta.dx / recorrido).clamp(0.0, 1.0);
    });
  }

  void _alSoltar(double recorrido) {
    if (!_activo) return;
    if (_drag >= 0.88) {
      // Confirmado: la perilla termina de llegar y se dispara una sola vez.
      setState(() {
        _animando = true;
        _drag = 1;
        _confirmado = true;
      });
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        if (!mounted || !_confirmado) return;
        widget.onConfirmed?.call();
        // La acción puede haber desmontado la pantalla; se comprueba antes.
        if (mounted) {
          setState(() {
            _drag = 0;
            _confirmado = false;
            _animando = false;
          });
        }
      });
      return;
    }
    // No llegó: vuelve al inicio sin disparar.
    setState(() {
      _animando = true;
      _drag = 0;
    });
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _animando = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final deshabilitado = !_activo;
    final relleno = deshabilitado ? AppColors.deshabilitado : widget.color;
    final texto = deshabilitado ? AppColors.deshabilitadoTexto : widget.foregroundColor;

    return Semantics(
      button: true,
      enabled: _activo,
      label: '${widget.label}. Desliza para confirmar.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ancho = constraints.maxWidth;
          const perilla = _alto - _margen * 2;
          final recorrido = ancho - _margen * 2 - perilla;
          final izquierda = _margen + (recorrido <= 0 ? 0 : recorrido * _drag);

          return SizedBox(
            height: _alto,
            child: Stack(
              children: [
                // Riel.
                Container(
                  decoration: BoxDecoration(
                    color: deshabilitado ? AppColors.campo : relleno,
                    borderRadius: BorderRadius.circular(_alto / 2),
                    border: Border.all(
                      color: deshabilitado
                          ? AppColors.borde
                          : relleno.withValues(alpha: 0.9),
                    ),
                  ),
                ),
                // Texto centrado, dejando hueco a la perilla.
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 58),
                    child: Center(
                      child: Opacity(
                        // Se desvanece conforme avanza la perilla.
                        opacity: (1 - _drag).clamp(0.15, 1.0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(widget.icon, size: 19, color: texto),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: texto,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Perilla.
                AnimatedPositioned(
                  duration: _animando
                      ? const Duration(milliseconds: 200)
                      : Duration.zero,
                  curve: Curves.easeOut,
                  left: izquierda,
                  top: _margen,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) => _alArrastrar(d, recorrido),
                    onHorizontalDragEnd: (_) => _alSoltar(recorrido),
                    onHorizontalDragCancel: () => _alSoltar(recorrido),
                    child: Container(
                      width: perilla,
                      height: perilla,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Center(
                        child: widget.loading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: AppColors.ambar,
                                ),
                              )
                            : Icon(
                                _drag >= 0.88
                                    ? Icons.check_rounded
                                    : Icons.chevron_right_rounded,
                                size: 28,
                                color: deshabilitado
                                    ? AppColors.deshabilitadoTexto
                                    : AppColors.tinta,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
