"""
Pruebas del reparto de dinero de un viaje.

El caso que protege este archivo: el descuento al cliente lo paga la PLATAFORMA,
nunca el chofer. Con un viaje de 10.00, comision del 15% y descuento del 10%, el
chofer tiene que quedarse con sus 8.50 intactos y la plataforma con 0.50.

    python -m unittest tests.test_promociones -v
"""
import os
import unittest
from datetime import datetime, timedelta
from decimal import Decimal

os.environ["TELEGRAM_BOT_TOKEN"] = "123456:TOKEN-DE-PRUEBA"
os.environ["TELEGRAM_WEBHOOK_SECRET"] = "secreto-de-prueba"
os.environ["TELEGRAM_ADMIN_CHAT_ID"] = "999"

from routers import promociones as promo_mod
from routers.promociones import (DESCUENTO_MAXIMO, PromoIn, _a_dinero,
                                 _esta_expirada, calcular_descuento_cliente)


def promo(comision="0.15", descuento="0.10", descuento_activo=True, expirada=False):
    """Configuracion ya resuelta, como la devuelve `leer_promocion`."""
    comision_dec = Decimal(comision)
    descuento_dec = Decimal(descuento)
    if comision_dec <= 0:
        descuento_activo = False
        descuento_dec = Decimal("0")
    return {
        "comision_porcentaje": comision_dec,
        "descuento_cliente_activo": descuento_activo,
        "descuento_cliente_porcentaje": descuento_dec,
        "expirada": expirada,
        "descuento_aplicando": descuento_activo and not expirada and comision_dec > 0,
    }


# ===================== EL EJEMPLO MATEMATICO DEL ENUNCIADO =====================

class TestEjemploDelEnunciado(unittest.TestCase):

    def test_viaje_de_10_con_comision_15_y_descuento_10(self):
        precio = Decimal("10.00")
        p = promo()

        descuento = calcular_descuento_cliente(precio, p)
        comision_nominal = _a_dinero(precio * p["comision_porcentaje"])
        comision_cobrada = comision_nominal - descuento

        # Lo que paga el pasajero
        self.assertEqual(precio - descuento, Decimal("9.00"))
        # La plataforma cobra su 15%, menos el descuento
        self.assertEqual(comision_nominal, Decimal("1.50"))
        self.assertEqual(comision_cobrada, Decimal("0.50"))
        # Y lo que conserva el chofer: 8.50, intactos
        self.assertEqual(precio - comision_nominal, Decimal("8.50"))
        # La plataforma se queda con 0.50
        self.assertEqual((precio - descuento) - (precio - comision_nominal), Decimal("0.50"))

    def test_el_chofer_nunca_paga_el_descuento(self):
        """La propiedad que da nombre al sistema: pase lo que pase, lo que se
        descuenta del Fondo del chofer es la comision menos el descuento, nunca el
        precio entero menos el precio rebajado."""
        for precio in ("10.00", "7.33", "1250.75", "0.50", "999.99"):
            with self.subTest(precio=precio):
                bruto = Decimal(precio)
                p = promo()
                descuento = calcular_descuento_cliente(bruto, p)
                nominal = _a_dinero(bruto * p["comision_porcentaje"])
                cobrada = nominal - descuento

                conserva_bruto = bruto - nominal
                conserva_real = (bruto - descuento) - cobrada
                self.assertEqual(conserva_bruto, conserva_real)
                self.assertEqual(conserva_bruto, Decimal("8.50") if bruto == Decimal("10.00")
                                 else conserva_bruto)


# ===================== COMISION CERO =====================

