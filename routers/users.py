"""
Gestión de cuenta de usuario.
"""
import logging
import os
import uuid
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Header, HTTPException, Depends
from pydantic import BaseModel
from bson import ObjectId
import bcrypt

from db.Administración.auth import verify_token as verify_admin_token
from db.Cliente.connection import cliente_db
from services.codigos_referido import asegurar_codigo

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
    if user.get("eliminado"):
        raise HTTPException(status_code=403, detail="La cuenta ya fue eliminada")
    return {"id": str(user["_id"]), "email": email, "rol": user.get("rol"), **user}

@router.delete("/me")
async def delete_account(user: dict = Depends(get_current_user)):
    """El pasajero borra SU cuenta (token requerido).

    Los campos se anonimizan con los nombres REALES de la coleccion de
    clientes (numero_de_telefono/Nombre/password). Antes se intentaba borrar
    `phone`/`full_name`/`password_hash`, que no existen en estos documentos:
    los datos verdaderos quedaban intactos y la cuenta se volvia a activar
    con el mismo telefono, como si no se hubiera borrado nada.
    """
    user_id = ObjectId(user["id"])
    anonymous_email = f"deleted_{user['id']}@deleted.local"
    # Contrasena imposible de adivinar: un hash real de bcrypt (con un string
    # aleatorio) para que el login no rompa al comprobarla y nunca acierte.
    secreto = bcrypt.hashpw(
        uuid.uuid4().hex.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
    users_coleccion.update_one(
        {"_id": user_id},
        {
            "$set": {
                "email": anonymous_email,
                "numero_de_telefono": None,
                "password": secreto,
                "Nombre": "Usuario eliminado",
                "Apellidos": "",
                "full_name": "Usuario eliminado",   # por los documentos viejos
                "phone": None,                      # por los documentos viejos
                "descuentos_disponibles": 0,
                "eliminado": True,
                "fecha_eliminacion": datetime.utcnow().isoformat(),
                # Sin esto el refresh token seguia valido 30 dias: la app
                # renovaba el access y parecia que la cuenta nunca se borro.
                # Con Enable en False, /auth/refresh la rechaza al instante.
                "Enable": False,
                "status": "deleted",
            },
            "$unset": {
                "codigo_referido": "",
                "referido_por": "",
                "direccion": "",
                "foto_perfil": "",
                "password_hash": "",
            }
        }
    )
    logger.info("Cuenta del pasajero %s eliminada desde la app", user_id)
    return {"message": "Cuenta eliminada correctamente"}

@router.get("/me")
async def get_my_profile(user: dict = Depends(get_current_user)):
    # Si la cuenta es anterior al sistema de referidos, el codigo se crea en
    # esta primera consulta y se guarda; no se devuelve null nunca.
    codigo = asegurar_codigo(users_coleccion, user)
    return {
        "id": user["id"],
        "email": user["email"],
        "full_name": user.get("full_name"),
        "phone": user.get("phone"),
        "rol": user.get("rol", "cliente"),
        "codigo_referido": codigo,
        "descuentos_disponibles": user.get("descuentos_disponibles", 0),
    }