"""Migra los saldos de MongoDB a `wallet_ledger` (Tarea 2).

Uso habitual — primero en seco, luego de verdad:

    python scripts/backfill_saldo.py --dry-run
    python scripts/backfill_saldo.py --escribir

Es idempotente: se puede repetir tantas veces como haga falta. Guarda un
checkpoint por colección en `scripts/.backfill_saldo.json` para reanudar si
se corta a mitad; `--no-checkpoint` lo desactiva.

Conexión:
    MONGODB_URI      cadena de Atlas (o local)
    POSTGRES_URL     base destino (o DB_HOST/DB_PORT/DB_USER/DB_PASSWORD)

`--mongo-prefix test_` permite apuntar a bases de prueba sin tocar las reales.
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

from app.wallet.backfill import ejecutar_backfill  # noqa: E402

CHECKPOINT = Path(__file__).resolve().with_name(".backfill_saldo.json")


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


def colecciones(uri: str, prefijo: str = ""):
    cliente = MongoClient(uri, serverSelectionTimeoutMS=5000)
    return cliente, cliente[f"{prefijo}Cliente"]["users"], \
        cliente[f"{prefijo}Chofer"]["users"]


def leer_checkpoint() -> dict[str, str]:
    try:
        return json.loads(CHECKPOINT.read_text(encoding="utf-8"))
    except Exception:
        return {}


def guardar_checkpoint(datos: dict[str, str]) -> None:
    CHECKPOINT.write_text(json.dumps(datos, ensure_ascii=False, indent=2),
                          encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Backfill de saldos Mongo → wallet_ledger")
    ap.add_argument("--escribir", action="store_true",
                    help="escribe de verdad (por defecto solo simula)")
    ap.add_argument("--dry-run", action="store_true",
                    help="fuerza la simulación (por defecto ya lo es)")
    ap.add_argument("--batch-size", type=int, default=200)
    ap.add_argument("--limit", type=int, default=None,
                    help="máximo de documentos por colección (pruebas)")
    ap.add_argument("--mongo-uri", default=os.getenv("MONGODB_URI", ""))
    ap.add_argument("--mongo-prefix", default="",
                    help="prefijo de las bases de Mongo (ej. test_)")
    ap.add_argument("--incluir-ceros", action="store_true")
    ap.add_argument("--no-checkpoint", action="store_true")
    ap.add_argument("--reiniciar", action="store_true",
                    help="ignora el checkpoint y empieza desde el principio")
    args = ap.parse_args()

    if not args.mongo_uri:
        print("[X] Falta MONGODB_URI o --mongo-uri")
        return 1

    escribir = args.escribir and not args.dry_run
    desde = {} if (args.reiniciar or args.no_checkpoint) else leer_checkpoint()

    cliente, col_cliente, col_chofer = colecciones(args.mongo_uri,
                                                   args.mongo_prefix)
    conn = None
    if escribir:
        try:
            conn = conectar_pg()
        except Exception as exc:
            cliente.close()
            print(f"[X] No se pudo conectar a PostgreSQL: {exc}")
            return 1

    def progreso(coleccion: str, ultimo_id: str, _stats: dict) -> None:
        if args.no_checkpoint:
            return
        datos = leer_checkpoint() if not args.reiniciar else {}
        datos[coleccion] = ultimo_id
        guardar_checkpoint(datos)

    modo = "ESCRITURA" if escribir else "SIMULACIÓN"
    print(f"[..] Backfill en modo {modo}"
          + (f" (reanudando desde {desde})" if desde else ""))

    try:
        stats = ejecutar_backfill(
            conn, col_cliente, col_chofer,
            dry_run=not escribir,
            batch_size=max(1, args.batch_size),
            limite=args.limit,
            desde=desde,
            incluir_ceros=args.incluir_ceros,
            progreso=progreso,
            log=print,
        )
    except Exception as exc:
        if conn:
            conn.rollback()
        print(f"[X] Backfill abortado: {type(exc).__name__}: {exc}")
        return 1
    finally:
        if conn:
            conn.close()
        cliente.close()

    print(json.dumps(stats, ensure_ascii=False, indent=2))
    if not escribir:
        print("[i] Simulación: no se escribió nada. Repite con --escribir.")
    elif stats["errores"]:
        print(f"[!] {stats['errores']} errores; revisa el log antes de cerrar.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
