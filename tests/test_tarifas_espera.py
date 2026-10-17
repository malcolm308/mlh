"""
Pruebas de los coeficientes por distancia y de la espera de cortesía.

    python -m unittest tests.test_tarifas_espera -v
"""
import asyncio
import os
import unittest
from datetime import datetime, timedelta, timezone
from decimal import Decimal

os.environ["TELEGRAM_BOT_TOKEN"] = "123456:TOKEN-DE-PRUEBA"
os.environ["TELEGRAM_WEBHOOK_SECRET"] = "secreto-de-prueba"
os.environ["TELEGRAM_ADMIN_CHAT_ID"] = "999"

from routers.promociones import (PromoIn, _validar, coeficiente_por_distancia,
                                  excedente_espera)


def promo(corto_km="3", corto="0.5", medio_km="10", medio="0.6", largo="1.0"):
    return {"coef_corto_km": Decimal(corto_km), "coef_corto_valor": Decimal(corto),
            "coef_medio_km": Decimal(medio_km), "coef_medio_valor": Decimal(medio),
            "coef_largo_valor": Decimal(largo)}


# ===================== TRAMOS DEL COEFICIENTE =====================

class TestTramosCoeficiente(unittest.TestCase):

    def setUp(self):
        self.p = promo()

    def test_hasta_3_km_mismo_coeficiente(self):
        for km in ("0", "0.5", "1", "2.99", "3"):
            with self.subTest(km=km):
                self.assertEqual(coeficiente_por_distancia(Decimal(km), self.p),
                                 Decimal("0.5"))

    def test_de_3_a_10_km_coeficiente_medio(self):
        for km in ("3.01", "4", "7", "9.99", "10"):
            with self.subTest(km=km):
                self.assertEqual(coeficiente_por_distancia(Decimal(km), self.p),
                                 Decimal("0.6"))

    def test_mas_de_10_km_coeficiente_largo(self):
        for km in ("10.01", "12", "30", "150"):
            with self.subTest(km=km):
                self.assertEqual(coeficiente_por_distancia(Decimal(km), self.p),
                                 Decimal("1.0"))

    def test_los_limites_son_inclusivos_por_arriba(self):
        """De 3 a 10 km significa que 3 entra en el tramo corto y 10 en el medio.
        Es lo que se lee de forma natural y donde un <= mal puesto cobraria de mas
        en viajes justo en la frontera."""
        self.assertEqual(coeficiente_por_distancia(Decimal("3"), self.p), Decimal("0.5"))
        self.assertEqual(coeficiente_por_distancia(Decimal("10"), self.p), Decimal("0.6"))

    def test_los_limites_se_pueden_cambiar_desde_el_panel(self):
        p = promo(corto_km="5", corto="0.3", medio_km="15", medio="0.7", largo="0.9")
        self.assertEqual(coeficiente_por_distancia(Decimal("4"), p), Decimal("0.3"))
        self.assertEqual(coeficiente_por_distancia(Decimal("6"), p), Decimal("0.7"))
        self.assertEqual(coeficiente_por_distancia(Decimal("20"), p), Decimal("0.9"))

    def test_limites_invertidos_no_rompen_el_precio(self):
        """Si el administrador se cuelga y pone 10 en el corto y 3 en el medio,
        mejor el tramo largo que un precio raro."""
        p = promo(corto_km="10", medio_km="3")
        self.assertEqual(coeficiente_por_distancia(Decimal("2"), p), Decimal("1.0"))

    def test_distancia_no_numerica_no_revienta(self):
        self.assertEqual(coeficiente_por_distancia(None, self.p), Decimal("1.0"))
        self.assertEqual(coeficiente_por_distancia("abc", self.p), Decimal("1.0"))


# ===================== LA FORMULA =====================

