"""
Pruebas del aislamiento por tipo de vehiculo.

La regla: un chofer solo ve y solo puede aceptar viajes del MISMO tipo. Moto con
moto, triciclo con triciclo, basico con basico, confort con confort. Sin
excepciones y sin "casi": el fallo que se tapa aqui es un chofer atado a un viaje
que no puede hacer.

    python -m unittest tests.test_tipo_vehiculo -v
"""
import os
import unittest

os.environ["TELEGRAM_BOT_TOKEN"] = "123456:TOKEN-DE-PRUEBA"
os.environ["TELEGRAM_WEBHOOK_SECRET"] = "secreto-de-prueba"
os.environ["TELEGRAM_ADMIN_CHAT_ID"] = "999"

from services.tipo_vehiculo import (normalizar_tipo_vehiculo,
                                    resolver_tipo_vehiculo, tipos_iguales)

TIPOS = ["basico", "moto", "triciclo", "confort"]


# ===================== NORMALIZACION =====================

class TestNormalizacion(unittest.TestCase):

    def test_tildes_y_espacios(self):
        for crudo in ("basico", "básico", "  Básico  ", "BASICO", "Basico"):
            with self.subTest(crudo=crudo):
                self.assertEqual(normalizar_tipo_vehiculo(crudo), "basico")

    def test_vacio_es_none_no_cadena_vacia(self):
        self.assertIsNone(normalizar_tipo_vehiculo(""))
        self.assertIsNone(normalizar_tipo_vehiculo("   "))
        self.assertIsNone(normalizar_tipo_vehiculo(None))


class TestIgualdadExacta(unittest.TestCase):

    def test_cada_tipo_solo_se_igual_consigo_mismo(self):
        for a in TIPOS:
            for b in TIPOS:
                with self.subTest(a=a, b=b):
                    self.assertEqual(tipos_iguales(a, b), a == b)

    def test_el_reproducido_del_bug(self):
        """Este es exactamente el caso que reporto el usuario: moto no puede ser
        basico, ni al reves, aunque se escriban con distinta capitalizacion."""
        self.assertFalse(tipos_iguales("moto", "basico"))
        self.assertFalse(tipos_iguales("basico", "moto"))
        self.assertFalse(tipos_iguales("Moto", "Basico"))
        self.assertFalse(tipos_iguales("confort", "comfort"))
        self.assertFalse(tipos_iguales("basico", "triciclo"))

    def test_la_tilde_no_corta_la_coincidencia(self):
        """La base guarda 'básico' con tilde y la app escribe 'basico'. Si aqui no
        se normalizara, un chofer basico no veria sus propias ofertas: el mismo
        fallo del lado opuesto."""
        self.assertTrue(tipos_iguales("basico", "básico"))
        self.assertTrue(tipos_iguales("Básico", " basico "))

    def test_desconocidos_no_coinciden(self):
        """Dos nulos no son iguales. No se puede afirmar que coincidan cuando no
        se sabe ninguno de los dos."""
        self.assertFalse(tipos_iguales(None, None))
        self.assertFalse(tipos_iguales("moto", None))
        self.assertFalse(tipos_iguales(None, "moto"))
        self.assertFalse(tipos_iguales("", ""))


# ===================== RESOLUCION DESDE EL DOCUMENTO =====================

class TestResolucion(unittest.TestCase):

    def test_cada_forma_que_usa_el_repo(self):
        casos = [
            ({"type_vehicle": "moto"}, "moto"),
            ({"vehicle_type": "moto"}, "moto"),
            ({"vehicle": {"servicio": "moto"}}, "moto"),
            ({"vehicle": {"type": "moto"}}, "moto"),
            ({"type_vehicle": "Básico"}, "basico"),
            ({"vehicle": {"servicio": " Confort "}}, "confort"),
        ]
        for documento, esperado in casos:
            with self.subTest(documento=documento):
                self.assertEqual(resolver_tipo_vehiculo(documento), esperado)

    def test_gana_el_registro_por_encima_del_legacy(self):
        """`type_vehicle` se prueba primero: es el que escribe el registro con
        fotos, que es el camino real de altas nuevas."""
        documento = {"type_vehicle": "moto", "vehicle_type": "basico",
                     "vehicle": {"servicio": "moto"}}
        self.assertEqual(resolver_tipo_vehiculo(documento), "moto")

    def test_sin_tipo_devuelve_none(self):
        self.assertIsNone(resolver_tipo_vehiculo({"Nombre": "X"}))
        self.assertIsNone(resolver_tipo_vehiculo({}))
        self.assertIsNone(resolver_tipo_vehiculo(None))
        self.assertIsNone(resolver_tipo_vehiculo({"vehicle": "no-es-un-mapa"}))


