"""
Pruebas del bot de Telegram.

No necesitan Mongo, Redis ni internet: la coleccion de choferes y el cliente de
Telegram se sustituyen por dobles de prueba, y Redis se sustituye por uno que
siempre falla para que el bot caiga en su respaldo en memoria.

    python -m unittest tests.test_telegram_webhook -v
"""
import json
import os
import re
import unittest
from datetime import datetime
from typing import Any, Dict, List, Optional

os.environ["TELEGRAM_BOT_TOKEN"] = "123456:TOKEN-DE-PRUEBA"
os.environ["TELEGRAM_WEBHOOK_SECRET"] = "secreto-de-prueba"
os.environ["TELEGRAM_ADMIN_CHAT_ID"] = "999"

import routers.telegram_webhook as bot  # noqa: E402


class RedisFalsa:
    """Falla siempre. Asi el bot usa su respaldo en memoria y las pruebas no
    dependen de que haya un Garnet encendido ni tardan segundos en cada intento."""

    def get(self, *args, **kwargs):
        raise ConnectionError("sin Redis en las pruebas")

    def setex(self, *args, **kwargs):
        raise ConnectionError("sin Redis en las pruebas")

    def delete(self, *args, **kwargs):
        raise ConnectionError("sin Redis en las pruebas")

    def lpush(self, *args, **kwargs):
        raise ConnectionError("sin Redis en las pruebas")

    def ltrim(self, *args, **kwargs):
        raise ConnectionError("sin Redis en las pruebas")

    def lrange(self, *args, **kwargs):
        raise ConnectionError("sin Redis en las pruebas")


bot.garnet_client = RedisFalsa()


# ===================== DOBLES DE PRUEBA =====================

class ResultadoUpdate:
    def __init__(self, modified_count: int):
        self.modified_count = modified_count


def _coincide(documento: Dict[str, Any], filtro: Optional[dict]) -> bool:
    """Comparador minimo: suficientes para los filtros que usa el bot."""
    for campo, esperado in (filtro or {}).items():
        valor = documento.get(campo)
        if isinstance(esperado, dict):
            for operador, objetivo in esperado.items():
                if operador == "$in":
                    if valor not in objetivo:
                        return False
                elif operador == "$ne":
                    if valor == objetivo:
                        return False
                else:
                    raise AssertionError("Operador no soportado: %s" % operador)
        elif isinstance(esperado, re.Pattern):
            if not valor or not esperado.search(str(valor)):
                return False
        elif valor != esperado:
            return False
    return True


class _Cursor:
    """Lo que el bot hace con el resultado de un `find`: recorrerlo y limitarlo."""

    def __init__(self, documentos):
        self.documentos = documentos

    def limit(self, cantidad):
        return _Cursor(self.documentos[:cantidad])

    def __iter__(self):
        return iter(self.documentos)

    def __len__(self):
        return len(self.documentos)


class ColeccionFalsa:
    """Lo justo de la API de pymongo que usa el bot."""

    def __init__(self, documentos: Optional[List[dict]] = None):
        self.documentos = [dict(d) for d in (documentos or [])]
        for indice, documento in enumerate(self.documentos, start=1):
            documento.setdefault("_id", "id%02d" % indice)
        self.indices = []

    def create_index(self, campo, **opciones):
        self.indices.append((campo, opciones))
        return "telegram_chat_id_unico"

    def find(self, filtro=None, proyeccion=None):
        return _Cursor([dict(d) for d in self.documentos if _coincide(d, filtro)])

    def find_one(self, filtro=None, proyeccion=None):
        for documento in self.documentos:
            if _coincide(documento, filtro):
                return dict(documento)
        return None

    def update_one(self, filtro, cambio):
        for documento in self.documentos:
            if _coincide(documento, filtro):
                if "$set" in cambio:
                    documento.update(cambio["$set"])
                if "$unset" in cambio:
                    for campo in cambio["$unset"]:
                        documento.pop(campo, None)
                return ResultadoUpdate(1)
        return ResultadoUpdate(0)

    def por_id(self, id_: str) -> Dict[str, Any]:
        for documento in self.documentos:
            if str(documento["_id"]) == str(id_):
                return documento
        raise AssertionError("No existe el chofer %s" % id_)


class TelegramFalsa(bot.Telegram):
    """Captura las llamadas a la API en vez de salir a internet."""

    def __init__(self):
        super().__init__("TOKEN-DE-PRUEBA")
        self.llamadas: List[tuple] = []

    async def _llamar(self, metodo: str, **params):
        self.llamadas.append((metodo, params))
        return {}

    def textos(self) -> List[str]:
        return [p.get("text", "") for metodo, p in self.llamadas if metodo == "sendMessage"]

    def ultimo(self) -> str:
        textos = self.textos()
        return textos[-1] if textos else ""

    def metodos(self) -> List[str]:
        return [metodo for metodo, _ in self.llamadas]