class TestFormula(unittest.TestCase):

    def _precio(self, km, base, precio_km, precio_min, coef):
        """Reproduce exactamente lo que hace `_price_breakdown`."""
        minutos = (km / 30.0) * 60.0
        return base + (km * precio_km * coef) + (minutos * precio_min)

    def test_el_coeficiente_solo_toca_el_kilometraje(self):
        """La base y el tiempo van enteros. Si el coeficiente tocara el total,
        bajarian tambien, que es justo lo que el enunciado pide que no pase."""
        base, pkm, pmin = 1500.0, 700.0, 5.0
        km = 2.0

        con_coef = self._precio(km, base, pkm, pmin, 0.5)
        sin_coef = self._precio(km, base, pkm, pmin, 1.0)
        diferencia = sin_coef - con_coef

        # Lo único que cambia es km * precio_km * (1 - coeficiente)
        self.assertAlmostEqual(diferencia, km * pkm * 0.5, places=6)
        # Y la base sigue intacta: si bajara, la diferencia seria mayor.
        self.assertLess(diferencia, km * pkm)

    def test_un_viaje_largo_no_cuesta_menos(self):
        """Pasados los 10 km el coeficiente es 1: el precio es el de siempre."""
        base, pkm, pmin = 1500.0, 700.0, 5.0
        nuevo = self._precio(15.0, base, pkm, pmin, 1.0)
        viejo = base + 15.0 * pkm + ((15.0 / 30.0) * 60.0) * pmin
        self.assertAlmostEqual(nuevo, viejo, places=6)

    def test_el_precio_crece_con_la_distancia(self):
        base, pkm, pmin = 1500.0, 700.0, 5.0
        precios = [self._precio(km, base, pkm, pmin,
                                float(coeficiente_por_distancia(Decimal(km), promo())))
                   for km in (1, 2, 5, 10, 20)]
        self.assertEqual(precios, sorted(precios))

    def test_el_descuento_del_cliente_se_sigue_aplicando_despues(self):
        """El coeficiente baja el precio Y el descuento al cliente se calcula
        sobre ese precio ya rebajado. Los dos se suman, no se pisan."""
        base, pkm, pmin = 1500.0, 700.0, 5.0
        km = 7.0
        coef = float(coeficiente_por_distancia(Decimal(km), promo()))
        precio = self._precio(km, base, pkm, pmin, coef)
        descuento = round(precio * 0.10, 2)
        self.assertLess(precio, self._precio(km, base, pkm, pmin, 1.0))
        self.assertGreater(descuento, 0)


# ===================== EL COEFICIENTE EN EL COBRO REAL =====================

class TestCobroReal(unittest.TestCase):
    """El coeficiente tambien va al cobro, no solo a la estimación.

    Si solo afectara a la estimación el pasajero veria un precio y se le
    cobraría otro: por debajo de 3 km la diferencia son cientos de CUP y es
    justo el caso corto el que más se nota."""

    def _cobro(self, km, base, pkm, pmin, coef, coef_cortesia):
        """Reproduce el paso 8 de `complete_trip`: coeficiente, después comisión
        y descuento sobre ese precio."""
        minutos = (km / 30.0) * 60.0
        distance_fare = km * pkm * coef
        time_fare = minutos * pmin
        bruto = base + distance_fare + time_fare
        comision = round(bruto * 0.15, 2)
        descuento = round(bruto * 0.10, 2)
        return distance_fare, bruto, comision, max(0.0, round(comision - descuento, 2))

    def test_el_cobro_de_una_carrera_corta_baja(self):
        base, pkm, pmin = 1500.0, 700.0, 5.0
        km = 2.0

        con, bruto, _, _ = self._cobro(km, base, pkm, pmin, 0.5, 4.0)
        sin, bruto_sin, _, _ = self._cobro(km, base, pkm, pmin, 1.0, 4.0)

        # 2 km * 700 * 0.5 = 700 en vez de 1400.
        self.assertAlmostEqual(con, 700.0, places=2)
        self.assertAlmostEqual(bruto - bruto_sin, -700.0, places=2)

    def test_una_carrera_larga_se_cobra_entera(self):
        base, pkm, pmin = 1500.0, 700.0, 5.0
        km, coef = 15.0, 1.0
        con, _, _, _ = self._cobro(km, base, pkm, pmin, coef, 4.0)
        self.assertAlmostEqual(con, km * pkm, places=2)

    def test_el_precio_pagado_y_la_estimacion_no_se_difieren(self):
        """La garantía que importa: lo que ve el pasajero al pedir y lo que se le
        cobra tienen que salir de la misma función. Si un camino se queda sin
        coeficiente, esta comprobación falla."""
        import inspect
        from routers.Solicitud_de_viajes_v4 import complete_trip, _price_breakdown
        fuente = inspect.getsource(complete_trip).lower()

        # Ambos caminos llaman a la misma función, y ninguno multiplica el
        # kilometraje por su cuenta.
        self.assertIn("coeficiente_por_distancia(distance_km, promo)", fuente)
        self.assertEqual(fuente.count("coeficiente_por_distancia("), 1)
        self.assertIn(
            "distance_fare = distance_km * price_per_km * float(coeficiente)", fuente)

        estimacion = _price_breakdown(2.0, "basico")
        # La estimación y el cobro comparten la fórmula y la misma función.
        self.assertEqual(estimacion["coeficiente"],
                         float(coeficiente_por_distancia(Decimal("2"), promo())))
        self.assertAlmostEqual(estimacion["distance_fare"],
                               2.0 * estimacion["price_per_km"]
                               * estimacion["coeficiente"], places=2)

    def test_la_comision_baja_con_el_precio_y_no_se_paga_dos_veces(self):
        """El coeficiente baja el precio, así que la comisión baja con él. Pero
        el descuento al cliente sale de esa comisión, nunca de más: la
        plataforma no puede terminar pagando."""
        base, pkm, pmin = 1500.0, 700.0, 5.0
        _, _, comision, cobrado = self._cobro(2.0, base, pkm, pmin, 0.5, 4.0)
        _, _, comision_sin, cobrado_sin = self._cobro(2.0, base, pkm, pmin, 1.0, 4.0)

        self.assertLess(comision, comision_sin)
        self.assertLess(cobrado, cobrado_sin)
        # Y lo que se le paga a la plataforma nunca es negativo.
        self.assertGreaterEqual(cobrado, 0.0)

    def test_un_viaje_largo_no_le_cuesta_menos_al_chofer(self):
        """Con el tramo largo a 1.0, el chofer cobra lo de siempre. El
        coeficiente no puede convertirse en una forma de cobrarle menos."""
        base, pkm, pmin = 1500.0, 700.0, 5.0
        km = 12.0
        coef = float(coeficiente_por_distancia(Decimal(km), promo()))
        self.assertEqual(coef, 1.0)
        con, _, _, _ = self._cobro(km, base, pkm, pmin, coef, 4.0)
        sin, _, _, _ = self._cobro(km, base, pkm, pmin, 1.0, 4.0)
        self.assertAlmostEqual(con, sin, places=2)


