"""Pruebas del servicio de billetera (Tarea 3).

Cubren los criterios de aceptación que se pueden probar sin el worker:

* saldo exacto → la reserva deja el disponible en 0;
* saldo menor → no se crea el viaje (rollback) y no hay reserva;
* cancelar libera la reserva;
* capturar dos veces no cobra dos veces;
* 20 viajes concurrentes del mismo cliente no dejan saldo negativo ni
  duplican reservas.

Necesitan PostgreSQL real. Se saltan solos si no está:

    python -m unittest tests.test_wallet_service -v

Variable:
    TEST_POSTGRES_URL   por defecto postgresql://postgres@localhost:5432/taxi_db_test
"""
from __future__ import annotations

import os
import threading
import unittest
import uuid
from pathlib import Path

import psycopg2

from app.wallet import ledger, service
from app.wallet.errors import SaldoInsuficiente

RAIZ = Path(__file__).resolve().parents[1]
MIGRACION = RAIZ / "migrations" / "0001_wallet_core.sql"

PG_DSN = os.getenv(
    "TEST_POSTGRES_URL",
    "postgresql://postgres@localhost:5432/taxi_db_test")


class TestWalletService(unittest.TestCase):

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
            cur.execute("DELETE FROM wallet_ledger WHERE user_id LIKE 'test-%'")
            cur.execute("DELETE FROM outbox WHERE aggregate_id LIKE 'test-%'")
            cur.execute("DELETE FROM trips WHERE trip_id LIKE 'test-%'")
        conn.commit()

    def setUp(self):
        self._limpiar(self.conn)
        self.user = f"test-{uuid.uuid4().hex[:12]}"
        self.trip_ids = []

    def tearDown(self):
        if not self.conn.closed:
            self.conn.rollback()
        self._limpiar(self.conn)

    # -- utilidades ----------------------------------------------------
    def _fondear(self, monto_cents, user_type="client", user_id=None):
        with self.conn.cursor() as cur:
            ledger.insertar_asiento(
                self.conn,
                user_id=user_id or self.user,
                user_type=user_type,
                tipo="ajuste",
                monto_cents=monto_cents,
                idempotency_key=f"test:{uuid.uuid4().hex}",
                cur=cur,
            )
        self.conn.commit()

    def _crear_viaje(self, conn=None, payment_method="Billetera",
                     client_id=None):
        conn = conn or self.conn
        trip_id = f"test-{uuid.uuid4().hex[:16]}"
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO trips (trip_id, client_id, status, "
                "payment_method, precio_estimado) "
                "VALUES (%s, %s, 'requested', %s, %s)",
                (trip_id, client_id or self.user, payment_method, 0))
        self.trip_ids.append(trip_id)
        return trip_id

    def _hold(self, trip_id):
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT monto_cents, estado FROM wallet_holds WHERE trip_id = %s",
                (trip_id,))
            return cur.fetchone()

    def _asientos(self, tipo=None):
        sql = ("SELECT user_id, monto_cents, tipo, idempotency_key "
               "FROM wallet_ledger WHERE user_id LIKE %s")
        params: list = ["test-%"]
        if tipo:
            sql += " AND tipo = %s"
            params.append(tipo)
        with self.conn.cursor() as cur:
            cur.execute(sql + " ORDER BY id", tuple(params))
            return cur.fetchall()

    def _outbox(self):
        with self.conn.cursor() as cur:
            cur.execute("SELECT event_type, aggregate_id FROM outbox "
                        "WHERE aggregate_id LIKE 'test-%' ORDER BY created_at")
            return cur.fetchall()

    # -- criterio 1: saldo exacto --------------------------------------
    def test_saldo_exacto_reserva_todo_y_disponible_queda_en_cero(self):
        self._fondear(50000)
        trip_id = self._crear_viaje()

        resultado = service.reservar_hold(
            self.conn, user_id=self.user, trip_id=trip_id,
            monto_cents=50000)
        self.conn.commit()

        self.assertTrue(resultado["creada"])
        self.assertEqual(resultado["saldo_disponible_cents"], 0)
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 0)
        self.assertEqual(self._hold(trip_id), (50000, "activa"))
        # La reserva no es un cobro: no hay asiento todavía.
        self.assertEqual(self._asientos("captura_viaje"), [])

    def test_saldo_menor_no_crea_viaje_ni_reserva(self):
        self._fondear(30000)
        trip_id = self._crear_viaje()

        with self.assertRaises(SaldoInsuficiente) as ctx:
            service.reservar_hold(
                self.conn, user_id=self.user, trip_id=trip_id,
                monto_cents=50000)
        self.assertEqual(ctx.exception.requerido_cents, 50000)
        self.assertEqual(ctx.exception.disponible_cents, 30000)
        # El router revierte la transacción completa: el viaje desaparece.
        self.conn.rollback()

        with self.conn.cursor() as cur:
            cur.execute("SELECT 1 FROM trips WHERE trip_id = %s", (trip_id,))
            self.assertIsNone(cur.fetchone())
            cur.execute("SELECT 1 FROM wallet_holds WHERE trip_id = %s",
                        (trip_id,))
            self.assertIsNone(cur.fetchone())
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 30000)

    def test_reserva_duplicada_devuelve_la_misma(self):
        self._fondear(50000)
        trip_id = self._crear_viaje()
        primero = service.reservar_hold(
            self.conn, user_id=self.user, trip_id=trip_id, monto_cents=20000)
        segundo = service.reservar_hold(
            self.conn, user_id=self.user, trip_id=trip_id, monto_cents=20000)
        self.conn.commit()

        self.assertTrue(primero["creada"])
        self.assertFalse(segundo["creada"])
        self.assertEqual(primero["hold_id"], segundo["hold_id"])
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 30000)
        with self.conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM wallet_holds "
                        "WHERE trip_id = %s", (trip_id,))
            self.assertEqual(cur.fetchone()[0], 1)

    # -- criterio 4: cancelar libera el hold ---------------------------
    def test_cancelar_libera_la_reserva(self):
        self._fondear(50000)
        trip_id = self._crear_viaje()
        service.reservar_hold(self.conn, user_id=self.user,
                              trip_id=trip_id, monto_cents=50000)
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 0)

        self.assertTrue(service.liberar_hold(self.conn, trip_id=trip_id))
        self.conn.commit()

        self.assertEqual(service.saldo_disponible(self.conn, self.user), 50000)
        self.assertEqual(self._hold(trip_id), (50000, "liberada"))
        self.assertEqual(self._asientos("captura_viaje"), [])
        # Idempotente: liberar dos veces no rompe ni mueve dinero.
        self.assertFalse(service.liberar_hold(self.conn, trip_id=trip_id))
        self.conn.commit()

    def test_cancelar_sin_reserva_no_falla(self):
        trip_id = self._crear_viaje()
        self.assertFalse(service.liberar_hold(self.conn, trip_id=trip_id))

    # -- captura -------------------------------------------------------
    def test_capturar_cobra_una_sola_vez(self):
        self._fondear(50000)
        trip_id = self._crear_viaje()
        service.reservar_hold(self.conn, user_id=self.user,
                              trip_id=trip_id, monto_cents=50000)

        primera = service.capturar_hold(self.conn, trip_id=trip_id)
        segunda = service.capturar_hold(self.conn, trip_id=trip_id)
        self.conn.commit()

        self.assertTrue(primera["capturada"])
        self.assertEqual(primera["monto_cents"], 50000)
        self.assertFalse(segunda["capturada"])
        self.assertEqual(segunda["motivo"], "ya_capturada")
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 0)
        self.assertEqual(len(self._asientos("captura_viaje")), 1)
        self.assertEqual(self._hold(trip_id), (50000, "capturada"))
        # Un evento wallet.changed, no dos.
        self.assertEqual(
            [e for e in self._outbox() if e[0] == "wallet.changed"].__len__(),
            1)

    def test_captura_parcial_nunca_deja_saldo_negativo(self):
        self._fondear(50000)
        trip_id = self._crear_viaje()
        service.reservar_hold(self.conn, user_id=self.user,
                              trip_id=trip_id, monto_cents=50000)

        # La tarifa final subió (espera) a 600 CUP y solo hay 500.
        resultado = service.capturar_hold(
            self.conn, trip_id=trip_id, monto_cents=60000,
            permitir_parcial=True)
        self.conn.commit()

        self.assertTrue(resultado["capturada"])
        self.assertEqual(resultado["monto_cents"], 50000)
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 0)
        self.assertGreaterEqual(
            service.saldo(self.conn, self.user)["saldo_cents"], 0)

    def test_captura_estricta_rechaza_importe_mayor(self):
        self._fondear(50000)
        trip_id = self._crear_viaje()
        service.reservar_hold(self.conn, user_id=self.user,
                              trip_id=trip_id, monto_cents=30000)
        self.conn.commit()

        with self.assertRaises(SaldoInsuficiente):
            service.capturar_hold(self.conn, trip_id=trip_id,
                                  monto_cents=60000)
        self.conn.rollback()
        self.assertEqual(self._hold(trip_id), (30000, "activa"))

    # -- criterio 5: concurrencia --------------------------------------
    def test_veinte_viajes_concurrentes_no_sobregiran(self):
        self._fondear(100000)  # alcanza para 3 viajes de 300 CUP

        resultados: list[tuple[str, str]] = []
        candado = threading.Lock()

        def intentar(indice: int):
            conn = psycopg2.connect(PG_DSN, connect_timeout=5)
            trip_id = f"test-{uuid.uuid4().hex[:16]}"
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO trips (trip_id, client_id, status, "
                        "payment_method) VALUES (%s, %s, 'requested', "
                        "'Billetera')", (trip_id, self.user))
                service.reservar_hold(conn, user_id=self.user,
                                      trip_id=trip_id, monto_cents=30000)
                conn.commit()
                with candado:
                    resultados.append(("ok", trip_id))
            except SaldoInsuficiente:
                conn.rollback()
                with candado:
                    resultados.append(("sin_saldo", trip_id))
            except Exception as exc:  # pragma: no cover - diagnóstico
                conn.rollback()
                with candado:
                    resultados.append((f"error:{type(exc).__name__}", trip_id))
            finally:
                conn.close()

        hilos = [threading.Thread(target=intentar, args=(i,))
                 for i in range(20)]
        for hilo in hilos:
            hilo.start()
        for hilo in hilos:
            hilo.join(timeout=30)

        exitos = [t for estado, t in resultados if estado == "ok"]
        errores = [r for r in resultados if not r[0] in ("ok", "sin_saldo")]

        self.assertEqual(errores, [])
        self.assertEqual(len(resultados), 20)
        self.assertLessEqual(len(exitos), 3)
        self.assertEqual(len(exitos), 3)

        disponible = service.saldo_disponible(self.conn, self.user)
        self.assertEqual(disponible, 10000)
        self.assertEqual(service.saldo(self.conn, self.user)["saldo_cents"],
                         100000)
        with self.conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM wallet_holds "
                        "WHERE user_id = %s AND estado = 'activa'",
                        (self.user,))
            self.assertEqual(cur.fetchone()[0], len(exitos))
            cur.execute("SELECT COUNT(DISTINCT trip_id) FROM wallet_holds "
                        "WHERE user_id = %s", (self.user,))
            self.assertEqual(cur.fetchone()[0], len(exitos))

    # -- recargas / descargos / expiración -----------------------------
    def test_recarga_y_descargo_con_idempotencia(self):
        clave = f"test-recarga:{uuid.uuid4().hex}"
        service.recargar_saldo(
            self.conn, user_id=self.user, user_type="client",
            monto_cents=10000, idempotency_key=clave)
        repetida = service.recargar_saldo(
            self.conn, user_id=self.user, user_type="client",
            monto_cents=10000, idempotency_key=clave)
        self.conn.commit()

        self.assertFalse(repetida["insertado"])
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 10000)

        with self.assertRaises(SaldoInsuficiente):
            service.descargar_saldo(
                self.conn, user_id=self.user, user_type="client",
                monto_cents=20000,
                idempotency_key=f"test-descargo:{uuid.uuid4().hex}")
        self.conn.rollback()

        service.descargar_saldo(
            self.conn, user_id=self.user, user_type="client",
            monto_cents=4000,
            idempotency_key=f"test-descargo:{uuid.uuid4().hex}")
        self.conn.commit()
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 6000)

    def test_expirar_holds_libera_saldo(self):
        self._fondear(50000)
        trip_id = self._crear_viaje()
        service.reservar_hold(self.conn, user_id=self.user,
                              trip_id=trip_id, monto_cents=40000)
        with self.conn.cursor() as cur:
            cur.execute("UPDATE wallet_holds SET expires_at = NOW() - "
                        "INTERVAL '1 minute' WHERE trip_id = %s", (trip_id,))
        self.conn.commit()

        expirados = service.expirar_holds(self.conn)
        self.conn.commit()

        self.assertIn(trip_id, expirados)
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 50000)
        self.assertEqual(self._hold(trip_id), (40000, "expirada"))

    def test_outbox_se_revierte_con_la_transaccion(self):
        trip_id = self._crear_viaje()
        service.recargar_saldo(
            self.conn, user_id=self.user, user_type="client",
            monto_cents=7000,
            idempotency_key=f"test:{uuid.uuid4().hex}")
        self.assertEqual(len(self._outbox()), 1)
        self.conn.rollback()
        self.assertEqual(self._outbox(), [])
        self.assertEqual(service.saldo_disponible(self.conn, self.user), 0)
        # trip_id solo para que el rollback no deje basura
        self.assertIsNotNone(trip_id)


if __name__ == "__main__":
    unittest.main()
