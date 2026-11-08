import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

// El mapa va en TextureView y NO en Virtual Display: mismo motivo que la app
// de cliente. El camino Virtual Display del motor tiene el bug abierto
// flutter/flutter#154613 (un resize del mapa que choca con su dispose mata el
// proceso) y el chofer vive redimensionando el mapa: teclado, hoja de
// vehiculos, drawer, modos de navegacion. Sin este modo, un crash nativo
// cierra la app en pleno turno.
import 'package:maplibre_gl/maplibre_gl.dart' show MapLibreMap;

import 'services/ofertas_background_service.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

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

  // OTA: instala el cargador del parche ANTES de crear la app. Si no hay
  // parche (o no es Android) es una operacion nula. Cualquier fallo aqui no
  // puede impedir abrir la app ni el servicio de ofertas.
  try {
    await FlutterPatcher.init();
  } catch (_) {}

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
      theme: AppTheme.light(),
    );
  }
}