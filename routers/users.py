"""
Gestión de cuenta de usuario.
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

router = APIRouter(prefix="/users", tags=["Usuarios"])

# La cuenta del pasajero vive en la base de datos "Cliente".
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
    return {"id": str(user["_id"]), "email": email, "rol": user.get("rol"), **user}

@router.delete("/me")
async def delete_account(user: dict = Depends(get_current_user)):
    user_id = ObjectId(user["id"])
    anonymous_email = f"deleted_{user['id']}@deleted.local"
    users_coleccion.update_one(
        {"_id": user_id},
        {
            "$set": {
                "email": anonymous_email,
                "full_name": "Usuario eliminado",
                "phone": None,
                "password_hash": None,
                "codigo_referido": None,
                "referido_por": None,
                "descuentos_disponibles": 0,
                "eliminado": True,
                "fecha_eliminacion": datetime.utcnow(),
            },
            "$unset": {
                "direccion": "",
                "foto_perfil": "",
            }
        }
    )
    return {"message": "Cuenta eliminada correctamente"}

@router.get("/me")
async def get_my_profile(user: dict = Depends(get_current_user)):
    return {
        "id": user["id"],
        "email": user["email"],
        "full_name": user.get("full_name"),
        "phone": user.get("phone"),
        "rol": user.get("rol", "cliente"),
        "codigo_referido": user.get("codigo_referido"),
        "descuentos_disponibles": user.get("descuentos_disponibles", 0),
    }