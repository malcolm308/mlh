"""Regresión del 422 intermitente de /trips/requested-nearby.

La APK vieja pega `lat`, `lng` y `radius_km` sin '&'. El fix definitivo vive en
Flutter; estos tests fijan el parche de contención del servidor.

    python -m unittest tests.test_http_compat -v
"""
from __future__ import annotations

import unittest

from fastapi import FastAPI, Query
from fastapi.testclient import TestClient
from starlette.requests import Request

from app.http_compat import compat_query_middleware, reparar_query_legacy


class TestRepararQueryLegacy(unittest.TestCase):
    def test_url_rota_de_produccion(self):
        crudo = (
            b"lat=23.0472165lng=-82.3602766radius_km=5&limit=20"
            b"&driver_id=6af87bb295b1fb9f5855a2d0&vehicle_type=basico"
        )
        self.assertEqual(
            reparar_query_legacy(crudo),
            b"lat=23.0472165&lng=-82.3602766&radius_km=5&limit=20"
            b"&driver_id=6af87bb295b1fb9f5855a2d0&vehicle_type=basico",
        )

    def test_url_correcta_no_se_toca(self):
        crudo = b"lat=23.0475660469383&lng=-82.36147452704608&radius_km=5.0&limit=20"
        self.assertEqual(reparar_query_legacy(crudo), crudo)

    def test_signos_y_notacion_cientifica(self):
        crudo = b"lat=23.1lng=-8.2e+1radius_km=5.0&limit=20"
        self.assertEqual(
            reparar_query_legacy(crudo),
            b"lat=23.1&lng=-8.2e+1&radius_km=5.0&limit=20",
        )

    def test_parametros_ajenos_no_se_reescriben(self):
        crudo = b"q=lat=1lng=2radius_km=3&limit=20"
        self.assertEqual(reparar_query_legacy(crudo), crudo)
        self.assertEqual(reparar_query_legacy(b""), b"")


class TestMiddlewareAntesDeValidar(unittest.IsolatedAsyncioTestCase):
    async def test_reescribe_el_scope(self):
        scope = {
            "type": "http",
            "method": "GET",
            "path": "/trips/requested-nearby",
            "query_string": b"lat=23.1lng=-82.3radius_km=5&limit=20",
            "headers": [],
        }
        vista = Request(scope)

        async def call_next(req):
            return req.scope["query_string"]

        resultado = await compat_query_middleware(vista, call_next)
        self.assertEqual(
            resultado, b"lat=23.1&lng=-82.3&radius_km=5&limit=20")


class TestEndpointConQueryRota(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app = FastAPI()
        app.middleware("http")(compat_query_middleware)

        @app.get("/trips/requested-nearby")
        def eco(lat: float, lng: float, radius_km: float = Query(5.0),
                limit: int = 20):
            return {"lat": lat, "lng": lng, "radius_km": radius_km,
                    "limit": limit}

        cls.cliente = TestClient(app)

    def test_antes_era_422_y_ahora_200(self):
        resp = self.cliente.get(
            "/trips/requested-nearby"
            "?lat=23.0472165lng=-82.3602766radius_km=5&limit=20"
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(resp.json(), {
            "lat": 23.0472165, "lng": -82.3602766,
            "radius_km": 5.0, "limit": 20,
        })

    def test_la_url_bien_formada_sigue_igual(self):
        resp = self.cliente.get(
            "/trips/requested-nearby"
            "?lat=23.0475660469383&lng=-82.36147452704608"
            "&radius_km=5.0&limit=20"
        )
        self.assertEqual(resp.status_code, 200, resp.text)


if __name__ == "__main__":
    unittest.main()