def chofer_de_prueba(telefono: str, **extra) -> dict:
    documento = {"Nombre": "Carlos", "Apellidos": "Perez", "email": "c@e.com",
                 "numero_de_telefono": telefono, "estado_habilitacion": "aprobado"}
    documento.update(extra)
    return documento


# ===================== TELEFONO =====================

class TestNormalizarTelefono(unittest.TestCase):

    def test_quita_prefijo_de_cuba_en_todos_los_formatos(self):
        for crudo in ("+5359295207", "5359295207", "+53 5 9295207", "+53-5-9295207"):
            with self.subTest(crudo=crudo):
                self.assertEqual(bot.normalizar_telefono(crudo), "59295207")

    def test_deja_el_numero_nacional_si_ya_lo_esta(self):
        self.assertEqual(bot.normalizar_telefono("59295207"), "59295207")
        self.assertEqual(bot.normalizar_telefono(" 59295207 "), "59295207")

    def test_no_mutila_un_fijo_de_ocho_digitos(self):
        # Un fijo que empiece por 53 tiene 8 digitos: no lleva pais delante.
        self.assertEqual(bot.normalizar_telefono("53123456"), "53123456")

    def test_tolera_el_cero_antes_del_pais(self):
        self.assertEqual(bot.normalizar_telefono("05359295207"), "59295207")

    def test_sin_digitos_devuelve_vacio(self):
        self.assertEqual(bot.normalizar_telefono(""), "")
        self.assertEqual(bot.normalizar_telefono(None), "")


# ===================== VINCULACION =====================

