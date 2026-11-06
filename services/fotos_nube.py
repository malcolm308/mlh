"""Almacen de fotos en Cloudinary (reemplaza el disco efimero de Render).

Las fotos (documento del chofer y fotos del vehiculo) viven en Cloudinary y en
MongoDB se guarda la `secure_url` que devuelve la nube, no una ruta local: asi
los redeploys no pierden nada.

Configuracion por variables de entorno:
    CLOUDINARY_CLOUD_NAME / CLOUDINARY_API_KEY / CLOUDINARY_API_SECRET

Sin credenciales el servicio queda desactivado y los routers caen al respaldo
de disco local (`uploads/`), util en desarrollo.
"""

import base64
import logging
import os
import urllib.request
from typing import Optional


logger = logging.getLogger(__name__)

_EXT_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".heic": "image/heic",
}

_configurada = False
_config_ok = False


def disponible() -> bool:
    """True si hay credenciales de Cloudinary en el entorno."""
    return bool(os.getenv("CLOUDINARY_CLOUD_NAME")
                and os.getenv("CLOUDINARY_API_KEY")
                and os.getenv("CLOUDINARY_API_SECRET"))


def _configurar():
    global _configurada, _config_ok
    if _configurada:
        return _config_ok
    _configurada = True
    if not disponible():
        return False
    try:
        import cloudinary
        cloudinary.config(
            cloud_name=os.getenv("CLOUDINARY_CLOUD_NAME"),
            api_key=os.getenv("CLOUDINARY_API_KEY"),
            api_secret=os.getenv("CLOUDINARY_API_SECRET"),
            secure=True,
        )
        _config_ok = True
    except Exception:
        logger.exception("No se pudo configurar el SDK de Cloudinary")
    return _config_ok


def subir(data: bytes, mime: str, carpeta: str, public_id: str) -> Optional[dict]:
    """Sube bytes de una imagen y devuelve `{"url", "public_id"}`.

    Devuelve None si la nube no esta configurada. Si la subida falla se
    registra el error y se devuelve None para que el llamador use su respaldo
    de disco: una foto nunca debe perderse por un fallo externo.
    """
    if not _configurar():
        return None
    try:
        from cloudinary import uploader
        data_uri = "data:%s;base64,%s" % (mime, base64.b64encode(data).decode())
        res = uploader.upload(
            data_uri,
            public_id="%s/%s" % (carpeta, public_id),
            resource_type="image",
            overwrite=True,
            invalidate=True,
        )
        url = res.get("secure_url") or res.get("url")
        if not url:
            raise ValueError("Cloudinary no devolvio secure_url")
        return {"url": url, "public_id": res.get("public_id")}
    except Exception:
        logger.exception("Fallo la subida a Cloudinary (%s/%s)", carpeta, public_id)
        return None


def borrar(public_id: Optional[str]) -> None:
    """Elimina una imagen de la nube (best-effort, no rompe nada si falla)."""
    if not public_id or not _configurar():
        return
    try:
        from cloudinary import uploader
        uploader.destroy(public_id, resource_type="image")
    except Exception:
        logger.exception("No se pudo borrar %s de Cloudinary", public_id)


def descargar(url: str):
    """Descarga los bytes de una imagen ya subida -> (data, content_type)."""
    req = urllib.request.Request(url, headers={"User-Agent": "rapitaxi-api"})
    with urllib.request.urlopen(req, timeout=25) as r:
        data = r.read()
        tipo = (r.headers.get("Content-Type") or "image/jpeg").split(";")[0]
    return data, tipo
