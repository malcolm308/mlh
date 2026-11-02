"""
Ubicaciones favoritas del usuario.
"""
import logging
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Header, HTTPException, Depends
from pydantic import BaseModel
from bson import ObjectId

from db.Administración.auth import verify_token as verify_admin_token
from db.Cliente.connection import cliente_db

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/favoritos", tags=["Favoritos"])

# Los pasajeros viven en la base "Cliente".
favoritos_coleccion = cliente_db["favoritos"]
users_coleccion = cliente_db["users"]


def get_current_user(authorization: Optional[str] = Header(None)) -> dict:
    if not authorization:
        raise HTTPException(status_code=401, detail="Token requerido")
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Formato de token inválido")
    payload = verify_admin_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token inválido")
    email = payload.get("sub")
    user = users_coleccion.find_one({"email": email})
    if not user:
        raise HTTPException(status_code=403, detail="Usuario no encontrado")
    return {"id": str(user["_id"]), "email": email, "rol": user.get("rol")}


class FavoritoCreate(BaseModel):
    alias: str
    direccion: str
    # Las coordenadas son opcionales: muchas veces el pasajero solo quiere
    # guardar el nombre y la calle ("Casa", "Trabajo") sin saber el punto GPS.
    lat: Optional[float] = None
    lng: Optional[float] = None
    # El cliente puede mandarlo; si viene, tiene que coincidir con el token.
    user_id: Optional[str] = None


class FavoritoUpdate(BaseModel):
    alias: Optional[str] = None
    direccion: Optional[str] = None
    lat: Optional[float] = None
    lng: Optional[float] = None


@router.post("/", status_code=201)
async def crear_favorito(body: FavoritoCreate, user: dict = Depends(get_current_user)):
    if body.user_id and body.user_id != user["id"]:
        raise HTTPException(status_code=403, detail="El user_id no coincide con tu cuenta")
    alias = (body.alias or "").strip()
    direccion = (body.direccion or "").strip()
    if not alias:
        raise HTTPException(status_code=400, detail="El alias es obligatorio")
    if not direccion:
        raise HTTPException(status_code=400, detail="La dirección es obligatoria")
    # Si se indican coordenadas tienen que venir las dos y ser validas; una sola
    # no sirve para situar nada en el mapa.
    if (body.lat is None) != (body.lng is None):
        raise HTTPException(
            status_code=400,
            detail="Indica latitud y longitud, o deja las dos vacías",
        )
    if body.lat is not None and (
        not (-90 <= body.lat <= 90) or not (-180 <= body.lng <= 180)
    ):
        raise HTTPException(status_code=400, detail="Coordenadas inválidas")

    favorito = {
        "user_id": user["id"],
        "alias": alias,
        "direccion": direccion,
        "lat": body.lat,
        "lng": body.lng,
        "created_at": datetime.utcnow(),
    }
    result = favoritos_coleccion.insert_one(favorito)
    # `insert_one` escribe `_id` (un ObjectId) dentro del propio dict que
    # devuelve: si se expande tal cual en la respuesta, `jsonable_encoder` no
    # sabe serializarlo y el POST responde 500 AUNQUE el favorito ya se haya
    # guardado. Se saca y se devuelve el id como texto.
    favorito.pop("_id", None)
    return {"id": str(result.inserted_id), **favorito}


@router.get("/")
async def listar_favoritos(user: dict = Depends(get_current_user)):
    favoritos = list(favoritos_coleccion.find(
        {"user_id": user["id"]},
        {"_id": 1, "alias": 1, "direccion": 1, "lat": 1, "lng": 1},
    ).sort("created_at", -1))
    for f in favoritos:
        f["id"] = str(f["_id"])
        del f["_id"]
    return favoritos


@router.delete("/{favorito_id}")
async def eliminar_favorito(favorito_id: str, user: dict = Depends(get_current_user)):
    try:
        oid = ObjectId(favorito_id)
    except Exception:
        raise HTTPException(status_code=400, detail="ID inválido")
    result = favoritos_coleccion.delete_one({"_id": oid, "user_id": user["id"]})
    if result.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Favorito no encontrado")
    return {"message": "Favorito eliminado"}
