"""Pruebas del backfill y del cuadre (Tarea 2).

Necesitan PostgreSQL y MongoDB reales. Se saltan solos si no están:

    python -m unittest tests.test_backfill_cuadre -v

Variables:
    TEST_POSTGRES_URL   por defecto postgresql://postgres@localhost:5432/taxi_db_test
    TEST_MONGODB_URI    por defecto mongodb://localhost:27018

Las bases de Mongo son `test_Cliente` y `test_Chofer`: nunca las reales.
"""
from __future__ import annotations

import os
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2
from bson import ObjectId
from pymongo import MongoClient

from app.money import a_cents, a_decimal, de_cents
from app.wallet.backfill import (clave_migracion, comparar_cuadre,
                                 ejecutar_backfill, saldos_postgres)

RAIZ = Path(__file__).resolve().parents[1]
MIGRACION = RAIZ / "migrations" / "0001_wallet_core.sql"

PG_DSN = os.getenv(
    "TEST_POSTGRES_URL",
    "postgresql://postgres@localhost:5432/taxi_db_test")
MONGO_URI = os.getenv("TEST_MONGODB_URI", "mongodb://localhost:27018")
PREFIJO = "test_"


class TestMoney(unittest.TestCase):
    """La conversión es la base de todo: si redondea mal, se pierde dinero."""

    def test_centavos_exactos(self):
        self.assertEqual(a_cents(100.50), 10050)
        self.assertEqual(a_cents("0.01"), 1)
        self.assertEqual(a_cents(0), 0)
        self.assertEqual(a_cents(None), 0)

    def test_redondeo_a_dos_decimales(self):
        self.assertEqual(a_cents(0.1 + 0.2), 30)
        self.assertEqual(a_cents(10.005), 1001)

    def test_vuelta_a_decimal(self):
        self.assertEqual(str(de_cents(10050)), "100.50")
        self.assertEqual(de_cents(-1525), a_decimal("-15.25"))

    def test_booleano_no_es_importe(self):
        with self.assertRaises(TypeError):
            a_cents(True)


