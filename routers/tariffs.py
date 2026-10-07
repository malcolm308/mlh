"""
Endpoints publicos de tarifas y reglas de precio por horario.

Leen de PostgreSQL con el pool que ya usa todo el backend
(`get_connection`), que en produccion apunta a Supabase (POSTGRES_URL) y en
desarrollo a la base local. Asi una sola conexion sirve para tarifas, viajes y
reglas horarias y el precio que ve el pasajero coincide con el que se cobra.

No cierran queries en dedo: `get_connection` ya pone las conexiones de vuelta
en el pool al salir del `with`.
"""
import logging
import sys

sys.path.insert(0, r"E:\Taxi_Rapid")

from fastapi import APIRouter, HTTPException
from psycopg2.extras import RealDictCursor

# El pool compartido. Importado de Solicitud_de_viajes_v4, que es donde vive
# la conexion a Postgres del proyecto.
from routers.Solicitud_de_viajes_v4 import get_connection

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Tarifas"])


# Normaliza el tipo de vehiculo para comparar sin importar acentos ni
# mayusculas: 'basico' y 'básico' deben resolverse a la misma tarifa.
_ACENTOS = str.maketrans(
    "áàäâãéèëêíìïîóòöôõúùüûñç",
    "aaaaaeeeeiiiiooooouuuunc",
)


def _normalizar(tipo) -> str:
    """Minusculas y sin acentos, para igualar 'basico' con 'básico'."""
    return str(tipo or "").strip().translate(_ACENTOS).lower()


def _fila_tarifa(fila) -> dict:
    """Convierte una fila de `tariffs` (RealDict) en JSON listo para la app."""
    return {
        "tariff_id": fila["tariff_id"],
        "vehicle_type": fila["vehicle_type"],
        "base_fare": float(fila["base_fare"] or 0),
        "price_per_km": float(fila["price_per_km"] or 0),
        "price_per_minute": float(fila["price_per_minute"] or 0),
        "max_passengers": fila["max_passengers"],
    }


def _fila_regla(fila) -> dict:
    """Convierte una fila de `time_pricing_rules` en JSON listo para la app.

    La columna de id se llama `rule_id` en la base local y `id` en Supabase:
    se devuelve siempre como `id` para que el movil tenga un contrato estable.
    """
    return {
        "id": fila.get("id") or fila.get("rule_id"),
        "vehicle_type": fila["vehicle_type"],
        "start_time": str(fila["start_time"]),
        "end_time": str(fila["end_time"]),
        "base_fare_multiplier": float(fila["base_fare_multiplier"] or 1),
        "price_per_km_multiplier": float(fila["price_per_km_multiplier"] or 1),
        "price_per_minute_multiplier": float(fila["price_per_minute_multiplier"] or 1),
        "description": fila.get("description"),
    }


def _leer_reglas() -> list[dict]:
    """Todas las filas de `time_pricing_rules` ordenadas por id y hora.

    La base local usa `rule_id` y Supabase `id`: se selecciona `*` para no
    depender de cual de las dos exista y el orden se resuelve en Python.
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT * FROM time_pricing_rules")
        filas = [dict(r) for r in cur.fetchall()]
        cur.close()
    filas.sort(key=lambda r: (_fila_regla(r)["id"] or 0, r["start_time"]))
    return filas


@router.get("/tariffs")
def listar_tarifas():
    """Devuelve todas las tarifas, ordenadas por `tariff_id`."""
    try:
        with get_connection() as conn:
            cur = conn.cursor(cursor_factory=RealDictCursor)
            cur.execute(
                "SELECT tariff_id, vehicle_type, base_fare, price_per_km, "
                "price_per_minute, max_passengers "
                "FROM tariffs ORDER BY tariff_id"
            )
            filas = [dict(r) for r in cur.fetchall()]
            cur.close()
        return {"tariffs": [_fila_tarifa(f) for f in filas]}
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Error listando tarifas")
        raise HTTPException(status_code=500, detail="Error consultando las tarifas") from e


@router.get("/tariffs/{vehicle_type}")
def obtener_tarifa(vehicle_type: str):
    """Devuelve la tarifa de un tipo de vehiculo (acepta 'basico' o 'básico')."""
    buscado = _normalizar(vehicle_type)
    try:
        with get_connection() as conn:
            cur = conn.cursor(cursor_factory=RealDictCursor)
            cur.execute(
                "SELECT tariff_id, vehicle_type, base_fare, price_per_km, "
                "price_per_minute, max_passengers "
                "FROM tariffs"
            )
            fila = None
            for r in cur.fetchall():
                if _normalizar(r["vehicle_type"]) == buscado:
                    fila = dict(r)
                    break
            cur.close()
        if not fila:
            raise HTTPException(status_code=404, detail="Tarifa no encontrada")
        return _fila_tarifa(fila)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Error buscando tarifa %s", vehicle_type)
        raise HTTPException(status_code=500, detail="Error consultando las tarifas") from e


@router.get("/pricing-rules")
def listar_reglas():
    """Devuelve todas las reglas de precio por horario."""
    try:
        filas = _leer_reglas()
        return {"rules": [_fila_regla(f) for f in filas]}
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Error listando reglas horarias")
        raise HTTPException(status_code=500, detail="Error consultando las reglas horarias") from e


@router.get("/pricing-rules/{vehicle_type}")
def obtener_reglas(vehicle_type: str):
    """Reglas horarias de una tarifa especifica (para el multiplicador)."""
    buscado = _normalizar(vehicle_type)
    try:
        filas = [f for f in _leer_reglas() if _normalizar(f["vehicle_type"]) == buscado]
        if not filas:
            raise HTTPException(status_code=404, detail="Tarifa no encontrada")
        return {"rules": [_fila_regla(f) for f in filas]}
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Error buscando reglas de %s", vehicle_type)
        raise HTTPException(status_code=500, detail="Error consultando las reglas horarias") from e