"""Tests del mapeo device de Traccar <-> chofer.

Ejecutar:
    python -m unittest tests.test_traccar_device -v

Estos tests usan la Mongo y la Garnet reales (localhost), que es como corre el
servicio en desarrollo. No modifican datos de otros choferes: solo leen y
escriben el documento de un chofer de prueba.
"""

import logging
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from bson import ObjectId

from db.Chofer.connection import chofer_db
from services.traccar_listener import procesar_posicion


USERS = chofer_db["users"]

# Ventana temporal que usa _get_traccar_route (no admite None).
_VENTANA_INICIO = datetime(2026, 10, 6, 3, 0, 0, tzinfo=timezone.utc)
_VENTANA_FIN = datetime(2026, 10, 6, 4, 0, 0, tzinfo=timezone.utc)


class TestFindChoferPorDevice(unittest.TestCase):
    """Test que verifica que find_one con traccar_device_id funciona."""

    def setUp(self):
        self.oid = ObjectId()
        self.driver_doc = {
            "_id": self.oid,
            "Nombre": "Chofer Test Traccar",
            "email": "traccar_test@taxirapid.cu",
            "status": "active",
            "traccar_device_id": 900001,
        }
        USERS.insert_one(self.driver_doc)

    def tearDown(self):
        USERS.delete_one({"_id": self.oid})

    def test_find_one_por_traccar_device_id_devuelve_el_chofer(self):
        encontrado = USERS.find_one({"traccar_device_id": 900001})
        self.assertIsNotNone(encontrado)
        self.assertEqual(encontrado["_id"], self.oid)
        self.assertEqual(encontrado["email"], "traccar_test@taxirapid.cu")

    def test_procesar_posicion_asocia_el_device_al_chofer(self):
        """Con el chofer asignado, una posicion del device se le atribuye."""
        with mock.patch("services.traccar_listener.update_driver_location") as upd, \
             mock.patch("services.traccar_listener.get_driver_status", return_value="offline"), \
             mock.patch("services.traccar_listener.set_driver_status") as st:
            driver_id = procesar_posicion(
                {"deviceId": 900001, "latitude": 23.1175, "longitude": -82.3535}
            )

        self.assertEqual(driver_id, str(self.oid))
        upd.assert_called_once_with(str(self.oid), -82.3535, 23.1175)
        # status previo "offline" != "on_trip", asi que se marca disponible
        st.assert_called_once_with(str(self.oid), "available")

    def test_no_pisa_el_estado_on_trip(self):
        with mock.patch("services.traccar_listener.update_driver_location"), \
             mock.patch("services.traccar_listener.get_driver_status", return_value="on_trip"), \
             mock.patch("services.traccar_listener.set_driver_status") as st:
            driver_id = procesar_posicion(
                {"deviceId": 900001, "latitude": 23.1175, "longitude": -82.3535}
            )
        self.assertEqual(driver_id, str(self.oid))
        st.assert_not_called()


class TestDeviceSinChofer(unittest.TestCase):
    """Test que verifica que un device sin chofer devuelve None sin petar."""

    def test_device_sin_chofer_devuelve_none(self):
        with mock.patch("services.traccar_listener.update_driver_location") as upd, \
             mock.patch("services.traccar_listener.get_driver_status") as gs, \
             mock.patch("services.traccar_listener.set_driver_status"):
            driver_id = procesar_posicion(
                {"deviceId": 987654321, "latitude": 23.11, "longitude": -82.36}
            )
        self.assertIsNone(driver_id)
        upd.assert_not_called()
        gs.assert_not_called()

    def test_log_informativo_cuando_no_hay_chofer(self):
        with self.assertLogs("services.traccar_listener", level=logging.INFO) as ctx:
            with mock.patch("services.traccar_listener.update_driver_location"):
                procesar_posicion(
                    {"deviceId": 987654321, "latitude": 23.11, "longitude": -82.36}
                )
        self.assertTrue(
            any("Device 987654321 sin chofer asignado" in m for m in ctx.output),
            ctx.output,
        )

    def test_posicion_incompleta_no_lanza(self):
        for pos in (
            {"deviceId": 1},
            {"deviceId": 1, "latitude": 23.1},
            {"longitude": -82.3, "latitude": 23.1},
            {},
        ):
            with mock.patch("services.traccar_listener.update_driver_location"):
                self.assertIsNone(procesar_posicion(pos))


