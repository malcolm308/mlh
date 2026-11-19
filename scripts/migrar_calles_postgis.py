"""Migra la malla de calles de MongoDB (Geo.calles) a PostGIS (tabla `streets`).

Esta es la ÚNICA parte de la Tarea 5 que lee Mongo:

    Mongo (Geo.calles, solo lectura)  --->  Postgres (streets, geography/LineString)

Las zonas NO se leen de Mongo: `scripts/migrar_zonas_postgis.py` toma
`promociones` directamente de Postgres.

Características
---------------
* Streaming con cursor (no carga los 17,037 documentos en memoria).
* Prefiere `geom_geojson` (GeoJSON LineString [lon,lat]); si falta, usa `geom`
  ([[lat,lon], ...]) como hacía `routers/geo.py`.
* Upsert idempotente por `mongo_id` (ObjectId hex). Repetir el script no duplica.
* Geometrías inválidas/auto-intersectantes se normalizan en SQL con
  `ST_MakeValid` + `ST_CollectionExtract(...,2)` + `ST_Dump` (se conserva el
  tramo más largo). Las que no se puedan normalizar se cuentan como error y no
  detienen el resto.
* `--dry-run` y `--limit` permiten probar sin escribir.

Uso
---
    python scripts/migrar_calles_postgis.py --dry-run --limit 100
    python scripts/migrar_calles_postgis.py                 # migración completa
    python scripts/migrar_calles_postgis.py --verificar     # solo Postgres

Conexiones
----------
Mongo: `MONGO_URI`, `MONGODB_URI`, `MONGO_URL`, ... (o .env), BD `Geo`.
Postgres: `POSTGRES_URL` o `DB_*` (misma convención del backend).
La URI NUNCA se imprime.
"""
from __future__ import annotations

import argparse
import json
import logging
import math
import os
import sys
from pathlib import Path
from typing import Any, Iterable

import psycopg2
from psycopg2.extras import execute_values

try:
    from pymongo import MongoClient
except ImportError:  # pragma: no cover
    MongoClient = None  # type: ignore[assignment]

RAIZ = Path(__file__).resolve().parents[1]
if str(RAIZ) not in sys.path:
    sys.path.insert(0, str(RAIZ))

log = logging.getLogger("migrar_calles")

MONGO_KEYS = (
    "MONGO_URI", "MONGODB_URI", "MONGO_URL", "MONGODB_URL",
    "ATLAS_URI", "MONGO_CONNECTION_STRING",
)

# Un solo marcador %s: el de VALUES, que execute_values rellena por lotes.
SQL_UPSERT = """
INSERT INTO streets (mongo_id, nombre, geom, puntos, properties, source, updated_at)
SELECT v.mongo_id,
       v.nombre,
       tramo.g::geography,
       v.puntos,
       v.properties::jsonb,
       'Geo.calles',
       NOW()
  FROM (VALUES %s) AS v(mongo_id, nombre, geojson, puntos, properties)
  CROSS JOIN LATERAL (
      SELECT (d).geom AS g
        FROM ST_Dump(
               ST_CollectionExtract(
                   ST_MakeValid(
                       ST_SetSRID(ST_GeomFromGeoJSON(v.geojson), 4326)
                   ), 2
               )
             ) AS d
       ORDER BY ST_Length((d).geom::geography) DESC
       LIMIT 1
  ) AS tramo
 WHERE tramo.g IS NOT NULL AND ST_IsValid(tramo.g)
ON CONFLICT (mongo_id) DO UPDATE SET
    nombre     = EXCLUDED.nombre,
    geom       = EXCLUDED.geom,
    puntos     = EXCLUDED.puntos,
    properties = EXCLUDED.properties,
    source     = EXCLUDED.source,
    updated_at = NOW()
"""


# ---------------------------------------------------------------------------
# Conexiones
# ---------------------------------------------------------------------------

def _uri_de_entorno() -> str:
    for clave in MONGO_KEYS:
        valor = os.getenv(clave, "").strip()
        if valor:
            return valor
    for ruta in (RAIZ / ".env", Path.cwd() / ".env"):
        if not ruta.is_file():
            continue
        try:
            texto = ruta.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for linea in texto.splitlines():
            linea = linea.strip()
            if not linea or linea.startswith("#") or "=" not in linea:
                continue
            clave, _, valor = linea.partition("=")
            if clave.strip() in MONGO_KEYS and valor.strip():
                return valor.strip().strip('"').strip("'")
    return ""


