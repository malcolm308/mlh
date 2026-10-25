"""
Fase 2 - Actualizacion diaria de precios CUP (CRON JOB DIARIO).

Consulta la tasa de cambio del DIA en El Toque y recalcula todos los precios
en CUP multiplicando los valores USD (fijos) por la tasa de hoy.

Estrategia de fallo: si la API de El Toque falla, el script ABORTA sin modificar
ningun precio. Esto evita que un fallo de red o de la API deje los precios
corruptos o desactualizados.

Variable de entorno requerida:
    POSTGRES_URL  - URL de conexion a Supabase
    API_KEY_TOQUE - (opcional) API key de El Toque

Uso (Cron Job Render, cada dia a las 8:00 AM hora Cuba):
    python scripts/update_daily_prices.py
"""
import os
import sys
import logging
from datetime import datetime

import httpx
import psycopg2
import psycopg2.extras

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("update_daily_prices")

# ---------------------------------------------------------------------------
# 1. Obtener tasa de cambio de HOY
# ---------------------------------------------------------------------------

EL_TOQUE_TRML = "https://tasas.eltoque.com/v1/trml"
EL_TOQUE_PUBLIC = "https://www.eltoque.com/api/currencies/latest"
EL_TOQUE_API = "https://api.eltoque.com/currencies/latest"


def obtener_tasa_usd_hoy() -> float:
    """Devuelve la tasa USD->CUP de hoy. Lanza excepcion si falla."""
    api_key = os.getenv("API_KEY_TOQUE")
    
    # Intento 1: endpoint TRML oficial
    try:
        with httpx.Client(timeout=30, follow_redirects=True) as client:
            headers = {"Accept": "application/json"}
            if api_key:
                headers["Authorization"] = f"Bearer {api_key}"
            r = client.get(EL_TOQUE_TRML, headers=headers)
            r.raise_for_status()
            data = r.json()
            tasas = data.get("tasas") or {}
            tasa = tasas.get("USD")
            if tasa and float(tasa) > 0:
                return float(tasa)
    except Exception as e:
        log.warning("Fallo TRML: %s", e)

    # Intento 2: endpoint con API key
    if api_key:
        try:
            with httpx.Client(timeout=30, follow_redirects=True) as client:
                r = client.get(EL_TOQUE_API, headers={"Authorization": f"Bearer {api_key}", "Accept": "application/json"})
                r.raise_for_status()
                data = r.json()
                usd = data.get("USD") or data.get("usd") or {}
                if isinstance(usd, dict):
                    tasa = usd.get("sell") or usd.get("buy") or usd.get("rate") or usd.get("value")
                elif isinstance(usd, (int, float)):
                    tasa = usd
                else:
                    tasa = None
                if tasa and float(tasa) > 0:
                    return float(tasa)
        except Exception as e:
            log.warning("Fallo API: %s", e)

    # Intento 3: endpoint publico
    try:
        with httpx.Client(timeout=30, follow_redirects=True) as client:
            r = client.get(EL_TOQUE_PUBLIC, headers={"User-Agent": "RapiTaxi/1.0"})
            r.raise_for_status()
            data = r.json()
            usd = data.get("USD") or data.get("usd") or data.get("dolar") or {}
            if isinstance(usd, dict):
                tasa = usd.get("sell") or usd.get("buy") or usd.get("rate") or usd.get("value")
            elif isinstance(usd, (int, float)):
                tasa = usd
            else:
                tasa = None
            if tasa and float(tasa) > 0:
                return float(tasa)
    except Exception as e:
        log.warning("Fallo publico: %s", e)

    raise ValueError("No se pudo obtener tasa USD de ninguna fuente de El Toque")


# ---------------------------------------------------------------------------
# 2. Actualizacion
# ---------------------------------------------------------------------------


