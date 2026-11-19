"""Compatibilidad HTTP con APKs de chofer todavía no actualizadas.

Algunas instalaciones en producción siguen construyendo la consulta de ofertas
como ``lat=$lat`` + ``lng=$lng`` + ``radius_km=5`` (sin los ``&``). FastAPI ve
un único ``lat`` con texto y responde 422, así que el chofer se queda sin
ofertas aunque el backend esté sano.

El fix real ya está en Flutter (``Uri(queryParameters:)``). Este módulo es un
parche de contención en el servidor: reinserta los separadores **solo** cuando
detecta esa concatenación exacta. Una query bien formada no se toca, y el log
cuenta las reparaciones para saber cuándo ya no queda nadie con la APK vieja.
"""
from __future__ import annotations

import logging
import re

from starlette.requests import Request

logger = logging.getLogger(__name__)

_NUMERO = rb"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"
_QUERY_PEGADA = re.compile(
    rb"(^|&)(lat=" + _NUMERO + rb")(lng=" + _NUMERO + rb")(radius_km=" + _NUMERO + rb")"
)

_reparaciones = 0


def reparar_query_legacy(query_string: bytes) -> bytes:
    """Devuelve la query con los ``&`` que la APK antigua se comió.

    Solo actúa sobre la secuencia ``lat=<num>lng=<num>radius_km=<num>``. El
    resto de parámetros (``limit``, ``driver_id``, ``vehicle_type``) se dejan
    intactos, y una query correcta devuelve exactamente los mismos bytes.
    """
    if not query_string or b"lng=" not in query_string or b"radius_km=" not in query_string:
        return query_string
    return _QUERY_PEGADA.sub(rb"\1\2&\3&\4", query_string)


async def compat_query_middleware(request: Request, call_next):
    """Middleware Starlette que repara la query antes de la validación."""
    global _reparaciones
    crudo = request.scope.get("query_string", b"")
    reparado = reparar_query_legacy(crudo)
    if reparado != crudo:
        # Modificamos el scope ANTES de call_next: FastAPI construye su propio
        # Request a partir de este mismo scope y valida los query params de ahí.
        request.scope["query_string"] = reparado
        _reparaciones += 1
        if _reparaciones == 1 or _reparaciones % 100 == 0:
            logger.warning(
                "Query legacy reparada x%s en %s (APK chofer desactualizada)",
                _reparaciones,
                request.scope.get("path", "?"),
            )
    return await call_next(request)