def conectar_mongo(uri: str | None = None):
    if MongoClient is None:  # pragma: no cover
        raise RuntimeError("falta pymongo: pip install pymongo")
    uri = (uri or _uri_de_entorno()).strip()
    if not uri:
        raise RuntimeError(
            "No se encontró URI de Mongo. Define MONGO_URI o MONGODB_URI "
            "(o pásala con --uri).")
    cliente = MongoClient(uri, serverSelectionTimeoutMS=10000)
    cliente.admin.command("ping")
    return cliente


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


# ---------------------------------------------------------------------------
# Normalización de geometría (puro Python, testeable sin BD)
# ---------------------------------------------------------------------------

def _numero(valor: Any) -> float | None:
    try:
        numero = float(valor)
    except (TypeError, ValueError):
        return None
    return numero if math.isfinite(numero) else None


def _normalizar_tramos(tramos: Iterable[Any], *, lat_lon: bool) -> list[list[float]]:
    """Devuelve el mejor tramo como [[lon, lat], ...] (GeoJSON)."""
    mejor: list[list[float]] = []
    for tramo in tramos:
        if not isinstance(tramo, (list, tuple)):
            continue
        puntos: list[list[float]] = []
        for punto in tramo:
            if not isinstance(punto, (list, tuple)) or len(punto) < 2:
                continue
            a, b = _numero(punto[0]), _numero(punto[1])
            if a is None or b is None:
                continue
            lon, lat = (b, a) if lat_lon else (a, b)
            if not (-180.0 <= lon <= 180.0 and -90.0 <= lat <= 90.0):
                continue
            par = [lon, lat]
            if puntos and puntos[-1] == par:
                continue
            puntos.append(par)
        if len(puntos) > len(mejor):
            mejor = puntos
    return mejor


def puntos_de(doc: dict) -> list[list[float]]:
    """Extrae el LineString de un documento de Geo.calles.

    Prefiere `geom_geojson` (lon,lat); si no existe, usa `geom` (lat,lon).
    """
    geojson = doc.get("geom_geojson")
    if isinstance(geojson, dict):
        tipo = geojson.get("type")
        coords = geojson.get("coordinates")
        if tipo == "LineString":
            return _normalizar_tramos([coords], lat_lon=False)
        if tipo == "MultiLineString" and isinstance(coords, (list, tuple)):
            return _normalizar_tramos(coords, lat_lon=False)
    geom = doc.get("geom")
    if isinstance(geom, (list, tuple)):
        return _normalizar_tramos([geom], lat_lon=True)
    return []


def fila_para(doc: dict) -> tuple[str, str | None, str, int, str] | None:
    puntos = puntos_de(doc)
    if len(puntos) < 2:
        return None
    mongo_id = str(doc.get("_id") or "")
    if not mongo_id:
        return None
    nombre = doc.get("nombre")
    props: dict[str, Any] = {"origen": "Geo.calles"}
    if doc.get("tipo") is not None:
        props["tipo"] = doc.get("tipo")
    if doc.get("osm_id") is not None:
        props["osm_id"] = doc.get("osm_id")
    return (
        mongo_id,
        str(nombre) if nombre is not None else None,
        json.dumps({"type": "LineString", "coordinates": puntos}),
        len(puntos),
        json.dumps(props, ensure_ascii=False),
    )


def host_de_uri(uri: str) -> str:
    """Solo host:puerto, sin usuario ni credenciales."""
    try:
        return uri.split("@")[-1].split("/")[0]
    except Exception:
        return "(desconocido)"


# ---------------------------------------------------------------------------
# Migración
# ---------------------------------------------------------------------------

def escribir_lote(conn, filas: list[tuple]) -> tuple[int, int]:
    """Upsert de un lote. Si falla, aísla fila por fila. Devuelve (ok, errores)."""
    if not filas:
        return 0, 0
    with conn.cursor() as cur:
        try:
            execute_values(cur, SQL_UPSERT, filas, page_size=len(filas))
            conn.commit()
            return len(filas), 0
        except Exception:
            conn.rollback()
            log.warning("Lote de %d filas falló; reintentando una por una", len(filas))
    ok = 0
    errores = 0
    for fila in filas:
        with conn.cursor() as cur:
            try:
                execute_values(cur, SQL_UPSERT, [fila])
                conn.commit()
                ok += 1
            except Exception:
                conn.rollback()
                errores += 1
                log.debug("Fila descartada: %s", fila[0])
    return ok, errores


