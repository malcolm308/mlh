"""Compara el saldo de MongoDB con `wallet_ledger` (Tareas 2 y 4).

    python scripts/verificar_cuadre.py
    python scripts/verificar_cuadre.py --json informe.json
    python scripts/verificar_cuadre.py --estricto

Salida: un informe JSON (una línea por diferencia, más el resumen) y un
código de salida 1 si hay cualquier diferencia. Pensado para el cron diario
de la Tarea 6: si devuelve 0, el cuadre está limpio.

El cuadre tolera el outbox: el chofer se actualiza de forma asíncrona, así
que los eventos `trip.completed` y `driver.payout` en `pendiente`/`error` se
suman al saldo de Mongo antes de comparar. El cliente se comprueba de forma
estricta. `--estricto` desactiva esa tolerancia.

Conexión: `MONGODB_URI` y `POSTGRES_URL` (o `DB_*`). `--mongo-prefix test_`
para bases de prueba.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
if str(RAIZ) not in sys.path:
    sys.path.insert(0, str(RAIZ))

import psycopg2  # noqa: E402
from pymongo import MongoClient  # noqa: E402

from app.wallet.backfill import comparar_cuadre  # noqa: E402


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


def main() -> int:
    ap = argparse.ArgumentParser(description="Cuadre Mongo vs wallet_ledger")
    ap.add_argument("--mongo-uri", default=os.getenv("MONGODB_URI", ""))
    ap.add_argument("--mongo-prefix", default="")
    ap.add_argument("--tolerancia", type=int, default=0,
                    help="diferencia aceptada en centavos (por defecto 0)")
    ap.add_argument("--estricto", action="store_true",
                    help="no tolerar eventos pendientes del outbox")
    ap.add_argument("--json", default="", help="ruta donde guardar el informe")
    args = ap.parse_args()

    if not args.mongo_uri:
        print("[X] Falta MONGODB_URI o --mongo-uri")
        return 1

    cliente = MongoClient(args.mongo_uri, serverSelectionTimeoutMS=5000)
    col_cliente = cliente[f"{args.mongo_prefix}Cliente"]["users"]
    col_chofer = cliente[f"{args.mongo_prefix}Chofer"]["users"]

    try:
        conn = conectar_pg()
    except Exception as exc:
        print(f"[X] No se pudo conectar a PostgreSQL: {exc}")
        return 1

    try:
        informe = comparar_cuadre(conn, col_cliente, col_chofer,
                                  tolerancia_cents=args.tolerancia,
                                  tolerar_outbox=not args.estricto)
    finally:
        conn.close()
        cliente.close()

    # Una línea JSON por diferencia: fácil de filtrar en los logs.
    for d in informe["diferencias"]:
        print(json.dumps({"evento": "diferencia_saldo", **d},
                         ensure_ascii=False))
    for d in informe["solo_en_postgres"]:
        print(json.dumps({"evento": "solo_en_postgres", **d},
                         ensure_ascii=False))

    print(json.dumps({"evento": "resumen_cuadre",
                      "ok": informe["ok"],
                      "usuarios_mongo": informe["usuarios_mongo"],
                      "usuarios_postgres": informe["usuarios_postgres"],
                      "diferencias": len(informe["diferencias"]),
                      "solo_en_postgres": len(informe["solo_en_postgres"]),
                      "tolerados_por_outbox": len(
                          informe.get("tolerados_por_outbox", [])),
                      "pendiente_outbox_cents": sum(
                          informe.get("pendientes_outbox_cents",
                                      {}).values()),
                      "revisado_en": informe["revisado_en"]},
                     ensure_ascii=False))

    if args.json:
        Path(args.json).write_text(
            json.dumps(informe, ensure_ascii=False, indent=2),
            encoding="utf-8")
        print(f"[i] Informe guardado en {args.json}")

    return 0 if informe["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