class TestGetTraccarRoute(unittest.TestCase):
    """Test del router: _get_traccar_route usa traccar_device_id del chofer."""

    def test_ruta_vacia_si_el_chofer_no_tiene_device(self):
        from routers.Solicitud_de_viajes_v4 import _get_traccar_route

        ventana = (_VENTANA_INICIO, _VENTANA_FIN)
        with mock.patch("routers.Solicitud_de_viajes_v4.chofer_coleccion.find_one",
                        return_value={"_id": ObjectId(), "email": "x@y.z"}):
            self.assertEqual(_get_traccar_route("6abd9fa0aac15d405abc183a", *ventana), [])

    def test_ruta_usa_el_device_y_el_token_del_chofer(self):
        from routers.Solicitud_de_viajes_v4 import _get_traccar_route

        uri = {}
        # urllib.request.urlopen se usa como context manager, asi que lo que
        # importa es el valor de __enter__.
        cuerpo = mock.MagicMock()
        cuerpo.read.return_value = b'[{"latitude": 23.1175, "longitude": -82.3535}]'
        resp = mock.MagicMock()
        resp.__enter__.return_value = cuerpo

        def fake_urlopen(req, timeout=None):
            uri["full_url"] = req.full_url
            uri["auth"] = req.headers.get("Authorization")
            return resp

        doc = {"_id": ObjectId(), "traccar_device_id": 1}
        with mock.patch("routers.Solicitud_de_viajes_v4.chofer_coleccion.find_one",
                        return_value=doc), \
             mock.patch("routers.Solicitud_de_viajes_v4.TRACCAR_TOKEN",
                        "token-de-prueba"), \
             mock.patch("routers.Solicitud_de_viajes_v4.urllib.request.urlopen", fake_urlopen):
            puntos = _get_traccar_route("6abd9fa0aac15d405abc183a", _VENTANA_INICIO, _VENTANA_FIN)

        self.assertEqual(len(puntos), 1)
        self.assertEqual(puntos[0]["lat"], 23.1175)
        self.assertEqual(puntos[0]["lng"], -82.3535)
        self.assertIn("deviceId=1", uri["full_url"])
        self.assertIn("from=", uri["full_url"])
        self.assertIn("to=", uri["full_url"])
        self.assertTrue(uri["auth"].startswith("Bearer "), uri["auth"])

    def test_ruta_vacia_si_traccar_devuelve_error(self):
        """Un fallo de red o un token caducado no debe propagar la excepcion."""
        from routers.Solicitud_de_viajes_v4 import _get_traccar_route

        doc = {"_id": ObjectId(), "traccar_device_id": 1}
        with mock.patch("routers.Solicitud_de_viajes_v4.chofer_coleccion.find_one",
                        return_value=doc), \
             mock.patch("routers.Solicitud_de_viajes_v4.TRACCAR_TOKEN",
                        "token-de-prueba"), \
             mock.patch("routers.Solicitud_de_viajes_v4.urllib.request.urlopen",
                        side_effect=OSError("connection refused")):
            self.assertEqual(
                _get_traccar_route("6abd9fa0aac15d405abc183a", _VENTANA_INICIO, _VENTANA_FIN), []
            )

    def test_ruta_vacia_sin_token_configurado(self):
        """Sin TRACCAR_TOKEN no se llama a Traccar: no se manda 'Bearer None'."""
        from routers.Solicitud_de_viajes_v4 import _get_traccar_route

        doc = {"_id": ObjectId(), "traccar_device_id": 1}
        urlopen = mock.MagicMock()
        with mock.patch("routers.Solicitud_de_viajes_v4.chofer_coleccion.find_one",
                        return_value=doc), \
             mock.patch("routers.Solicitud_de_viajes_v4.TRACCAR_TOKEN", None), \
             mock.patch("routers.Solicitud_de_viajes_v4.urllib.request.urlopen", urlopen):
            self.assertEqual(
                _get_traccar_route("6abd9fa0aac15d405abc183a", _VENTANA_INICIO, _VENTANA_FIN), []
            )
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
