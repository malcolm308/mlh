"""Pruebas del worker del outbox y del cuadre tolerante (Tarea 4).

Cubren los criterios pedidos:

* `trip.completed` aplica el `Fondo` del chofer con un `$inc` atómico;
* reprocesar el mismo `event_id` no duplica el abono;
* `mongo_aplicado=True` no toca Mongo (el camino legacy ya lo aplicó);
* `driver.payout` resta del `Fondo`;
* un fallo pasa a `pendiente` con backoff y, al agotar los intentos, a
  `error` (nunca se descarta);
* el cuadre tolera los eventos `pendiente`/`error` del chofer y sigue
  siendo estricto con el cliente.

Necesitan PostgreSQL y MongoDB reales. Se saltan solos si no están:

    python -m unittest tests.test_outbox_worker -v

Variables:
    TEST_POSTGRES_URL   por defecto postgresql://postgres@localhost:5432/taxi_db_test
    TEST_MONGODB_URI    por defecto mongodb://localhost:27018
"""
from __future__ import annotations

import os
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2
from bson import ObjectId
from decimal import Decimal
from pymongo import MongoClient

from app.outbox import worker
from app.outbox.events import (DriverPayoutV1, TripCompletedV2, encolar)
from app.wallet import ledger, service
from app.wallet.backfill import comparar_cuadre

RAIZ = Path(__file__).resolve().parents[1]
MIGRACION = RAIZ / "migrations" / "0001_wallet_core.sql"

PG_DSN = os.getenv(
    "TEST_POSTGRES_URL",
    "postgresql://postgres@localhost:5432/taxi_db_test")
MONGO_URI = os.getenv("TEST_MONGODB_URI", "mongodb://localhost:27018")
PREFIJO = "test_"


