"""
Puntos de interes (hoteles, bares, hostales y centros recreativos) que se
muestran en el mapa de las apps.

Se guardan en MongoDB, en la base de Administracion, coleccion `pois`.
"""
import sys

sys.path.insert(0, "E:\\Taxi_Rapid")

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from typing import List, Optional

from pymongo import MongoClient
from bson import ObjectId

router = APIRouter()

# La base real se llama "Administracion" (utf-8). Se escribe con escapes para
# no depender de la codificacion del archivo fuente.
_admin = MongoClient("mongodb://localhost:27017")["Administraci\u00f3n"]
_pois = _admin["pois"]

CATEGORIAS = {
    "hotel": "Hotel",
    "hostal": "Hostal",
    "bar": "Bar",
    "centro_recreativo": "Centro recreativo",
}


class PoiIn(BaseModel):
    nombre: str = Field(min_length=1)
    categoria: str
    lat: float
    lng: float
    direccion: Optional[str] = None


class PoiOut(BaseModel):
    id: str
    nombre: str
    categoria: str
    lat: float
    lng: float
    direccion: Optional[str] = None


def _out(doc) -> PoiOut:
    return PoiOut(
        id=str(doc["_id"]),
        nombre=doc.get("nombre", ""),
        categoria=doc.get("categoria", ""),
        lat=doc.get("lat", 0.0),
        lng=doc.get("lng", 0.0),
        direccion=doc.get("direccion"),
    )


@router.get("/pois", response_model=List[PoiOut])
def list_pois(categoria: Optional[str] = None):
    """Lista los puntos de interes. Opcional: ?categoria=hotel|hostal|bar|centro_recreativo"""
    filtro = {"categoria": categoria} if categoria else {}
    docs = _pois.find(filtro).sort(
        [("categoria", 1), ("nombre", 1)]
    )
    return [_out(d) for d in docs]


@router.post("/pois", response_model=PoiOut, status_code=201)
def create_poi(poi: PoiIn):
    """Da de alta un punto de interes nuevo."""
    if poi.categoria not in CATEGORIAS:
        raise HTTPException(
            status_code=400,
            detail=f"categoria debe ser una de: {', '.join(CATEGORIAS)}",
        )
    res = _pois.insert_one(poi.model_dump())
    return _out(_pois.find_one({"_id": res.inserted_id}))


@router.delete("/pois/{poi_id}", status_code=204)
def delete_poi(poi_id: str):
    """Elimina un punto de interes."""
    if not ObjectId.is_valid(poi_id):
        raise HTTPException(status_code=400, detail="id invalido")
    res = _pois.delete_one({"_id": ObjectId(poi_id)})
    if res.deleted_count == 0:
        raise HTTPException(status_code=404, detail="punto de interes no encontrado")


@router.get("/pois/categorias", response_model=dict)
def categorias():
    """Nombres de las categorias disponibles."""
    return CATEGORIAS