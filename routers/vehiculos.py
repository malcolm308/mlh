"""
Tipos de vehiculo y sus tarifas, leidos de PostgreSQL.

La app del chofer y la del cliente necesitan la lista de servicios disponibles
para el registro y para el selector de tipo. Salen de la tabla `tariffs`, que es
donde el administrador ya ajusta precios y pasajeros: asi el selector no puede
quedarse desincronizado de lo que se cobra de verdad.

Los valores no se repiten en el codigo. Si el administrador anade un tipo nuevo
o renombra uno, aparece en las apps sin tocar el movil.
"""
import sys

sys.path.insert(0, "E:\\Taxi_Rapid")

from fastapi import APIRouter
from pydantic import BaseModel
from typing import List, Optional

from routers.Solicitud_de_viajes_v4 import get_all_tariffs

router = APIRouter(prefix="/vehiculos", tags=["Vehiculos"])


class TarifaOut(BaseModel):
    """Un tipo de vehiculo con lo que la app necesita para offercerlo."""

    # Identificador tal cual esta en la base, porque es la clave con la que se
    # piden las tarifas: `basic`, `comfort`... Cambiarlo aqui romperia el calculo.
    tipo: str

    # Mismo identificador con la primera letra en mayuscula, que es como se
    # muestra. La app lo guarda aparte para no reescribir strings en pantalla.
    etiqueta: str

    tarifa_base: float
    precio_por_km: float
    precio_por_minuto: float
    max_pasajeros: Optional[int] = None


@router.get("/tipos", response_model=List[TarifaOut])
def listar_tipos():
    """Devuelve los tipos de vehiculo disponibles, ordenados por tarifa base.

    Si PostgreSQL no responde devuelve una lista vacia en vez de un 500: que el
    selector se quede vacio es molesto, pero que la app no cargue es peor.
    """
    try:
        filas = get_all_tariffs()
    except Exception:
        return []

    salida = []
    for f in filas:
        vt = f.get("vehicle_type")
        if not vt:
            continue
        salida.append(
            TarifaOut(
                tipo=vt,
                etiqueta=str(vt).capitalize(),
                tarifa_base=float(f.get("base_fare") or 0),
                precio_por_km=float(f.get("price_per_km") or 0),
                precio_por_minuto=float(f.get("price_per_minute") or 0),
                max_pasajeros=f.get("max_passengers"),
            )
        )
    return salida