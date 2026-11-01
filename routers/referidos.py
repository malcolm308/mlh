"""
Sistema de referidos con descuentos automaticos.
"""
import logging
import secrets
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Header, HTTPException, Depends
from pydantic import BaseModel
from bson import ObjectId

from db.Administración.auth import verify_token as verify_admin_token
from db.Cliente.connection import cliente_db

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/referidos", tags=["Referidos"])

# Los pasajeros viven en la base de datos "Cliente", no en "Administración".
users_coleccion = cliente_db["users"]
descuentos_coleccion = cliente_db["descuentos"]


def generate_referral_code() -> str:
    while True:
        code = secrets.token_urlsafe(6)[:8].upper()
        if not users_coleccion.find_one({"codigo_referido": code}):
            return code


def _nombre(doc: Optional[dict]) -> str:
    """Nombre visible del pasajero (el registro usa Nombre/Apellidos)."""
    if not doc:
        return "Usuario"
    nombre = (doc.get("Nombre") or doc.get("nombre") or "").strip()
    apellidos = (doc.get("Apellidos") or doc.get("apellidos") or "").strip()
    completo = f"{nombre} {apellidos}".strip()
    return completo or doc.get("full_name") or doc.get("email") or "Usuario"


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


class CodigoIn(BaseModel):
    codigo: str


@router.get("/mi-codigo")
async def obtener_mi_codigo(user: dict = Depends(get_current_user)):
    codigo = user.get("codigo_referido")
    if not codigo:
        codigo = generate_referral_code()
        users_coleccion.update_one(
            {"_id": ObjectId(user["id"])},
            {"$set": {"codigo_referido": codigo}},
        )
    return {"codigo": codigo}


@router.get("/mis-descuentos")
async def obtener_descuentos(user: dict = Depends(get_current_user)):
    descuentos = user.get("descuentos_disponibles", 0)
    return {"descuentos_disponibles": descuentos}


@router.get("/mis-referidos")
async def obtener_relativos(user: dict = Depends(get_current_user)):
    user_id = user["id"]
    referidos = list(users_coleccion.find(
        {"referido_por": user_id},
        {"_id": 1, "email": 1, "full_name": 1, "Nombre": 1, "Apellidos": 1,
         "fecha_registro": 1},
    ).sort("fecha_registro", -1))
    for r in referidos:
        r["id"] = str(r["_id"])
        r["full_name"] = _nombre(r)
        del r["_id"]
    return referidos


@router.post("/validar-codigo")
async def validar_codigo_referido(datos: CodigoIn, user: dict = Depends(get_current_user)):
    codigo = (datos.codigo or "").strip().upper()
    referidor = users_coleccion.find_one({"codigo_referido": codigo})
    if not referidor:
        return {"valido": False, "mensaje": "Código inválido"}
    if str(referidor["_id"]) == user["id"]:
        return {"valido": False, "mensaje": "No puedes referirte a ti mismo"}
    return {"valido": True, "referidor_nombre": _nombre(referidor)}


@router.post("/canjear-codigo")
async def canjear_codigo_referido(datos: CodigoIn, user: dict = Depends(get_current_user)):
    """Vincula la cuenta con quien lo invitó y le da su descuento de bienvenida.

    Solo se puede usar una vez y antes de completar el primer viaje.
    """
    codigo = (datos.codigo or "").strip().upper()
    if not codigo:
        raise HTTPException(status_code=400, detail="Escribe un código")

    yo = users_coleccion.find_one({"_id": ObjectId(user["id"])})
    if not yo:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    if yo.get("referido_por"):
        raise HTTPException(status_code=400, detail="Ya usaste un código de referido")
    if int(yo.get("viajes_completados") or 0) > 0:
        raise HTTPException(
            status_code=400,
            detail="Solo puedes usar un código antes de tu primer viaje")

    referidor = users_coleccion.find_one({"codigo_referido": codigo})
    if not referidor:
        raise HTTPException(status_code=404, detail="Código inválido")
    if str(referidor["_id"]) == user["id"]:
        raise HTTPException(status_code=400, detail="No puedes usar tu propio código")

    users_coleccion.update_one(
        {"_id": ObjectId(user["id"])},
        {
            "$set": {"referido_por": str(referidor["_id"])},
            "$inc": {"descuentos_disponibles": 1},
        },
    )
    descuentos = int(yo.get("descuentos_disponibles") or 0) + 1
    return {
        "ok": True,
        "mensaje": "¡Código aplicado! Tienes 10% de descuento en tu primer viaje.",
        "descuentos_disponibles": descuentos,
        "referidor_nombre": _nombre(referidor),
    }
