"""
Sistema de referidos con descuentos automáticos.
"""
import logging
import secrets
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from bson import ObjectId

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/referidos", tags=["Referidos"])

users_coleccion = admin_db["users"]
descuentos_coleccion = admin_db["descuentos"]

def generate_referral_code() -> str:
    while True:
        code = secrets.token_urlsafe(6)[:8].upper()
        if not users_coleccion.find_one({"codigo_referido": code}):
            return code

def get_current_user(authorization: Optional[str] = None) -> dict:
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

@router.get("/mi-codigo")
async def obtener_mi_codigo(user: dict = Depends(get_current_user)):
    codigo = user.get("codigo_referido")
    if not codigo:
        codigo = generate_referral_code()
        users_coleccion.update_one({"_id": ObjectId(user["id"])}, {"$set": {"codigo_referido": codigo}})
    return {"codigo": codigo}

@router.get("/mis-descuentos")
async def obtener_descuentos(user: dict = Depends(get_current_user)):
    descuentos = user.get("descuentos_disponibles", 0)
    return {"descuentos_disponibles": descuentos}

@router.get("/mis-referidos")
async def obtener_relativos(user: dict = Depends(get_current_user)):
    user_id = user["id"]
    referidos = list(users_coleccion.find({"referido_por": user_id}, {"_id": 1, "email": 1, "full_name": 1, "fecha_registro": 1}).sort("fecha_registro", -1))
    for r in referidos:
        r["id"] = str(r["_id"])
        del r["_id"]
    return referidos

@router.post("/validar-codigo")
async def validar_codigo_referido(codigo: str, user: dict = Depends(get_current_user)):
    referidor = users_coleccion.find_one({"codigo_referido": codigo.upper()})
    if not referidor:
        return {"valido": False, "mensaje": "Código inválido"}
    if str(referidor["_id"]) == user["id"]:
        return {"valido": False, "mensaje": "No puedes referirte a ti mismo"}
    return {"valido": True, "referidor_nombre": referidor.get("full_name", "Usuario")}