class TestVincular(unittest.IsolatedAsyncioTestCase):

    def preparar(self, documentos):
        self.coleccion = ColeccionFalsa(documentos)
        self.original = bot._coleccion
        bot._coleccion = lambda: self.coleccion
        bot._MEMORIA.clear()
        self.telegram = TelegramFalsa()

    def restaurar(self):
        bot._coleccion = self.original
        bot._MEMORIA.clear()

    async def test_caso_a_chofer_nuevo_se_vincula(self):
        self.preparar([chofer_de_prueba("59295207")])

        await bot._procesar_contacto(self.telegram, 987654, {"phone_number": "+5359295207",
                                                            "user_id": 987654},
                                    987654, "carlosp")

        documento = self.coleccion.documentos[0]
        self.assertEqual(documento["telegram_chat_id"], 987654)
        self.assertEqual(documento["telegram_username"], "carlosp")
        self.assertIsInstance(documento["telegram_registered_at"], datetime)
        self.assertIn("Bienvenido", self.telegram.ultimo())
        self.assertIn("Carlos Perez", self.telegram.ultimo())
        self.restaurar()

    async def test_caso_a_normaliza_el_telefono_al_vincular(self):
        # Estaba guardado con el prefijo; se deja en la forma normalizada.
        self.preparar([chofer_de_prueba("+53 5 9295207")])

        await bot._procesar_contacto(self.telegram, 111, {"phone_number": "59295207",
                                                          "user_id": 111}, 111, None)

        self.assertEqual(self.coleccion.documentos[0]["numero_de_telefono"], "59295207")
        self.restaurar()

    async def test_caso_a_encuentra_formatos_raros(self):
        # Separadores raros: lo encuentra por el busqueda de respaldo.
        self.preparar([chofer_de_prueba("(53) 592-952.07")])

        await bot._procesar_contacto(self.telegram, 222, {"phone_number": "+5359295207",
                                                          "user_id": 222}, 222, None)

        self.assertEqual(self.coleccion.documentos[0]["telegram_chat_id"], 222)
        self.assertEqual(self.coleccion.documentos[0]["numero_de_telefono"], "59295207")
        self.restaurar()

    async def test_caso_b_ya_vinculado_en_el_mismo_chat(self):
        self.preparar([chofer_de_prueba("59295207", telegram_chat_id=555)])

        await bot._procesar_contacto(self.telegram, 555, {"phone_number": "59295207",
                                                          "user_id": 555}, 555, None)

        self.assertIn("Ya estas vinculado", self.telegram.ultimo())
        self.restaurar()

    async def test_caso_c_vinculado_en_otro_chat_rechaza_y_avisa(self):
        self.preparar([chofer_de_prueba("59295207", telegram_chat_id=111)])

        await bot._procesar_contacto(self.telegram, 222, {"phone_number": "59295207",
                                                          "user_id": 222}, 222, None)

        # No se toca el documento...
        self.assertEqual(self.coleccion.documentos[0]["telegram_chat_id"], 111)
        # ...y se le avisa al administrador (999 es TELEGRAM_ADMIN_CHAT_ID).
        avisos_al_admin = [p for m, p in self.telegram.llamadas
                           if m == "sendMessage" and p["chat_id"] == 999]
        self.assertTrue(avisos_al_admin, "no se aviso al administrador")
        self.assertIn("duplicado", avisos_al_admin[0]["text"])
        self.assertIn("otra cuenta", self.telegram.textos()[0])
        self.restaurar()

    async def test_caso_d_numero_inexistente_manda_al_soporte(self):
        self.preparar([chofer_de_prueba("59295207")])

        await bot._procesar_contacto(self.telegram, 333, {"phone_number": "+5355555555",
                                                          "user_id": 333}, 333, None)

        self.assertIn("No encontramos tu numero", self.telegram.textos()[0])
        self.assertIn("soporte", self.telegram.textos()[0])
        self.assertNotIn("telegram_chat_id", self.coleccion.documentos[0])
        self.restaurar()

    async def test_caso_e_numero_de_otra_persona_se_rechaza(self):
        self.preparar([chofer_de_prueba("59295207")])

        await bot._procesar_contacto(self.telegram, 444,
                                     {"phone_number": "59295207", "user_id": 999999},
                                     444, None)

        self.assertIn("TU PROPIO numero", self.telegram.textos()[0])
        self.assertNotIn("telegram_chat_id", self.coleccion.documentos[0])
        self.restaurar()

    async def test_numero_repetido_no_vincula_a_nadie(self):
        self.preparar([chofer_de_prueba("59295207"),
                       chofer_de_prueba("+53 59295207", email="otro@e.com")])

        await bot._procesar_contacto(self.telegram, 555, {"phone_number": "59295207",
                                                          "user_id": 555}, 555, None)

        for documento in self.coleccion.documentos:
            self.assertNotIn("telegram_chat_id", documento)
        avisos = [p for m, p in self.telegram.llamadas
                  if m == "sendMessage" and p["chat_id"] == 999]
        self.assertTrue(avisos, "no se aviso del numero repetido")
        self.restaurar()

    async def test_telefono_de_relleno_se_rechaza(self):
        self.preparar([chofer_de_prueba("00000000")])

        await bot._procesar_contacto(self.telegram, 666, {"phone_number": "00000000",
                                                          "user_id": 666}, 666, None)

        self.assertIn("no es valido", self.telegram.textos()[0])
        self.assertNotIn("telegram_chat_id", self.coleccion.documentos[0])
        self.restaurar()

    async def test_chofer_rechazado_no_se_vincula(self):
        self.preparar([chofer_de_prueba("59295207", estado_habilitacion="rechazado")])

        await bot._procesar_contacto(self.telegram, 777, {"phone_number": "59295207",
                                                          "user_id": 777}, 777, None)

        self.assertIn("rechazada", self.telegram.textos()[0])
        self.assertNotIn("telegram_chat_id", self.coleccion.documentos[0])
        self.restaurar()

    async def test_chofer_pendiente_se_vincula_con_aviso(self):
        self.preparar([chofer_de_prueba("59295207", estado_habilitacion="pendiente")])

        await bot._procesar_contacto(self.telegram, 888, {"phone_number": "59295207",
                                                          "user_id": 888}, 888, None)

        self.assertEqual(self.coleccion.documentos[0]["telegram_chat_id"], 888)
        self.assertIn("pendiente", self.telegram.textos()[0])
        self.restaurar()

    async def test_el_boton_pide_el_contacto_nativo(self):
        self.preparar([])
        await self.telegram.teclado_boton_compartir(987654)

        teclado = json.loads(self.telegram.llamadas[0][1]["reply_markup"])
        boton = teclado["keyboard"][0][0]
        self.assertTrue(boton["request_contact"])
        self.assertTrue(teclado["one_time_keyboard"])
        self.assertTrue(teclado["resize_keyboard"])
        self.restaurar()


# ===================== DESVINCULAR =====================

