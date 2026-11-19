"""Pruebas de T5: zonas PostGIS y resolución por ST_Contains.

Requiere PostgreSQL con PostGIS y BD de pruebas con tabla `promociones`/esquema base
no es estrictamente necesaria para estas consultas, pero la migración sí.

    python -m unittest tests.test_zones_postgis -v

Conexión: `TEST_POSTGRES_URL` o `postgresql://postgres@localhost:5432/taxi_db_test`.
"""
from __future__ import annotations

import os
import unittest
from pathlib import Path

import psycopg2

RAIZ = Path(__file__).resolve().parents[1]
MIGRACION = RAIZ / "migrations" / "0002_zones_postgis.sql"

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


class TestZonesPostgis(unittest.TestCase):
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
        self.cur.execute("DELETE FROM zones WHERE code LIKE 'test_%'")

    def tearDown(self):
        self.cur.execute("DELETE FROM zones WHERE code LIKE 'test_%'")
        self.cur.close()

    def _insertar_zona_cuadrada(self, code="test_sq", active=True):
        # Cuadrado alrededor de (23.0,-82.4)
        geojson = (
            '{"type":"MultiPolygon","coordinates":[[[[-82.41,22.99],[-82.39,22.99],'
            '[-82.39,23.01],[-82.41,23.01],[-82.41,22.99]]]]}'
        )
        self.cur.execute(
            """
            INSERT INTO zones (code, name, active, geom,
                               precio_km_zona_basico, precio_km_zona_confort,
                               precio_km_zona_triciclo, precio_km_zona_moto)
            VALUES (%s, 'Test', %s,
                    ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s),4326))::geography,
                    1000,1200,700,600)
            """,
            (code, active, geojson),
        )

    def test_objetos_y_migracion_idempotente(self):
        self.cur.execute(
            "SELECT to_regclass('public.zones'), to_regclass('public.idx_zones_geom')"
        )
        self.assertEqual(self.cur.fetchone()[0], "zones")
        # segunda pasada no falla
        self.cur.execute(MIGRACION.read_text(encoding="utf-8"))
        self.cur.execute(
            "SELECT COUNT(*) FROM schema_migrations WHERE version='0002_zones_postgis'"
        )
        self.assertEqual(self.cur.fetchone()[0], 1)

    def test_st_contains_dentro_y_fuera(self):
        self._insertar_zona_cuadrada()
        self.cur.execute(
            """
            SELECT code FROM zones
             WHERE code = 'test_sq' AND active
               AND ST_Contains(geom::geometry, ST_SetSRID(ST_MakePoint(%s,%s),4326))
            """,
            (-82.40, 23.00),
        )
        self.assertEqual(self.cur.fetchone()[0], "test_sq")
        self.cur.execute(
            """
            SELECT code FROM zones
             WHERE code = 'test_sq' AND active
               AND ST_Contains(geom::geometry, ST_SetSRID(ST_MakePoint(%s,%s),4326))
            """,
            (-82.50, 23.20),
        )
        self.assertIsNone(self.cur.fetchone())

    def test_zona_inactiva_no_coincide(self):
        self._insertar_zona_cuadrada(code="test_off", active=False)
        self.cur.execute(
            """
            SELECT code FROM zones
             WHERE code = 'test_off' AND active
               AND ST_Contains(geom::geometry, ST_SetSRID(ST_MakePoint(%s,%s),4326))
            """,
            (-82.40, 23.00),
        )
        self.assertIsNone(self.cur.fetchone())

    def test_geometria_invalida_rechazada(self):
        # polígono auto-intersectante (bow-tie) debe violar check de validez
        bowtie = (
            '{"type":"MultiPolygon","coordinates":[[[[-82.41,22.99],[-82.39,23.01],'
            '[-82.39,22.99],[-82.41,23.01],[-82.41,22.99]]]]}'
        )
        with self.assertRaises(psycopg2.Error):
            self.cur.execute(
                """
                INSERT INTO zones (code, name, geom)
                VALUES ('test_bad', 'Bad',
                        ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s),4326))::geography)
                """,
                (bowtie,),
            )
        # autocommit=True: no hay transacción abortada que limpiar.
        self.cur.execute("DELETE FROM zones WHERE code='test_bad'")


if __name__ == "__main__":
    unittest.main()