def migrar(*, uri: str, db_name: str, collection: str, batch_size: int,
           limit: int | None, dry_run: bool) -> dict[str, Any]:
    uri = (uri or _uri_de_entorno()).strip()
    cliente = conectar_mongo(uri)
    resumen: dict[str, Any] = {
        "mongo_host": host_de_uri(uri),
        "mongo_db": db_name,
        "mongo_collection": collection,
        "leidas": 0, "con_geometria": 0, "sin_geometria": 0,
        "escritas": 0, "errores": 0, "dry_run": dry_run,
    }
    try:
        col = cliente[db_name][collection]
        cursor = col.find(
            {}, {"nombre": 1, "geom": 1, "geom_geojson": 1},
            batch_size=batch_size,
        )
        pg = None
        lote: list[tuple] = []
        try:
            if not dry_run:
                pg = conectar_pg()
            for doc in cursor:
                if limit is not None and resumen["leidas"] >= limit:
                    break
                resumen["leidas"] += 1
                fila = fila_para(doc)
                if fila is None:
                    resumen["sin_geometria"] += 1
                    continue
                resumen["con_geometria"] += 1
                if dry_run:
                    continue
                lote.append(fila)
                if len(lote) >= batch_size:
                    ok, errores = escribir_lote(pg, lote)
                    resumen["escritas"] += ok
                    resumen["errores"] += errores
                    lote = []
                    if resumen["leidas"] % (batch_size * 10) == 0:
                        log.info("Progreso: %s", json.dumps(resumen, default=str))
            if lote and pg is not None:
                ok, errores = escribir_lote(pg, lote)
                resumen["escritas"] += ok
                resumen["errores"] += errores
        finally:
            if pg is not None:
                pg.close()
    finally:
        cliente.close()
    return resumen


def verificar() -> dict[str, Any]:
    conn = conectar_pg()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COUNT(*),
                       COUNT(*) FILTER (WHERE NOT ST_IsValid(geom::geometry)),
                       MIN(ST_XMin(geom::geometry)), MAX(ST_XMax(geom::geometry)),
                       MIN(ST_YMin(geom::geometry)), MAX(ST_YMax(geom::geometry))
                  FROM streets
                """
            )
            total, invalidas, xmin, xmax, ymin, ymax = cur.fetchone()
            cur.execute(
                "SELECT indexname FROM pg_indexes WHERE tablename='streets' ORDER BY indexname"
            )
            indices = [fila[0] for fila in cur.fetchall()]
            cur.execute(
                "SELECT version FROM schema_migrations WHERE version='0005_streets_postgis'"
            )
            migracion = cur.fetchone()
        return {
            "tabla": "streets", "filas": int(total), "invalidas": int(invalidas),
            "bbox": [xmin, ymin, xmax, ymax], "indices": indices,
            "migracion_registrada": bool(migracion),
        }
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Migrar Geo.calles (Mongo) a PostGIS")
    ap.add_argument("--uri", default="", help="URI de Mongo (por defecto, variables de entorno/.env)")
    ap.add_argument("--db", default="Geo", help="Base de Mongo (default: Geo)")
    ap.add_argument("--collection", default="calles", help="Colección (default: calles)")
    ap.add_argument("--batch-size", type=int, default=500)
    ap.add_argument("--limit", type=int, default=None, help="Solo leer N documentos (smoke test)")
    ap.add_argument("--dry-run", action="store_true", help="Leer Mongo y contar, sin escribir")
    ap.add_argument("--verificar", action="store_true", help="Solo consultar Postgres")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    try:
        if args.verificar:
            resumen = verificar()
        else:
            resumen = migrar(
                uri=args.uri, db_name=args.db, collection=args.collection,
                batch_size=max(1, args.batch_size), limit=args.limit,
                dry_run=args.dry_run,
            )
    except Exception:
        log.exception("Falló la migración de calles")
        return 1
    print(json.dumps(resumen, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