class TestOutboxWorker(unittest.TestCase):

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
            cls.mongo = MongoClient(MONGO_URI, serverSelectionTimeoutMS=2000)
            cls.mongo.admin.command("ping")
        except Exception as exc:
            cls.conn.close()
            raise unittest.SkipTest(f"MongoDB no disponible: {exc}")

        cls.col_cliente = cls.mongo[f"{PREFIJO}Cliente"]["users"]
        cls.col_chofer = cls.mongo[f"{PREFIJO}Chofer"]["users"]
        cls.col_procesados = cls.mongo[f"{PREFIJO}Chofer"]["processed_events"]
        worker.asegurar_indice(cls.col_procesados)

    @classmethod
    def tearDownClass(cls):
        cls.mongo.drop_database(f"{PREFIJO}Cliente")
        cls.mongo.drop_database(f"{PREFIJO}Chofer")
        cls.mongo.close()
        with cls.conn.cursor() as cur:
            cur.execute("DELETE FROM outbox WHERE aggregate_id LIKE 'test-%' "
                        "OR event_type = 'driver.payout'")
            cur.execute("DELETE FROM wallet_ledger")
        cls.conn.commit()
        cls.conn.close()

    def setUp(self):
        self.col_cliente.delete_many({})
        self.col_chofer.delete_many({})
        self.col_procesados.delete_many({})
        with self.conn.cursor() as cur:
            cur.execute("DELETE FROM outbox WHERE aggregate_id LIKE 'test-%' "
                        "OR event_type = 'driver.payout'")
            cur.execute("DELETE FROM wallet_ledger")
            cur.execute("DELETE FROM trips WHERE trip_id LIKE 'test-%'")
        self.conn.commit()

        self.driver_id = str(ObjectId())
        self.col_chofer.insert_one({"_id": ObjectId(self.driver_id),
                                    "Nombre": "Chofer Test", "Fondo": 0})

    def tearDown(self):
        if not self.conn.closed:
            self.conn.rollback()

    # -- utilidades ----------------------------------------------------
    def _encolar_completed(self, *, trip_id, chofer_neto_cents,
                           mongo_aplicado=False, driver_id=None,
                           chofer_credito_cents=0, comision_cents=0):
        encolar(
            self.conn,
            event_type="trip.completed",
            aggregate_type="trip",
            aggregate_id=trip_id,
            payload=TripCompletedV2(
                trip_id=trip_id,
                client_id=str(ObjectId()),
                driver_id=driver_id or self.driver_id,
                status="completed",
                payment_method="Efectivo",
                total_cents=chofer_neto_cents,
                chofer_credito_cents=chofer_credito_cents,
                comision_cents=comision_cents,
                chofer_neto_cents=chofer_neto_cents,
                mongo_aplicado=mongo_aplicado,
            ),
        )
        self.conn.commit()

    def _fondo(self):
        doc = self.col_chofer.find_one({"_id": ObjectId(self.driver_id)})
        return float(doc.get("Fondo") or 0)

    def _outbox(self):
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT event_type, estado, intentos FROM outbox "
                "WHERE aggregate_id LIKE 'test-%' ORDER BY created_at")
            return cur.fetchall()

    # -- aplicación ---------------------------------------------------
    def test_trip_completed_plica_el_fondo(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        self._encolar_completed(trip_id=trip_id, chofer_neto_cents=50000,
                                chofer_credito_cents=50000)

        stats = worker.procesar_lote(self.conn, self.col_chofer,
                                     self.col_procesados, log=lambda m: None)

        self.assertEqual(stats["procesados"], 1)
        self.assertEqual(self._fondo(), 500.0)
        self.assertEqual(self._outbox(), [("trip.completed", "procesado", 1)])
        self.assertEqual(self.col_procesados.count_documents({}), 1)

    def test_reproceso_no_duplica(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        self._encolar_completed(trip_id=trip_id, chofer_neto_cents=50000)

        primero = worker.procesar_lote(self.conn, self.col_chofer,
                                       self.col_procesados, log=lambda m: None)
        self.assertEqual(primero["procesados"], 1)
        self.assertEqual(self._fondo(), 500.0)

        # Se fuerza el reproceso: el evento vuelve a `pendiente` pero el
        # `event_id` ya está en `processed_events`.
        with self.conn.cursor() as cur:
            cur.execute("UPDATE outbox SET estado = 'pendiente', "
                        "next_retry_at = NOW() WHERE aggregate_id = %s",
                        (trip_id,))
        self.conn.commit()

        segundo = worker.procesar_lote(self.conn, self.col_chofer,
                                       self.col_procesados, log=lambda m: None)
        self.assertEqual(segundo["duplicados"], 1)
        self.assertEqual(self._fondo(), 500.0)

    def test_mongo_aplicado_no_toca_mongo(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        self._encolar_completed(trip_id=trip_id, chofer_neto_cents=50000,
                                mongo_aplicado=True)

        stats = worker.procesar_lote(self.conn, self.col_chofer,
                                     self.col_procesados, log=lambda m: None)

        self.assertEqual(stats["procesados"], 1)
        self.assertEqual(self._fondo(), 0.0)
        self.assertEqual(self._outbox(), [("trip.completed", "procesado", 1)])

    def test_driver_payout_resta_del_fondo(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        self.col_chofer.update_one({"_id": ObjectId(self.driver_id)},
                                   {"$set": {"Fondo": 1000.0}})
        encolar(
            self.conn,
            event_type="driver.payout",
            aggregate_type="driver",
            aggregate_id=trip_id,
            payload=DriverPayoutV1(
                payout_id=f"test-{uuid.uuid4().hex[:8]}",
                driver_id=self.driver_id,
                monto_cents=30000,
            ),
        )
        self.conn.commit()

        worker.procesar_lote(self.conn, self.col_chofer, self.col_procesados,
                             log=lambda m: None)

        self.assertEqual(self._fondo(), 700.0)
        self.assertEqual(self._outbox(), [("driver.payout", "procesado", 1)])

    def test_evento_sin_movimiento_se_marca_procesado(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        self._encolar_completed(trip_id=trip_id, chofer_neto_cents=0)

        stats = worker.procesar_lote(self.conn, self.col_chofer,
                                     self.col_procesados, log=lambda m: None)

        self.assertEqual(stats["procesados"], 1)
        self.assertEqual(self._fondo(), 0.0)
        self.assertEqual(self._outbox(), [("trip.completed", "procesado", 1)])

    # -- backoff y error ----------------------------------------------
    def test_fallo_reintenta_con_backoff(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        # El chofer no existe en Mongo: el `$inc` no puede aplicarse.
        inexistente = str(ObjectId())
        self._encolar_completed(trip_id=trip_id, chofer_neto_cents=50000,
                                driver_id=inexistente)

        stats = worker.procesar_lote(
            self.conn, self.col_chofer, self.col_procesados,
            max_intentos=3, log=lambda m: None)

        self.assertEqual(stats["errores"], 1)
        self.assertEqual(stats["pendientes"], 1)
        filas = self._outbox()
        self.assertEqual(filas[0][0], "trip.completed")
        self.assertEqual(filas[0][1], "pendiente")
        self.assertEqual(filas[0][2], 1)

    def test_error_al_agotar_intentos(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        inexistente = str(ObjectId())
        self._encolar_completed(trip_id=trip_id, chofer_neto_cents=50000,
                                driver_id=inexistente)

        stats = worker.procesar_lote(
            self.conn, self.col_chofer, self.col_procesados,
            max_intentos=1, log=lambda m: None)

        self.assertEqual(stats["errores"], 1)
        self.assertEqual(stats["pendientes"], 0)
        self.assertEqual(self._outbox()[0][1], "error")
        # El evento no se descarta: queda para revisión.
        with self.conn.cursor() as cur:
            cur.execute("SELECT last_error FROM outbox WHERE aggregate_id = %s",
                        (trip_id,))
            self.assertIn("no existe", cur.fetchone()[0])

    # -- ledger del chofer --------------------------------------------
    def test_acreditar_chofer_viaje_idempotente(self):
        trip_id = f"test-{uuid.uuid4().hex[:16]}"
        with self.conn.cursor() as cur:
            cur.execute(
                "INSERT INTO trips (trip_id, client_id, status) "
                "VALUES (%s, %s, 'in_progress')", (trip_id, str(ObjectId())))
        self.conn.commit()

        primero = service.acreditar_chofer_viaje(
            self.conn, trip_id=trip_id, driver_id=self.driver_id,
            chofer_credito_cents=50000, comision_cents=5000)
        segundo = service.acreditar_chofer_viaje(
            self.conn, trip_id=trip_id, driver_id=self.driver_id,
            chofer_credito_cents=50000, comision_cents=5000)
        self.conn.commit()

        self.assertEqual(primero["insertadas"],
                         ["chofer_credito", "comision"])
        self.assertEqual(segundo["insertadas"], [])
        self.assertEqual(primero["saldo_cents"], 45000)
        self.assertEqual(service.saldo(self.conn, self.driver_id,
                                       "driver")["saldo_cents"], 45000)
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM wallet_ledger WHERE trip_id = %s",
                (trip_id,))
            self.assertEqual(cur.fetchone()[0], 2)

    # -- cuadre tolerante ---------------------------------------------
    def test_cuadre_tolera_evento_pendiente_del_chofer(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        with self.conn.cursor() as cur:
            cur.execute(
                "INSERT INTO trips (trip_id, client_id, status) "
                "VALUES (%s, %s, 'completed')", (trip_id, str(ObjectId())))
        # Postgres ya tiene el asiento del viaje; Mongo aún no.
        ledger.insertar_asiento(
            self.conn, user_id=self.driver_id, user_type="driver",
            tipo="captura_viaje", monto_cents=50000,
            idempotency_key=f"trip:{trip_id}:chofer_credito",
            trip_id=trip_id)
        self.conn.commit()
        self._encolar_completed(trip_id=trip_id, chofer_neto_cents=50000)

        informe = comparar_cuadre(self.conn, self.col_cliente, self.col_chofer)
        self.assertTrue(informe["ok"], informe["diferencias"])
        self.assertEqual(len(informe["tolerados_por_outbox"]), 1)
        self.assertEqual(
            informe["pendientes_outbox_cents"][self.driver_id], 50000)

        estricto = comparar_cuadre(self.conn, self.col_cliente, self.col_chofer,
                                   tolerar_outbox=False)
        self.assertFalse(estricto["ok"])
        self.assertEqual(len(estricto["diferencias"]), 1)
        self.assertEqual(estricto["diferencias"][0]["delta_cents"], 50000)

    def test_cuadre_cliente_sigue_siendo_estricto(self):
        cliente_id = str(ObjectId())
        self.col_cliente.insert_one({"_id": ObjectId(cliente_id),
                                     "Nombre": "Cliente", "Fondo": 100.0})
        ledger.insertar_asiento(
            self.conn, user_id=cliente_id, user_type="client",
            tipo="ajuste", monto_cents=20000,
            idempotency_key=f"test:{uuid.uuid4().hex}")
        self.conn.commit()

        informe = comparar_cuadre(self.conn, self.col_cliente, self.col_chofer)
        self.assertFalse(informe["ok"])
        self.assertEqual(informe["diferencias"][0]["user_type"], "client")
        self.assertEqual(informe["diferencias"][0]["delta_cents"], 10000)
        self.assertEqual(informe["tolerados_por_outbox"], [])

    def test_cuadre_tolera_driver_payout_pendiente(self):
        trip_id = f"test-{uuid.uuid4().hex[:12]}"
        # Mongo tiene 1.000; el ledger tiene 700 porque aún no se aplicó el
        # payout de 300.
        self.col_chofer.update_one({"_id": ObjectId(self.driver_id)},
                                   {"$set": {"Fondo": 1000.0}})
        ledger.insertar_asiento(
            self.conn, user_id=self.driver_id, user_type="driver",
            tipo="ajuste", monto_cents=100000,
            idempotency_key=f"test:{uuid.uuid4().hex}")
        ledger.insertar_asiento(
            self.conn, user_id=self.driver_id, user_type="driver",
            tipo="liquidacion", monto_cents=-30000,
            idempotency_key=f"trip:{trip_id}:payout")
        self.conn.commit()
        encolar(
            self.conn,
            event_type="driver.payout",
            aggregate_type="driver",
            aggregate_id=trip_id,
            payload=DriverPayoutV1(
                payout_id=f"test-{uuid.uuid4().hex[:8]}",
                driver_id=self.driver_id,
                monto_cents=30000,
            ),
        )
        self.conn.commit()

        informe = comparar_cuadre(self.conn, self.col_cliente, self.col_chofer)
        self.assertTrue(informe["ok"], informe["diferencias"])
        self.assertEqual(
            informe["pendientes_outbox_cents"][self.driver_id], -30000)


class TestRepartoViaje(unittest.TestCase):
    """El reparto se calcula antes del COMMIT y el worker no recalcula.

    Se prueba la función pura `_calcular_reparto_viaje` con el cliente y la
    comisión sustituidos, para no depender de tarifas ni de la promoción real.
    """

    def setUp(self):
        from bson import ObjectId
        self.driver_id = str(ObjectId())
        self.client_id = str(ObjectId())
        self.futuro = datetime.now(timezone.utc) + timedelta(days=2)

    def _promo(self, **cambios):
        base = {"comision_porcentaje": 0.15, "comision_billetera": 0.0,
                "recargo_transferencia": 0.10}
        base.update(cambios)
        return base

    def _reparto(self, *, total, cliente, payment_method, promo=None,
                 capturado_cents=0, precio_bruto=None, descuento_total=0,
                 comision_info=None, resolve_falla=False):
        from unittest import mock
        from routers import Solicitud_de_viajes_v4 as sv

        promo = promo or self._promo()
        precio_bruto = total if precio_bruto is None else precio_bruto

        def resolucion(*args, **kwargs):
            if resolve_falla:
                raise RuntimeError("mongo caido")
            return comision_info or {
                "rate": float(promo["comision_porcentaje"]),
                "label": "15 %", "discount_applied": False,
                "discount_date": "2026-01-01",
            }

        with mock.patch.object(sv.cliente_coleccion, "find_one",
                               return_value=cliente), \
             mock.patch.object(sv, "resolve_commission", side_effect=resolucion):
            return sv._calcular_reparto_viaje(
                trip={"client_id": self.client_id,
                      "driver_id": self.driver_id},
                total_fare=total,
                precio_bruto=precio_bruto,
                descuento_total=descuento_total,
                payment_method=payment_method,
                promo=promo,
                capturado_cents=capturado_cents,
            )

    def test_efectivo_deja_al_chofer_en_negativo_por_la_comision(self):
        reparto = self._reparto(total=1000.0, cliente=None,
                                payment_method="Efectivo")
        self.assertEqual(reparto["total"], Decimal("1000.00"))
        self.assertEqual(reparto["excedente"], Decimal("1000.00"))
        self.assertEqual(reparto["efectivo"], Decimal("1000.00"))
        self.assertEqual(reparto["chofer_credito"], Decimal("0.00"))
        self.assertEqual(reparto["comision"], Decimal("150.00"))
        self.assertEqual(reparto["chofer_neto"], Decimal("-150.00"))

    def test_billetera_paga_al_chofer_con_billetera(self):
        cliente = {"Fondo": 1000.0, "saldo_promocional": 0.0,
                   "fecha_expiracion_promocional": self.futuro}
        reparto = self._reparto(total=1000.0, cliente=cliente,
                                payment_method="Billetera")
        self.assertEqual(reparto["billetera"], Decimal("1000.00"))
        self.assertEqual(reparto["saldo"], Decimal("1000.00"))
        self.assertEqual(reparto["promo"], Decimal("0.00"))
        self.assertEqual(reparto["chofer_credito"], Decimal("1000.00"))
        self.assertEqual(reparto["comision"], Decimal("0.00"))
        self.assertEqual(reparto["chofer_neto"], Decimal("1000.00"))
        self.assertEqual(reparto["excedente"], Decimal("0.00"))

    def test_billetera_promocional_y_bono(self):
        cliente = {"Fondo": 500.0, "saldo_promocional": 600.0,
                   "fecha_expiracion_promocional": self.futuro,
                   "monto_bono_chofer_campana": 100.0}
        reparto = self._reparto(total=1000.0, cliente=cliente,
                                payment_method="Billetera")
        self.assertEqual(reparto["promo"], Decimal("600.00"))
        self.assertEqual(reparto["saldo"], Decimal("400.00"))
        self.assertEqual(reparto["billetera"], Decimal("1000.00"))
        self.assertEqual(reparto["bono"], Decimal("100.00"))
        self.assertEqual(reparto["chofer_credito"], Decimal("1100.00"))
        self.assertEqual(reparto["chofer_neto"], Decimal("1100.00"))

    def test_sin_mongo_usa_lo_capturado_en_postgres(self):
        reparto = self._reparto(total=1000.0, cliente=None,
                                payment_method="Billetera",
                                capturado_cents=40000)
        # `cliente=None` no simula una caída: se necesita que find_one falle.
        # Este caso se cubre abajo con `resolve_falla` y un cliente real.
        self.assertEqual(reparto["billetera"], Decimal("0.00"))

    def test_caida_de_mongo_al_leer_el_cliente_usa_el_capturado(self):
        from unittest import mock
        from routers import Solicitud_de_viajes_v4 as sv

        with mock.patch.object(sv.cliente_coleccion, "find_one",
                               side_effect=RuntimeError("mongo caido")):
            reparto = sv._calcular_reparto_viaje(
                trip={"client_id": self.client_id,
                      "driver_id": self.driver_id},
                total_fare=1000.0, precio_bruto=1000.0, descuento_total=0,
                payment_method="Billetera", promo=self._promo(),
                capturado_cents=40000)

        self.assertEqual(reparto["billetera"], Decimal("400.00"))
        self.assertEqual(reparto["saldo"], Decimal("400.00"))
        self.assertEqual(reparto["promo"], Decimal("0.00"))
        self.assertEqual(reparto["excedente"], Decimal("600.00"))
        self.assertEqual(reparto["chofer_credito"], Decimal("400.00"))

    def test_caida_de_mongo_al_resolver_comision_usa_la_tasa_base(self):
        reparto = self._reparto(total=1000.0, cliente=None,
                                payment_method="Efectivo",
                                promo=self._promo(comision_porcentaje=0.20),
                                resolve_falla=True)
        self.assertEqual(reparto["comision"], Decimal("200.00"))
        self.assertEqual(reparto["comision_info"]["rate"], 0.20)


if __name__ == "__main__":
    unittest.main()
