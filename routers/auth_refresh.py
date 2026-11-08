"""Renovacion del access token sin pedir la contrasena otra vez.

`POST /auth/refresh` recibe el `refresh_token` que devolvio el login y
responde un `access_token` nuevo (2 h). No rota el refresh: el movil conserva
el mismo hasta que caduque (30 dias) o el usuario cierre sesion.

El endpoint es publico (no lleva `Authorization`) porque su credencial ES el
refresh token. Aun asi se revalida la cuenta en Mongo: si el administrador
deshabilito o rechazo al chofer, el refresh deja de servir de inmediato.

Los endpoints de salud y OTA (`/healthz`, `/readyz`, `/app/version`) siguen
sin autenticacion: la app puede comprobar actualizaciones con la sesion
caducada.
"""

from __future__ import annotations

from typing import Optional

from bson import ObjectId
from bson.errors import InvalidId
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from db.Administración.connection import admin_db
from db.Chofer.connection import chofer_db
from db.Cliente.connection import cliente_db
from db.tokens import (ACCESS_TOKEN_EXPIRE_MINUTES, create_access_token,
                       verify_refresh_token)

router = APIRouter()

ESTADO_APROBADO = "aprobado"

_COLECCIONES = {
    "client": cliente_db.users,
    "driver": chofer_db.users,
    "admin": admin_db.users,
}


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1)


class RefreshResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int = ACCESS_TOKEN_EXPIRE_MINUTES * 60


def _sesion_invalida(detalle: str = "Tu sesión expiró. Inicia sesión de nuevo."):
    return HTTPException(status_code=401, detail=detalle)


def _buscar_cuenta(identificador: Optional[str], app: Optional[str]):
    """Devuelve `(app, documento)` de la cuenta del refresh, o `(None, None)`.

    Se busca por `_id` (lo normal). Si el token es de una version anterior sin
    `app`, se prueban las tres colecciones. Como ultimo recurso se busca por
    email, porque `sub` siempre lleva el correo.
    """
    apps = [app] if app in _COLECCIONES else list(_COLECCIONES)
    oid = None
    if identificador:
        try:
            oid = ObjectId(identificador)
        except (InvalidId, TypeError):
            oid = None

    for nombre in apps:
        coleccion = _COLECCIONES[nombre]
        documento = None
        if oid is not None:
            documento = coleccion.find_one({"_id": oid})
        if documento is None:
            correo = (identificador or "").lower()
            if correo:
                documento = coleccion.find_one({"email": correo})
        if documento:
            return nombre, documento
    return None, None


@router.post("/auth/refresh", response_model=RefreshResponse)
async def refresh(request: RefreshRequest):
    payload = verify_refresh_token(request.refresh_token)
    if not payload:
        raise _sesion_invalida()

    identificador = payload.get("id") or payload.get("sub")
    app, cuenta = _buscar_cuenta(identificador, payload.get("app"))
    if cuenta is None:
        raise _sesion_invalida()

    # La cuenta pudo cambiar de estado despues de emitir el refresh: el
    # administrador manda. Sin esto, un chofer rechazado seguiria dentro 30
    # dias renovando el access.
    if app == "driver":
        if (cuenta.get("estado_habilitacion") or ESTADO_APROBADO) != ESTADO_APROBADO:
            raise _sesion_invalida("Tu cuenta ya no está habilitada.")
        if not cuenta.get("Enable", True):
            raise _sesion_invalida("Tu cuenta está deshabilitada.")
    elif app == "client" and not cuenta.get("Enable", True):
        raise _sesion_invalida("Tu cuenta está deshabilitada.")

    # `sub` se conserva tal cual: varios modulos lo usan como email del usuario
    # y cambiarlo aqui romperia esos flujos a mitad de sesion.
    datos = {"sub": payload.get("sub"), "id": str(cuenta["_id"])}
    return RefreshResponse(
        access_token=create_access_token(datos, app=app),
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
    )
