"""Aplica un archivo .sql a la base configurada.

Uso:
    python scripts/aplicar_migraciones.py migrations/0001_wallet_core.sql
    python scripts/aplicar_migraciones.py migrations/0001_wallet_core_rollback.sql --si

Conexion: `POSTGRES_URL` si esta definida; si no, las mismas variables que
usa la app (`DB_PASSWORD`, host local, base `taxi_db`).

No imprime la cadena de conexion ni el contenido del archivo: solo el nombre
y el resultado. `--si` es obligatorio para scripts de rollback.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import psycopg2

RAIZ = Path(__file__).resolve().parents[1]


def conectar():
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
    ap = argparse.ArgumentParser()
    ap.add_argument("archivo", help="ruta al .sql")
    ap.add_argument("--si", action="store_true",
                    help="confirma que se ejecuta un rollback")
    args = ap.parse_args()

    ruta = Path(args.archivo)
    if not ruta.is_absolute():
        ruta = RAIZ / ruta
    if not ruta.is_file():
        print(f"[X] No existe: {ruta}")
        return 1
    if "rollback" in ruta.name and not args.si:
        print("[X] Es un rollback. Repite con --si para confirmar.")
        return 1

    sql = ruta.read_text(encoding="utf-8")
    print(f"[..] Aplicando {ruta.name} ({len(sql)} bytes)")

    conn = conectar()
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(sql)
        print(f"[OK] {ruta.name} aplicado")
    except Exception as exc:
        print(f"[X] {ruta.name} fallo: {type(exc).__name__}: {exc}")
        return 1
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
