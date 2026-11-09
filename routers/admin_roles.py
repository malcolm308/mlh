"""Roles jerarquicos para el panel de administracion (RBAC estricto en el API).

Jerarquia:
    super_admin      acceso total (gatekeeper de administradores y config)
    trip_operator    gestion de viajes criticos (asignacion forzada, huerfanos)
    user_operator    registro y aprobacion de choferes y vehiculos
    wallet_operator  recargas, descuentos y movimientos de saldo

La regla de oro: `super_admin` SIEMPRE pasa; un operador solo pasa en las
areas de su rol. El rol se lee de la BASE DE DATOS en cada peticion (no del
JWT): si el super_admin degrada a alguien, su token deja de servir al instante
sin esperar a que caduque.

Uso:
    from routers.admin_roles import require_rol

    @router.put("/ruta", dependencies=[Depends(require_rol("user_operator"))])
    ...o si el endpoint necesita saber QUIEN:
    @router.put("/ruta")
    async def endpoint(admin: dict = Depends(require_rol("wallet_operator"))):
        # admin = {"id", "email", "rol"}

Super: malcolmlamarhurtado@gmail.com (backfill automatico en el login).
"""
import logging
import re
from datetime import datetime
from typing import Optional

from bson import ObjectId
from fastapi import Header, HTTPException

from db.Administración.auth import verify_token
from db.Administración.connection import admin_db

logger = logging.getLogger(__name__)

ROLES_VALIDOS = ("super_admin", "trip_operator", "user_operator", "wallet_operator")

ROL_SUPER = "super_admin"
SUPER_EMAIL = "malcolmlamarhurtado@gmail.com"

admin_coleccion = admin_db.users


def _admin_doc_por_email(email: Optional[str]) -> Optional[dict]:
    """Busca el administrador por su correo del token.

    Primero por igualdad exacta; si no, case-insensitive: el email vive tal
    cual se registro y un anti caso distino con mayusculas NO debe romper el
    auth del panel (origine del falso "La cuenta no es de administrador").
    """
    if not email:
        return None
    email = email.strip().lower()
    doc = admin_coleccion.find_one({"email": email})
    if doc:
        return doc
    seguro = re.escape(text_email)
    return admin_coleccion.find_one({"email": {"$regex":("^%s$" % seguro),
                                               "$options": "i"}})


def _token_admin(authorization: Optional[str]) -> dict:
    """Valida el header y devuelve el payload; 401 si no es admin valido."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Token requerido")
    payload = verify_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token invalido o expirado")
    if payload.get("app") != "admin":
        raise HTTPException(status_code=403, detail="La cuenta no es de administrador")
    return payload


def require_rol(*roles_validos: str):
    """Fabrica de dependencias FastAPI: Depends(require_rol("trip_operator")).

    super_admin pasa SIEMPRE. Los operadores pasan solo si su rol esta en la
    lista. Si el documento no tiene ninguno de los roles nuevos (cuenta vieja),
    se trata como operador sin permisos hasta que el super admin lo asigne.
    """
    invalidos = [r for r in roles_validos if r not in ROLES_VALIDOS]
    if invalidos:
        raise RuntimeError("Rol desconocido en la configuracion: %s" % invalidos)

    def _dependencia(authorization: Optional[str] = Header(None)) -> dict:
        payload = _token_admin(authorization)
        email = payload.get("sub")
        admin = _admin_doc_por_email(email)
        if not admin:
            raise HTTPException(status_code=403, detail="La cuenta no es de administrador")
        rol = (admin.get("rol") or "").strip().lower()
        # Latido del super: si su cuenta aun no tiene el rol (base vieja) se
        # arregla en el momento, sin depender de que el admin entre al panel.
        if email == SUPER_EMAIL and rol != ROL_SUPER:
            admin_coleccion.update_one(
                {"_id": admin["_id"]},
                {"$set": {"rol": ROL_SUPER, "updated_at": datetime.utcnow()}})
            rol = ROL_SUPER
        if rol == ROL_SUPER:
            return {"id": str(admin["_id"]), "email": admin.get("email"), "rol": rol,
                    "nombre": admin.get("nombre")}
        if rol in roles_validos:
            return {"id": str(admin["_id"]), "email": admin.get("email"), "rol": rol,
                    "nombre": admin.get("nombre")}
        logger.info("403: %s (%s) intento un area de %s",
                    email, rol or "sin-rol", "+".join(roles_validos))
        raise HTTPException(
            status_code=403,
            detail="Tu cuenta no tiene permiso para esta accion. "
                   "Pide al super_admin el rol correspondiente.")

    return _dependencia


def verificar_rol_para_token(authorization: Optional[str], roles_validos) -> dict:
    """Version programatica para comprobaciones dentro de un endpoint."""
    payload = _token_admin(authorization)
    admin = _admin_doc_por_email(payload.get("sub"))
    if not admin:
        raise HTTPException(status_code=403, detail="La cuenta no es de administrador")
    rol = (admin.get("rol") or "").strip().lower()
    if admin.get("email") == SUPER_EMAIL:
        return {"id": str(admin["_id"]), "email": admin.get("email"), "rol": ROL_SUPER}
    if rol in roles_validos:
        return {"id": str(admin["_id"]), "email": admin.get("email"), "rol": rol}
    raise HTTPException(status_code=403,
                        detail="Tu cuenta no tiene permiso para esta accion.")


def require_admin_super():
    return require_rol(ROL_SUPER)


# Areas predefinidas (legible en cada router).
REQUIERE_SUPER = require_rol(ROL_SUPER)
REQUIERE_OPERADOR_VIAJES = require_rol("trip_operator")
REQUIERE_OPERADOR_REGISTROS = require_rol("user_operator")
REQUIERE_OPERADOR_CARTERA = require_rol("wallet_operator")
