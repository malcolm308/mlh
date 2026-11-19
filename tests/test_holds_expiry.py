"""Pruebas de T6: expiración de holds y viajes (función SQL).

Ejecuta `expirar_holds_y_viajes()` definida en 0003_holds_expiry_pgcron.sql.
Requiere BD de pruebas con tablas `trips`, `wallet_holds`, `outbox` (0001 + base).

    python -m unittest tests.test_holds_expiry -v
"""
from __future__ import annotations

import os
import unittest
from pathlib import Path

import psycopg2

RAIZ = Path(__file__).resolve().parents[1]
MIG_0001 = RAIZ / "migrations" / "0001_wallet_core.sql"
MIG_0003 = RAIZ / "migrations" / "0003_holds_expiry_pgcron.sql"

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


class TestHoldsExpiry(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = _conectar()
        with cls.conn.cursor() as cur:
            cur.execute("SELECT to_regclass('public.trips')")
            if cur.fetchone()[0] is None:
                raise unittest.SkipTest("La base de pruebas no tiene la tabla trips")
            # asegurar dependencias
            cur.execute(MIG_0001.read_text(encoding="utf-8"))
            cur.execute(MIG_0003.read_text(encoding="utf-8"))
            # confirmar función creada
            cur.execute("SELECT to_regprocedure('public.expirar_holds_y_viajes(integer)')")
            if cur.fetchone()[0] is None:
                raise unittest.SkipTest("Función expirar_holds_y_viajes no disponible")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def setUp(self):
        self.cur = self.conn.cursor()
        self.cur.execute("DELETE FROM outbox")
        self.cur.execute("DELETE FROM wallet_holds")
        self.cur.execute("DELETE FROM wallet_ledger")
        self.cur.execute("DELETE FROM trips WHERE trip_id LIKE 'test_exp_%'")

    def tearDown(self):
        self.cur.execute("DELETE FROM outbox")
        self.cur.execute("DELETE FROM wallet_holds")
        self.cur.execute("DELETE FROM wallet_ledger")
        self.cur.execute("DELETE FROM trips WHERE trip_id LIKE 'test_exp_%'")
        self.cur.close()

    def _viaje(self, trip_id, status="requested"):
        self.cur.execute(
            "INSERT INTO trips (trip_id, client_id, status) VALUES (%s,%s,%s)",
            (trip_id, "cli_exp", status),
        )

    def _hold(self, trip_id, expires_at_sql, estado="activa", monto=1000):
        self.cur.execute(
            """
            INSERT INTO wallet_holds (user_id, user_type, trip_id, monto_cents, estado, expires_at)
            VALUES ('cli_exp','client',%s,%s,%s,%s)
            """,
            (trip_id, monto, estado, expires_at_sql),
        )

    def test_expira_hold_vencida_y_viaje_requested(self):
        self._viaje("test_exp_1", "requested")
        self.cur.execute(
            "INSERT INTO wallet_holds (user_id,user_type,trip_id,monto_cents,estado,expires_at) "
            "VALUES ('cli_exp','client','test_exp_1',1000,'activa', NOW() - INTERVAL '1 minute')"
        )
        self.cur.execute("SELECT * FROM expirar_holds_y_viajes(100)")
        holds, viajes, eventos = self.cur.fetchone()
        self.assertEqual((holds, viajes, eventos), (1, 1, 1))

        self.cur.execute("SELECT estado FROM wallet_holds WHERE trip_id='test_exp_1'")
        self.assertEqual(self.cur.fetchone()[0], "expirada")
        self.cur.execute("SELECT status FROM trips WHERE trip_id='test_exp_1'")
        self.assertEqual(self.cur.fetchone()[0], "expired")
        self.cur.execute(
            "SELECT event_type, payload->>'status' FROM outbox WHERE aggregate_id='test_exp_1'"
        )
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "trip.status_changed")
        self.assertEqual(row[1], "expired")

    def test_no_expira_viaje_en_curso(self):
        self._viaje("test_exp_2", "in_progress")
        self.cur.execute(
            "INSERT INTO wallet_holds (user_id,user_type,trip_id,monto_cents,estado,expires_at) "
            "VALUES ('cli_exp','client','test_exp_2',1000,'activa', NOW() - INTERVAL '1 minute')"
        )
        self.cur.execute("SELECT * FROM expirar_holds_y_viajes(100)")
        holds, viajes, eventos = self.cur.fetchone()
        self.assertEqual((holds, viajes, eventos), (1, 0, 0))
        self.cur.execute("SELECT estado FROM wallet_holds WHERE trip_id='test_exp_2'")
        self.assertEqual(self.cur.fetchone()[0], "expirada")
        self.cur.execute("SELECT status FROM trips WHERE trip_id='test_exp_2'")
        self.assertEqual(self.cur.fetchone()[0], "in_progress")

    def test_idempotente(self):
        self._viaje("test_exp_3", "requested")
        self.cur.execute(
            "INSERT INTO wallet_holds (user_id,user_type,trip_id,monto_cents,estado,expires_at) "
            "VALUES ('cli_exp','client','test_exp_3',1000,'activa', NOW() - INTERVAL '1 minute')"
        )
        self.cur.execute("SELECT * FROM expirar_holds_y_viajes(100)")
        self.cur.execute("SELECT * FROM expirar_holds_y_viajes(100)")
        holds, viajes, eventos = self.cur.fetchone()
        self.assertEqual((holds, viajes, eventos), (0, 0, 0))
        self.cur.execute("SELECT COUNT(*) FROM outbox WHERE aggregate_id='test_exp_3'")
        self.assertEqual(self.cur.fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()