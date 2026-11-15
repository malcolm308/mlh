import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_client/models/models.dart';

/// Regresion del crash de login:
/// "type 'Null' is not a subtype of type 'String' in type cast".
///
/// El backend devuelve `titulo_promo`, `fecha_expiracion_promocional` y
/// `codigo_referido` como `null` cuando no hay campana vigente o la cuenta es
/// antigua. `ClientProfile.fromJson` debe aceptarlo sin lanzar.
void main() {
  group('ClientProfile.fromJson sin promocion', () {
    test('campos de promocion en null no rompen el parseo', () {
      final perfil = ClientProfile.fromJson({
        '_id': '6af207444d0744fe6f78b622',
        'Nombre': 'Malcolm',
        'Apellidos': 'Lamar',
        'email': 'malcolm@example.com',
        'numero_de_telefono': '5351003875',
        'Fondo': null,
        'saldo_promocional': null,
        'fecha_expiracion_promocional': null,
        'campana_promocional_activa': null,
        'monto_bono_chofer_campana': null,
        'titulo_promo': null,
        'codigo_referido': null,
      });

      expect(perfil.id, '6af207444d0744fe6f78b622');
      expect(perfil.fullName, 'Malcolm Lamar');
      expect(perfil.fondo, 0);
      expect(perfil.saldoPromocional, 0);
      expect(perfil.fechaExpiracionPromocional, isNull);
      expect(perfil.campanaPromocionalActiva, isFalse);
      expect(perfil.montoBonoChoferCampana, 0);
      expect(perfil.tituloPromo, isNull);
      expect(perfil.codigoReferido, isNull);
    });

    test('campos ausentes tampoco rompen el parseo', () {
      final perfil = ClientProfile.fromJson({'_id': 'abc'});
      expect(perfil.saldoPromocional, 0);
      expect(perfil.fechaExpiracionPromocional, isNull);
      expect(perfil.tituloPromo, isNull);
      expect(perfil.codigoReferido, isNull);
    });

    test('strings vacios se normalizan a null/0', () {
      final perfil = ClientProfile.fromJson({
        '_id': 'abc',
        'saldo_promocional': '',
        'fecha_expiracion_promocional': '   ',
        'titulo_promo': '   ',
        'codigo_referido': '',
        'monto_bono_chofer_campana': '',
      });
      expect(perfil.saldoPromocional, 0);
      expect(perfil.fechaExpiracionPromocional, isNull);
      expect(perfil.tituloPromo, isNull);
      expect(perfil.codigoReferido, isNull);
      expect(perfil.montoBonoChoferCampana, 0);
    });
    test('respuesta real de produccion sin promo (auditoria)', () {
      // Payload exacto devuelto por GET /cliente/<id> para una cuenta nueva sin
      // campana: `titulo_promo: null` era el que disparaba el cast a String.
      final perfil = ClientProfile.fromJson({
        'Apellidos': 'SinPromo',
        'Enable': true,
        'Fondo': 0.0,
        'Nombre': 'Prueba',
        '_id': '6af9ae9c51f57e152e502e72',
        'campana_promocional_activa': false,
        'codigo_referido': 'GNRGCDIT',
        'email': 'sinpromo.1794747932@example.com',
        'fecha_expiracion_promocional': null,
        'monto_bono_chofer_campana': 0.0,
        'numero_de_telefono': '55997932',
        'saldo_promocional': 0.0,
        'titulo_promo': null,
      });

      expect(perfil.id, '6af9ae9c51f57e152e502e72');
      expect(perfil.fullName, 'Prueba SinPromo');
      expect(perfil.email, 'sinpromo.1794747932@example.com');
      expect(perfil.saldoPromocional, 0);
      expect(perfil.fechaExpiracionPromocional, isNull);
      expect(perfil.campanaPromocionalActiva, isFalse);
      expect(perfil.tituloPromo, isNull);
      expect(perfil.codigoReferido, 'GNRGCDIT');
    });
  });

  group('ClientProfile.fromJson con promocion activa', () {
    test('lee saldo, fecha y titulo', () {
      final perfil = ClientProfile.fromJson({
        '_id': 'abc',
        'saldo_promocional': 2000.0,
        'fecha_expiracion_promocional': '2026-11-15T11:17:00Z',
        'campana_promocional_activa': true,
        'monto_bono_chofer_campana': 1100,
        'titulo_promo': '  ¡Hoy es sábado!  ',
        'codigo_referido': '  ABC123  ',
      });
      expect(perfil.saldoPromocional, 2000);
      expect(perfil.fechaExpiracionPromocional, '2026-11-15T11:17:00Z');
      expect(perfil.campanaPromocionalActiva, isTrue);
      expect(perfil.montoBonoChoferCampana, 1100);
      expect(perfil.tituloPromo, '¡Hoy es sábado!');
      expect(perfil.codigoReferido, 'ABC123');
    });

    test('acepta numeros enviados como texto (documentos viejos)', () {
      final perfil = ClientProfile.fromJson({
        '_id': 'abc',
        'Fondo': '150.50',
        'saldo_promocional': '2000.00',
        'monto_bono_chofer_campana': '1100',
      });
      expect(perfil.fondo, 150.50);
      expect(perfil.saldoPromocional, 2000);
      expect(perfil.montoBonoChoferCampana, 1100);
    });
  });
}
