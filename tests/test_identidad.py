"""
Pruebas de las reglas de identidad: login por teléfono, teléfono único y saldo
negativo.

    python -m unittest tests.test_identidad -v
"""
import os
import unittest

os.environ["TELEGRAM_BOT_TOKEN"] = "123456:TOKEN-DE-PRUEBA"
os.environ["TELEGRAM_WEBHOOK_SECRET"] = "secreto-de-prueba"
os.environ["TELEGRAM_ADMIN_CHAT_ID"] = "999"

from services.telefono import (LARGO_NACIONAL, buscar_por_telefono,
                               es_telefono_valido, normalizar_telefono, variantes)


class _Cursor:
    def __init__(self, documentos):
        self.documentos = documentos

    def limit(self, cantidad):
        return _Cursor(self.documentos[:cantidad])

    def __iter__(self):
        return iter(self.documentos)

    def __len__(self):
        return len(self.documentos)


class ColeccionFalsa:
    def __init__(self, documentos=None):
        self.documentos = [dict(d) for d in (documentos or [])]
        for i, d in enumerate(self.documentos, start=1):
            d.setdefault("_id", "id%02d" % i)
        self.indices = []

    def create_index(self, campo, **opciones):
        self.indices.append((campo, opciones))

    @staticmethod
    def _proyectar(documento, proyeccion):
        """Respeta la proyeccion. Se importa a proposito porque el bug que este
        archivo sujeta viene de ahi: `{"password": 0}` esconde el hash, y el
        login se lo comia como si fuera una cadena vacia."""
        if not proyeccion:
            return dict(documento)
        copia = dict(documento)
        for campo, valor in proyeccion.items():
            if valor == 0:
                copia.pop(campo, None)
            elif valor == 1:
                copia = {campo: copia[campo]} if campo in copia else {}
        return copia

    def find(self, filtro=None, proyeccion=None):
        salida = []
        for documento in self.documentos:
            if filtro is None or self._casa(documento, filtro):
                salida.append(self._proyectar(documento, proyeccion))
        return _Cursor(salida)

    def find_one(self, filtro=None, proyeccion=None):
        for documento in self.documentos:
            if filtro is None or self._casa(documento, filtro):
                return self._proyectar(documento, proyeccion)
        return None

    @staticmethod
    def _casa(documento, filtro):
        import re as _re
        for campo, esperado in filtro.items():
            valor = documento.get(campo)
            if isinstance(esperado, dict):
                for operador, objetivo in esperado.items():
                    if operador == "$in" and valor not in objetivo:
                        return False
            elif isinstance(esperado, _re.Pattern):
                if not valor or not esperado.search(str(valor)):
                    return False
            elif valor != esperado:
                return False
        return True


# ===================== NORMALIZACION =====================

class TestNormalizar(unittest.TestCase):

    def test_formatos_con_pais(self):
        for crudo in ("+5359295207", "5359295207", "+53 5 9295207", "05359295207"):
            with self.subTest(crudo=crudo):
                self.assertEqual(normalizar_telefono(crudo), "59295207")

    def test_nacional_no_se_toca(self):
        self.assertEqual(normalizar_telefono("59295207"), "59295207")

    def test_no_mutila_un_numero_de_8_que_empieza_por_53(self):
        self.assertEqual(normalizar_telefono("53123456"), "53123456")

    def test_variantes_cubren_los_formatos_guardados(self):
        self.assertEqual(variantes("59295207"),
                         ["59295207", "5359295207", "+5359295207", "05359295207",
                          "53 59295207", "+53 59295207"])

    def test_validez(self):
        self.assertTrue(es_telefono_valido("+53 5 9295207"))
        self.assertFalse(es_telefono_valido("123"))          # corto
        self.assertFalse(es_telefono_valido("00000000"))     # relleno
        self.assertFalse(es_telefono_valido(""))
        self.assertFalse(es_telefono_valido(None))

    def test_relleno_esta_definido(self):
        self.assertEqual(LARGO_NACIONAL, 8)


# ===================== BUSQUEDA =====================

