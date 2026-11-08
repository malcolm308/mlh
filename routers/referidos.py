"""
Sistema de referidos con descuentos automaticos.
"""
import logging
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Header, HTTPException, Depends
from pydantic import BaseModel
from bson import ObjectId

from db.Administración.auth import verify_token as verify_admin_token
from db.Cliente.connection import cliente_db
from services.codigos_referido import asegurar_codigo, generar_codigo

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/referidos", tags=["Referidos"])

# Los pasajeros viven en la base de datos "Cliente", no en "Administración".
users_coleccion = cliente_db["users"]
descuentos_coleccion = cliente_db["descuentos"]


def generate_referral_code() -> str:
    """Codigo nuevo para un pasajero (ver `services.codigos_referido`)."""
    return generar_codigo(users_coleccion)


def _nombre(doc: Optional[dict]) -> str:
    """Nombre visible del pasajero (el registro usa Nombre/Apellidos)."""
    if not doc:
        return "Usuario"
    nombre = (doc.get("Nombre") or doc.get("nombre") or "").strip()
    apellidos = (doc.get("Apellidos") or doc.get("apellidos") or "").strip()
    completo = f"{nombre} {apellidos}".strip()
    return completo or doc.get("full_name") or doc.get("email") or "Usuario"


def _referidos_activos() -> bool:
    """Interruptor global de referidos, configurable desde el panel Tkinter."""
    try:
        from routers.promociones import leer_promocion
        return bool(leer_promocion().get("referidos_activos", True))
    except Exception:
        # Si la configuracion no se puede leer, se mantiene el comportamiento
        # historico (activo) antes que romper el cierre de viajes.
        logger.warning("No se pudo leer referidos_activos; se asume activo",
                       exc_info=True)
        return True


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
    # `asegurar_codigo` crea y guarda el codigo si la cuenta es anterior al
    # sistema de referidos: la app puede compartirlo siempre, sin pantallas
    # intermedias ni codigos distintos entre consultas.
    return {"codigo": asegurar_codigo(users_coleccion, user)}


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
    """DESUSADO (410): el codigo de referido solo se acepta AL REGISTRARSE.

    Antes estos endpoints permitian aplicar el codigo desde la pantalla de
    referidos ya con sesion abierta, que abre la puerta a pedir codigos a
    personas que no invitaron. El alta de la cuenta los procesa.
    """
    return {
        "valido": False,
        "error": "gone",
        "mensaje": "Los códigos de invitación solo se aceptan al registrarse",
    }


@router.post("/canjear-codigo")
async def canjear_codigo_referido(datos: CodigoIn, user: dict = Depends(get_current_user)):
    """DESUSADO (410): el codigo de referido solo se acepta AL REGISTRARSE."""
    raise HTTPException(
        status_code=410,
        detail="Los códigos de invitación solo se aceptan al registrarse")