class TestDesvincular(unittest.IsolatedAsyncioTestCase):

    def setUp(self):
        self.coleccion = ColeccionFalsa([
            chofer_de_prueba("59295207", telegram_chat_id=111,
                             telegram_username="carlosp",
                             telegram_registered_at=datetime.utcnow())])
        self.original = bot._coleccion
        bot._coleccion = lambda: self.coleccion
        bot._MEMORIA.clear()
        self.telegram = TelegramFalsa()

    def tearDown(self):
        bot._coleccion = self.original
        bot._MEMORIA.clear()

    async def test_desvincula_y_limpia_los_tres_campos(self):
        await bot._cmd_desvincular(self.telegram, 999, "59295207")

        documento = self.coleccion.documentos[0]
        self.assertNotIn("telegram_chat_id", documento)
        self.assertNotIn("telegram_username", documento)
        self.assertNotIn("telegram_registered_at", documento)
        self.assertIn("Desvinculado", self.telegram.ultimo())

    async def test_no_encuentra_el_numero(self):
        await bot._cmd_desvincular(self.telegram, 999, "55555555")
        self.assertIn("No se encontro", self.telegram.ultimo())

    async def test_exige_argumento(self):
        await bot._cmd_desvincular(self.telegram, 999, "")
        self.assertIn("Uso", self.telegram.ultimo())


# ===================== INDICE =====================

class TestIndice(unittest.TestCase):

    def test_se_crea_unico_y_disperso(self):
        coleccion = ColeccionFalsa([])
        original = bot._coleccion
        bot._coleccion = lambda: coleccion
        try:
            bot.asegurar_indice_telegram()
        finally:
            bot._coleccion = original

        self.assertEqual(len(coleccion.indices), 1)
        campo, opciones = coleccion.indices[0]
        self.assertEqual(campo, "telegram_chat_id")
        self.assertTrue(opciones["unique"])
        self.assertTrue(opciones["sparse"])

    def test_un_indice_que_falla_no_tumba_el_arranque(self):
        class ColeccionQueFalla(ColeccionFalsa):
            def create_index(self, campo, **opciones):
                raise RuntimeError("ya hay duplicados")

        original = bot._coleccion
        bot._coleccion = lambda: ColeccionQueFalla([])
        try:
            bot.asegurar_indice_telegram()   # no debe lanzar
        finally:
            bot._coleccion = original


# ===================== WEBHOOK =====================

class TestWebhook(unittest.TestCase):

    def test_sin_configuracion_devuelve_503(self):
        os.environ.pop("TELEGRAM_BOT_TOKEN", None)
        os.environ.pop("TELEGRAM_WEBHOOK_SECRET", None)
        try:
            respuesta = self._cliente().post("/webhook/123456:TOKEN-DE-PRUEBA", json={})
            self.assertEqual(respuesta.status_code, 503)
        finally:
            os.environ["TELEGRAM_BOT_TOKEN"] = "123456:TOKEN-DE-PRUEBA"
            os.environ["TELEGRAM_WEBHOOK_SECRET"] = "secreto-de-prueba"

    def _cliente(self):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        app = FastAPI()
        app.include_router(bot.router)
        return TestClient(app)

    def test_token_de_ruta_invalido_da_404(self):
        respuesta = self._cliente().post(
            "/webhook/token-equivocado",
            headers={"X-Telegram-Bot-Api-Secret-Token": "secreto-de-prueba"}, json={})
        self.assertEqual(respuesta.status_code, 404)

    def test_cabecera_secreta_invalida_da_403(self):
        respuesta = self._cliente().post(
            "/webhook/123456:TOKEN-DE-PRUEBA",
            headers={"X-Telegram-Bot-Api-Secret-Token": "charlando"}, json={})
        self.assertEqual(respuesta.status_code, 403)

    def test_sin_cabecera_da_403(self):
        respuesta = self._cliente().post("/webhook/123456:TOKEN-DE-PRUEBA", json={})
        self.assertEqual(respuesta.status_code, 403)

    def test_token_y_cabecera_correctos_da_200(self):
        respuesta = self._cliente().post(
            "/webhook/123456:TOKEN-DE-PRUEBA",
            headers={"X-Telegram-Bot-Api-Secret-Token": "secreto-de-prueba"},
            json={"update_id": 1})
        self.assertEqual(respuesta.status_code, 200)
        self.assertEqual(respuesta.json(), {"ok": True})

    def test_cuerpo_no_json_da_400(self):
        respuesta = self._cliente().post(
            "/webhook/123456:TOKEN-DE-PRUEBA",
            headers={"X-Telegram-Bot-Api-Secret-Token": "secreto-de-prueba"},
            content=b"esto no es json")
        self.assertEqual(respuesta.status_code, 400)

    def test_el_diagnostico_no_filtra_secretos(self):
        respuesta = self._cliente().get("/telegram/status")
        self.assertEqual(respuesta.status_code, 200)
        cuerpo = respuesta.text
        self.assertNotIn("TOKEN-DE-PRUEBA", cuerpo)
        self.assertNotIn("secreto-de-prueba", cuerpo)
        self.assertIn("tope_por_pasada_automatica", cuerpo)


if __name__ == "__main__":
    unittest.main(verbosity=2)