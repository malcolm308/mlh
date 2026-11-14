"""
Pruebas HTTP de los endpoints de avisos del panel web.

`GET /admin/eventos` es el que consulta el vigilante JavaScript del panel cada
15 s; `POST /admin/eventos/prueba` es el botón «Probar aviso». Se cubren tres
cosas que fallaron o podrían fallar en silencio:

* el puntero `desde` (sin él, abrir el panel no debe disparar avisos viejos);
* el filtro por rol (un operador de registros no ve viajes y viceversa);
* CORS con `Authorization`, porque el panel vive en otro origen que la API.

Se monta solo el router en una app de prueba y se sustituye la dependencia de
autenticación; no se toca Mongo real (se usa la colección falsa de
`tests.test_eventos_admin`).

    python -m unittest tests.test_eventos_api -v
"""
import unittest

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.testclient import TestClient

from routers import admin_panel, admin_web
from services import eventos_admin
from tests.test_eventos_admin import FakeColeccion


class BaseApi(unittest.TestCase):

    def setUp(self):
        self.fake = FakeColeccion()
        self._coleccion = eventos_admin.coleccion
        self._indice = eventos_admin._indice_listo
        eventos_admin.coleccion = self.fake
        eventos_admin._indice_listo = True
        with eventos_admin._lock:
            eventos_admin._memoria.clear()

        self.rol = "super_admin"
        app = FastAPI()
        app.add_middleware(
            CORSMiddleware,
            allow_origins=["*"],
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )
        app.include_router(admin_web.router)
        app.dependency_overrides[admin_panel.require_admin] = self._admin
        self.app = app
        self.cliente = TestClient(app)

    def tearDown(self):
        eventos_admin.coleccion = self._coleccion
        eventos_admin._indice_listo = self._indice
        with eventos_admin._lock:
            eventos_admin._memoria.clear()

    def _admin(self):
        return {"id": "A1", "email": "admin@ejemplo.com", "rol": self.rol}

    def _publicar(self, tipo="viaje_huerfano", titulo="Viaje sin chofer",
                  mensaje="Calle A → Calle B", roles=("trip_operator",)):
        return eventos_admin.publicar(
            tipo, titulo, mensaje, datos={"trip_id": "T1"}, roles=list(roles))


class TestPuntero(BaseApi):

    def test_sin_desde_no_dispara_avisos_viejos(self):
        self._publicar()
        respuesta = self.cliente.get("/admin/eventos")
        self.assertEqual(respuesta.status_code, 200)
        datos = respuesta.json()
        self.assertEqual(datos["eventos"], [])
        self.assertTrue(datos["ultimo"])

    def test_desde_devuelve_los_eventos_nuevos(self):
        uno = self._publicar(mensaje="Calle A → Calle B")
        dos = self._publicar(mensaje="Calle C → Calle D")
        datos = self.cliente.get(
            "/admin/eventos", params={"desde": uno["id"]}).json()
        self.assertEqual([e["id"] for e in datos["eventos"]], [dos["id"]])
        self.assertEqual(datos["ultimo"], dos["id"])

    def test_dos_consultas_seguidas_no_repiten(self):
        uno = self._publicar()
        primera = self.cliente.get(
            "/admin/eventos", params={"desde": uno["id"]}).json()
        segunda = self.cliente.get(
            "/admin/eventos", params={"desde": primera["ultimo"]}).json()
        self.assertEqual(primera["eventos"], [])
        self.assertEqual(segunda["eventos"], [])

    def test_limite_invalido_se_rechaza_con_422(self):
        respuesta = self.cliente.get(
            "/admin/eventos", params={"desde": "x", "limite": "mucho"})
        self.assertEqual(respuesta.status_code, 422)


class TestRoles(BaseApi):

    def test_user_operator_no_ve_viajes(self):
        self.rol = "user_operator"
        self._publicar(roles=("trip_operator",))
        datos = self.cliente.get("/admin/eventos", params={"desde": "x"}).json()
        self.assertEqual(datos["eventos"], [])

    def test_trip_operator_ve_sus_viajes(self):
        self.rol = "trip_operator"
        self._publicar(mensaje="Calle vieja → Calle vieja")
        puntero = self.cliente.get("/admin/eventos").json()["ultimo"]
        evento = self._publicar(mensaje="Calle nueva → Calle nueva")
        datos = self.cliente.get(
            "/admin/eventos", params={"desde": puntero}).json()
        self.assertEqual([e["id"] for e in datos["eventos"]], [evento["id"]])

    def test_super_admin_ve_todo(self):
        self._publicar(roles=("wallet_operator",))
        puntero = self.cliente.get("/admin/eventos").json()["ultimo"]
        self._publicar(roles=("trip_operator",))
        self._publicar(tipo="registro_chofer", titulo="Nuevo chófer",
                       mensaje="Ana · Kia", roles=("user_operator",))
        datos = self.cliente.get(
            "/admin/eventos", params={"desde": puntero}).json()
        self.assertEqual(len(datos["eventos"]), 2)


class TestPrueba(BaseApi):

    def test_publica_un_evento_que_el_panel_vera(self):
        self._publicar(tipo="prueba", mensaje="semilla")
        puntero = self.cliente.get("/admin/eventos").json()["ultimo"]
        respuesta = self.cliente.post("/admin/eventos/prueba")
        self.assertEqual(respuesta.status_code, 200)
        cuerpo = respuesta.json()
        self.assertTrue(cuerpo["ok"])
        self.assertEqual(cuerpo["evento"]["tipo"], "prueba")

        datos = self.cliente.get(
            "/admin/eventos", params={"desde": puntero or ""}).json()
        self.assertEqual([e["tipo"] for e in datos["eventos"]], ["prueba"])
        self.assertIn("timbre", datos["eventos"][0]["mensaje"])


class TestCors(unittest.TestCase):

    def setUp(self):
        app = FastAPI()
        app.add_middleware(
            CORSMiddleware,
            allow_origins=["*"],
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )
        app.include_router(admin_web.router)
        self.cliente = TestClient(app)

    def test_preflight_permite_authorization(self):
        respuesta = self.cliente.options(
            "/admin/eventos",
            headers={
                "Origin": "http://localhost:8501",
                "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": "authorization",
            },
        )
        self.assertEqual(respuesta.status_code, 200)
        self.assertIn("access-control-allow-origin", respuesta.headers)
        self.assertIn("authorization",
                      respuesta.headers.get(
                          "access-control-allow-headers", "").lower())

    def test_sin_token_da_401(self):
        respuesta = self.cliente.get("/admin/eventos")
        self.assertEqual(respuesta.status_code, 401)


if __name__ == "__main__":
    unittest.main()
