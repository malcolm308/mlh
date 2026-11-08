import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show MapLibreMap;

import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'theme/app_theme.dart';

/// Permite navegar al Login desde `ApiClient` cuando el refresh caduca, sin
/// acoplar el transporte HTTP a una pantalla concreta.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // OTA: instala el cargador del parche ANTES de crear la app. Si no hay
  // parche (o no es Android) es una operacion nula. Cualquier fallo aqui no
  // puede impedir abrir la app.
  try {
    await FlutterPatcher.init();
  } catch (_) {}

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

  // Red de seguridad: si la sesion caduca en una pantalla que no sea el home,
  // se vuelve al Login. El home instala su propio aviso para limpiar el viaje.
  ApiClient.alExpirarSesion = () {
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/', (r) => false);
  };

  runApp(const TaxiClientApp());
}

class TaxiClientApp extends StatelessWidget {
  const TaxiClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: 'RapiTaxi',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      routes: {'/': (_) => const LoginScreen()},
      theme: AppTheme.light(),
    );
  }
}