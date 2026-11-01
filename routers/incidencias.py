"""
Bloqueos de choferes e incidencias de viajes.
"""
import logging
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from bson import ObjectId

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/incidencias", tags=["Incidencias y Bloqueos"])

bloqueos_coleccion = admin_db["bloqueos"]
incidencias_coleccion = admin_db["incidencias"]

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

class BloqueoCreate(BaseModel):
    driver_id: str
    trip_id: str
    motivo: str

@router.post("/bloquear-chofer", status_code=201)
async def bloquear_chofer(body: BloqueoCreate, user: dict = Depends(get_current_user)):
    bloqueo = {"user_id": user["id"], "driver_id": body.driver_id, "trip_id": body.trip_id, "motivo": body.motivo, "fecha": datetime.utcnow()}
    bloqueos_coleccion.insert_one(bloqueo)
    incidencia = {"trip_id": body.trip_id, "user_id": user["id"], "driver_id": body.driver_id, "tipo": "bloqueo_chofer", "motivo": body.motivo, "estado": "pendiente", "fecha": datetime.utcnow()}
    result = incidencias_coleccion.insert_one(incidencia)
    return {"message": "Chofer bloqueado e incidencia creada", "incidencia_id": str(result.inserted_id)}

@router.get("/bloqueos")
async def listar_bloqueos(user: dict = Depends(get_current_user)):
    bloqueos = list(bloqueos_coleccion.find({"user_id": user["id"]}).sort("fecha", -1))
    for b in bloqueos:
        b["id"] = str(b["_id"])
        del b["_id"]
    return bloqueos