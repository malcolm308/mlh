"""
Pruebas del mensaje de Telegram de los viajes huerfanos.

El mensaje es lo unico que ve el chofer en el grupo: si falta el tipo de
vehiculo, un chofer de moto puede pedir un viaje de basico (o al reves) y el
administrador se entera tarde. Estas pruebas fijan el formato y la etiqueta.

    python -m unittest tests.test_telegram_huerfano -v
"""
import unittest

from services.telegram_huerfanos import mensaje_huerfano


def _mensaje(tipo=None):
    return mensaje_huerfano(
        trip_id="TEST-123",
        origen="Calle Falsa 123",
        destino="Avenida Siempre Viva 742",
        precio=1500,
        numero_whatsapp="5359295207",
        tipo_vehiculo=tipo,
    )


class TestTipoVehiculo(unittest.TestCase):

    def test_cada_tipo_sale_con_su_etiqueta(self):
        casos = {
            "basico": "Básico",
            "BÁSICO": "Básico",
            " Basico ": "Básico",
            "moto": "Moto",
            "triciclo": "Triciclo",
            "Confort": "Confort",
            "premium": "Premium",
        }
        for crudo, etiqueta in casos.items():
            with self.subTest(crudo=crudo):
                self.assertIn("🚘 <b>Tipo:</b> %s" % etiqueta, _mensaje(crudo))

    def test_tipo_nuevo_se_capitaliza(self):
        self.assertIn("🚘 <b>Tipo:</b> Furgoneta", _mensaje("furgoneta"))

    def test_sin_tipo_no_se_inventa_uno(self):
        """Decir 'Básico' por defecto mandaria al chofer equivocado."""
        for vacio in (None, "", "   "):
            with self.subTest(valor=vacio):
                self.assertIn("🚘 <b>Tipo:</b> por confirmar", _mensaje(vacio))


class TestFormato(unittest.TestCase):

    def test_encabezado_y_campos(self):
        texto = _mensaje("moto")
        self.assertIn("🚕 <b>VIAJE SIN CHOFER</b> (ID: <code>TEST-123</code>)",
                      texto)
        self.assertIn("📍 <b>Recogida:</b> Calle Falsa 123", texto)
        self.assertIn("🏁 <b>Destino:</b> Avenida Siempre Viva 742", texto)
        self.assertIn("💰 <b>Precio:</b> 1,500.00 CUP", texto)

    def test_enlace_whatsapp_con_el_id_y_coma_literal(self):
        texto = _mensaje("basico")
        self.assertIn(
            "https://wa.me/5359295207?text=Hola,%20quiero%20el%20viaje%20TEST-123",
            texto,
        )

    def test_escapa_html_de_las_direcciones(self):
        """Una direccion con `<` o `&` no puede romper el parse_mode=HTML."""
        texto = mensaje_huerfano(
            trip_id="T1",
            origen="Casa <script>",
            destino="Calle & Sol",
            precio=10,
            numero_whatsapp="5359295207",
            tipo_vehiculo="basico",
        )
        self.assertIn("Casa &lt;script&gt;", texto)
        self.assertIn("Calle &amp; Sol", texto)
        self.assertNotIn("<script>", texto)


if __name__ == "__main__":
    unittest.main(verbosity=2)
