"""Enlaces cortos para descargar los APK.

Los acortadores externos (shty.in) fallaban o dejaban paginas intermedias con
publicidad, y WhatsApp a veces no los marcaba como clicables. Estos cuatro
endpoints son del propio backend y redirigen directo al archivo de `/static`:

    GET /c64  -> app_cliente_64bits.apk
    GET /c32  -> app_cliente_32bits.apk
    GET /d64  -> app_chofer_64bits.apk
    GET /d32  -> app_chofer_32bits.apk

La redireccion es **relativa** a proposito: Render termina el TLS en su proxy y
una URL absoluta construida con `request.url` podria salir en `http://`, que
Android bloquea. Con `/static/...` el telefono sigue hablando https.
"""
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import RedirectResponse

router = APIRouter(tags=["descargas"])

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"

APK_CLIENTE_64 = "app_cliente_64bits.apk"
APK_CLIENTE_32 = "app_cliente_32bits.apk"
APK_CHOFER_64 = "app_chofer_64bits.apk"
APK_CHOFER_32 = "app_chofer_32bits.apk"


def _redirigir_al_apk(archivo: str) -> RedirectResponse:
    """302 al APK de `/static`, o 404 claro si todavia no se publico."""
    if not (STATIC_DIR / archivo).is_file():
        raise HTTPException(
            status_code=404, detail=f"APK no publicado: {archivo}")
    # `no-store` para que WhatsApp y los navegadores no cacheen la redireccion
    # cuando se publique una version nueva con el mismo nombre.
    return RedirectResponse(
        url=f"/static/{archivo}",
        status_code=302,
        headers={"Cache-Control": "no-store"},
    )


@router.get("/c64", include_in_schema=False)
def apk_cliente_64() -> RedirectResponse:
    """APK del cliente de 64 bits (el enlace principal)."""
    return _redirigir_al_apk(APK_CLIENTE_64)


@router.get("/c32", include_in_schema=False)
def apk_cliente_32() -> RedirectResponse:
    """APK del cliente de 32 bits (telefonos antiguos)."""
    return _redirigir_al_apk(APK_CLIENTE_32)


@router.get("/d64", include_in_schema=False)
def apk_chofer_64() -> RedirectResponse:
    """APK del chofer de 64 bits (el enlace principal)."""
    return _redirigir_al_apk(APK_CHOFER_64)


@router.get("/d32", include_in_schema=False)
def apk_chofer_32() -> RedirectResponse:
    """APK del chofer de 32 bits (telefonos antiguos)."""
    return _redirigir_al_apk(APK_CHOFER_32)
