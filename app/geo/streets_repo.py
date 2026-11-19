"""Lectura de la malla de calles desde PostGIS (`streets`, Tarea 5).

`routers/geo.py` usa este módulo cuando `GEO_READ_SOURCE=postgres`. Mongo sigue
siendo la fuente por defecto durante la transición. Este adaptador es
*read-only* y reproduce las consultas que el buscador hacía contra Mongo:
búsqueda por tokens de nombre, calles que intersectan una geometría y calles
cercanas a un punto.

Los documentos devueltos tienen la misma forma que los de Mongo que consume
`geo.py`: `nombre`, `tipo`, `geom` ([[lat,lon],...]), `punto` (GeoJSON) y
`geom_geojson` (GeoJSON). El scoring/orden final lo sigue haciendo `geo.py`.
"""
from __future__ import annotations

import json
import logging
import os
import re
from contextlib import contextmanager
from typing import Iterable, Optional

import psycopg2
import psycopg2.extras

log = logging.getLogger(__name__)

_VARIANTES = {
    "a": "aáàäâã", "e": "eéèëê", "i": "iíìïî", "o": "oóòöôõ",
    "u": "uúùüû", "n": "nñ", "c": "cç", "y": "yý",
}

_SELECT_BASE = """
    SELECT s.mongo_id, s.nombre, s.properties,
           ST_AsGeoJSON(s.geom::geometry) AS geom_geojson,
           ST_X(ST_Centroid(s.geom::geometry)) AS _lon,
           ST_Y(ST_Centroid(s.geom::geometry)) AS _lat
      FROM streets s
"""


@contextmanager
def _conexion():
    url = os.getenv("POSTGRES_URL", "").strip()
    if url:
        conn = psycopg2.connect(url, connect_timeout=10)
    else:
        conn = psycopg2.connect(
            dbname=os.getenv("DB_NAME", "taxi_db"),
            user=os.getenv("DB_USER", "postgres"),
            password=os.getenv("DB_PASSWORD", ""),
            host=os.getenv("DB_HOST", "localhost"),
            port=int(os.getenv("DB_PORT", "5432")),
            connect_timeout=10,
        )
    try:
        yield conn
    finally:
        conn.close()


def _regex_palabra(token: str) -> str:
    """Versión PostgreSQL (ARE) del patrón con acentos de geo.py."""
    partes = []
    for ch in token:
        if ch in _VARIANTES:
            partes.append("[%s]" % _VARIANTES[ch])
        else:
            partes.append(re.escape(ch))
    return "".join(partes)


def patron_token(token: str, alias: Optional[str] = None) -> str:
    """Prefijo regex para `~*`; los límites de palabra los valida geo.py."""
    if token.isdigit():
        base = re.escape(token)
        if alias and token != alias:
            base = "(?:%s|%s)" % (base, re.escape(alias))
    else:
        base = _regex_palabra(token)
    return ".*" + base + ".*"


def _doc(fila: dict, *, con_dist: bool = False) -> dict:
    geojson = fila.get("geom_geojson")
    if isinstance(geojson, str):
        try:
            geojson = json.loads(geojson)
        except ValueError:
            geojson = None
    coords = (geojson or {}).get("coordinates") or []
    latlon = []
    for par in coords:
        if isinstance(par, (list, tuple)) and len(par) >= 2:
            try:
                latlon.append([float(par[1]), float(par[0])])
            except (TypeError, ValueError):
                continue
    props = fila.get("properties") or {}
    if isinstance(props, str):
        try:
            props = json.loads(props)
        except ValueError:
            props = {}
    doc = {
        "_id": fila.get("mongo_id"),
        "nombre": fila.get("nombre"),
        "tipo": props.get("tipo"),
        "osm_id": props.get("osm_id"),
        "geom": latlon,
        "geom_geojson": geojson or {"type": "LineString", "coordinates": []},
        "punto": {
            "type": "Point",
            "coordinates": [float(fila.get("_lon") or 0), float(fila.get("_lat") or 0)],
        },
    }
    if con_dist:
        doc["dist_m"] = float(fila.get("dist_m") or 0)
    return doc


def hay_calles() -> bool:
    try:
        with _conexion() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1 FROM streets LIMIT 1")
            return cur.fetchone() is not None
    except Exception:
        return False


def buscar_por_nombre(tokens: list[str], alias: Optional[str] = None,
                      limite: int = 400) -> list[dict]:
    """Precandidatas por nombre; el scoring exacto lo hace `geo.py`."""
    if not tokens:
        return []
    patrones = [patron_token(t, alias) for t in tokens]
    conds = " AND ".join(["s.nombre ~* %s"] * len(patrones))
    sql = _SELECT_BASE + f" WHERE {conds} LIMIT %s"
    try:
        with _conexion() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, patrones + [int(limite)])
            filas: Iterable[dict] = cur.fetchall()
    except Exception:
        log.exception("streets_repo.buscar_por_nombre falló")
        return []
    return [_doc(f) for f in filas]


def calles_cerca(lat: float, lon: float, radio_m: float) -> list[dict]:
    """Calles con geometría dentro de `radio_m` metros del punto."""
    try:
        with _conexion() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT s.mongo_id, s.nombre, s.properties,
                       ST_AsGeoJSON(s.geom::geometry) AS geom_geojson,
                       ST_X(ST_Centroid(s.geom::geometry)) AS _lon,
                       ST_Y(ST_Centroid(s.geom::geometry)) AS _lat,
                       ST_Distance(s.geom,
                                   ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography) AS dist_m
                  FROM streets s
                 WHERE ST_DWithin(s.geom,
                                  ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s)
                 ORDER BY dist_m
                 LIMIT 800
                """,
                (float(lon), float(lat), float(lon), float(lat), float(radio_m)),
            )
            filas: Iterable[dict] = cur.fetchall()
    except Exception:
        log.exception("streets_repo.calles_cerca falló")
        return []
    return [_doc(f, con_dist=True) for f in filas]


def cruza_con(geom_geojson: dict | str, nombres: list[str],
              limite: int = 600) -> list[dict]:
    """Calles de `nombres` que intersectan de verdad la geometría dada."""
    if not nombres or geom_geojson is None:
        return []
    if isinstance(geom_geojson, dict):
        geom_geojson = json.dumps(geom_geojson)
    try:
        with _conexion() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                _SELECT_BASE +
                " WHERE s.nombre = ANY(%s)"
                "   AND ST_Intersects(s.geom::geometry,"
                "                     ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326))"
                " LIMIT %s",
                (list(nombres), geom_geojson, int(limite)),
            )
            filas: Iterable[dict] = cur.fetchall()
    except Exception:
        log.exception("streets_repo.cruza_con falló")
        return []
    return [_doc(f) for f in filas]
