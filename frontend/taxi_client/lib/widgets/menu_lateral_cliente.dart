import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/models.dart';

/// Paleta del menu lateral "Tema Claro Translucido" (light glassmorphism).
/// Todo el color vive aqui: cambiar una constante cambia el tema entero.
const Color kAcentoMarca = Color(0xFFFFD100); // amarillo RapiTaxi
const Color kCabeceraAlta = Color(0xFFFFEBB0); // degradado calido
const Color kCabeceraBaja = Color(0xFFFFFDF4);
const Color kTextoInk = Color(0xFF1C1E21);
const Color kTextoSecundario = Color(0xFF6B6A70);
const Color kAmbarTexto = Color(0xFF946E00);
const Color kPanelBlur = Color(0xD9FFFFFF); // blanco 85%

/// Sombra sutil de cada pildora inactiva.
const BoxShadow kSombraPildora = BoxShadow(
  color: Color(0x14000000),
  blurRadius: 6,
  offset: Offset(0, 2),
);

/// Menu lateral del pasajero, diseno premium "Tema Claro Translucido".
///
/// El panel se dibuja con [BackdropFilter] y blanco 85% para que el MAPA que
/// hay detras se vea desenfocado; las opciones del cliente van aqui y no se
/// mezclan con las del chofer.
class MenuLateralCliente extends StatelessWidget {
  final ClientProfile profile;
  final VoidCallback onHistorial;
  final VoidCallback onFavoritas;
  final VoidCallback onBloqueados;
  final VoidCallback onCompartir;
  final VoidCallback onAyuda;
  final VoidCallback onCerrarSesion;
  final VoidCallback onBorrarCuenta;

