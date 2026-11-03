import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show MapLibreMap;

import 'screens/login_screen.dart';

Future<void> main() async {
  // El mapa va en TextureView y NO en Virtual Display.
  //
  // Por defecto el plugin renderiza el mapa con GLSurfaceView embebido por
  // Virtual Display, y ese camino del motor de Flutter tiene un bug abierto
  // (flutter/flutter#154613): un `resize()` del mapa que choca con su
  // `dispose()` inmediato crashea toda la app con
  // "NullPointerException: SurfaceProducer.getWidth()". En nuestro flujo pasa
  // al pedir un viaje: teclado que redimensiona el mapa, cambiar ruta y abrir
  // la hoja de vehiculos casi junticos.
  //
  // Con TextureView Flutter compone el mapa como una capa mas y el
  // VirtualDisplayController no existe. Cuesta algo mas de render; es el
  // precio de no perder viajes por crash.
  MapLibreMap.useHybridComposition = true;
  runApp(const TaxiClientApp());
}

class TaxiClientApp extends StatelessWidget {
  const TaxiClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: 'RapiTaxi',
      debugShowCheckedModeBanner: false,
      routes: {'/': (_) => const LoginScreen()},
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF2F3F5),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF333333),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            minimumSize: const Size(0, 48),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            minimumSize: const Size(0, 44),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
        ),
      ),
    );
  }
}