class TestBusqueda(unittest.TestCase):

    def test_encuentra_segun_como_este_escrito(self):
        for guardado in ("59295207", "+5359295207", "53 5 9295207", "(53) 592-952.07"):
            with self.subTest(guardado=guardado):
                col = ColeccionFalsa([{"numero_de_telefono": guardado}])
                hallados = buscar_por_telefono(col, "+53 59295207")
                self.assertEqual(len(hallados), 1)

    def test_no_confunde_con_otro_numero(self):
        col = ColeccionFalsa([{"numero_de_telefono": "59295208"}])
        self.assertEqual(buscar_por_telefono(col, "59295207"), [])

    def test_detecta_duplicados_en_vez_de_devolver_el_primero(self):
        col = ColeccionFalsa([{"numero_de_telefono": "59295207"},
                              {"numero_de_telefono": "+53 59295207"}])
        self.assertEqual(len(buscar_por_telefono(col, "59295207")), 2)

    def test_ignora_rellenos(self):
        col = ColeccionFalsa([{"numero_de_telefono": "00000000"}])
        self.assertEqual(buscar_por_telefono(col, "00000000"), [])

    def test_excluye_un_id_concreto(self):
        col = ColeccionFalsa([{"_id": "a", "numero_de_telefono": "59295207"},
                              {"_id": "b", "numero_de_telefono": "+5359295207"}])
        self.assertEqual(len(buscar_por_telefono(col, "59295207", excluding_id="a")), 1)

    def test_es_la_misma_busqueda_que_usa_el_bot(self):
        """La comparacion normalizada es la unica red real: el indice unico de
        Mongo compara cadenas y no sabe que +53... y 59295207 son el mismo numero."""
        col = ColeccionFalsa([{"numero_de_telefono": "+5359295207"}])
        self.assertEqual(len(buscar_por_telefono(col, "59295207")), 1)


# ===================== SALDO NEGATIVO =====================

class TestSaldoNegativo(unittest.TestCase):

    def setUp(self):
        from bson import ObjectId
        from routers import Solicitud_de_viajes_v4 as viajes
        self.viajes = viajes
        self.original = viajes.chofer_coleccion
        # `_id` tiene que ser un ObjectId de verdad: `to_mongo_id` lanza si no lo
        # es, y `saldo_de_chofer` se traga esa excepcion devolviendo None.
        self.oid = ObjectId()
        self.oid_s = str(self.oid)
        viajes.chofer_coleccion = ColeccionFalsa([{"_id": self.oid, "Fondo": -250.0}])

    def tearDown(self):
        self.viajes.chofer_coleccion = self.original

    def test_lee_el_fondo_en_negativo(self):
        self.assertEqual(self.viajes.saldo_de_chofer(self.oid_s), -250.0)

    def test_lee_el_fondo_tambien_en_la_clave_en_minuscula(self):
        self.viajes.chofer_coleccion = ColeccionFalsa([{"_id": self.oid, "fondo": 10.0}])
        self.assertEqual(self.viajes.saldo_de_chofer(self.oid_s), 10.0)

    def test_fondo_ausente_cuenta_como_cero(self):
        self.viajes.chofer_coleccion = ColeccionFalsa([{"_id": self.oid}])
        self.assertEqual(self.viajes.saldo_de_chofer(self.oid_s), 0.0)

    def test_chofer_inexistente_devuelve_none(self):
        self.assertIsNone(self.viajes.saldo_de_chofer(str(__import__("bson").ObjectId())))

    def test_mongo_caido_devuelve_none_y_no_cero(self):
        """Devolver 0 con la base caida bloquearia a un chofer que si tiene
        fondo. Por eso tiene que ser None y no un numero."""
        class Roto:
            def find_one(self, *a, **k):
                raise ConnectionError("Mongo caido")
        self.viajes.chofer_coleccion = Roto()
        self.assertIsNone(self.viajes.saldo_de_chofer(self.oid_s))

    def test_id_invalido_devuelve_none_y_no_rompe(self):
        self.assertIsNone(self.viajes.saldo_de_chofer("no-es-un-id"))


# ===================== INDICE DE TELEFONO =====================

class TestIndiceTelefono(unittest.TestCase):

    def test_no_se_crea_si_ya_hay_repetidos(self):
        from services import indices
        original = indices.COLECCIONES_TELEFONO
        col = ColeccionFalsa([{"numero_de_telefono": "59295207"},
                              {"numero_de_telefono": "+53 59295207"}])
        indices.COLECCIONES_TELEFONO = {"choferes": col}
        try:
            indices.asegurar_indice_telefono()
        finally:
            indices.COLECCIONES_TELEFONO = original
        # Sin repetidos no habria indice, pero aqui si hay: no debe crearse.
        self.assertEqual(col.indices, [])

    def test_se_crea_unico_si_no_hay_repetidos(self):
        from services import indices
        original = indices.COLECCIONES_TELEFONO
        col = ColeccionFalsa([{"numero_de_telefono": "59295207"},
                              {"numero_de_telefono": "59295208"}])
        indices.COLECCIONES_TELEFONO = {"choferes": col}
        try:
            indices.asegurar_indice_telefono()
        finally:
            indices.COLECCIONES_TELEFONO = original
        self.assertEqual(len(col.indices), 1)
        campo, opciones = col.indices[0]
        self.assertEqual(campo, "numero_de_telefono")
        self.assertTrue(opciones["unique"])