# ===================== EL CONTRATO CON LA APP =====================

class TestContratoChoferResponse(unittest.TestCase):
    """`GET /chofer/{id}` es de donde la app saca el tipo. Antes llegaba null y por
    eso la app no lo mandaba al sondeo, que a su vez no filtraba."""

    def _respuesta(self, documento):
        from routers.CRUD_MONGODB import ChoferResponse
        return ChoferResponse(**documento)

    def test_registro_con_fotos_llega_como_vehicle_type(self):
        """Este es el camino de un alta real: `type_vehicle` + `vehicle.servicio`."""
        r = self._respuesta({
            "_id": "abc", "Nombre": "A", "Apellidos": "B",
            "type_vehicle": "moto",
            "vehicle": {"Marca": "Honda", "servicio": "moto"},
        })
        self.assertEqual(r.vehicle_type, "moto")
        self.assertEqual(r.type_vehicle, "moto")

    def test_chofer_legacy_con_vehicle_type(self):
        r = self._respuesta({"_id": "abc", "Nombre": "A", "Apellidos": "B",
                             "vehicle_type": "basico"})
        self.assertEqual(r.vehicle_type, "basico")

    def test_solo_vehicle_servicio(self):
        r = self._respuesta({"_id": "abc", "Nombre": "A", "Apellidos": "B",
                             "vehicle": {"Marca": "Lada", "servicio": "triciclo"}})
        self.assertEqual(r.vehicle_type, "triciclo")

    def test_tilde_se_normaliza_en_la_respuesta(self):
        r = self._respuesta({"_id": "abc", "Nombre": "A", "Apellidos": "B",
                             "type_vehicle": "Básico"})
        self.assertEqual(r.vehicle_type, "basico")

    def test_sin_tipo_no_se_inventa(self):
        """Sigue devolviendo null. Inventar un 'basico' seria peor: el chofer
        recibiria ofertas de un vehiculo que no es el suyo."""
        r = self._respuesta({"_id": "abc", "Nombre": "A", "Apellidos": "B"})
        self.assertIsNone(r.vehicle_type)

    def test_serializa_a_json(self):
        r = self._respuesta({"_id": "abc", "Nombre": "A", "Apellidos": "B",
                             "type_vehicle": "moto"})
        self.assertEqual(r.model_dump()["vehicle_type"], "moto")


# ===================== EL FILTRO DEL SONDEO =====================