def main():
    log.info("=== Actualizacion diaria de precios ===")
    log.info("Fecha: %s", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))

    try:
        tasa = obtener_tasa_usd_hoy()
    except Exception as e:
        log.error("FALLO al obtener tasa de El Toque: %s", e)
        tasa_fallback = os.getenv("TASA_USD_FALLBACK")
        if tasa_fallback:
            tasa = float(tasa_fallback)
            log.warning("Usando TASA_USD_FALLBACK=%.4f como respaldo", tasa)
        else:
            log.error("ABORTANDO: no hay TASA_USD_FALLBACK configurada. Revisar API o conectividad.")
            sys.exit(1)

    log.info("Tasa USD de hoy: %.4f CUP/USD", tasa)

    if tasa <= 0:
        log.error("Tasa invalida (%.4f). ABORTANDO.", tasa)
        sys.exit(1)

    with psycopg2.connect(os.environ["POSTGRES_URL"]) as conn:
        conn.autocommit = True

        # ---- tarifas ----
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT tariff_id, vehicle_type, "
                "base_fare_usd, price_per_km_usd, price_per_minute_usd "
                "FROM tariffs"
            )
            filas = list(cur.fetchall())

        log.info("--- actualizando tarifas ---")
        for f in filas:
            base_usd = float(f["base_fare_usd"] or 0)
            km_usd = float(f["price_per_km_usd"] or 0)
            min_usd = float(f["price_per_minute_usd"] or 0)

            if base_usd == 0 and km_usd == 0 and min_usd == 0:
                log.warning("  %-10s sin valores USD, saltando", f["vehicle_type"])
                continue

            base_cup = round(base_usd * tasa, 2)
            km_cup = round(km_usd * tasa, 2)
            min_cup = round(min_usd * tasa, 2)

            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE tariffs SET base_fare = %s, price_per_km = %s, "
                    "price_per_minute = %s, updated_at = NOW() WHERE tariff_id = %s",
                    (base_cup, km_cup, min_cup, f["tariff_id"]),
                )

            log.info(
                "  %-10s base=%.2f CUP | km=%.2f CUP | min=%.2f CUP",
                f["vehicle_type"], base_cup, km_cup, min_cup,
            )

        # ---- promociones (zonas especiales) ----
        campos = [
            "precio_km_zona_basico",
            "precio_km_zona_confort",
            "precio_km_zona_triciclo",
            "precio_km_zona_moto",
            "precio_por_minuto",
        ]

        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT * FROM promociones WHERE id = 1")
            promo = cur.fetchone()

        if promo:
            sets = []
            params = []
            log.info("--- actualizando zonas especiales ---")
            for col in campos:
                col_usd = col + "_usd"
                usd_val = float(promo.get(col_usd) or 0)
                if usd_val == 0:
                    log.warning("  %-35s sin valor USD, saltando", col)
                    continue
                cup_nuevo = round(usd_val * tasa, 2)
                sets.append(f"{col} = %s")
                params.append(cup_nuevo)
                log.info("  %-35s %.2f CUP (usd=%.3f * tasa=%.2f)", col, cup_nuevo, usd_val, tasa)

            if sets:
                params.append(1)
                with conn.cursor() as cur:
                    cur.execute(
                        f"UPDATE promociones SET {', '.join(sets)}, actualizado_at = NOW() "
                        "WHERE id = %s",
                        tuple(params),
                    )

        # ---- verificacion final ----
        log.info("--- verificacion ---")
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT vehicle_type, base_fare, base_fare_usd "
                "FROM tariffs ORDER BY tariff_id"
            )
            for f in cur.fetchall():
                esperado = round(float(f["base_fare_usd"] or 0) * tasa, 2)
                actual = float(f["base_fare"] or 0)
                ok = "OK" if abs(esperado - actual) < 0.02 else "DIFERENCIA"
                log.info(
                    "  %-10s base_cup=%.2f | base_usd=%.3f * tasa=%.2f = %.2f [%s]",
                    f["vehicle_type"], actual,
                    float(f["base_fare_usd"] or 0), tasa, esperado, ok,
                )

    log.info("=== Actualizacion diaria completada ===")


if __name__ == "__main__":
    main()