# ===================== LOGIN =====================

class TestLoginRequest(unittest.TestCase):

    def test_detecta_un_telefono(self):
        from routers.CRUD_MONGODB import LoginRequest
        self.assertTrue(LoginRequest(email="59295207", password="x").parece_telefono)
        self.assertTrue(LoginRequest(email="+53 5 9295207", password="x").parece_telefono)

    def test_detecta_un_correo(self):
        from routers.CRUD_MONGODB import LoginRequest
        self.assertFalse(LoginRequest(email="persona@correo.com", password="x").parece_telefono)

    def test_acepta_los_dos_nombres_de_campo(self):
        from routers.CRUD_MONGODB import LoginRequest
        self.assertEqual(LoginRequest(telefono="59295207", password="x").identificador,
                         "59295207")
        self.assertEqual(LoginRequest(email="59295207", password="x").identificador,
                         "59295207")

    def test_sin_identificador_deviene_vacio(self):
        from routers.CRUD_MONGODB import LoginRequest
        self.assertEqual(LoginRequest(password="x").identificador, "")


# ===================== LOGIN CONTRA UNA BASE DE PRUEBA =====================

class TestLoginPorTelefono(unittest.IsolatedAsyncioTestCase):
    """El login por telefono tiene que devolver el documento CON su hash.

    La busqueda por telefono proyecta `{"password": 0}` para que el hash no viaje
    suelto, asi que el login tiene que releer el documento. Si se le pasa tal cual
    lo que devuelve la busqueda, `bcrypt.checkpw` recibe una cadena vacia y
    responde "Invalid salt" en todos los accesos por telefono, sin importar la
    clave: un fallo que parece de contrasena y no lo es.
    """

    def setUp(self):
        import bcrypt
        from routers import CRUD_MONGODB
        self.modulo = CRUD_MONGODB
        self.hash_ = bcrypt.hashpw(b"1234", bcrypt.gensalt()).decode("utf-8")
        self.documento = {"_id": "x", "email": "a@b.com", "numero_de_telefono": "59295207",
                          "password": self.hash_, "Enable": True,
                          "estado_habilitacion": "aprobado"}
        # La coleccion sin proyeccion devuelve el hash; con proyeccion, no.
        self.chofer = ColeccionFalsa([self.documento])
        self.original = self.modulo.chofer_coleccion
        self.modulo.chofer_coleccion = self.chofer
        self.original_cliente = self.modulo.cliente_coleccion
        self.modulo.cliente_coleccion = ColeccionFalsa([])
        self.original_admin = self.modulo.admin_coleccion
        self.modulo.admin_coleccion = ColeccionFalsa([])

    def tearDown(self):
        self.modulo.chofer_coleccion = self.original
        self.modulo.cliente_coleccion = self.original_cliente
        self.modulo.admin_coleccion = self.original_admin

    async def test_entra_con_el_telefono(self):
        r = await self.modulo.login(self.modulo.LoginRequest(email="59295207", password="1234"))
        self.assertIn("access_token", r)

    async def test_entra_igual_con_el_prefijo_del_pais(self):
        for valor in ("+5359295207", "53 5 9295207"):
            with self.subTest(valor=valor):
                r = await self.modulo.login(
                    self.modulo.LoginRequest(email=valor, password="1234"))
                self.assertIn("access_token", r)

    async def test_el_correo_antiguo_ya_no_se_rompe(self):
        r = await self.modulo.login(
            self.modulo.LoginRequest(email="a@b.com", password="1234"))
        self.assertIn("access_token", r)

    async def test_clave_mala_da_401_y_no_un_error_de_bcrypt(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as contexto:
            await self.modulo.login(
                self.modulo.LoginRequest(email="59295207", password="9999"))
        self.assertEqual(contexto.exception.status_code, 401)
        self.assertIn("contraseña", str(contexto.exception.detail))

    async def test_telefono_inexistente_da_401(self):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as contexto:
            await self.modulo.login(
                self.modulo.LoginRequest(email="59299999", password="1234"))
        self.assertEqual(contexto.exception.status_code, 401)


if __name__ == "__main__":
    unittest.main(verbosity=2)