class TestBackfillCuadre(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        try:
            cls.conn = psycopg2.connect(PG_DSN, connect_timeout=3)
        except Exception as exc:
            raise unittest.SkipTest(f"PostgreSQL no disponible: {exc}")
        cls.conn.autocommit = False
        with cls.conn.cursor() as cur:
            cur.execute(MIGRACION.read_text(encoding="utf-8"))
        cls.conn.commit()

        try:
            cls.mongo = MongoClient(MONGO_URI,
                                    serverSelectionTimeoutMS=2000)
            cls.mongo.admin.command("ping")
        except Exception as exc:
            cls.conn.close()
            raise unittest.SkipTest(f"MongoDB no disponible: {exc}")

        cls.col_cliente = cls.mongo[f"{PREFIJO}Cliente"]["users"]
        cls.col_chofer = cls.mongo[f"{PREFIJO}Chofer"]["users"]

    @classmethod
    def tearDownClass(cls):
        cls.mongo.drop_database(f"{PREFIJO}Cliente")
        cls.mongo.drop_database(f"{PREFIJO}Chofer")
        cls.mongo.close()
        with cls.conn.cursor() as cur:
            cur.execute("DELETE FROM wallet_ledger")
        cls.conn.commit()
        cls.conn.close()

    def setUp(self):
        self.col_cliente.delete_many({})
        self.col_chofer.delete_many({})
        with self.conn.cursor() as cur:
            cur.execute("DELETE FROM wallet_ledger")
        self.conn.commit()

        self.a = ObjectId()
        self.b = ObjectId()
        self.c = ObjectId()
        self.d = ObjectId()
        self.e = ObjectId()
        self.col_cliente.insert_many([
            {"_id": self.a, "Nombre": "Ana", "Fondo": 1005.50,
             "saldo_promocional": 25.0,
             "fecha_expiracion_promocional":
                 datetime.now(timezone.utc) + timedelta(days=2)},
            {"_id": self.b, "Nombre": "Beto", "Fondo": 0},
            {"_id": self.c, "Nombre": "Carla", "Fondo": -15.25},
            # Campaña vencida: la app la ve como 0; migrarla regalaría dinero.
            {"_id": self.e, "Nombre": "Eva", "Fondo": 0,
             "saldo_promocional": 1200.0,
             "fecha_expiracion_promocional":
                 datetime.now(timezone.utc) - timedelta(days=1)},
        ])
        self.col_chofer.insert_one(
            {"_id": self.d, "Nombre": "Danilo", "Fondo": 250.75})

    def _asientos(self):
        with self.conn.cursor() as cur:
            cur.execute("SELECT user_id, user_type, monto_cents, tipo, "
                        "idempotency_key FROM wallet_ledger "
                        "ORDER BY user_id, idempotency_key")
            return cur.fetchall()

    # -- backfill -----------------------------------------------------
    def test_dry_run_no_escribe(self):
        stats = ejecutar_backfill(self.conn, self.col_cliente,
                                  self.col_chofer, dry_run=True)
        self.assertEqual(self._asientos(), [])
        self.assertEqual(stats["insertados"], 4)
        self.assertEqual(stats["omitidos"], 1)

    def test_backfill_inserta_los_tres_saldos(self):
        stats = ejecutar_backfill(self.conn, self.col_cliente,
                                  self.col_chofer)
        self.assertEqual(stats["insertados"], 4)
        self.assertEqual(stats["omitidos"], 1)
        self.assertEqual(stats["errores"], 0)

        filas: dict[tuple[str, str], int] = {}
        for user_id, user_type, monto, _tipo, _clave in self._asientos():
            filas[(user_id, user_type)] = \
                filas.get((user_id, user_type), 0) + monto
        self.assertEqual(filas[(str(self.a), "client")], 103050)
        self.assertEqual(filas[(str(self.c), "client")], -1525)
        self.assertEqual(filas[(str(self.d), "driver")], 25075)
        self.assertNotIn((str(self.b), "client"), filas)
        # Eva tenía 1.200 de promo vencida: no debe existir en el ledger.
        self.assertNotIn((str(self.e), "client"), filas)

    def test_promo_vencida_no_se_migra(self):
        ejecutar_backfill(self.conn, self.col_cliente, self.col_chofer)
        with self.conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM wallet_ledger WHERE user_id = %s",
                        (str(self.e),))
            self.assertEqual(cur.fetchone()[0], 0)

    def test_promo_vigente_guarda_su_expiracion(self):
        ejecutar_backfill(self.conn, self.col_cliente, self.col_chofer)
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT metadata->>'expira_en' FROM wallet_ledger "
                "WHERE idempotency_key = %s",
                (clave_migracion("client", str(self.a), "promo"),))
            expira = cur.fetchone()[0]
        self.assertIsNotNone(expira)
        self.assertGreater(datetime.fromisoformat(expira),
                           datetime.now(timezone.utc).replace(tzinfo=None))

    def test_claves_de_idempotencia_unicas_por_campo(self):
        ejecutar_backfill(self.conn, self.col_cliente, self.col_chofer)
        claves = {f[4] for f in self._asientos()}
        self.assertIn(clave_migracion("client", str(self.a), "fondo"), claves)
        self.assertIn(clave_migracion("client", str(self.a), "promo"), claves)
        self.assertIn(clave_migracion("driver", str(self.d), "fondo"),
                      claves)
        self.assertEqual(len(claves), 4)

    def test_repetir_no_duplica(self):
        ejecutar_backfill(self.conn, self.col_cliente, self.col_chofer)
        antes = len(self._asientos())
        stats = ejecutar_backfill(self.conn, self.col_cliente,
                                  self.col_chofer)
        self.assertEqual(stats["insertados"], 0)
        self.assertEqual(stats["ya_existian"], 4)
        self.assertEqual(len(self._asientos()), antes)

    def test_reanuda_desde_checkpoint(self):
        ejecutar_backfill(self.conn, self.col_cliente, self.col_chofer,
                          desde={"cliente": str(self.a)},
                          limite=None)
        filas = {(f[0], f[1]) for f in self._asientos()}
        # Ana ya estaba procesada: no debe repetirse.
        self.assertNotIn((str(self.a), "client"), filas)
        self.assertIn((str(self.c), "client"), filas)
        self.assertIn((str(self.d), "driver"), filas)

    # -- cuadre -------------------------------------------------------
    def test_cuadre_limpio_tras_backfill(self):
        ejecutar_backfill(self.conn, self.col_cliente, self.col_chofer)
        informe = comparar_cuadre(self.conn, self.col_cliente,
                                  self.col_chofer)
        self.assertTrue(informe["ok"], informe["diferencias"])
        self.assertEqual(informe["diferencias"], [])
        self.assertEqual(informe["solo_en_postgres"], [])

    def test_cuadre_detecta_una_diferencia(self):
        ejecutar_backfill(self.conn, self.col_cliente, self.col_chofer)
        self.col_cliente.update_one({"_id": self.a},
                                    {"$set": {"Fondo": 905.50}})
        informe = comparar_cuadre(self.conn, self.col_cliente,
                                  self.col_chofer)
        self.assertFalse(informe["ok"])
        self.assertEqual(len(informe["diferencias"]), 1)
        diff = informe["diferencias"][0]
        self.assertEqual(diff["user_id"], str(self.a))
        self.assertEqual(diff["user_type"], "client")
        self.assertEqual(diff["mongo_cents"], 93050)
        self.assertEqual(diff["postgres_cents"], 103050)
        self.assertEqual(diff["delta_cents"], 10000)

    def test_cuadre_ve_asientos_huerfanos(self):
        with self.conn.cursor() as cur:
            cur.execute(
                "INSERT INTO wallet_ledger (user_id, user_type, tipo, "
                "monto_cents, idempotency_key) "
                "VALUES ('huerfano', 'client', 'ajuste', 500, 'test:huerfano')")
        self.conn.commit()
        informe = comparar_cuadre(self.conn, self.col_cliente,
                                  self.col_chofer)
        self.assertFalse(informe["ok"])
        self.assertEqual(len(informe["solo_en_postgres"]), 1)

    def test_saldos_postgres_agrega_por_usuario(self):
        ejecutar_backfill(self.conn, self.col_cliente, self.col_chofer)
        saldos = saldos_postgres(self.conn)
        self.assertEqual(saldos[("client", str(self.a))], 103050)
        self.assertEqual(saldos[("driver", str(self.d))], 25075)


if __name__ == "__main__":
    unittest.main()