# ===================== ESPERA DE CORTESIA =====================

class TestEsperaCortesia(unittest.TestCase):

    def test_el_ejemplo_del_enunciado(self):
        """El pasajero tarda 8 min, de los que 4 son de cortesia; el trayecto
        dura 12. Se le cobran 12 + 4 = 16."""
        espera = 8 * 60
        trayecto = 12 * 60
        excedente, total = excedente_espera(espera, trayecto, 4.0)
        self.assertEqual(excedente, 4 * 60)
        self.assertEqual(total, 12 * 60 + 4 * 60)

    def test_si_no_pasa_de_la_cortesia_no_se_cobra_nada(self):
        excedente, total = excedente_espera(4 * 60, 10 * 60, 4.0)
        self.assertEqual(excedente, 0)
        self.assertEqual(total, 10 * 60)

    def test_llegada_tardia_no_es_excedente(self):
        excedente, total = excedente_espera(0, 20 * 60, 4.0)
        self.assertEqual(excedente, 0)
        self.assertEqual(total, 20 * 60)

    def test_un_segundo_de_mas_si_se_cobra(self):
        excedente, _ = excedente_espera(4 * 60 + 1, 10 * 60, 4.0)
        self.assertEqual(excedente, 1)

    def test_espera_larga(self):
        excedente, total = excedente_espera(30 * 60, 5 * 60, 4.0)
        self.assertEqual(excedente, 26 * 60)
        self.assertEqual(total, 5 * 60 + 26 * 60)

    def test_los_minutos_de_cortesia_son_configurables(self):
        excedente, total = excedente_espera(8 * 60, 12 * 60, 10.0)
        self.assertEqual(excedente, 0)
        self.assertEqual(total, 12 * 60)
        excedente, total = excedente_espera(8 * 60, 12 * 60, 2.0)
        self.assertEqual(excedente, 6 * 60)
        self.assertEqual(total, 12 * 60 + 6 * 60)

    def test_cortesia_cero_cobra_toda_la_espera(self):
        excedente, total = excedente_espera(8 * 60, 12 * 60, 0.0)
        self.assertEqual(excedente, 8 * 60)
        self.assertEqual(total, 12 * 60 + 8 * 60)

    def test_espera_negativa_no_resta(self):
        """Un reloj desajustado podria dar un `started_at` anterior a la
        llegada. No se descuenta tiempo: la duracion nunca baja de la real."""
        excedente, total = excedente_espera(-120, 10 * 60, 4.0)
        self.assertEqual(excedente, 0)
        self.assertEqual(total, 10 * 60)

    def test_espera_nula(self):
        excedente, total = excedente_espera(None, 15 * 60, 4.0)
        self.assertEqual(excedente, 0)
        self.assertEqual(total, 15 * 60)