class TestFalloCerradoDelSondeo(unittest.TestCase):
    """Sin tipo declarado el sondeo NO devuelve ofertas. Antes no devolvia todas
    solo cuando el filtro se aplicaba, y el filtro no se aplicaba nunca porque el
    tipo no llegaba."""

    def test_el_sql_siempre_filtra(self):
        """El `where +=` con el filtro no puede estar dentro de un `if`.

        Se comprueba con el AST y no buscando texto, porque el comentario del
        propio codigo cita el `if tipo_norm:` viejo y una busqueda a pelo lo
        encontraria y daria un falso negativo.
        """
        import ast
        import inspect
        from routers.Solicitud_de_viajes_v4 import get_nearby_requested_trips
        arbol = ast.parse(inspect.getsource(get_nearby_requested_trips))
        funcion = arbol.body[0]

        def donde_esta(nodo, destino):
            """True si `destino` esta DENTRO de un `if` de la funcion."""
            for hijo in ast.iter_child_nodes(nodo):
                if isinstance(hijo, ast.If):
                    for sub in ast.walk(hijo):
                        if isinstance(sub, destino):
                            return True
                    if donde_esta(hijo, destino):
                        return True
                elif donde_esta(hijo, destino):
                    return True
            return False

        filtros = [n for n in ast.walk(funcion)
                   if isinstance(n, ast.AugAssign) and isinstance(n.target, ast.Name)
                   and n.target.id == "where"]
        self.assertTrue(filtros, "no se encontro ningun where += en la funcion")
        for filtro in filtros:
            self.assertFalse(
                donde_esta(funcion, type(filtro)),
                "el filtro de vehicle_type sigue dentro de un if: "
                "si falta el tipo se devolverian todas las ofertas")

    def test_el_filtro_es_igualdad_exacta(self):
        """Igualdad exacta, nunca `LIKE`. Con `LIKE 'moto%'` un chófer de 'moto'
        seguiría viendo ofertas de 'motocicleta', que es justo el tipo de
        colisión que hay que evitar."""
        import inspect
        from routers.Solicitud_de_viajes_v4 import get_nearby_requested_trips
        fuente = inspect.getsource(get_nearby_requested_trips)
        self.assertIn("lower(vehicle_type) = %s", fuente)
        mayusculas = fuente.upper()
        for prohibido in ("VEHICLE_TYPE LIKE", "VEHICLE_TYPE ILIKE",
                          "VEHICLE_TYPE !=", "VEHICLE_TYPE >"):
            self.assertNotIn(prohibido, mayusculas)

    def test_sin_tipo_devuelve_lista_vacia(self):
        from routers.Solicitud_de_viajes_v4 import get_nearby_requested_trips
        # Sin vehicle_type: no debe tocar la base de datos ni devolver nada.
        self.assertEqual(get_nearby_requested_trips(23.1, -82.3, 5, 20, None), [])

    def test_tipo_vacio_tambien_es_fallo_cerrado(self):
        from routers.Solicitud_de_viajes_v4 import get_nearby_requested_trips
        for vacio in ("", "   ", None):
            with self.subTest(valor=vacio):
                self.assertEqual(get_nearby_requested_trips(23.1, -82.3, 5, 20, vacio), [])


# ===================== LA BARRERA DE ACEPTAR =====================

class TestBarreraDeAceptar(unittest.TestCase):
    """Aceptar es el punto sin retorno. Ahi se comprueba el tipo aunque las otras
    dos barreras hayan fallado."""

    def _fuente(self):
        import inspect
        from routers.Solicitud_de_viajes_v4 import api_accept_trip
        return inspect.getsource(api_accept_trip)

    def test_aceptar_comprueba_el_tipo(self):
        fuente = self._fuente()
        self.assertIn("tipo_vehiculo_no_coincide", fuente)
        self.assertIn("_driver_vehicle_type", fuente)

    def test_la_comprobacion_va_antes_del_update(self):
        """Si el UPDATE al viaje ya se ejecuto cuando se comprueba, el chofer ya
        esta atado al viaje y el 400 llega tarde."""
        fuente = self._fuente()
        self.assertLess(fuente.index("tipo_vehiculo_no_coincide"),
                        fuente.index("UPDATE trips SET driver_id"))

    def test_chofer_sin_tipo_no_puede_aceptar(self):
        from routers.Solicitud_de_viajes_v4 import _driver_vehicle_type
        self.assertIsNone(_driver_vehicle_type({"Nombre": "X"}))

    def test_el_push_ya_filter_bien_y_sigue_asi(self):
        """El push por notificacion ya comparaba bien; no se toca, pero se deja
        una prueba para que nadie lo relaje sin darse cuenta."""
        import inspect
        from routers.Solicitud_de_viajes_v4 import offer_trip_to_nearby_drivers
        fuente = inspect.getsource(offer_trip_to_nearby_drivers)
        self.assertIn("_driver_vehicle_type(doc)", fuente)
        self.assertIn("continue", fuente)


if __name__ == "__main__":
    unittest.main(verbosity=2)