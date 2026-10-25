"""
Fase 1 - Inicializacion de precios anclados a USD (EJECUTAR UNA SOLA VEZ).

Consulta la tasa de cambio de HOY en El Toque y calcula el equivalente USD
de todos los precios actuales en CUP (tarifas + zonas especiales).
Guarda esos valores USD en la BD. Los precios en CUP de HOY no cambian.

Variable de entorno requerida:
    POSTGRES_URL  - URL de conexion a Supabase (ya configurada en Render)
    API_KEY_TOQUE - (opcional) API key de El Toque. Si no existe, usa endpoint publico.

Uso:
    python scripts/init_prices_usd.py
"""
import os
import sys
import logging
from decimal import Decimal, ROUND_HALF_UP

import httpx
import psycopg2
import psycopg2.extras

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("init_usd")

# ---------------------------------------------------------------------------
# 1. Obtener tasa de cambio de HOY
# ---------------------------------------------------------------------------

EL_TOQUE_PUBLIC = "https://www.eltoque.com/api/currencies/latest"
EL_TOQUE_API = "https://api.eltoque.com/currencies/latest"


def obtener_tasa_usd_hoy() -> float:
    """Devuelve la tasa USD->CUP de hoy."""
    api_key = os.getenv("API_KEY_TOQUE")
    headers = {"Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
        url = EL_TOQUE_API
    else:
        url = EL_TOQUE_PUBLIC
        headers["User-Agent"] = "RapiTaxi/1.0"

    with httpx.Client(timeout=30, follow_redirects=True) as client:
        r = client.get(url, headers=headers)
        r.raise_for_status()
        data = r.json()

    # El Toque devuelve {"USD": {"buy": 350, "sell": 355}, ...} o similar
    # Buscamos el campo USD. Si no existe, probamos otras estructuras.
    usd = data.get("USD") or data.get("usd") or data.get("dolar") or {}
    if isinstance(usd, dict):
        tasa = usd.get("sell") or usd.get("buy") or usd.get("rate") or usd.get("value")
    elif isinstance(usd, (int, float)):
        tasa = usd
    else:
        # Intentar estructura alternativa
        for key in ("USD", "usd", "dolar", "Dolar"):
            if key in data and isinstance(data[key], (int, float)):
                tasa = data[key]
                break
        else:
            raise ValueError(f"Estructura de respuesta inesperada: {data}")

    if not tasa:
        raise ValueError(f"No se encontro la tasa USD en la respuesta: {data}")
    return float(tasa)


# ---------------------------------------------------------------------------
# 2. Esquema de columnas USD a anadir
# ---------------------------------------------------------------------------

ALTER_TARIFAS = """
    ALTER TABLE tariffs
        ADD COLUMN IF NOT EXISTS base_fare_usd NUMERIC(12,6),
        ADD COLUMN IF NOT EXISTS price_per_km_usd NUMERIC(12,6),
        ADD COLUMN IF NOT EXISTS price_per_minute_usd NUMERIC(12,6);
"""

ALTER_PROMOCIONES = """
    ALTER TABLE promociones
        ADD COLUMN IF NOT EXISTS precio_km_zona_basico_usd NUMERIC(12,6),
        ADD COLUMN IF NOT EXISTS precio_km_zona_confort_usd NUMERIC(12,6),
        ADD COLUMN IF NOT EXISTS precio_km_zona_triciclo_usd NUMERIC(12,6),
        ADD COLUMN IF NOT EXISTS precio_km_zona_moto_usd NUMERIC(12,6),
        ADD COLUMN IF NOT EXISTS precio_por_minuto_usd NUMERIC(12,6);
"""

# ---------------------------------------------------------------------------
# 3. Script principal
# ---------------------------------------------------------------------------


def main():
    tasa = obtener_tasa_usd_hoy()
    log.info("Tasa USD de hoy: %.4f CUP/USD", tasa)

    with psycopg2.connect(os.environ["POSTGRES_URL"]) as conn:
        conn.autocommit = True

        # Crear columnas USD
        with conn.cursor() as cur:
            cur.execute(ALTER_TARIFAS)
            cur.execute(ALTER_PROMOCIONES)
        log.info("Columnas USD creadas")

        # ---- tarifas ----
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT tariff_id, vehicle_type, base_fare, price_per_km, price_per_minute "
                "FROM tariffs"
            )
            filas = list(cur.fetchall())

        log.info("--- tarifas ---")
        resumen_tarifas = []
        for f in filas:
            base_usd = round(float(f["base_fare"]) / tasa, 3)
            km_usd = round(float(f["price_per_km"]) / tasa, 3)
            min_usd = round(float(f["price_per_minute"]) / tasa, 3)

            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE tariffs SET base_fare_usd = %s, price_per_km_usd = %s, "
                    "price_per_minute_usd = %s WHERE tariff_id = %s",
                    (base_usd, km_usd, min_usd, f["tariff_id"]),
                )

            log.info(
                "  %-10s base=%7.2f CUP -> %.3f USD | km=%6.2f CUP -> %.3f USD | min=%5.2f CUP -> %.3f USD",
                f["vehicle_type"],
                float(f["base_fare"]), base_usd,
                float(f["price_per_km"]), km_usd,
                float(f["price_per_minute"]), min_usd,
            )
            resumen_tarifas.append({
                "vehicle_type": f["vehicle_type"],
                "base_cup": float(f["base_fare"]), "base_usd": base_usd,
                "km_cup": float(f["price_per_km"]), "km_usd": km_usd,
                "min_cup": float(f["price_per_minute"]), "min_usd": min_usd,
            })

        # ---- promociones (precios de zonas especiales) ----
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT * FROM promociones WHERE id = 1")
            promo = cur.fetchone()

        if promo:
            campos = [
                ("precio_km_zona_basico", 1000.0),
                ("precio_km_zona_confort", 1200.0),
                ("precio_km_zona_triciclo", 700.0),
                ("precio_km_zona_moto", 600.0),
                ("precio_por_minuto", 5.0),
            ]
            sets = []
            params = []
            log.info("--- promociones (zonas especiales) ---")
            resumen_promo = []
            for col, default in campos:
                cup_actual = float(promo.get(col) or default)
                usd = round(cup_actual / tasa, 3)
                col_usd = col + "_usd"
                sets.append(f"{col_usd} = %s")
                params.append(usd)
                log.info("  %-35s %8.2f CUP -> %.3f USD", col, cup_actual, usd)
                resumen_promo.append({"campo": col, "cup": cup_actual, "usd": usd})

            params.append(1)
            with conn.cursor() as cur:
                cur.execute(
                    f"UPDATE promociones SET {', '.join(sets)} WHERE id = %s",
                    tuple(params),
                )

        # ---- verificacion ----
        log.info("--- verificacion final ---")
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT vehicle_type, base_fare, base_fare_usd, "
                "price_per_km, price_per_km_usd "
                "FROM tariffs ORDER BY tariff_id"
            )
            for f in cur.fetchall():
                verif = float(f["base_fare_usd"]) * tasa if f["base_fare_usd"] else 0
                log.info(
                    "  %-10s base_cup=%7.2f | base_usd=%.3f | base_usd*tasa=%.2f (debe coincidir)",
                    f["vehicle_type"], float(f["base_fare"]),
                    float(f["base_fare_usd"] or 0), verif,
                )

        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT precio_km_zona_basico, precio_km_zona_basico_usd, "
                "precio_km_zona_moto, precio_km_zona_moto_usd "
                "FROM promociones WHERE id = 1"
            )
            p = cur.fetchone()
            if p:
                log.info(
                    "  promo basico: cup=%.2f usd=%.3f -> cup recalculado=%.2f",
                    float(p["precio_km_zona_basico"] or 0),
                    float(p["precio_km_zona_basico_usd"] or 0),
                    (float(p["precio_km_zona_basico_usd"] or 0)) * tasa,
                )
                log.info(
                    "  promo moto:   cup=%.2f usd=%.3f -> cup recalculado=%.2f",
                    float(p["precio_km_zona_moto"] or 0),
                    float(p["precio_km_zona_moto_usd"] or 0),
                    (float(p["precio_km_zona_moto_usd"] or 0)) * tasa,
                )

    log.info("Fase 1 completada. Precios CUP no modificados. Valores USD guardados.")


if __name__ == "__main__":
    main()
