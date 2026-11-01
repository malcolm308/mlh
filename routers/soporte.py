"""
Soporte y contacto.
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

router = APIRouter(prefix="/soporte", tags=["Soporte"])

soporte_coleccion = admin_db["soporte"]

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

class TicketCreate(BaseModel):
    tipo: str
    mensaje: str

@router.post("/ticket", status_code=201)
async def crear_ticket(body: TicketCreate, user: dict = Depends(get_current_user)):
    ticket = {
        "user_id": user["id"],
        "user_email": user["email"],
        "tipo": body.tipo,
        "mensaje": body.mensaje,
        "estado": "abierto",
        "fecha": datetime.utcnow(),
    }
    result = soporte_coleccion.insert_one(ticket)
    return {"message": "Ticket creado. Nos pondremos en contacto contigo pronto.", "ticket_id": str(result.inserted_id)}
