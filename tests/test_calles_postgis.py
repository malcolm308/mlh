"""Pruebas de T5: malla de calles en PostGIS (import desde Mongo).

    python -m unittest tests.test_calles_postgis -v

Conexión para las pruebas de BD: `TEST_POSTGRES_URL` o
`postgresql://postgres@localhost:5432/taxi_db_test`.
"""
from __future__ import annotations

import importlib.util
import json
import os
import unittest
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values

RAIZ = Path(__file__).resolve().parents[1]
MIGRACION = RAIZ / "migrations" / "0005_streets_postgis.sql"
SCRIPT = RAIZ / "scripts" / "migrar_calles_postgis.py"

_spec = importlib.util.spec_from_file_location("migrar_calles_postgis", SCRIPT)
mig = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(mig)

DSN = os.getenv(
    "TEST_POSTGRES_URL",
    "postgresql://postgres@localhost:5432/taxi_db_test",
)


def _conectar():
    try:
        conn = psycopg2.connect(DSN, connect_timeout=3)
    except Exception as exc:  # pragma: no cover
        raise unittest.SkipTest(f"PostgreSQL de pruebas no disponible: {exc}")
    conn.autocommit = True
    return conn


class TestParserCalles(unittest.TestCase):
    def test_geojson_linestring(self):
        doc = {"_id": "a", "geom_geojson": {
            "type": "LineString", "coordinates": [[-82.4, 23.0], [-82.3, 23.1]]}}
        self.assertEqual(mig.puntos_de(doc), [[-82.4, 23.0], [-82.3, 23.1]])

    def test_legacy_geom_lat_lon_se_convierte(self):
        doc = {"_id": "b", "geom": [[23.0, -82.4], [23.1, -82.3]]}
        self.assertEqual(mig.puntos_de(doc), [[-82.4, 23.0], [-82.3, 23.1]])

    def test_multilinestring_usa_el_tramo_mas_largo(self):
        doc = {"_id": "c", "geom_geojson": {
            "type": "MultiLineString", "coordinates": [
                [[-82.4, 23.0], [-82.399, 23.0]],
                [[-82.5, 23.1], [-82.4, 23.1], [-82.3, 23.1]],
            ]}}
        self.assertEqual(len(mig.puntos_de(doc)), 3)

    def test_puntos_duplicados_y_fuera_de_rango_se_ignoran(self):
        doc = {"_id": "d", "geom_geojson": {
            "type": "LineString", "coordinates": [
                [-82.4, 23.0], [-82.4, 23.0], [999, 23.0], [-82.3, 23.1]]}}
        self.assertEqual(mig.puntos_de(doc), [[-82.4, 23.0], [-82.3, 23.1]])

    def test_filas_sin_id_o_sin_geometria_se_descartan(self):
        self.assertIsNone(mig.fila_para({"geom_geojson": {
            "type": "LineString", "coordinates": [[-82.4, 23.0], [-82.3, 23.1]]}}))
        self.assertIsNone(mig.fila_para({"_id": "x", "geom": [[23.0, -82.4]]}))
        fila = mig.fila_para({"_id": "ok", "nombre": "Calle 23",
                              "geom_geojson": {"type": "LineString", "coordinates": [
                                  [-82.4, 23.0], [-82.3, 23.1]]}})
        self.assertEqual(fila[0], "ok")
        self.assertEqual(fila[1], "Calle 23")


class TestStreetsPostgis(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = _conectar()
        with cls.conn.cursor() as cur:
            try:
                cur.execute("CREATE EXTENSION IF NOT EXISTS postgis")
            except Exception as exc:  # pragma: no cover
                raise unittest.SkipTest(f"PostGIS no disponible: {exc}")
            cur.execute(MIGRACION.read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def setUp(self):
        self.cur = self.conn.cursor()
        self.cur.execute("DELETE FROM streets WHERE mongo_id LIKE 'test_%'")

    def tearDown(self):
        self.cur.execute("DELETE FROM streets WHERE mongo_id LIKE 'test_%'")
        self.cur.close()

    def _insertar(self, mongo_id="test_calle", coords=None):
        coords = coords or [[-82.40, 23.00], [-82.39, 23.00]]
        fila = (
            mongo_id, "Calle Test",
            json.dumps({"type": "LineString", "coordinates": coords}),
            len(coords), "{}",
        )
        execute_values(self.cur, mig.SQL_UPSERT, [fila])

    def test_migracion_idempotente_y_objetos(self):
        self.cur.execute(
            "SELECT to_regclass('public.streets'), to_regclass('public.idx_streets_geom')"
        )
        self.assertEqual(self.cur.fetchone()[0], "streets")
        self.cur.execute(MIGRACION.read_text(encoding="utf-8"))
        self.cur.execute(
            "SELECT COUNT(*) FROM schema_migrations WHERE version='0005_streets_postgis'"
        )
        self.assertEqual(self.cur.fetchone()[0], 1)

    def test_upsert_por_mongo_id_y_consulta_espacial(self):
        self._insertar()
        self._insertar()  # repetir no duplica
        self.cur.execute("SELECT COUNT(*) FROM streets WHERE mongo_id='test_calle'")
        self.assertEqual(self.cur.fetchone()[0], 1)
        self.cur.execute(
            """
            SELECT COUNT(*) FROM streets
             WHERE mongo_id = 'test_calle'
               AND ST_DWithin(geom, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 60)
            """,
            (-82.395, 23.0),
        )
        self.assertEqual(self.cur.fetchone()[0], 1)
        self.cur.execute(
            """
            SELECT COUNT(*) FROM streets
             WHERE mongo_id = 'test_calle'
               AND ST_DWithin(geom, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 60)
            """,
            (-82.50, 23.2),
        )
        self.assertEqual(self.cur.fetchone()[0], 0)

    def test_geom_debe_ser_linestring(self):
        multi = ('{"type":"MultiLineString","coordinates":['
                 '[[-82.4,23.0],[-82.3,23.0]],[[-82.4,23.1],[-82.3,23.1]]]}')
        with self.assertRaises(psycopg2.Error):
            self.cur.execute(
                """
                INSERT INTO streets (mongo_id, nombre, geom)
                VALUES ('test_multi', 'Multi', ST_SetSRID(ST_GeomFromGeoJSON(%s),4326)::geography)
                """,
                (multi,),
            )
        self.cur.execute("DELETE FROM streets WHERE mongo_id='test_multi'")


if __name__ == "__main__":
    unittest.main()
