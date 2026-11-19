"""Pruebas del cableado de la billetera en los endpoints (Tarea 3).

Dos cosas que los tests de servicio no pueden demostrar:

* que `SaldoInsuficiente` sale como **402** y no como 500;
* que `cancel_trip` libera la reserva y encola el evento en la MISMA
  transacción de la cancelación.

El primer test no necesita base de datos (se sustituye `create_trip`).
El segundo usa PostgreSQL real y se salta solo si no está.
"""
from __future__ import annotations

import asyncio
import os
import unittest
import uuid
from contextlib import contextmanager
from pathlib import Path

import psycopg2
from fastapi import BackgroundTasks, HTTPException

import routers.Solicitud_de_viajes_v4 as sv
from app import config as wallet_flags
from app.wallet import ledger, service
from app.wallet.errors import SaldoInsuficiente

RAIZ = Path(__file__).resolve().parents[1]
MIGRACION = RAIZ / "migrations" / "0001_wallet_core.sql"

PG_DSN = os.getenv(
    "TEST_POSTGRES_URL",
    "postgresql://postgres@localhost:5432/taxi_db_test")


class TestApiSinSaldo(unittest.TestCase):

    def test_saldo_insuficiente_devuelve_402(self):
        original = sv.create_trip

        def sin_saldo(**kwargs):
            raise SaldoInsuficiente(50000, 30000)

        sv.create_trip = sin_saldo
        try:
            body = sv.TripCreate(
                client_id="test-cliente",
                request_lat=23.1, request_lng=-82.4,
                dropoff_lat=23.2, dropoff_lng=-82.5,
                payment_method="Billetera",
            )
            with self.assertRaises(HTTPException) as ctx:
                asyncio.run(sv.api_create_trip(body, BackgroundTasks()))
        finally:
            sv.create_trip = original

        error = ctx.exception
        self.assertEqual(error.status_code, 402)
        self.assertEqual(error.detail["code"], "saldo_insuficiente")
        self.assertEqual(error.detail["requerido_cents"], 50000)
        self.assertEqual(error.detail["disponible_cents"], 30000)


class TestCancelarLiberaHold(unittest.TestCase):

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

    @classmethod
    def tearDownClass(cls):
        cls._limpiar(cls.conn)
        cls.conn.close()

    @staticmethod
    def _limpiar(conn):
        with conn.cursor() as cur:
            cur.execute("DELETE FROM wallet_holds WHERE trip_id LIKE 'test-%'")
            cur.execute("DELETE FROM wallet_ledger WHERE user_id LIKE %s",
                        ("test-%",))
            cur.execute("DELETE FROM outbox WHERE aggregate_id LIKE %s",
                        ("test-%",))
            cur.execute("DELETE FROM trips WHERE trip_id LIKE 'test-%'")
        conn.commit()

    def setUp(self):
        self._limpiar(self.conn)
        self.user = f"test-{uuid.uuid4().hex[:12]}"
        self.trip_id = f"test-{uuid.uuid4().hex[:16]}"

        with self.conn.cursor() as cur:
            ledger.insertar_asiento(
                self.conn, user_id=self.user, user_type="client",
                tipo="ajuste", monto_cents=50000,
                idempotency_key=f"test:{uuid.uuid4().hex}")
            cur.execute(
                "INSERT INTO trips (trip_id, client_id, status, "
                "payment_method) VALUES (%s, %s, 'requested', 'Billetera')",
                (self.trip_id, self.user))
        service.reservar_hold(self.conn, user_id=self.user,
                              trip_id=self.trip_id, monto_cents=20000)
        self.conn.commit()

        # `cancel_trip` abre su propia conexión: se le pasa la del test para
        # poder comprobar el resultado sin tocar la base real.
        self._original_get_connection = sv.get_connection
        self._original_dual = wallet_flags.WALLET_DUAL_WRITE
        self._original_enforce = wallet_flags.WALLET_ENFORCE_HOLD
        conn = self.conn

        @contextmanager
        def conexion_de_prueba():
            yield conn

        sv.get_connection = conexion_de_prueba
        wallet_flags.WALLET_DUAL_WRITE = True
        wallet_flags.WALLET_ENFORCE_HOLD = True

    def tearDown(self):
        sv.get_connection = self._original_get_connection
        wallet_flags.WALLET_DUAL_WRITE = self._original_dual
        wallet_flags.WALLET_ENFORCE_HOLD = self._original_enforce
        if not self.conn.closed:
            self.conn.rollback()
        self._limpiar(self.conn)

    def test_cancelar_libera_el_hold_y_encola_el_evento(self):
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 30000)

        self.assertTrue(sv.cancel_trip(self.trip_id))

        self.assertEqual(service.saldo_disponible(self.conn, self.user), 50000)
        with self.conn.cursor() as cur:
            cur.execute("SELECT estado FROM wallet_holds WHERE trip_id = %s",
                        (self.trip_id,))
            self.assertEqual(cur.fetchone()[0], "liberada")
            cur.execute("SELECT status FROM trips WHERE trip_id = %s",
                        (self.trip_id,))
            self.assertEqual(cur.fetchone()[0], "cancelled")
            cur.execute("SELECT event_type, payload->>'status' FROM outbox "
                        "WHERE aggregate_id = %s", (self.trip_id,))
            self.assertEqual(cur.fetchall(), [("trip.cancelled", "cancelled")])
            cur.execute("SELECT COUNT(*) FROM wallet_ledger "
                        "WHERE user_id = %s AND tipo = 'captura_viaje'",
                        (self.user,))
            self.assertEqual(cur.fetchone()[0], 0)

    def test_cancelar_dos_veces_no_duplica_el_evento(self):
        self.assertTrue(sv.cancel_trip(self.trip_id))
        self.assertFalse(sv.cancel_trip(self.trip_id))
        with self.conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM outbox WHERE aggregate_id = %s",
                        (self.trip_id,))
            self.assertEqual(cur.fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()