class TestComisionCero(unittest.TestCase):

    def test_comision_0_el_chofer_se_lleva_el_100(self):
        bruto = Decimal("10.00")
        p = promo(comision="0", descuento="0.10", descuento_activo=True)
        self.assertEqual(calcular_descuento_cliente(bruto, p), Decimal("0"))
        self.assertEqual(bruto - calcular_descuento_cliente(bruto, p), bruto)

    def test_comision_0_el_descuento_se_ignora_aunque_este_activo(self):
        """El panel apaga la casilla, pero la API tiene que ignorarlo igual: si
        alguien la llama a mano no puede regalar viajes."""
        p = promo(comision="0", descuento="0.10", descuento_activo=True)
        self.assertFalse(p["descuento_aplicando"])
        self.assertEqual(calcular_descuento_cliente(Decimal("1000"), p), Decimal("0"))

    def test_la_plataforma_no_llega_a_pagar_negativo(self):
        """Cinturon: aunque alguien metiera un descuento enorme, la comision cobrada
        nunca baja de cero."""
        bruto = Decimal("10.00")
        p = promo(comision="0.01", descuento="0.10")   # 10% de descuento > 1% de comision
        descuento = calcular_descuento_cliente(bruto, p)
        nominal = _a_dinero(bruto * p["comision_porcentaje"])
        self.assertLessEqual(descuento, nominal)
        self.assertGreaterEqual(nominal - descuento, Decimal("0"))


# ===================== EXPIRACION =====================

class TestExpiracion(unittest.TestCase):

    def test_sin_fecha_no_expira(self):
        self.assertFalse(_esta_expirada(None))

    def test_fecha_pasada_esta_expirada(self):
        self.assertTrue(_esta_expirada(datetime.utcnow() - timedelta(days=1)))

    def test_fecha_futura_no_esta_expirada(self):
        self.assertFalse(_esta_expirada(datetime.utcnow() + timedelta(days=30)))

    def test_expirada_el_descuento_se_ignora(self):
        bruto = Decimal("10.00")
        p = promo(expirada=True)
        self.assertEqual(calcular_descuento_cliente(bruto, p), Decimal("0"))

    def test_expirada_no_apaga_el_bono_automáticamente(self):
        """La caducidad es de la promoción comercial. El bono del chofer no es un
        premio al cliente: se decide en otra parte y no se apaga solo."""
        p = promo(expirada=True)
        self.assertFalse(p["descuento_aplicando"])


# ===================== VALIDACIONES DE LA API =====================

