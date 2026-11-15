import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_client/api_config.dart';
import 'package:taxi_client/models/models.dart';
import 'package:taxi_client/widgets/menu_lateral_cliente.dart';

void main() {
  test('la constante apunta al canal oficial del equipo', () {
    expect(
      whatsappChannelUrl,
      'https://whatsapp.com/channel/0029Vb9JG2f5fM5hayk9g12C',
    );
  });

  testWidgets('el menu del cliente muestra y dispara el canal de WhatsApp',
      (tester) async {
    var pulsado = false;

    await tester.pumpWidget(MaterialApp(
      home: MenuLateralCliente(
        profile: const ClientProfile(
          id: 'test',
          fullName: 'Cliente Prueba',
          email: 'prueba@example.com',
        ),
        onPerfil: () {},
        onPromociones: () {},
        onCanalWhatsApp: () => pulsado = true,
        onHistorial: () {},
        onFondo: () {},
        onFavoritas: () {},
        onBloqueados: () {},
        onCompartir: () {},
        onAyuda: () {},
        onCerrarSesion: () {},
        onBorrarCuenta: () {},
      ),
    ));

    const texto = 'Sigue nuestro Canal de Ofertas 📢';
    expect(find.text(texto), findsOneWidget);

    await tester.tap(find.text(texto));
    await tester.pump();

    expect(pulsado, isTrue);
  });
}
