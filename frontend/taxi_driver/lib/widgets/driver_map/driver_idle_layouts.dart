import 'package:flutter/material.dart';

import 'driver_map_theme.dart';

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.saldo,
    required this.onMenu,
    required this.onNotifications,
    this.onSaldoTap,
  });

  final double? saldo;
  final VoidCallback onMenu;
  final VoidCallback onNotifications;
  final VoidCallback? onSaldoTap;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle(
      style: DriverMapTypography.style(),
      child: Row(
        children: <Widget>[
          LogoChip(onTap: onMenu),
          const SizedBox(width: 8),
          Expanded(
            child: _BalancePill(saldo: saldo, onTap: onSaldoTap),
          ),
          const SizedBox(width: 8),
          _SquareIconButton(
            label: 'Notificaciones',
            onTap: onNotifications,
            child: const Icon(
              Icons.notifications_none_rounded,
              size: 21,
              color: DriverMapColors.negro,
            ),
          ),
        ],
      ),
    );
  }
}

class _BalancePill extends StatelessWidget {
  const _BalancePill({required this.saldo, required this.onTap});

  final double? saldo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final importe = saldo == null ? '— CUP' : '${formatImporteEntero(saldo!)} CUP';
    final contenido = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'SALDO',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DriverMapTypography.style(
            size: 8.5,
            weight: FontWeight.w600,
            color: DriverMapColors.secundario,
            height: 1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          importe,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DriverMapTypography.style(
            size: 13,
            weight: FontWeight.w800,
            height: 1,
          ),
        ),
      ],
    );
    final decoration = BoxDecoration(
      color: DriverMapColors.blanco,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: DriverMapColors.bordeAmarillo, width: 1),
    );
    if (onTap == null) {
      return Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: decoration,
        child: contenido,
      );
    }
    return Semantics(
      button: true,
      label: 'Refrescar saldo',
      child: Material(
        color: DriverMapColors.blanco,
        borderRadius: BorderRadius.circular(13),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              border: Border.all(color: DriverMapColors.bordeAmarillo, width: 1),
              borderRadius: BorderRadius.circular(13),
            ),
            child: contenido,
          ),
        ),
      ),
    );
  }
}

class _SquareIconButton extends StatelessWidget {
  const _SquareIconButton({
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: DriverMapColors.blanco,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(width: 42, height: 42, child: Center(child: child)),
          ),
        ),
      ),
    );
  }
}

class BottomSheetPaused extends StatelessWidget {
  const BottomSheetPaused({
    super.key,
    required this.tipoVehiculo,
    required this.modeloVehiculo,
    required this.gananciasHoy,
    required this.onActivar,
    this.cargando = false,
  });

  final String tipoVehiculo;
  final String modeloVehiculo;
  final double gananciasHoy;
  final VoidCallback onActivar;
  final bool cargando;

