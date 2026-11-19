"""Pruebas del read-model de calles en Postgres (T5, GEO_READ_SOURCE).

    python -m unittest tests.test_geo_streets_source -v
"""
from __future__ import annotations

import json
import os
import unittest
from unittest import mock

import psycopg2

from app import config as app_config
from app.geo import streets_repo
from routers import geo

DSN = os.getenv(
    "TEST_POSTGRES_URL",
    "postgresql://postgres@localhost:5432/taxi_db_test",
)

MIGRACION = None  # la tabla streets la crea tests.test_calles_postgis / 0005


def _conectar():
    try:
        conn = psycopg2.connect(DSN, connect_timeout=3)
    except Exception as exc:  # pragma: no cover
        raise unittest.SkipTest(f"PostgreSQL de pruebas no disponible: {exc}")
    conn.autocommit = True
    return conn


class TestConfigFuente(unittest.TestCase):
    def test_default_mongo_y_selection(self):
        self.assertIn(app_config.GEO_READ_SOURCE, ("mongo", "postgres"))
        with mock.patch.object(app_config, "GEO_READ_SOURCE", "postgres"):
            self.assertTrue(geo._usar_streets_postgres())
        with mock.patch.object(app_config, "GEO_READ_SOURCE", "mongo"):
            self.assertFalse(geo._usar_streets_postgres())

    def test_asegurar_geometrias_no_escribe_en_mongo(self):
        with mock.patch.object(app_config, "GEO_READ_SOURCE", "postgres"):
            resumen = geo.asegurar_geometrias()
        self.assertTrue(resumen["omitido"])
        self.assertEqual(resumen["pendientes"], 0)


class TestDocPostgres(unittest.TestCase):
    def test_doc_tiene_forma_de_mongo(self):
        fila = {
            "mongo_id": "abc",
            "nombre": "Calle 23",
            "properties": {"tipo": "residential"},
            "geom_geojson": json.dumps({
                "type": "LineString",
                "coordinates": [[-82.40, 23.00], [-82.39, 23.00]],
            }),
            "_lon": -82.395,
            "_lat": 23.0,
        }
        doc = streets_repo._doc(fila)
        self.assertEqual(doc["_id"], "abc")
        self.assertEqual(doc["tipo"], "residential")
        self.assertEqual(doc["geom"], [[23.0, -82.40], [23.0, -82.39]])
        self.assertEqual(doc["punto"]["coordinates"], [-82.395, 23.0])
        self.assertEqual(doc["geom_geojson"]["type"], "LineString")

    def test_patron_token_acepta_acentos(self):
        patron = streets_repo.patron_token("malecon")
        conn = _conectar()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 'Malecón' ~* %s", (patron,))
                self.assertTrue(cur.fetchone()[0])
        finally:
            conn.close()


class TestRepositorioPostgres(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = _conectar()
        with cls.conn.cursor() as cur:
            try:
                cur.execute("CREATE EXTENSION IF NOT EXISTS postgis")
            except Exception as exc:  # pragma: no cover
                raise unittest.SkipTest(f"PostGIS no disponible: {exc}")
            try:
                cur.execute("SELECT 1 FROM streets LIMIT 1")
            except Exception:
                raise unittest.SkipTest("Falta la tabla streets (migración 0005)")
            cur.execute("DELETE FROM streets WHERE mongo_id LIKE 'geo_test_%'")
            cur.execute(
                """
                INSERT INTO streets (mongo_id, nombre, geom, puntos, properties)
                VALUES (%s, %s,
                        ST_SetSRID(ST_GeomFromGeoJSON(%s),4326)::geography,
                        2, %s::jsonb)
                """,
                (
                    "geo_test_1", "Calle 23",
                    json.dumps({"type": "LineString", "coordinates": [
                        [-82.40, 23.00], [-82.39, 23.00]]}),
                    json.dumps({"tipo": "residential"}),
                ),
            )
        cls._env_anterior = os.environ.get("POSTGRES_URL")
        os.environ["POSTGRES_URL"] = DSN

    @classmethod
    def tearDownClass(cls):
        with cls.conn.cursor() as cur:
            cur.execute("DELETE FROM streets WHERE mongo_id LIKE 'geo_test_%'")
        cls.conn.close()
        if cls._env_anterior is None:
            os.environ.pop("POSTGRES_URL", None)
        else:
            os.environ["POSTGRES_URL"] = cls._env_anterior

    def test_hay_calles_y_busqueda_por_nombre(self):
        self.assertTrue(streets_repo.hay_calles())
        docs = streets_repo.buscar_por_nombre(["23"], None, 10)
        self.assertTrue(any(d.get("nombre") == "Calle 23" for d in docs))
        self.assertEqual(streets_repo.buscar_por_nombre([], None, 10), [])

    def test_calles_cerca(self):
        docs = streets_repo.calles_cerca(23.0, -82.395, 100)
        self.assertTrue(any(d.get("nombre") == "Calle 23" for d in docs))

    def test_cruza_con(self):
        principal = {"type": "LineString", "coordinates": [
            [-82.395, 22.99], [-82.395, 23.01]]}
        docs = streets_repo.cruza_con(principal, ["Calle 23"], 10)
        self.assertTrue(any(d.get("nombre") == "Calle 23" for d in docs))

    def test_geo_hay_calles_con_flag(self):
        with mock.patch.object(app_config, "GEO_READ_SOURCE", "postgres"):
            self.assertTrue(geo._hay_calles())


if __name__ == "__main__":
    unittest.main()
