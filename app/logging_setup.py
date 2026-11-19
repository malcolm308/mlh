"""Hacer visibles los logs INFO de la app bajo uvicorn en Render.

Uvicorn configura handlers de logging **solo** para sus propios loggers
(``uvicorn``, ``uvicorn.error``, ``uvicorn.access``). Los loggers de nuestros
modulos (``main_v2``, ``routers.*``) se propagan al logger raiz, que no tiene
ningun handler: Python usa ``logging.lastResort`` y solo muestra WARNING o mas.
Por eso en Render aparecia ``WS rechazado ...`` (warning) pero no
``=== INICIANDO APLICACIÓN ===`` ni ``Outbox heartbeat`` (info), y parecia que
el loop del outbox estaba mudo.

Llamar una sola vez al arrancar, antes de crear los loggers del modulo.
"""
from __future__ import annotations

import logging
import os
import sys

_MARCA = "_taxi_rapid_handler"
# Librerias muy charladoras en INFO: con el root a INFO inundarian los logs.
_RUIDO = ("pymongo", "httpx", "httpcore", "urllib3", "asyncio", "apscheduler")


def configurar_logging() -> None:
    """Deja un unico handler propio en el root, a nivel INFO por defecto."""
    nivel = os.getenv("LOG_LEVEL", "INFO").strip().upper()
    if nivel not in ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"):
        nivel = "INFO"

    raiz = logging.getLogger()
    raiz.setLevel(nivel)
    for handler in raiz.handlers:
        if getattr(handler, _MARCA, False):
            handler.setLevel(nivel)
            break
    else:
        handler = logging.StreamHandler(sys.stdout)
        handler.setLevel(nivel)
        handler.setFormatter(logging.Formatter(
            "%(asctime)s %(levelname)s %(name)s %(message)s"))
        setattr(handler, _MARCA, True)
        raiz.addHandler(handler)

    for nombre in _RUIDO:
        logging.getLogger(nombre).setLevel(logging.WARNING)