  @override
  Widget build(BuildContext context) {
    final vehiculo = <String>[
      tipoVehiculo.trim(),
      modeloVehiculo.trim(),
    ].where((s) => s.isNotEmpty).join(' · ');
    return DefaultTextStyle(
      style: DriverMapTypography.style(),
      child: Material(
        color: DriverMapColors.blanco,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(18, 12, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD9D9D9),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: DriverMapColors.cremaArriba,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: DriverMapColors.bordeAmarillo,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: DriverMapColors.negro,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: const Center(
                              child: LightningBolt(size: 14),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  'VEHÍCULO · PAUSADO',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DriverMapTypography.style(
                                    size: 8.5,
                                    weight: FontWeight.w600,
                                    color: DriverMapColors.secundario,
                                    height: 1,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  vehiculo.isEmpty ? 'Vehículo' : vehiculo,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DriverMapTypography.style(
                                    size: 13,
                                    weight: FontWeight.w800,
                                    height: 1.1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 86,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'GANANCIAS HOY',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: DriverMapTypography.style(
                            size: 8.5,
                            weight: FontWeight.w600,
                            color: DriverMapColors.secundario,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${formatImporteEntero(gananciasHoy)} CUP',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: DriverMapTypography.style(
                            size: 15,
                            weight: FontWeight.w900,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Semantics(
                button: true,
                label: 'Activar viajes',
                child: Material(
                  color: DriverMapColors.negro,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: cargando ? null : onActivar,
                    child: Opacity(
                      opacity: cargando ? 0.65 : 1,
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(minHeight: 62),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            if (cargando)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: DriverMapColors.amarillo,
                                ),
                              )
                            else
                              const LightningBolt(size: 19),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'Activar viajes',
                                    style: DriverMapTypography.style(
                                      size: 15,
                                      weight: FontWeight.w800,
                                      color: DriverMapColors.amarillo,
                                      height: 1.05,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Recibirás solicitudes cercanas',
                                    style: DriverMapTypography.style(
                                      size: 11,
                                      weight: FontWeight.w400,
                                      color: DriverMapColors.secundario,
                                      height: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ActiveOverlay extends StatelessWidget {
  const ActiveOverlay({
    super.key,
    required this.gananciasHoy,
    required this.onDesactivar,
    required this.onUbicacion,
    this.cargando = false,
  });

  final double gananciasHoy;
  final VoidCallback onDesactivar;
  final VoidCallback onUbicacion;
  final bool cargando;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle(
      style: DriverMapTypography.style(),
      // Esta capa entra en un `Positioned(bottom: 0)` sin altura propia, que le
      // da maxHeight=Infinity. Con todos los hijos `Positioned`, el Stack no
      // podia calcular su tamano y en release dejaba de pintarse entero. La
      // altura explicita cubre el mini stat (170+44) y el StopFab (28+~125).
      child: SizedBox(
        height: 240,
        child: Stack(
          children: <Widget>[
            // El chevron lo dibuja NavigationMapView directamente en el estilo.
            // Un marcador propio aqui solo lo taparia al activarse, asi que no
            // se pinta nada en el centro del mapa.
            Positioned(
              left: 16,
              bottom: 170,
              child: _MiniStat(gananciasHoy: gananciasHoy),
            ),
            Positioned(
              right: 16,
              bottom: 170,
              child: LocationFab(onTap: onUbicacion),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Center(
                child: StopFab(onTap: onDesactivar, cargando: cargando),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.gananciasHoy});

  final double gananciasHoy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: DriverMapColors.blanco,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DriverMapColors.bordeAmarillo, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'HOY',
            style: DriverMapTypography.style(
              size: 8.5,
              weight: FontWeight.w600,
              color: DriverMapColors.secundario,
              height: 1,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${formatImporteEntero(gananciasHoy)} CUP',
            style: DriverMapTypography.style(
              size: 13,
              weight: FontWeight.w900,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class LocationFab extends StatelessWidget {
  const LocationFab({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Centrar en mi posición',
      child: Tooltip(
        message: 'Centrar en mi posición',
        child: Material(
          color: DriverMapColors.blanco,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.my_location_rounded,
                color: DriverMapColors.amarillo,
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RadarMarker extends StatefulWidget {
  const RadarMarker({super.key, this.animated = true});

  final bool animated;

  @override
  State<RadarMarker> createState() => _RadarMarkerState();
}

class _RadarMarkerState extends State<RadarMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    if (widget.animated) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant RadarMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animated == widget.animated) return;
    if (widget.animated) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Tu posición',
      child: SizedBox(
        width: 120,
        height: 120,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Stack(
              alignment: Alignment.center,
              children: <Widget>[
                for (var i = 0; i < 3; i++)
                  _ring(progress: (_controller.value + i / 3) % 1.0),
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: DriverMapColors.amarillo,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: DriverMapColors.blanco,
                      width: 5,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _ring({required double progress}) {
    final eased = Curves.easeOut.transform(progress);
    final size = 26 + 82 * eased;
    final opacity = (1 - progress) * 0.42;
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: DriverMapColors.amarillo.withValues(alpha: opacity),
            width: 2,
          ),
        ),
      ),
    );
  }
}

class StopFab extends StatefulWidget {
  const StopFab({super.key, required this.onTap, this.cargando = false});

  final VoidCallback onTap;
  final bool cargando;

  @override
  State<StopFab> createState() => _StopFabState();
}

class _StopFabState extends State<StopFab> {
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Desactivar viajes',
      child: DefaultTextStyle(
        style: DriverMapTypography.style(),
        // La etiqueta tambien forma parte del boton: en el móvil se toca el
        // circulo, pero con el dedo gordo es facil acertar al texto de abajo.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.cargando ? null : widget.onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 104,
                height: 104,
                // Halo fijo: ningun AnimatedBuilder reconstruye el boton.
                // El círculo negro con el rayo queda siempre pintado encima.
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: DriverMapColors.amarillo.withValues(alpha: 0.16),
                      ),
                    ),
                    Material(
                      color: DriverMapColors.negro,
                      shape: const CircleBorder(
                        side: BorderSide(
                          color: DriverMapColors.blanco,
                          width: 4,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: widget.cargando ? null : widget.onTap,
                        customBorder: const CircleBorder(),
                        child: SizedBox(
                          width: 74,
                          height: 74,
                          child: widget.cargando
                              ? const Center(
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: DriverMapColors.amarillo,
                                    ),
                                  ),
                                )
                              : const Center(
                                  child: LightningBolt(
                                    size: 32,
                                    inverted: true,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Transform.translate(
              offset: const Offset(0, -8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: DriverMapColors.blanco,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  'Desactivar',
                  style: DriverMapTypography.style(
                    size: 11,
                    weight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }
}
