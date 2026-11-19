"""Crea una base local con el MISMO esquema que producción.

No inventa DDL: reutiliza `init_db()` de `routers/Solicitud_de_viajes_v4.py`,
que es lo que la app ejecuta al arrancar. Sirve para los tests que necesitan
un PostgreSQL real (concurrencia, holds, outbox).

    python tools/crear_bd_pruebas.py taxi_db_test

Conexión administrativa: `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`
(por defecto `localhost:5432`, usuario `postgres`, sin contraseña).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import psycopg2

RAIZ = Path(__file__).resolve().parents[1]
if str(RAIZ) not in sys.path:
    sys.path.insert(0, str(RAIZ))


def main() -> int:
    base = sys.argv[1] if len(sys.argv) > 1 else "taxi_db_test"
    host = os.getenv("DB_HOST", "localhost")
    port = int(os.getenv("DB_PORT", "5432"))
    user = os.getenv("DB_USER", "postgres")
    pw = os.getenv("DB_PASSWORD", "")

    admin = psycopg2.connect(dbname="postgres", user=user, password=pw,
                             host=host, port=port)
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (base,))
        if cur.fetchone():
            print(f"[..] la base {base} ya existe")
        else:
            cur.execute(f'CREATE DATABASE "{base}"')
            print(f"[OK] base {base} creada")
    admin.close()

    # init_db lee POSTGRES_URL, igual que la app en producción.
    os.environ["POSTGRES_URL"] = (
        f"postgresql://{user}:{pw}@{host}:{port}/{base}")

    from routers import Solicitud_de_viajes_v4 as s  # noqa: E402

    s.init_pool()
    s.init_db()

    conn = psycopg2.connect(dbname=base, user=user, password=pw,
                            host=host, port=port)
    with conn.cursor() as cur:
        cur.execute(
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_name = 'trips' "
            "  AND column_name IN ('trip_id', 'client_id', 'status') "
            "ORDER BY column_name")
        print("trips:", cur.fetchall())
        cur.execute("SELECT extname FROM pg_extension ORDER BY 1")
        print("extensiones:", [r[0] for r in cur.fetchall()])
    conn.close()
    print(f"[OK] {base} lista. Usa TEST_POSTGRES_URL="
          f"postgresql://{user}@{host}:{port}/{base}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
