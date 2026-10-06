"""Cliente WebSocket de Traccar.

Traccar autentica su WebSocket por query string (``?token=...``), **no** por
cabecera ``Authorization``: mandar la cabecera no autentica nada. Los tokens
caducan, y cuando lo hacen el handshake devuelve ``HTTP 401``/``HTTP 500``;
pide uno nuevo en la interfaz web de Traccar.

Este modulo es un cliente reutilizable de bajo nivel. El servicio que se
suscribe de forma continua y vuelca las posiciones en la cache de choferes es
``services/traccar_listener.py``.
"""

import json
import os
from typing import AsyncIterator, Optional

import websockets

TRACCAR_WS_URL = os.environ.get("TRACCAR_WS_URL", "ws://localhost:8082/api/socket")


async def conectar_traccar_token(token: Optional[str] = None) -> AsyncIterator[dict]:
    """Conecta al WebSocket de Traccar y va entregando los mensajes.

    Traccar empuja las posiciones solo, sin comando de suscripcion, asi que no
    hay que enviar nada: basta con leer. Cada elemento-yield es el mensaje
    completo, con su clave ``positions``.

    El token se pasa como parametro a proposito, para no tener un segundo
    token hardcodeado que se quede caducado sin que nadie se entere.
    """
    if not token:
        raise ValueError("hace falta un token de Traccar: generar uno en la UI de Traccar")

    async with websockets.connect(f"{TRACCAR_WS_URL}?token={token}") as ws:
        async for raw in ws:
            yield json.loads(raw)