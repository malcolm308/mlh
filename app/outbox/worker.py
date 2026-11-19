"""Worker del outbox: aplica en MongoDB lo que PostgreSQL ya decidió.

Diseño
------
1. **Claim**: una sola sentencia `UPDATE ... WHERE id = (SELECT ... FOR UPDATE
   SKIP LOCKED)` se queda con un evento y le pone un lease de 120 s. Dos
   workers pueden correr a la vez sin pisarse.
2. **Idempotencia**: antes de mover dinero se inserta el `event_id` en la
   colección `processed_events` (índice `unique`). Si la inserción choca, el
   evento ya se aplicó y solo se marca como procesado en Postgres.
3. **Cero cálculos**: el payload de `trip.completed` trae
   `chofer_neto_cents` ya calculado por el router. El worker hace un único
   `$inc` sobre `Chofer.users.Fondo`.
4. **Reintentos**: backoff exponencial (30 s, 60 s, 120 s...). Tras
   `max_intentos` el evento queda en `error` para revisión humana; no se
   descarta.

Uso
---
    python -m app.outbox.worker --una-pasada
    python -m app.outbox.worker --loop            # servicio continuo
    python -m app.outbox.worker --mongo-prefix test_

El worker real escribe en `Chofer.users`. El prefijo `test_` existe para las
pruebas y nunca debe usarse contra producción.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

RAIZ = Path(__file__).resolve().parents[2]
if str(RAIZ) not in sys.path:
    sys.path.insert(0, str(RAIZ))

import psycopg2  # noqa: E402
from bson import ObjectId  # noqa: E402
from bson.errors import InvalidId  # noqa: E402
from pymongo import MongoClient  # noqa: E402
from pymongo.errors import DuplicateKeyError  # noqa: E402

from app.money import de_cents  # noqa: E402
from app.outbox.events import (DriverPayoutV1,  # noqa: E402
                               TripCompletedV2)

logger = logging.getLogger("outbox.worker")

LEASE_SEGUNDOS = 120
MAX_INTENTOS = 8
BACKOFF_BASE_SEGUNDOS = 30
BACKOFF_MAX_SEGUNDOS = 3600


# ---------------------------------------------------------------------
# Conexiones
# ---------------------------------------------------------------------
def conectar_pg():
    url = os.getenv("POSTGRES_URL", "").strip()
    if url:
        return psycopg2.connect(url, connect_timeout=10)
    return psycopg2.connect(
        dbname=os.getenv("DB_NAME", "taxi_db"),
        user=os.getenv("DB_USER", "postgres"),
        password=os.getenv("DB_PASSWORD", ""),
        host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", "5432")),
        connect_timeout=10,
    )


def conectar_mongo(uri: str, prefijo: str = ""):
    cliente = MongoClient(uri, serverSelectionTimeoutMS=8000)
    chofer_col = cliente[f"{prefijo}Chofer"]["users"]
    processed_col = cliente[f"{prefijo}Chofer"]["processed_events"]
    return cliente, chofer_col, processed_col


def asegurar_indice(processed_col) -> None:
    """El índice único es la garantía de idempotencia. Debe existir siempre."""
    processed_col.create_index("event_id", unique=True,
                               name="ux_processed_event_id")


# ---------------------------------------------------------------------
# Aplicación de un evento (sin tocar Postgres)
# ---------------------------------------------------------------------
def _oid(valor: str) -> ObjectId:
    try:
        return ObjectId(str(valor))
    except (InvalidId, TypeError) as exc:
        raise ValueError(f"id de Mongo inválido: {valor!r}") from exc


def _reclamar_evento(processed_col, event_id: str, event_type: str) -> bool:
    """Registra el evento **antes** de tocar el saldo.

    Devuelve `True` si este worker es el primero en verlo (hay que aplicarlo)
    y `False` si ya existe (reproceso: se salta el `$inc` y solo hay que marcar
    el evento como procesado en Postgres).

    La unicidad la garantiza el índice, no una lectura previa: dos workers
    simultáneos no pueden insertar el mismo `event_id`.
    """
    try:
        processed_col.insert_one({
            "event_id": str(event_id),
            "event_type": event_type,
            "procesado_en": datetime.now(timezone.utc),
        })
        return True
    except DuplicateKeyError:
        return False


def aplicar_evento(chofer_col, processed_col, evento: dict[str, Any]) -> str:
    """Aplica un evento a Mongo. Devuelve un motivo legible.

    El `$inc` es atómico y el `event_id` ya quedó registrado en
    `processed_events`, así que un reproceso no puede duplicar el abono.
    No hace commit en Postgres: eso lo decide `procesar_lote`.
    """
    event_id = str(evento["id"])
    event_type = evento["event_type"]
    payload = evento["payload"]
    if isinstance(payload, str):
        payload = json.loads(payload)

    if not _reclamar_evento(processed_col, event_id, event_type):
        return "duplicado"

    if event_type == "trip.completed":
        modelo = TripCompletedV2(**payload)
        if modelo.mongo_aplicado:
            return "legacy_ya_aplicado"
        if not modelo.driver_id:
            return "sin_chofer"
        if modelo.chofer_neto_cents == 0:
            return "sin_movimiento"
        monto = float(de_cents(modelo.chofer_neto_cents))
        resultado = chofer_col.update_one(
            {"_id": _oid(modelo.driver_id)},
            {"$inc": {"Fondo": monto}},
        )
        if resultado.matched_count == 0:
            raise LookupError(
                f"Chofer {modelo.driver_id} no existe en MongoDB")
        logger.info("trip.completed %s: chofer %s +%.2f CUP",
                    modelo.trip_id, modelo.driver_id, monto)
        return "aplicado"

    if event_type == "driver.payout":
        modelo = DriverPayoutV1(**payload)
        if modelo.mongo_aplicado:
            return "legacy_ya_aplicado"
        if modelo.monto_cents == 0:
            return "sin_movimiento"
        monto = float(de_cents(modelo.monto_cents))
        resultado = chofer_col.update_one(
            {"_id": _oid(modelo.driver_id)},
            {"$inc": {"Fondo": -monto}},
        )
        if resultado.matched_count == 0:
            raise LookupError(
                f"Chofer {modelo.driver_id} no existe en MongoDB")
        logger.info("driver.payout %s: chofer %s -%.2f CUP",
                    modelo.payout_id, modelo.driver_id, monto)
        return "aplicado"

    # trip.created, trip.cancelled, trip.status_changed, wallet.changed...
    # No mueven dinero por el worker: sus escrituras de Mongo van por el
    # camino legacy o son solo de display.
    return "sin_movimiento"


# ---------------------------------------------------------------------
# Claim y procesamiento en Postgres
# ---------------------------------------------------------------------
def reclamar_siguiente(conn, *, lease_segundos: int = LEASE_SEGUNDOS
                       ) -> Optional[dict[str, Any]]:
    """Toma un evento pendiente y lo pone en lease. Devuelve None si no hay.

    `FOR UPDATE SKIP LOCKED` permite varios workers sin contención. El lease
    evita que un evento quede bloqueado para siempre si el proceso muere.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE outbox
               SET intentos = intentos + 1,
                   next_retry_at = NOW() + (%s * INTERVAL '1 second')
             WHERE id = (
                   SELECT id
                     FROM outbox
                    WHERE estado = 'pendiente'
                      AND next_retry_at <= NOW()
                    ORDER BY created_at
                    LIMIT 1
                      FOR UPDATE SKIP LOCKED
             )
         RETURNING id::text, event_type, payload, intentos
            """,
            (max(1, int(lease_segundos)),),
        )
        fila = cur.fetchone()
    conn.commit()
    if not fila:
        return None
    return {"id": fila[0], "event_type": fila[1], "payload": fila[2],
            "intentos": int(fila[3])}


def marcar_procesado(conn, event_id: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE outbox SET estado = 'procesado', processed_at = NOW(), "
            "last_error = NULL WHERE id = %s", (event_id,))
    conn.commit()


def marcar_fallo(conn, event_id: str, intentos: int, error: str,
                 *, max_intentos: int = MAX_INTENTOS) -> str:
    """Backoff exponencial. Devuelve el estado final del evento."""
    if intentos >= max_intentos:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE outbox SET estado = 'error', last_error = %s "
                "WHERE id = %s", (error[:2000], event_id))
        conn.commit()
        return "error"

    espera = min(BACKOFF_BASE_SEGUNDOS * (2 ** max(0, intentos - 1)),
                 BACKOFF_MAX_SEGUNDOS)
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE outbox SET estado = 'pendiente', last_error = %s, "
            "next_retry_at = NOW() + (%s * INTERVAL '1 second') "
            "WHERE id = %s", (error[:2000], espera, event_id))
    conn.commit()
    return "reintento"


def contar_pendientes(conn, *, solo_vencidos: bool = False) -> int:
    """Número de eventos pendientes en el outbox."""
    sql = "SELECT COUNT(*) FROM outbox WHERE estado = 'pendiente'"
    if solo_vencidos:
        sql += " AND next_retry_at <= NOW()"
    with conn.cursor() as cur:
        cur.execute(sql)
        return int(cur.fetchone()[0] or 0)


def procesar_lote(conn, chofer_col, processed_col, *,
                  limite: int = 100,
                  max_intentos: int = MAX_INTENTOS,
                  lease_segundos: int = LEASE_SEGUNDOS,
                  log=None) -> dict[str, int]:
    """Procesa hasta `limite` eventos. Nunca lanza por un evento concreto."""
    log = log or (lambda msg: None)
    stats = {"tomados": 0, "procesados": 0, "duplicados": 0,
             "errores": 0, "pendientes": 0}
    for _ in range(max(1, int(limite))):
        evento = reclamar_siguiente(conn, lease_segundos=lease_segundos)
        if evento is None:
            break
        stats["tomados"] += 1
        try:
            motivo = aplicar_evento(chofer_col, processed_col, evento)
            marcar_procesado(conn, evento["id"])
            stats["procesados"] += 1
            if motivo == "duplicado":
                stats["duplicados"] += 1
            log(f"[OK] {evento['event_type']} {evento['id']}: {motivo}")
        except Exception as exc:  # noqa: BLE001 - un evento malo no para la cola
            estado = marcar_fallo(conn, evento["id"], evento["intentos"],
                                  f"{type(exc).__name__}: {exc}",
                                  max_intentos=max_intentos)
            stats["errores"] += 1
            if estado == "reintento":
                stats["pendientes"] += 1
            logger.exception("Outbox: fallo el evento %s (%s)",
                             evento["id"], evento["event_type"])
            log(f"[X] {evento['event_type']} {evento['id']}: {estado}")
    return stats


# ---------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------
def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Worker outbox Postgres → Mongo")
    ap.add_argument("--mongo-uri", default=os.getenv("MONGODB_URI", ""))
    ap.add_argument("--mongo-prefix", default="")
    ap.add_argument("--limite", type=int, default=100)
    ap.add_argument("--max-intentos", type=int, default=MAX_INTENTOS)
    ap.add_argument("--intervalo", type=float, default=5.0,
                    help="segundos entre pasadas en modo --loop")
    modo = ap.add_mutually_exclusive_group()
    modo.add_argument("--una-pasada", action="store_true")
    modo.add_argument("--loop", action="store_true")
    args = ap.parse_args(argv)

    if not args.mongo_uri:
        print("[X] Falta MONGODB_URI o --mongo-uri")
        return 1

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s")

    cliente, chofer_col, processed_col = conectar_mongo(
        args.mongo_uri, args.mongo_prefix)
    asegurar_indice(processed_col)
    conn = conectar_pg()
    una_pasada = args.una_pasada or not args.loop

    try:
        while True:
            stats = procesar_lote(
                conn, chofer_col, processed_col,
                limite=args.limite, max_intentos=args.max_intentos,
                log=print)
            print(json.dumps({"evento": "pasada_outbox", **stats},
                             ensure_ascii=False), flush=True)
            if una_pasada:
                return 0
            if stats["tomados"] == 0:
                time.sleep(max(0.5, args.intervalo))
    except KeyboardInterrupt:
        return 0
    finally:
        conn.close()
        cliente.close()


if __name__ == "__main__":
    sys.exit(main())
