"""Emision y validacion de JWT para las tres apps (cliente, chofer y admin).

Antes cada `db/<perfil>/auth.py` repetia la misma logica con el secreto
hardcodeado y 30 minutos de vida. Ahora hay un solo sitio:

* **access token**: 2 horas. Es el que viaja en cada peticion.
* **refresh token**: 30 dias (configurable). Solo sirve para pedir un access
  nuevo en `POST /auth/refresh`, nunca para autenticar una peticion normal.

El claim `type` distingue los dos. Los tokens emitidos antes de este cambio no
lo llevan; se siguen aceptando como access para no cerrar sesiones al
desplegar.

El secreto se lee de `JWT_SECRET_KEY`; si no esta definida se usa el valor
historico para no romper produccion. Conviene definirla en Render: cambiar el
secreto invalida todas las sesiones (los usuarios tendran que entrar de nuevo).
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta
from typing import Optional

from jose import JWTError, jwt

SECRET_KEY = os.getenv("JWT_SECRET_KEY", "TaxiRapid_SecretKey_2026")
ALGORITHM = "HS256"

ACCESS_TOKEN_EXPIRE_MINUTES = int(
    os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "120"))
REFRESH_TOKEN_EXPIRE_DAYS = int(os.getenv("REFRESH_TOKEN_EXPIRE_DAYS", "30"))

ACCESS = "access"
REFRESH = "refresh"


def _crear(data: dict, *, tipo: str, delta: timedelta,
           app: Optional[str]) -> str:
    """Firma un JWT copiando `data` y anadiendo tipo, app y caducidad.

    No se muta el diccionario del llamador: los diccionarios con `sub`/`id` se
    reutilizan en varios sitios y no deben quedarse con claims de mas.
    """
    payload = data.copy()
    payload["type"] = tipo
    payload["exp"] = datetime.utcnow() + delta
    if app:
        payload["app"] = app
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def create_access_token(data: dict, app: Optional[str] = None) -> str:
    return _crear(data, tipo=ACCESS,
                  delta=timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES),
                  app=app)


def create_refresh_token(data: dict, app: Optional[str] = None) -> str:
    return _crear(data, tipo=REFRESH,
                  delta=timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS),
                  app=app)


def verify_token(token: str, tipo: str = ACCESS) -> Optional[dict]:
    """Devuelve el payload si la firma y la caducidad son validas, o `None`.

    `tipo` es el claim exigido. Un token sin `type` (emitido antes del cambio)
    se considera access, para que el despliegue no cierre sesiones abiertas.
    """
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None
    if tipo != ACCESS and payload.get("type") != tipo:
        return None
    if tipo == ACCESS:
        # Un refresh token NO vale como access: si se colara, duraria 30 dias
        # en cada peticion y el refresco dejaria de tener sentido.
        if payload.get("type") not in (None, ACCESS):
            return None
    return payload


def verify_access_token(token: str) -> Optional[dict]:
    return verify_token(token, ACCESS)


def verify_refresh_token(token: str) -> Optional[dict]:
    return verify_token(token, REFRESH)
