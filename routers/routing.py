"""
Recalculo de ruta del conductor cuando se desvía de la ruta original.

El endpoint existe por dos razones:

  1. El movil no sale a internet de forma fiable. Todo lo que necesite la
     navegacion pasa por el backend, que a su vez habla con OSRM.
  2. Centraliza los parametros. Si el umbral de desvio o el perfil cambian,
     se cambian aqui y no en cada instalacion de la app.

Formato de la respuesta: identico al que ya devuelve el servicio de routing de
la app, para que `OsrmRoute` pueda leerlo sin cambios. La geometria va en
GeoJSON (`LineString`), que es lo que entiende la capa del mapa.
"""
import sys

sys.path.insert(0, "E:\\Taxi_Rapid")

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from typing import Any, Dict, List, Optional

import httpx

router = APIRouter(prefix="/api/routing", tags=["Routing"])

# El mismo servidor que usa la app para la ruta inicial. Se deja configurable
# por entorno para poder apuntar a una instancia propia sin tocar codigo.
OSRM_BASE = "https://router.project-osrm.org/route/v1/driving"

# Perfiles que acepta OSRM en el path. La app solo usa `driving`; el resto se
# permite por si el taxi necesita_PROFILE_ distinto mas adelante.
_PERFILES = {"driving", "cycling", "walking"}

# Cortafuegos de OSRM: rechaza peticiones demasiado seguidas. Con estos valores
# se puede atender un desvio por conductor sin acercarse al limite.
_TIMEOUT_S = 10.0


class Punto(BaseModel):
    """Coordenada en el orden que espera la app: latitud primero."""
    lat: float
    lng: float


class RecalcularRequest(BaseModel):
    """Peticion de recalculo.

    `previous_route_id` es opcional y va para traza: el backend no guarda
    rutas, asi que hoy no lo usa para nada. Se acepta para que el contrato no
    cambie cuando se implemente el historial.
    """
    origin: Punto
    destination: Punto
    profile: str = Field(default="driving")
    previous_route_id: Optional[str] = None


class RecalcularResponse(BaseModel):
    route: Dict[str, Any]
    distance_meters: float
    duration_seconds: float
    geometry: Dict[str, Any]


@router.post("/recalculate", response_model=RecalcularResponse)
async def recalcular(req: RecalcularRequest):
    """Recalcula la ruta entre origen y destino.

    Devuelve 502 si OSRM no responde o no encuentra ninguna ruta, que es lo
    que la app necesita distinguir de un error de red propio.
    """
    perfil = (req.profile or "driving").lower()
    if perfil not in _PERFILES:
        raise HTTPException(
            status_code=400,
            detail=f"Perfil no soportado: {req.profile}. Use uno de {sorted(_PERFILES)}.",
        )

    # OSRM trabaja en orden lon,lat. El payload llega lat,lng porque es el que
    # usa la app en el resto de endpoints.
    url = (
        f"{OSRM_BASE}/{req.origin.lng},{req.origin.lat};"
        f"{req.destination.lng},{req.destination.lat}"
        "?overview=full&geometries=geojson&steps=false&alternatives=false"
    )

    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT_S) as cliente:
            resp = await cliente.get(url)
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="OSRM no respondio a tiempo.")
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"No se pudo contactar OSRM: {e}")

    if resp.status_code != 200:
        raise HTTPException(
            status_code=502,
            detail=f"OSRM devolvio {resp.status_code}.",
        )

    try:
        cuerpo = resp.json()
    except ValueError:
        raise HTTPException(status_code=502, detail="OSRM devolvio una respuesta ilegible.")

    rutas = cuerpo.get("routes") or []
    if not rutas:
        # OSRM responde 200 con routes vacio cuando no hay camino posible.
        raise HTTPException(status_code=404, detail="No hay ruta entre esos puntos.")

    ruta = rutas[0]
    geometria = ruta.get("geometry")
    if not isinstance(geometria, dict) or geometria.get("type") != "LineString":
        raise HTTPException(status_code=502, detail="OSRM devolvio una geometria inesperada.")

    return RecalcularResponse(
        route={
            "geometry": geometria,
            "distance": ruta.get("distance", 0.0),
            "duration": ruta.get("duration", 0.0),
        },
        distance_meters=float(ruta.get("distance", 0.0)),
        duration_seconds=float(ruta.get("duration", 0.0)),
        geometry=geometria,
    )


@router.get("/salud")
async def salud():
    """Comprueba si OSRM responde, para diagnostico."""
    url = f"{OSRM_BASE}/-82.3666,23.1136;-82.35,23.12?overview=false"
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT_S) as cliente:
            resp = await cliente.get(url)
        return {"osrm": "ok" if resp.status_code == 200 else f"http_{resp.status_code}"}
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"OSRM inaccesible: {e}")