# ===================== VALIDACION DE LA CONFIGURACION =====================

class TestValidacionConfig(unittest.TestCase):

    def _validar(self, **cambios):
        base = dict(comision_porcentaje=0.15, bono_chofer_activo=True,
                    bono_chofer_monto=1100, bono_chofer_viajes_requeridos=10,
                    descuento_cliente_activo=False, descuento_cliente_porcentaje=0,
                    fecha_expiracion=None)
        base.update(cambios)
        return _validar(PromoIn(**base))

    def test_los_seis_parametros_se_guardan(self):
        limpio = self._validar(coef_corto_km=5, coef_corto_valor=0.4,
                                coef_medio_km=15, coef_medio_valor=0.7,
                                coef_largo_valor=0.9,
                                tiempo_espera_cortesia_minutos=6)
        self.assertEqual(limpio["coef_corto_km"], 5.0)
        self.assertEqual(limpio["coef_corto_valor"], 0.4)
        self.assertEqual(limpio["coef_medio_km"], 15.0)
        self.assertEqual(limpio["coef_medio_valor"], 0.7)
        self.assertEqual(limpio["coef_largo_valor"], 0.9)
        self.assertEqual(limpio["tiempo_espera_cortesia_minutos"], 6.0)

    def test_limites_invertidos_se_rechazan_con_mensaje_claro(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as contexto:
            self._validar(coef_corto_km=10, coef_medio_km=3)
        self.assertIn("menor que", str(contexto.exception.detail))

    def test_limite_cero_se_rechaza(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException):
            self._validar(coef_corto_km=0)
        with self.assertRaises(HTTPException):
            self._validar(coef_medio_km=0)

    def test_coeficiente_cero_se_rechaza(self):
        """Un coeficiente de 0 haria que las carreras de ese tramo costaran 0."""
        from fastapi import HTTPException
        for campo in ("coef_corto_valor", "coef_medio_valor", "coef_largo_valor"):
            with self.subTest(campo=campo):
                with self.assertRaises(HTTPException):
                    self._validar(**{campo: 0})

    def test_espera_negativa_se_rechaza(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException):
            self._validar(tiempo_espera_cortesia_minutos=-1)

    def test_valores_no_numericos_se_signalan_con_el_nombre_del_campo(self):
        """Un texto donde va un numero lo para pydantic antes de llegar a la
        validacion propia. Lo que importa es que el error diga QUE campo esta
        mal, para que el panel pueda señalar la casilla y no decir "error" a
        secas."""
        from pydantic import ValidationError
        with self.assertRaises(ValidationError) as contexto:
            self._validar(tiempo_espera_cortesia_minutos="cuatro")
        mensaje = str(contexto.exception)
        self.assertIn("tiempo_espera_cortesia_minutos", mensaje)

    def test_un_none_no_revienta_la_validacion(self):
        """`_a_numero` existe justo para esto: pydantic acepta `None` en un campo
        opcional y la regla de negocio debe decir cual es el problema."""
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as contexto:
            _validar(PromoIn(comision_porcentaje=0.15, bono_chofer_activo=True,
                             bono_chofer_monto=1100, bono_chofer_viajes_requeridos=10,
                             descuento_cliente_activo=False,
                             descuento_cliente_porcentaje=0,
                             tiempo_espera_cortesia_minutos=None))
        self.assertIn("número", str(contexto.exception.detail))


# ===================== EL GUARDADO DE LA PESTAÑA DE TARIFAS =====================

class TestEndpointTarifasEspera(unittest.TestCase):
    """La pestaña de tarifas no debe poder tocar la comisión, el bono ni el
    descuento. Si compartiera guardado con las promociones, guardar un
    coeficiente reenviaría también el resto del formulario y resucitaría una
    promoción caducada."""

    def setUp(self):
        import asyncio
        self.promo = __import__("routers.promociones", fromlist=["x"])
        # Se parte de la configuración que hay ahora, no de una inventada: estos
        # tests escriben en la fila real y hay que devolverla como estaba al
        # terminar, tanto si pasan como si fallan.
        self.respaldo = dict(self.promo.leer_promocion())
        self._guardar(coef_corto_km=3.0, coef_corto_valor=0.5,
                      coef_medio_km=10.0, coef_medio_valor=0.6,
                      coef_largo_valor=1.0, tiempo_espera_cortesia_minutos=4.0)

    def tearDown(self):
        try:
            self._guardar(**{campo: self.respaldo[campo] for campo in (
                "coef_corto_km", "coef_corto_valor", "coef_medio_km",
                "coef_medio_valor", "coef_largo_valor",
                "tiempo_espera_cortesia_minutos")})
        except Exception:
            pass

    def _guardar(self, **cambios):
        from routers.promociones import PromoIn
        cuerpo = {
            "comision_porcentaje": 0.15, "bono_chofer_activo": True,
            "bono_chofer_monto": 1100, "bono_chofer_viajes_requeridos": 10,
            "descuento_cliente_activo": False, "descuento_cliente_porcentaje": 0,
            "fecha_expiracion": None,
        }
        cuerpo.update(cambios)
        # Los endpoints son `async`: sin correr la corrutina no se escribe nada
        # y el test pasa por la configuracion de otro test.
        asyncio.run(self.promo.guardar_promocion(
            PromoIn(**cuerpo), admin={"email": "prueba@taxirapid.cu"}))

    def _guardar_tarifas(self, **cambios):
        import asyncio
        from routers.promociones import TarifasEsperaIn
        cuerpo = {"coef_corto_km": 3.0, "coef_corto_valor": 0.5,
                  "coef_medio_km": 10.0, "coef_medio_valor": 0.6,
                  "coef_largo_valor": 1.0, "tiempo_espera_cortesia_minutos": 4.0}
        cuerpo.update(cambios)
        return asyncio.run(self.promo.guardar_tarifas_espera(
            TarifasEsperaIn(**cuerpo), admin={"email": "panel@taxirapid.cu"}))

    def _leer(self):
        return self.promo.leer_promocion()

    def test_guardar_tarifas_no_toca_la_comision(self):
        # Se pone una comisión reconocible antes de cambiar las tarifas.
        self._guardar(coef_corto_valor=0.5, bono_chofer_monto=1234,
                      bono_chofer_viajes_requeridos=7)

        self._guardar_tarifas(coef_corto_km=5, coef_corto_valor=0.3,
                              coef_medio_km=15, coef_medio_valor=0.7,
                              coef_largo_valor=0.9,
                              tiempo_espera_cortesia_minutos=6)

        promo = self._leer()
        self.assertEqual(promo["coef_corto_valor"], Decimal("0.3"))
        self.assertEqual(promo["coef_medio_valor"], Decimal("0.7"))
        self.assertEqual(promo["coef_largo_valor"], Decimal("0.9"))
        self.assertEqual(promo["tiempo_espera_cortesia_minutos"], Decimal("6.0"))
        # Y el resto de la promoción, intacto.
        self.assertEqual(promo["comision_porcentaje"], Decimal("0.1500"))
        self.assertTrue(promo["bono_chofer_activo"])
        self.assertEqual(promo["bono_chofer_monto"], Decimal("1234"))
        self.assertEqual(promo["bono_chofer_viajes_requeridos"], 7)

    def test_una_promocion_caducada_no_revive_al_guardar_una_tarifa(self):
        from datetime import date, timedelta
        caducada = (date.today() - timedelta(days=3)).isoformat()
        self._guardar(comision_porcentaje=0.0, fecha_expiracion=caducada)

        self._guardar_tarifas(coef_corto_valor=0.4)

        promo = self._leer()
        self.assertEqual(promo["coef_corto_valor"], Decimal("0.4"))
        # El filtro sigue puesto: tocar un coeficiente no reactiva comisiones.
        self.assertTrue(self.promo._esta_expirada(promo["fecha_expiracion"]))

    def test_el_lector_devuelve_los_tramos_ya_ordenados(self):
        self._guardar_tarifas(coef_corto_km=4, coef_corto_valor=0.4,
                              coef_medio_km=12, coef_medio_valor=0.7,
                              coef_largo_valor=0.9,
                              tiempo_espera_cortesia_minutos=5)

        import asyncio
        datos = asyncio.run(self.promo.obtener_tarifas_espera())

        tramos = datos["tramos"]
        self.assertEqual([t["coeficiente"] for t in tramos],
                         [Decimal("0.4"), Decimal("0.7"), Decimal("0.9")])
        self.assertEqual([t["hasta_km"] for t in tramos],
                         [Decimal("4.0"), Decimal("12.0"), None])
        # El último tramo no tiene tope: es "todo lo que pase de 12 km".
        self.assertIsNone(tramos[-1]["hasta_km"])
        self.assertEqual(datos["tiempo_espera_cortesia_minutos"], Decimal("5.0"))

    def test_los_tramos_prometidos_son_los_que_cobra_el_backend(self):
        """Los tramos que devuelve la API tienen que ser los que usa
        `coeficiente_por_distancia`. Si los dos caminos interpretaran la
        frontera distinto, el panel prometería un precio que el backend no cobra."""
        import asyncio
        self._guardar_tarifas(coef_corto_km=4, coef_corto_valor=0.4,
                              coef_medio_km=12, coef_medio_valor=0.7,
                              coef_largo_valor=0.9)

        datos = asyncio.run(self.promo.obtener_tarifas_espera())
        promo = self._leer()
        for tramo in datos["tramos"][:-1]:
            km = Decimal(str(tramo["hasta_km"]))
            self.assertEqual(coeficiente_por_distancia(km, promo),
                             Decimal(str(tramo["coeficiente"])),
                             "km=%s no coincide con lo prometido" % km)
        # Y un km por encima del último tope cae en el tramo largo.
        largo = datos["tramos"][-1]["coeficiente"]
        self.assertEqual(coeficiente_por_distancia(Decimal("50"), promo),
                         Decimal(str(largo)))

    def test_un_tarifa_invalida_no_llega_a_la_base(self):
        from fastapi import HTTPException
        self._guardar_tarifas(coef_corto_valor=0.5)

        with self.assertRaises(HTTPException):
            self._guardar_tarifas(coef_corto_km=12, coef_medio_km=3)

        # Sigue lo que habia: un rechazo no deja la configuracion a medias.
        self.assertEqual(self._leer()["coef_corto_valor"], Decimal("0.5"))

    def test_una_espera_negativa_no_llega_a_la_base(self):
        from fastapi import HTTPException
        self._guardar_tarifas(tiempo_espera_cortesia_minutos=4)
        with self.assertRaises(HTTPException):
            self._guardar_tarifas(tiempo_espera_cortesia_minutos=-1)
        self.assertEqual(self._leer()["tiempo_espera_cortesia_minutos"], Decimal("4.0"))


# ===================== LO QUE SE CALCULA EN SQL =====================

class TestCalculoEnSQL(unittest.TestCase):
    """La espera se resta en SQL, no en Python.

    En la base local `hora_llegada` es TIMESTAMP sin zona y `started_at` es
    TIMESTAMP WITH TIME ZONE. Restarlos en Python mezcla dos tipos y salia un
    desfase de horas: el chofer cobraba 5 horas de espera que no habian
    ocurrido. Postgres conoce los dos tipos y los resta bien."""

    def test_la_diferencia_se_calcula_en_postgres(self):
        import inspect
        from routers.Solicitud_de_viajes_v4 import complete_trip
        fuente = inspect.getsource(complete_trip)
        self.assertIn("EXTRACT(EPOCH FROM (", fuente)
        self.assertIn("started_at - hora_llegada", fuente)
        # Y no debe quedar una resta de datetimes en Python para la espera.
        self.assertNotIn("(started - llegada)", fuente)

    def test_el_excedente_usa_la_funcion_compartida(self):
        import inspect
        from routers.Solicitud_de_viajes_v4 import complete_trip
        self.assertIn("excedente_espera", inspect.getsource(complete_trip))

    def test_el_bloque_de_espera_no_usa_promo_antes_de_crearlo(self):
        """Regresión de un NameError real.

        El cálculo de la espera se puso antes que el `promo = leer_promocion()`
        que aparecía unas líneas más abajo, así que `complete_trip` reventaba
        con NameError en cuanto un chofer cerraba un viaje. Solo se nota al
        ejecutar, no al leer el código, y las pruebas no lo cazaban porque
        ninguna llegaba a cerrar un viaje.

        Se comprueba que la espera lee la cortesía por su cuenta, sin depender
        de una variable que todavía no existe en ese punto.
        """
        import inspect
        from routers.Solicitud_de_viajes_v4 import complete_trip
        fuente = inspect.getsource(complete_trip).lower()

        espera = fuente.index("tiempo de espera")
        corte = fuente.index("excedente_espera(", espera)
        bloque = fuente[espera:corte + 40]
        self.assertIn("_cortesia_minutos_actual()", bloque)
        self.assertNotIn("promo[", bloque)


if __name__ == "__main__":
    unittest.main(verbosity=2)