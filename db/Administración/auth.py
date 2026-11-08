"""JWT del administrador. La logica vive en `db/tokens.py`."""

from db.tokens import (ACCESS_TOKEN_EXPIRE_MINUTES, ALGORITHM, SECRET_KEY,
                       create_access_token as _create_access,
                       create_refresh_token as _create_refresh,
                       verify_token as _verify_token)

APP = "admin"


def create_access_token(data: dict) -> str:
    return _create_access(data, app=APP)


def create_refresh_token(data: dict) -> str:
    return _create_refresh(data, app=APP)


def verify_token(token: str):
    return _verify_token(token)