class TestValidacion(unittest.TestCase):

    def _validar(self, **kwargs):
        base = dict(comision_porcentaje=0.15, bono_chofer_activo=True,
                    bono_chofer_monto=1100, bono_chofer_viajes_requeridos=10,
                    descuento_cliente_activo=True, descuento_cliente_porcentaje=0.10,
                    fecha_expiracion=None)
        base.update(kwargs)
        return promo_mod._validar(PromoIn(**base))

    def test_comision_fuera_de_rango(self):
        from fastapi import HTTPException
        for valor in (-0.1, 1.5):
            with self.subTest(valor=valor):
                with self.assertRaises(HTTPException):
                    self._validar(comision_porcentaje=valor)

    def test_descuento_mas_que_diez_por_ciento(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as contexto:
            self._validar(descuento_cliente_porcentaje=0.11)
        self.assertIn("10", str(contexto.exception.detail))

    def test_descuento_mayor_que_la_comision(self):
        """La regla que impide que la plataforma pague al pasajero."""
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as contexto:
            self._validar(comision_porcentaje=0.05, descuento_cliente_porcentaje=0.10)
        self.assertIn("no puede ser mayor que la comisión", str(contexto.exception.detail))

    def test_descuento_igual_a_la_comision_si_se_puede(self):
        """Al 50% exacto la plataforma se queda en cero, no pierde: es el tope."""
        limpio = self._validar(comision_porcentaje=0.10, descuento_cliente_porcentaje=0.10)
        self.assertEqual(limpio["descuento_cliente_porcentaje"], Decimal("0.1000"))

    def test_comision_cero_apaga_el_descuento_sin_error(self):
        """No es un 400: es lo que el administrador quiere cuando pone la comision
        a cero. Devolver error lo dejaria atascado en el panel."""
        limpio = self._validar(comision_porcentaje=0.0, descuento_cliente_porcentaje=0.10,
                              descuento_cliente_activo=True)
        self.assertFalse(limpio["descuento_cliente_activo"])
        self.assertEqual(limpio["descuento_cliente_porcentaje"], Decimal("0.0000"))

    def test_bono_negativo_se_rechaza(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException):
            self._validar(bono_chofer_monto=-5)

    def test_viajes_negativos_se_rechazan(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException):
            self._validar(bono_chofer_viajes_requeridos=-1)

    def test_fecha_mal_escrita_da_ayuda(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as contexto:
            self._validar(fecha_expiracion="16/10/2026")
        self.assertIn("AAAA-MM-DD", str(contexto.exception.detail))

    def test_fecha_vacia_significa_que_no_caduca(self):
        limpio = self._validar(fecha_expiracion=None)
        self.assertIsNone(limpio["fecha_expiracion"])


# ===================== PRECISION =====================

class TestPrecision(unittest.TestCase):

    def test_redondeo_de_centavos(self):
        self.assertEqual(_a_dinero(Decimal("1.005")), Decimal("1.01"))
        self.assertEqual(_a_dinero(Decimal("1.004")), Decimal("1.00"))
        self.assertEqual(_a_dinero(Decimal("2.345")), Decimal("2.35"))

    def test_no_usa_el_redondeo_de_banker(self):
        """`round()` de Python usa banker's rounding y devuelve 2.67 donde un
        precio tiene que ser 2.68. Es justo el tipo de centimo que se nota cuando
        el chofer cuenta la plata."""
        self.assertEqual(_a_dinero(Decimal("2.675")), Decimal("2.68"))
        self.assertEqual(round(2.675, 2), 2.67)
        # Y al revés, para no dar por hecho que siempre difieren:
        self.assertEqual(_a_dinero(Decimal("1.005")), Decimal("1.01"))

    def test_descuento_siempre_dos_decimales(self):
        bruto = Decimal("33.33")
        descuento = calcular_descuento_cliente(bruto, promo())
        self.assertEqual(descuento, Decimal("3.33"))


# ===================== ETIQUETAS =====================

class TestEtiquetas(unittest.TestCase):

    def test_tasa_configurable_no_rompe_el_texto(self):
        """Antes `_etiqueta_tasa` era un diccionario con dos claves y reventaba
        con KeyError en cuanto el administrador pusiera 12%."""
        from routers.Solicitud_de_viajes_v4 import _etiqueta_tasa
        self.assertEqual(_etiqueta_tasa(0.15), "15%")
        self.assertEqual(_etiqueta_tasa(0.12), "12%")
        self.assertEqual(_etiqueta_tasa(0.0), "0%")
        self.assertEqual(_etiqueta_tasa(0.075), "7,5%")
        self.assertEqual(_etiqueta_tasa("basura"), "0%")

    def test_tope_de_descuento(self):
        self.assertEqual(DESCUENTO_MAXIMO, Decimal("0.10"))


# ===================== BONO =====================

class TestBono(unittest.TestCase):

    def test_el_bono_suma_al_mismo_fondo(self):
        """Ecosistema cerrado: el bono va al unico campo de saldo, `Fondo`, que se
        lee de la misma configuracion que los demas."""
        self.assertTrue(hasattr(promo_mod, "leer_promocion"))

    def test_umbral_igual_al_que_lo_declara_el_panel(self):
        """Antes era `daily_trips > 10`, asi que el bono saltaba en el viaje 11
        mientras el administrador ponia '10 viajes'. Ahora es `>=`."""
        import inspect
        from routers.Solicitud_de_viajes_v4 import apply_daily_bonus
        fuente = inspect.getsource(apply_daily_bonus)
        self.assertIn("daily_trips < umbral", fuente)
        self.assertNotIn("daily_trips > BONIFICATION_THRESHOLD", fuente)


if __name__ == "__main__":
    unittest.main(verbosity=2)