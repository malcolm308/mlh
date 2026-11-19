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
import json
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

EL_TOQUE_TRML = "https://tasas.eltoque.com/v1/trml"
EL_TOQUE_PUBLIC = "https://www.eltoque.com/api/currencies/latest"
EL_TOQUE_API = "https://api.eltoque.com/currencies/latest"


def obtener_tasa_usd_hoy() -> float:
    """Devuelve la tasa USD->CUP de hoy. Prueba 3 fuentes en orden."""
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


_ZONA_ESPECIAL_POR_DEFECTO = [
    [23.001228, -82.416735],
    [23.007982, -82.394788],
    [22.989298, -82.413242],
    [23.001007, -82.389251],
]


def _coords_zona_a_multipolygon_geojson(coords):
    raw = coords
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:
            raw = None
    if not isinstance(raw, list) or len(raw) < 3:
        raw = [list(p) for p in _ZONA_ESPECIAL_POR_DEFECTO]
    ring = []
    for punto in raw:
        if not isinstance(punto, (list, tuple)) or len(punto) < 2:
            continue
        try:
            lat = float(punto[0])
            lng = float(punto[1])
        except Exception:
            continue
        ring.append([lng, lat])
    if len(ring) < 3:
        ring = [[float(p[1]), float(p[0])] for p in _ZONA_ESPECIAL_POR_DEFECTO]
    if ring[0] != ring[-1]:
        ring.append(list(ring[0]))
    return {"type": "MultiPolygon", "coordinates": [[ring]]}


def sincronizar_zonas_desde_promociones(conn):
    """Upsert de `zones.airport_special` desde `promociones` (T5, best-effort)."""
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """
            SELECT zona_especial_activa, zona_especial_coords,
                   precio_km_zona_basico, precio_km_zona_confort,
                   precio_km_zona_triciclo, precio_km_zona_moto
              FROM promociones WHERE id = 1
            """
        )
        promo = cur.fetchone()
    if not promo:
        return
    geojson = _coords_zona_a_multipolygon_geojson(promo.get("zona_especial_coords"))
    activa = bool(promo.get("zona_especial_activa", True))
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO zones (
                code, name, active, geom,
                precio_km_zona_basico, precio_km_zona_confort,
                precio_km_zona_triciclo, precio_km_zona_moto,
                properties, source, updated_at
            ) VALUES (
                %s, %s, %s,
                ST_Multi(
                    ST_CollectionExtract(
                        ST_MakeValid(ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326))), 3
                    )
                )::geography,
                %s, %s, %s, %s,
                %s::jsonb, %s, NOW()
            )
            ON CONFLICT (code) DO UPDATE SET
                active = EXCLUDED.active,
                geom = EXCLUDED.geom,
                precio_km_zona_basico = EXCLUDED.precio_km_zona_basico,
                precio_km_zona_confort = EXCLUDED.precio_km_zona_confort,
                precio_km_zona_triciclo = EXCLUDED.precio_km_zona_triciclo,
                precio_km_zona_moto = EXCLUDED.precio_km_zona_moto,
                properties = EXCLUDED.properties,
                source = EXCLUDED.source,
                updated_at = NOW()
            """,
            (
                "airport_special",
                "Zona especial aeropuerto",
                activa,
                json.dumps(geojson),
                promo.get("precio_km_zona_basico"),
                promo.get("precio_km_zona_confort"),
                promo.get("precio_km_zona_triciclo"),
                promo.get("precio_km_zona_moto"),
                json.dumps({"origen": "init_prices_usd"}, ensure_ascii=False),
                "promociones",
            ),
        )


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

        # Sincroniza zona a PostGIS (T5). Best-effort para no fallar si no existe.
        try:
            sincronizar_zonas_desde_promociones(conn)
            log.info("Zona especial sincronizada en tabla zones")
        except Exception as e:
            log.warning("No se pudo sincronizar zones (tabla ausente o error): %s", e)

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
