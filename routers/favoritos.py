"""
Ubicaciones favoritas del usuario.
"""
import logging
from typing import Optional, List
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from bson import ObjectId

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/favoritos", tags=["Favoritos"])

favoritos_coleccion = admin_db["favoritos"]

def get_current_user(authorization: Optional[str] = None) -> dict:
    if not authorization:
        raise HTTPException(status_code=401, detail="Token requerido")
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Formato de token inválido")
    payload = verify_admin_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token inválido")
    email = payload.get("sub")
    user = admin_db.users.find_one({"email": email})
    if not user:
        raise HTTPException(status_code=403, detail="Usuario no encontrado")
    return {"id": str(user["_id"]), "email": email, "rol": user.get("rol")}

class FavoritoCreate(BaseModel):
    alias: str
    direccion: str
    lat: float
    lng: float

class FavoritoUpdate(BaseModel):
    alias: Optional[str] = None
    direccion: Optional[str] = None
    lat: Optional[float] = None
    lng: Optional[float] = None

@router.post("/", status_code=201)
async def crear_favorito(body: FavoritoCreate, user: dict = Depends(get_current_user)):
    favorito = {"user_id": user["id"], "alias": body.alias, "direccion": body.direccion, "lat": body.lat, "lng": body.lng}
    result = favoritos_coleccion.insert_one(favorito)
    return {"id": str(result.inserted_id), **favorito}

@router.get("/")
async def listar_favoritos(user: dict = Depends(get_current_user)):
    favoritos = list(favoritos_coleccion.find({"user_id": user["id"]}, {"_id": 1, "alias": 1, "direccion": 1, "lat": 1, "lng": 1}))
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
