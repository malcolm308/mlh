import 'package:flutter/material.dart';

import 'driver_map_theme.dart';

class TripRequestOverlay extends StatelessWidget {
  const TripRequestOverlay({
    super.key,
    required this.onMenu,
    required this.tipoVehiculo,
    required this.metodoPago,
    required this.precio,
    required this.distanciaKm,
    required this.pasajeros,
    required this.tiempoMin,
    required this.recogidaKm,
    required this.direccionRecogida,
    required this.direccionDestino,
    required this.countdown,
    required this.countdownTotal,
    required this.aceptando,
    required this.ocupado,
    required this.saldoNegativo,
    required this.onAceptar,
    required this.onRechazar,
    this.promocion,
  });

  final String tipoVehiculo;
  final String metodoPago;
  final double? precio;
  final double? distanciaKm;
  final int pasajeros;
  final double? tiempoMin;
  final double? recogidaKm;
  final String direccionRecogida;
  final String direccionDestino;
  final int countdown;
  final int countdownTotal;
  final bool aceptando;
  final bool ocupado;
  final bool saldoNegativo;
  final VoidCallback onAceptar;
  final VoidCallback onRechazar;
  final Widget? promocion;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return DefaultTextStyle(
      style: DriverMapTypography.style(),
      child: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: ColoredBox(color: Color(0x59000000)),
          ),
          Positioned(
            top: media.padding.top + 12,
            left: 16,
            right: 16,
            child: CountdownBar(
              countdown: countdown,
              countdownTotal: countdownTotal,
              onMenu: onMenu,
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: SafeArea(
              top: false,
              child: _SlideUpModal(
                child: TripRequestModal(
                  tipoVehiculo: tipoVehiculo,
                  metodoPago: metodoPago,
                  precio: precio,
                  distanciaKm: distanciaKm,
                  pasajeros: pasajeros,
                  tiempoMin: tiempoMin,
                  recogidaKm: recogidaKm,
                  direccionRecogida: direccionRecogida,
                  direccionDestino: direccionDestino,
                  aceptando: aceptando,
                  ocupado: ocupado,
                  saldoNegativo: saldoNegativo,
                  onAceptar: onAceptar,
                  onRechazar: onRechazar,
                  promocion: promocion,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Entrada del modal: sube desde abajo en 200 ms, sin retransmitir eventos.
class _SlideUpModal extends StatefulWidget {
  const _SlideUpModal({required this.child});

  final Widget child;

  @override
  State<_SlideUpModal> createState() => _SlideUpModalState();
}

class _SlideUpModalState extends State<_SlideUpModal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..forward();

  late final Animation<Offset> _desplazamiento = Tween<Offset>(
    begin: const Offset(0, 0.12),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _desplazamiento,
      child: FadeTransition(opacity: _controller, child: widget.child),
    );
  }
}

class CountdownBar extends StatelessWidget {
  const CountdownBar({
    super.key,
    required this.countdown,
    required this.countdownTotal,
    required this.onMenu,
  });

  final int countdown;
  final int countdownTotal;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final total = countdownTotal <= 0 ? 1 : countdownTotal;
    final progreso = (countdown / total).clamp(0.0, 1.0);
    return DefaultTextStyle(
      style: DriverMapTypography.style(),
      child: Row(
        children: <Widget>[
          LogoChip(onTap: onMenu),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              liveRegion: true,
              label: 'Aceptar en $countdown segundos',
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: DriverMapColors.negro,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const Icon(
                              Icons.timer_outlined,
                              size: 16,
                              color: DriverMapColors.amarillo,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'ACEPTAR EN',
                                    style: DriverMapTypography.style(
                                      size: 8.5,
                                      weight: FontWeight.w600,
                                      color: DriverMapColors.blanco.withValues(
                                        alpha: 0.60,
                                      ),
                                      height: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '$countdown s',
                                    style: DriverMapTypography.style(
                                      size: 14,
                                      weight: FontWeight.w800,
                                      color: DriverMapColors.amarillo,
                                      height: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 3,
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(13),
                            ),
                            child: ColoredBox(
                              color: DriverMapColors.blanco.withValues(
                                alpha: 0.15,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 900),
                                  curve: Curves.linear,
                                  width: constraints.maxWidth * progreso,
                                  height: 3,
                                  color: DriverMapColors.amarillo,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TripRequestModal extends StatelessWidget {
  const TripRequestModal({
    super.key,
    required this.tipoVehiculo,
    required this.metodoPago,
    required this.precio,
    required this.distanciaKm,
    required this.pasajeros,
    required this.tiempoMin,
    required this.recogidaKm,
    required this.direccionRecogida,
    required this.direccionDestino,
    required this.aceptando,
    required this.ocupado,
    required this.saldoNegativo,
    required this.onAceptar,
    required this.onRechazar,
    this.promocion,
  });

  final String tipoVehiculo;
  final String metodoPago;
  final double? precio;
  final double? distanciaKm;
  final int pasajeros;
  final double? tiempoMin;
  final double? recogidaKm;
  final String direccionRecogida;
  final String direccionDestino;
  final bool aceptando;
  final bool ocupado;
  final bool saldoNegativo;
  final VoidCallback onAceptar;
  final VoidCallback onRechazar;
  final Widget? promocion;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.76),
      child: Material(
        color: DriverMapColors.blanco,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        elevation: 18,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        child: DefaultTextStyle(
          style: DriverMapTypography.style(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _PriceAndTags(
                        precio: precio,
                        tipoVehiculo: tipoVehiculo,
                        metodoPago: metodoPago,
                      ),
                      const SizedBox(height: 14),
                      MetaRow(
                        distanciaKm: distanciaKm,
                        pasajeros: pasajeros,
                        tiempoMin: tiempoMin,
                      ),
                      if (promocion != null) ...[
                        const SizedBox(height: 12),
                        promocion!,
                      ],
                      const SizedBox(height: 16),
                      RouteStops(
                        recogidaKm: recogidaKm,
                        direccionRecogida: direccionRecogida,
                        direccionDestino: direccionDestino,
                      ),
                      if (saldoNegativo) ...[
                        const SizedBox(height: 14),
                        const _NegativeBalanceWarning(),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                child: _Actions(
                  aceptando: aceptando,
                  ocupado: ocupado,
                  saldoNegativo: saldoNegativo,
                  onAceptar: onAceptar,
                  onRechazar: onRechazar,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PriceAndTags extends StatelessWidget {
  const _PriceAndTags({
    required this.precio,
    required this.tipoVehiculo,
    required this.metodoPago,
  });

  final double? precio;
  final String tipoVehiculo;
  final String metodoPago;

  @override
  Widget build(BuildContext context) {
    final importe = precio == null ? '—' : formatImporteEntero(precio!);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'TARIFA DEL VIAJE',
                style: DriverMapTypography.style(
                  size: 9,
                  weight: FontWeight.w600,
                  color: DriverMapColors.secundario,
                  height: 1,
                ),
              ),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: RichText(
                  text: TextSpan(
                    children: <TextSpan>[
                      TextSpan(
                        text: importe,
                        style: DriverMapTypography.style(
                          size: 34,
                          weight: FontWeight.w900,
                          height: 1,
                        ),
                      ),
                      const TextSpan(text: '  '),
                      TextSpan(
                        text: 'CUP',
                        style: DriverMapTypography.style(
                          size: 13,
                          weight: FontWeight.w600,
                          color: DriverMapColors.secundario,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            _Tag(
              text: tipoVehiculo,
              fondo: DriverMapColors.cremaArriba,
              texto: DriverMapColors.texto,
              borde: DriverMapColors.bordeAmarillo,
              icono: Icons.local_taxi_rounded,
            ),
            _Tag(
              text: metodoPago,
              fondo: DriverMapColors.negro,
              texto: DriverMapColors.amarillo,
            ),
          ],
        ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.text,
    required this.fondo,
    required this.texto,
    this.borde,
    this.icono,
  });

  final String text;
  final Color fondo;
  final Color texto;
  final Color? borde;
  final IconData? icono;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(13),
        border: borde == null ? null : Border.all(color: borde!, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icono != null) ...[
            Icon(icono, size: 12, color: DriverMapColors.amarillo),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: DriverMapTypography.style(
              size: 10,
              weight: FontWeight.w800,
              color: texto,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class MetaRow extends StatelessWidget {
  const MetaRow({
    super.key,
    required this.distanciaKm,
    required this.pasajeros,
    required this.tiempoMin,
  });

  final double? distanciaKm;
  final int pasajeros;
  final double? tiempoMin;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: MetaChip(
            icono: Icons.location_on_rounded,
            valor: distanciaKm == null ? '—' : '${distanciaKm!.toStringAsFixed(1)} km',
            etiqueta: 'DISTANCIA',
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: MetaChip(
            icono: Icons.person_rounded,
            valor: '$pasajeros ${pasajeros == 1 ? 'pax' : 'pax'}',
            etiqueta: 'PASAJERO',
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: MetaChip(
            icono: Icons.schedule_rounded,
            valor: tiempoMin == null ? '—' : '${tiempoMin!.ceil()} min',
            etiqueta: 'LLEGADA',
          ),
        ),
      ],
    );
  }
}

class MetaChip extends StatelessWidget {
  const MetaChip({
    super.key,
    required this.icono,
    required this.valor,
    required this.etiqueta,
  });

  final IconData icono;
  final String valor;
  final String etiqueta;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: DriverMapColors.fondoChip,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: DriverMapColors.negro,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icono, size: 14, color: DriverMapColors.amarillo),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  valor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DriverMapTypography.style(
                    size: 13,
                    weight: FontWeight.w900,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  etiqueta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DriverMapTypography.style(
                    size: 8,
                    weight: FontWeight.w600,
                    color: DriverMapColors.secundario,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class RouteStops extends StatelessWidget {
  const RouteStops({
    super.key,
    required this.recogidaKm,
    required this.direccionRecogida,
    required this.direccionDestino,
  });

  final double? recogidaKm;
  final String direccionRecogida;
  final String direccionDestino;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 24,
            child: Column(
              children: <Widget>[
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: DriverMapColors.amarillo,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: DriverMapColors.blanco,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: DriverMapColors.negro,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Container(
                      width: 2,
                      color: DriverMapColors.bordeAmarillo,
                    ),
                  ),
                ),
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: DriverMapColors.negro,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: DriverMapColors.amarillo,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: DriverMapColors.amarillo,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _StopText(
                  titulo: 'RECOGER EN · ${recogidaKm == null ? '— km' : '${recogidaKm!.toStringAsFixed(1)} KM'}',
                  direccion: direccionRecogida,
                ),
                const SizedBox(height: 14),
                _StopText(
                  titulo: 'DESTINO',
                  direccion: direccionDestino,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StopText extends StatelessWidget {
  const _StopText({required this.titulo, required this.direccion});

  final String titulo;
  final String direccion;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          titulo,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DriverMapTypography.style(
            size: 8.5,
            weight: FontWeight.w600,
            color: DriverMapColors.secundario,
            height: 1,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          direccion.isEmpty ? 'Ubicación en el mapa' : direccion,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: DriverMapTypography.style(
            size: 12,
            weight: FontWeight.w800,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.aceptando,
    required this.ocupado,
    required this.saldoNegativo,
    required this.onAceptar,
    required this.onRechazar,
  });

  final bool aceptando;
  final bool ocupado;
  final bool saldoNegativo;
  final VoidCallback onAceptar;
  final VoidCallback onRechazar;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          flex: 42,
          child: Semantics(
            button: true,
            label: 'Rechazar viaje',
            child: Material(
              color: DriverMapColors.blanco,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: aceptando ? null : onRechazar,
                child: Container(
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: DriverMapColors.bordeGris,
                      width: 2,
                    ),
                  ),
                  child: Text(
                    'Rechazar',
                    style: DriverMapTypography.style(
                      size: 14,
                      weight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 100,
          child: Semantics(
            button: true,
            label: 'Aceptar viaje',
            child: Material(
              color: DriverMapColors.negro,
              borderRadius: BorderRadius.circular(16),
              elevation: 5,
              shadowColor: Colors.black.withValues(alpha: 0.25),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: aceptando || ocupado || saldoNegativo
                    ? null
                    : onAceptar,
                child: Opacity(
                  opacity: aceptando || ocupado || saldoNegativo ? 0.55 : 1,
                  child: Container(
                    height: 50,
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        if (aceptando)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: DriverMapColors.amarillo,
                            ),
                          )
                        else
                          const LightningBolt(size: 16),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            aceptando ? 'Aceptando...' : 'Aceptar',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DriverMapTypography.style(
                              size: 14,
                              weight: FontWeight.w800,
                              color: DriverMapColors.amarillo,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NegativeBalanceWarning extends StatelessWidget {
  const _NegativeBalanceWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.account_balance_wallet_outlined,
            color: Color(0xFF991B1B),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Tienes el saldo en rojo. Recarga tu fondo en "Fondo y '
              'transferencias" antes de aceptar viajes.',
              style: DriverMapTypography.style(
                size: 12,
                weight: FontWeight.w600,
                color: const Color(0xFF991B1B),
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
