# -*- coding: utf-8 -*-
"""
Pone la tilde en vehicle_type ('basico' -> 'basico' con tilde) de la BD local
taxi_db (localhost:5432), en las dos tablas donde aparece:

    tariffs                 (padre, UNIQUE en vehicle_type)
    time_pricing_rules      (hijo, FK -> tariffs.vehicle_type)

ORDEN DE LAS FK (confirmado):
    time_pricing_rules.vehicle_type -> tariffs.vehicle_type

    Ojo: NO basta con actualizar el padre primero. La FK es NO ACTION y se
    valida al terminar cada sentencia, asi que:
      - hijo primero  -> falla porque el valor nuevo no existe aun en el padre
      - padre primero -> falla porque quedan hijos apuntando al valor viejo
    Las dos ordenaciones revientan. La secuencia valida es:
      1) DROP CONSTRAINT de la FK
      2) UPDATE tariffs
      3) UPDATE time_pricing_rules
      4) ADD CONSTRAINT de la FK
    (todo dentro de una transaccion, con rollback si algo falla).

El script es idempotente: si ya no queda ninguna fila 'basico' hace 0 cambios
y solo re-verifica. La BD local ya fue actualizada con el mismo procedimiento.

Uso, desde E:\\Taxi_Rapid:
    python -X utf8 scripts_local_dev\\actualizar_basico_tilde.py
"""
import io
import os
import sys

sys.path.insert(0, r"E:\Taxi_Rapid")

# La consola de Windows usa cp1252: sin esto los acentos de los SELECT
# revientan o salen corruptos en la salida.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

import psycopg2

NUEVO = "b\u00e1sico"  # 'basico' con tilde
ANTIGUO = "basico"
CONSTRAINT = "time_pricing_rules_vehicle_type_fkey"

DB_CONFIG = {
    "dbname": "taxi_db",
    "user": "postgres",
    "password": os.environ.get("DB_PASSWORD", ""),
    "host": "localhost",
    "port": 5432,
}


def _existe_fk(cur) -> bool:
    """True si la FK ya esta puesta (para no reanadirla dos veces)."""
    cur.execute(
        """
        SELECT 1 FROM pg_constraint
        WHERE conname = %s
          AND conrelid = 'time_pricing_rules'::regclass
        """,
        (CONSTRAINT,),
    )
    return cur.fetchone() is not None


def main() -> int:
    conn = psycopg2.connect(**DB_CONFIG)
    try:
        conn.autocommit = False
        cur = conn.cursor()

        # 1) Quitar la FK (si esta puesta). Se anota si existia antes para
        #    no crear una FK que no estuviera en el esquema original.
        habia_fk = _existe_fk(cur)
        cur.execute(
            "ALTER TABLE time_pricing_rules DROP CONSTRAINT IF EXISTS %s"
            % CONSTRAINT
        )
        print(
            f"[OK] FK {CONSTRAINT} "
            + ("eliminada" if habia_fk else "no existia")
        )

        # 2) Padre: tariffs
        cur.execute(
            "UPDATE tariffs SET vehicle_type = %s WHERE vehicle_type = %s",
            (NUEVO, ANTIGUO),
        )
        print(f"[OK] tariffs actualizadas: {cur.rowcount} fila(s)")

        # 3) Hijo: time_pricing_rules
        cur.execute(
            "UPDATE time_pricing_rules SET vehicle_type = %s WHERE vehicle_type = %s",
            (NUEVO, ANTIGUO),
        )
        print(f"[OK] time_pricing_rules actualizadas: {cur.rowcount} fila(s)")

        # 4) Reponer la FK solo si estaba antes (no inventar FK nuevas)
        if habia_fk and not _existe_fk(cur):
            cur.execute(
                "ALTER TABLE time_pricing_rules ADD CONSTRAINT %s "
                "FOREIGN KEY (vehicle_type) REFERENCES tariffs(vehicle_type)"
                % CONSTRAINT
            )
            print(f"[OK] FK {CONSTRAINT} reanadida")
        elif habia_fk:
            print(f"[OK] FK {CONSTRAINT} ya estaba puesta")
        else:
            print(f"[i] FK {CONSTRAINT} no existia: no se reanade")

        conn.commit()

        # Verificacion final
        cur.execute("SELECT tariff_id, vehicle_type FROM tariffs ORDER BY tariff_id")
        print("\ntariffs:")
        for tid, vt in cur.fetchall():
            print(f"  {tid} -> {vt}")

        cur.execute(
            "SELECT DISTINCT vehicle_type FROM time_pricing_rules ORDER BY vehicle_type"
        )
        print("time_pricing_rules.vehicle_type distintos:")
        for (vt,) in cur.fetchall():
            print(f"  {vt}")

        cur.execute(
            "SELECT COUNT(*) FROM tariffs WHERE vehicle_type = %s", (ANTIGUO,)
        )
        restantes = cur.fetchone()[0]
        print(f"\nfilas que quedan sin tilde en tariffs: {restantes}")

        cur.close()
        return 0 if restantes == 0 else 1
    except Exception:
        conn.rollback()
        print("[X] Error: se hizo rollback, la BD queda como estaba", file=sys.stderr)
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
