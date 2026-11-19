"""Pruebas del esquema wallet (migración 0001).

No necesitan MongoDB ni la app arrancada: solo PostgreSQL.

    python -m unittest tests.test_wallet_schema -v

Conexión: `TEST_POSTGRES_URL` si está definida; si no,
`postgresql://postgres@localhost:5432/taxi_db_test`.
El test se salta solo (skip) si la base no responde.

La base de pruebas debe tener el esquema de `trips` real. Se crea con
`init_db()` de la app; el `README` de `migrations/` explica cómo.
"""
from __future__ import annotations

import os
import unittest
from pathlib import Path

import psycopg2

RAIZ = Path(__file__).resolve().parents[1]
MIGRACION = RAIZ / "migrations" / "0001_wallet_core.sql"
ROLLBACK = RAIZ / "migrations" / "0001_wallet_core_rollback.sql"

DSN = os.getenv(
    "TEST_POSTGRES_URL",
    "postgresql://postgres@localhost:5432/taxi_db_test",
)


def _conectar():
    try:
        conn = psycopg2.connect(DSN, connect_timeout=3)
    except Exception as exc:  # pragma: no cover - entorno sin base
        raise unittest.SkipTest(f"PostgreSQL de pruebas no disponible: {exc}")
    conn.autocommit = True
    return conn


