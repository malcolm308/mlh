import 'package:flutter/material.dart';

// El mapa va en TextureView y NO en Virtual Display: mismo motivo que la app
// de cliente. El camino Virtual Display del motor tiene el bug abierto
// flutter/flutter#154613 (un resize del mapa que choca con su dispose mata el
// proceso) y el chofer vive redimensionando el mapa: teclado, hoja de
// vehiculos, drawer, modos de navegacion. Sin este modo, un crash nativo
// cierra la app en pleno turno.
import 'package:maplibre_gl/maplibre_gl.dart' show MapLibreMap;

import 'services/ofertas_background_service.dart';
import 'screens/login_screen.dart';

Future<void> main() async {
  // El canal de notificacion del SERVICIO debe existir desde la primera
  // linea de la app.
  //
  // flutter_background_service anuncia el servicio como started y el sistema
  // puede REINICIARLO solo (el servicio no muere con la tarea, ver
  // `stopWithTask`). Eso puede pasar incluso en la reapertura: el arranque
  // del proceso entrego el intent del servicio y su notificacion con
  // `startForeground` ANTES de que corra cualquier pantalla. Sin canal a
  // mano, Android mata al proceso con "Bad notification for startForeground"
  // y la app "se cierra sola al abrir".
  //
  // Con este complemente, en la primera apertura el canal queda REGISTRADO
  // en el sistema (vive fuera del proceso) y cualquier reinicio posterior
  // encuentra el canal. Defensa extra: onStartOfertas tambien lo crea por si
  // el isolate del servicio corre primero.
  WidgetsFlutterBinding.ensureInitialized();
  MapLibreMap.useHybridComposition = true;
  try {
    await crearCanalServicio();
  } catch (_) {
    // Si falla no bloquea el arranque: sin canal el toggle "En linea"
    // avisara con su propio error en vez de crashear.
  }
  runApp(const TaxiDriverApp());
}

class TaxiDriverApp extends StatelessWidget {
  const TaxiDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: 'RapiTaxi Chofer',
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