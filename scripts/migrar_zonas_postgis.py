"""Migra zonas de negocio desde `promociones` a la tabla PostGIS `zones`.

Fuente actual (Tarea 5): Postgres `promociones`
  - `zona_especial_coords` (JSON: [[lat, lng], ...])
  - `zona_especial_activa`
  - `precio_km_zona_basico|confort|triciclo|moto`

Crea/actualiza la zona `airport_special` como `geography(MultiPolygon,4326)`.
No consulta Mongo (no existen colecciones de zonas/mallas). TODO futuro:
importación opcional desde Mongo si aparece una fuente productiva.

Uso:
  python scripts/migrar_zonas_postgis.py
  python scripts/migrar_zonas_postgis.py --dry-run
  python scripts/migrar_zonas_postgis.py --code airport_special --name "Zona especial aeropuerto"

Variables de entorno: `POSTGRES_URL` o `DB_*` (misma convención del backend).
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable

RAIZ = Path(__file__).resolve().parents[1]
if str(RAIZ) not in sys.path:
    sys.path.insert(0, str(RAIZ))

import psycopg2  # noqa: E402
import psycopg2.extras  # noqa: E402

log = logging.getLogger("migrar_zonas")

_ZONA_ESPECIAL_POR_DEFECTO = [
    [23.001228, -82.416735],
    [23.007982, -82.394788],
    [22.989298, -82.413242],
    [23.001007, -82.389251],
]


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


def _a_decimal(valor: Any) -> Decimal | None:
    if valor is None or valor == "":
        return None
    try:
        return Decimal(str(valor))
    except Exception:
        return None


def _parsear_coords(raw: Any) -> list:
    coords = raw
    if isinstance(coords, str):
        coords = json.loads(coords)
    if not isinstance(coords, list):
        raise ValueError("zona_especial_coords debe ser una lista de [lat,lng]")
    return coords


def coords_a_multipolygon_geojson(coords: Iterable[Any]) -> dict:
    """Convierte [[lat,lng], ...] a GeoJSON MultiPolygon (lng,lat, anillo cerrado)."""
    ring: list[list[float]] = []
    for punto in coords:
        if not isinstance(punto, (list, tuple)) or len(punto) < 2:
            continue
        lat = float(punto[0])
        lng = float(punto[1])
        ring.append([lng, lat])
    if len(ring) < 3:
        raise ValueError("Se requieren al menos 3 puntos válidos para el polígono")

    # Cerrar anillo si hace falta.
    if ring[0] != ring[-1]:
        ring.append(list(ring[0]))

    # MultiPolygon: [ polygon [ ring [ position ] ] ]
    return {"type": "MultiPolygon", "coordinates": [[ring]]}


def leer_promocion_zona(conn) -> dict[str, Any]:
    """Lee la configuración de zona desde promociones; usa defaults si falta."""
    defaults = {
        "zona_especial_activa": True,
        "zona_especial_coords": [list(p) for p in _ZONA_ESPECIAL_POR_DEFECTO],
        "precio_km_zona_basico": Decimal("1000.0"),
        "precio_km_zona_confort": Decimal("1200.0"),
        "precio_km_zona_triciclo": Decimal("700.0"),
        "precio_km_zona_moto": Decimal("600.0"),
    }
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT zona_especial_activa,
                       zona_especial_coords,
                       precio_km_zona_basico,
                       precio_km_zona_confort,
                       precio_km_zona_triciclo,
                       precio_km_zona_moto
                  FROM promociones
                 WHERE id = 1
                """
            )
            fila = cur.fetchone()
    except Exception:
        conn.rollback()
        log.warning("No se pudo leer promociones; se usan valores por defecto")
        return defaults
    if not fila:
        log.warning("promociones.id=1 no existe; se usan valores por defecto")
        return defaults
    resultado = defaults.copy()
    resultado.update({k: fila.get(k) for k in defaults.keys() if k in fila})
    return resultado


def migrar(*, code: str, name: str, dry_run: bool = False) -> dict[str, Any]:
    conn = conectar_pg()
    try:
        promo = leer_promocion_zona(conn)
        raw_coords = promo.get("zona_especial_coords")
        try:
            coords = _parsear_coords(raw_coords)
            if not coords:
                raise ValueError("coords vacías")
        except Exception:
            coords = [list(p) for p in _ZONA_ESPECIAL_POR_DEFECTO]
            log.warning("zona_especial_coords ausente/inválida; se usan coordenadas por defecto")
        geojson = coords_a_multipolygon_geojson(coords)
        activa = bool(promo.get("zona_especial_activa", True))

        precios = {
            "precio_km_zona_basico": _a_decimal(promo.get("precio_km_zona_basico")),
            "precio_km_zona_confort": _a_decimal(promo.get("precio_km_zona_confort")),
            "precio_km_zona_triciclo": _a_decimal(promo.get("precio_km_zona_triciclo")),
            "precio_km_zona_moto": _a_decimal(promo.get("precio_km_zona_moto")),
        }
        props = {
            "origen": "promociones",
            "puntos": len([c for c in coords if isinstance(c, (list, tuple)) and len(c) >= 2]),
        }

        resumen = {
            "code": code,
            "name": name,
            "active": activa,
            "puntos": props["puntos"],
            "precios": {k: (str(v) if v is not None else None) for k, v in precios.items()},
            "dry_run": dry_run,
        }

        if dry_run:
            log.info("DRY-RUN zona=%s activa=%s puntos=%s", code, activa, props["puntos"])
            return resumen

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
                            ST_MakeValid(
                                ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326))
                            ), 3
                        )
                    )::geography,
                    %s, %s, %s, %s,
                    %s::jsonb, %s, NOW()
                )
                ON CONFLICT (code) DO UPDATE SET
                    name = EXCLUDED.name,
                    active = EXCLUDED.active,
                    geom = EXCLUDED.geom,
                    precio_km_zona_basico = EXCLUDED.precio_km_zona_basico,
                    precio_km_zona_confort = EXCLUDED.precio_km_zona_confort,
                    precio_km_zona_triciclo = EXCLUDED.precio_km_zona_triciclo,
                    precio_km_zona_moto = EXCLUDED.precio_km_zona_moto,
                    properties = EXCLUDED.properties,
                    source = EXCLUDED.source,
                    updated_at = NOW()
                RETURNING id, code, active, ST_IsValid(geom::geometry) AS valido
                """,
                (
                    code,
                    name,
                    activa,
                    json.dumps(geojson),
                    precios["precio_km_zona_basico"],
                    precios["precio_km_zona_confort"],
                    precios["precio_km_zona_triciclo"],
                    precios["precio_km_zona_moto"],
                    json.dumps(props, ensure_ascii=False),
                    "promociones",
                ),
            )
            fila = cur.fetchone()
        conn.commit()
        resumen.update({"id": fila[0], "valido": bool(fila[3]), "migrada": True})
        log.info("Zona migrada: id=%s code=%s active=%s valido=%s", fila[0], fila[1], fila[2], fila[3])
        return resumen
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Migrar zonas de promociones a PostGIS")
    ap.add_argument("--code", default="airport_special")
    ap.add_argument("--name", default="Zona especial aeropuerto")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    try:
        resumen = migrar(code=args.code, name=args.name, dry_run=args.dry_run)
    except Exception:
        log.exception("Fallo la migración de zonas")
        return 1
    print(json.dumps(resumen, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