class TestEsquemaWallet(unittest.TestCase):
    """Verifica los objetos y las garantías que impone la migración."""

    @classmethod
    def setUpClass(cls):
        cls.conn = _conectar()
        with cls.conn.cursor() as cur:
            cur.execute("SELECT to_regclass('public.trips')")
            if cur.fetchone()[0] is None:
                raise unittest.SkipTest(
                    "La base de pruebas no tiene la tabla trips")
            cur.execute(MIGRACION.read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def setUp(self):
        self.cur = self.conn.cursor()
        self.cur.execute("DELETE FROM wallet_holds")
        self.cur.execute("DELETE FROM wallet_ledger")
        self.cur.execute("DELETE FROM trips WHERE trip_id LIKE 'test_%'")

    def tearDown(self):
        self.cur.execute("DELETE FROM wallet_holds")
        self.cur.execute("DELETE FROM wallet_ledger")
        self.cur.execute("DELETE FROM trips WHERE trip_id LIKE 'test_%'")
        self.cur.close()

    # -- utilidades ---------------------------------------------------
    def _viaje(self, trip_id="test_viaje", client_id="test_cliente"):
        self.cur.execute(
            "INSERT INTO trips (trip_id, client_id, status) "
            "VALUES (%s, %s, 'requested')", (trip_id, client_id))

    def _saldo(self, user_id, user_type="client"):
        self.cur.execute("SELECT saldo_disponible(%s, %s)",
                         (user_id, user_type))
        return self.cur.fetchone()[0]

    def _asiento(self, monto, clave, tipo="recarga", user_id="test_cliente"):
        self.cur.execute(
            "INSERT INTO wallet_ledger "
            "(user_id, user_type, tipo, monto_cents, idempotency_key) "
            "VALUES (%s, 'client', %s, %s, %s)",
            (user_id, tipo, monto, clave))

    # -- estructura ---------------------------------------------------
    def test_objetos_creados(self):
        self.cur.execute(
            "SELECT to_regclass('public.wallet_ledger'), "
            "       to_regclass('public.wallet_holds'), "
            "       to_regclass('public.outbox'), "
            "       to_regclass('public.v_wallet_saldos')")
        self.assertEqual(self.cur.fetchone(),
                         ("wallet_ledger", "wallet_holds", "outbox",
                          "v_wallet_saldos"))

        self.cur.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name = 'trips' AND column_name IN "
            "('monto_cents', 'fare_snapshot', 'client_display', "
            " 'driver_display')")
        self.assertEqual(len(self.cur.fetchall()), 4)

        self.cur.execute(
            "SELECT enumlabel FROM pg_enum e "
            "JOIN pg_type t ON t.oid = e.enumtypid "
            "WHERE t.typname = 'trip_status'")
        self.assertEqual(
            {r[0] for r in self.cur.fetchall()},
            {"requested", "accepted", "driver_on_the_way", "driver_arrived",
             "in_progress", "completed", "cancelled", "expired"})

    def test_migracion_idempotente(self):
        # setUpClass ya la aplicó una vez; una segunda pasada no debe fallar.
        self.cur.execute(MIGRACION.read_text(encoding="utf-8"))
        self.cur.execute(
            "SELECT count(*) FROM schema_migrations "
            "WHERE version = '0001_wallet_core'")
        self.assertEqual(self.cur.fetchone()[0], 1)

    # -- comportamiento del saldo -------------------------------------
    def test_recarga_suma_al_saldo(self):
        self._asiento(100000, "test:recarga")
        self.assertEqual(self._saldo("test_cliente"), 100000)

    def test_hold_descuenta_del_disponible(self):
        self._viaje()
        self._asiento(100000, "test:recarga")
        self.cur.execute(
            "INSERT INTO wallet_holds "
            "(user_id, user_type, trip_id, monto_cents, expires_at) "
            "VALUES ('test_cliente', 'client', 'test_viaje', 60000, "
            "        NOW() + INTERVAL '10 minutes')")
        self.assertEqual(self._saldo("test_cliente"), 40000)

    def test_hold_exacto_deja_saldo_en_cero(self):
        self._viaje()
        self._asiento(100000, "test:recarga")
        self.cur.execute(
            "INSERT INTO wallet_holds "
            "(user_id, user_type, trip_id, monto_cents, expires_at) "
            "VALUES ('test_cliente', 'client', 'test_viaje', 100000, "
            "        NOW() + INTERVAL '10 minutes')")
        self.assertEqual(self._saldo("test_cliente"), 0)

    def test_liberar_hold_devuelve_el_saldo(self):
        self._viaje()
        self._asiento(100000, "test:recarga")
        self.cur.execute(
            "INSERT INTO wallet_holds "
            "(user_id, user_type, trip_id, monto_cents, expires_at) "
            "VALUES ('test_cliente', 'client', 'test_viaje', 100000, "
            "        NOW() + INTERVAL '10 minutes')")
        self.cur.execute(
            "UPDATE wallet_holds SET estado = 'liberada' "
            "WHERE trip_id = 'test_viaje'")
        self.assertEqual(self._saldo("test_cliente"), 100000)

    def test_capturar_hold_no_lo_cuenta_dos_veces(self):
        """Tras capturar, el hold deja de restar y el ledger resta una vez."""
        self._viaje()
        self._asiento(100000, "test:recarga")
        self.cur.execute(
            "INSERT INTO wallet_holds "
            "(user_id, user_type, trip_id, monto_cents, expires_at) "
            "VALUES ('test_cliente', 'client', 'test_viaje', 40000, "
            "        NOW() + INTERVAL '10 minutes')")
        self.cur.execute(
            "UPDATE wallet_holds SET estado = 'capturada' "
            "WHERE trip_id = 'test_viaje'")
        self._asiento(-40000, "test:trip:captura", tipo="captura_viaje")
        self.assertEqual(self._saldo("test_cliente"), 60000)

    def test_saldos_separados_por_tipo_de_usuario(self):
        self._asiento(50000, "test:cliente", user_id="test_cliente")
        self._asiento(90000, "test:chofer", user_id="test_cliente")
        self.cur.execute(
            "UPDATE wallet_ledger SET user_type = 'driver' "
            "WHERE idempotency_key = 'test:chofer'")
        self.assertEqual(self._saldo("test_cliente", "client"), 50000)
        self.assertEqual(self._saldo("test_cliente", "driver"), 90000)

    # -- garantías de integridad --------------------------------------
    def test_idempotency_key_duplicada_es_rechazada(self):
        self._asiento(10000, "test:unica")
        with self.assertRaises(psycopg2.errors.UniqueViolation):
            self._asiento(10000, "test:unica")

    def test_doble_hold_del_mismo_viaje_es_rechazado(self):
        self._viaje()
        self.cur.execute(
            "INSERT INTO wallet_holds "
            "(user_id, user_type, trip_id, monto_cents, expires_at) "
            "VALUES ('test_cliente', 'client', 'test_viaje', 1000, "
            "        NOW() + INTERVAL '5 minutes')")
        with self.assertRaises(psycopg2.errors.UniqueViolation):
            self.cur.execute(
                "INSERT INTO wallet_holds "
                "(user_id, user_type, trip_id, monto_cents, expires_at) "
                "VALUES ('test_cliente', 'client', 'test_viaje', 1000, "
                "        NOW() + INTERVAL '5 minutes')")

    def test_estado_de_hold_invalido_es_rechazado(self):
        self._viaje()
        self.cur.execute(
            "INSERT INTO wallet_holds "
            "(user_id, user_type, trip_id, monto_cents, expires_at) "
            "VALUES ('test_cliente', 'client', 'test_viaje', 1000, "
            "        NOW() + INTERVAL '5 minutes')")
        with self.assertRaises(psycopg2.errors.CheckViolation):
            self.cur.execute(
                "UPDATE wallet_holds SET estado = 'volando' "
                "WHERE trip_id = 'test_viaje'")

    def test_monto_cero_es_rechazado(self):
        with self.assertRaises(psycopg2.errors.CheckViolation):
            self._asiento(0, "test:cero")

    def test_status_de_viaje_invalido_es_rechazado(self):
        with self.assertRaises(psycopg2.errors.CheckViolation):
            self.cur.execute(
                "INSERT INTO trips (trip_id, client_id, status) "
                "VALUES ('test_malo', 'test_cliente', 'asignado')")

    def test_outbox_pendiente_por_defecto(self):
        self.cur.execute(
            "INSERT INTO outbox (event_type, payload) "
            "VALUES ('trip.created', '{\"schema_version\": 1}') "
            "RETURNING estado, intentos, schema_version, next_retry_at <= NOW()")
        self.assertEqual(self.cur.fetchone(), ("pendiente", 0, 1, True))