  const MenuLateralCliente({
    super.key,
    required this.profile,
    required this.onHistorial,
    required this.onFavoritas,
    required this.onBloqueados,
    required this.onCompartir,
    required this.onAyuda,
    required this.onCerrarSesion,
    required this.onBorrarCuenta,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      // El fondo transparente hace que lo de "detras" (el mapa) se filtre
      // a traves del BackdropFilter. width fija el ancho del panel.
      backgroundColor: Colors.transparent,
      child: Stack(
        children: [
          // 1) Capa de vidrio: desenfoque 22 px + blanco translucido.
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: Container(color: kPanelBlur),
            ),
          ),
          // 2) Contenido.
          SafeArea(
            child: Column(
              children: [
                Cabecera(
                  fullName: profile.fullName,
                  email: profile.email,
                  calificacion: null, // el pasajero no trae rating visible
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    children: [
                      PilulaMenu(
                        icono: Icons.history,
                        texto: 'Historial de viajes',
                        onTap: onHistorial,
                      ),
                      PilulaMenu(
                        icono: Icons.star_outline,
                        texto: 'Ubicaciones favoritas',
                        onTap: onFavoritas,
                      ),
                      PilulaMenu(
                        icono: Icons.block_outlined,
                        texto: 'Chóferes bloqueados',
                        onTap: onBloqueados,
                      ),
                      const SizedBox(height: 10),
                      PilulaMenu(
                        icono: Icons.share_outlined,
                        texto: 'Compartir app',
                        onTap: onCompartir,
                      ),
                      PilulaMenu(
                        icono: Icons.support_agent_outlined,
                        texto: 'Ayuda y soporte',
                        onTap: onAyuda,
                      ),
                      const SizedBox(height: 10),
                      PilulaCerrarSesion(onTap: onCerrarSesion),
                      PilulaMenu(
                        icono: Icons.delete_outline,
                        texto: 'Borrar cuenta',
                        destacadoEnRojo: true,
                        onTap: onBorrarCuenta,
                      ),
                    ],
                  ),
                ),
                const PieMenu(),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Cabecera: degradado calido, silueta de ciudad, rayo de acento y datos del
/// usuario con foto en avatar amarillo.
class Cabecera extends StatelessWidget {
  final String fullName;
  final String email;
  final double? calificacion;

  /// Widget opcional de foto (el chofer reutiliza el suyo con la imagen).
  final Widget? avatar;

  const Cabecera({
    super.key,
    required this.fullName,
    required this.email,
    this.calificacion,
    this.avatar,
  });

  @override
  Widget build(BuildContext context) {
    final estrellas = (calificacion ?? 5.0).toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 18),
      decoration: const BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [kCabeceraAlta, kCabeceraBaja],
        ),
      ),
      child: Stack(
        children: [
          // Silueta de ciudad al fondo, sutil.
          const Positioned.fill(
            child: IgnorePointer(
              child: SiluetaCiudad(opacidad: 0.12),
            ),
          ),
          // Rayo de marca en la esquina superior derecha.
          Positioned(
            top: 0,
            right: 0,
            child: RotationTransition(
              turns: const AlwaysStoppedAnimation(0.08),
              child: Icon(Icons.bolt, size: 64, color: kAcentoMarca
                  .withValues(alpha: 0.55)),
            ),
          ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: kAcentoMarca, width: 3),
                  boxShadow: const [
                    BoxShadow(color: Color(0x22000000), blurRadius: 8),
                  ],
                ),
                child: avatar ??
                    const CircleAvatar(
                      radius: 28,
                      backgroundColor: Color(0xFFEDEFF3),
                      child: Icon(Icons.person,
                          color: Color(0xFF6B6A70), size: 30),
                    ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: kTextoInk,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: kTextoSecundario, fontSize: 12),
                    ),
                    if (calificacion != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.star,
                              color: kAcentoMarca, size: 16),
                          const SizedBox(width: 4),
                          Text(
                            estrellas,
                            style: const TextStyle(
                                color: kTextoInk,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Silueta de ciudad dibujada con vector (sin asset): edificios de alturas
/// variadas al fondo de la cabecera.
class SiluetaCiudad extends StatelessWidget {
  final double opacidad;
  const SiluetaCiudad({super.key, this.opacidad = 0.12});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 120),
      painter: _SiluetaCiudadPainter(opacidad: opacidad),
    );
  }
}

class _SiluetaCiudadPainter extends CustomPainter {
  final double opacidad;
  _SiluetaCiudadPainter({required this.opacidad});

  @override
  void paint(Canvas canvas, Size size) {
    final pintura = Paint()..color = kTextoInk.withValues(alpha: opacidad);
    final edificios = <List<double>>[
      // [izquierda, ancho, alto-de-arranque desdel suelo]
      [0.02, 0.06, 0.35],
      [0.10, 0.08, 0.55],
      [0.20, 0.05, 0.40],
      [0.27, 0.07, 0.70],
      [0.36, 0.06, 0.45],
      [0.44, 0.09, 0.62],
      [0.55, 0.06, 0.38],
      [0.63, 0.08, 0.55],
      [0.73, 0.05, 0.42],
      [0.80, 0.07, 0.66],
      [0.89, 0.06, 0.48],
      [0.96, 0.05, 0.30],
    ];
    final suelo = size.height;
    for (final e in edificios) {
      final izquierda = e[0] * size.width;
      final ancho = e[1] * size.width;
      final alto = e[2] * suelo;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(izquierda, suelo - alto, ancho, alto),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        pintura,
      );
    }
  }

  @override
  bool shouldRepaint(_SiluetaCiudadPainter viejo) =>
      viejo.opacidad != opacidad;
}

/// Boton tipo pildora del menu.
class PilulaMenu extends StatelessWidget {
  final IconData icono;
  final String texto;
  final VoidCallback onTap;
  final bool activo;

  /// Cambia icono/texto a rojo (para "Borrar cuenta").
  final bool destacadoEnRojo;
  final Color colorRojo = const Color(0xFFB3261E);
  final bool mostrarChevron;

  const PilulaMenu({
    super.key,
    required this.icono,
    required this.texto,
    required this.onTap,
    this.activo = false,
    this.destacadoEnRojo = false,
    this.mostrarChevron = true,
  });

  @override
  Widget build(BuildContext context) {
    final tinta = destacadoEnRojo ? colorRojo : kTextoInk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: activo ? kAcentoMarca : Colors.white,
        borderRadius: BorderRadius.circular(30),
        shadowColor: const Color(0x22000000),
        elevation: activo ? 0 : 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: onTap,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icono, size: 20, color: tinta),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    texto,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tinta,
                      fontSize: 13.5,
                      fontWeight: activo ? FontWeight.bold : FontWeight.w600,
                    ),
                  ),
                ),
                if (mostrarChevron && !activo)
                  const Icon(Icons.chevron_right,
                      size: 18, color: kTextoSecundario),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Boton pildora transparente con borde ambar para "Cerrar sesion".
class PilulaCerrarSesion extends StatelessWidget {
  final VoidCallback onTap;
  const PilulaCerrarSesion({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(30),
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: onTap,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: kAcentoMarca, width: 1.5),
            ),
            child: const Row(
              children: [
                Icon(Icons.logout, size: 20, color: kAmbarTexto),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Cerrar sesión',
                    style: TextStyle(
                        color: kAmbarTexto,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pie del menu: logo del rayo + eslogan, centrado.
class PieMenu extends StatelessWidget {
  const PieMenu({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Divider(indent: 24, endIndent: 24, color: Color(0x11000000)),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bolt, color: kAcentoMarca, size: 22),
            const SizedBox(width: 4),
            RichText(
              text: const TextSpan(
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: kTextoInk),
                children: [
                  TextSpan(text: 'Rapi'),
                  TextSpan(
                    text: 'Taxi',
                    style: TextStyle(
                      color: kAmbarTexto,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        const Text(
          'Tu taxi, más rápido',
          style: TextStyle(
              color: kTextoSecundario,
              fontSize: 11,
              fontStyle: FontStyle.italic),
        ),
      ],
    );
  }
}
