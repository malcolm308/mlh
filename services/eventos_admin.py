"""Buzon de eventos criticos para las alertas del panel web.

El backend no puede abrir una conexion con el navegador del administrador y el
panel Streamlit no expone endpoints propios, asi que los eventos se guardan
aqui y el vigilante JavaScript del panel los recoge por polling
(`GET /admin/eventos`).

Se guardan en Mongo (base `Chofer`, coleccion `eventos_admin`) por dos motivos:

* sobreviven a un reinicio de Render y a un redespliegue del panel;
* si el panel y la API corren en instancias distintas, no dependen de memoria
  compartida.

Si Mongo no responde, se cae a una cola en memoria para que el panel siga
avisando mientras el proceso viva; el fallo queda en el log. Las operaciones
contra Mongo usan un cliente propio con `serverSelectionTimeoutMS` corto: un
Mongo caido no puede dejar clavado el cron de huerfanos ni el registro de un
chofer.

Los eventos caducan solos a los 7 dias (indice TTL) y el panel nunca ve mas de
50 por consulta.
"""

from __future__ import annotations

import logging
import os
import threading
from collections import deque
from datetime import datetime, timezone
from typing import Any, Optional

from bson import ObjectId
from bson.errors import InvalidId
from pymongo import MongoClient

from db.Chofer.connection import chofer_db

logger = logging.getLogger(__name__)

COLECCION = "eventos_admin"
TTL_DIAS = 7
LIMITE_MAXIMO = 50
_MAX_MEMORIA = 200

# Cliente aparte: si Mongo esta caido, `insert_one` falla en ~1,5 s en vez de
# quedarse 30 s (el timeout por defecto) bloqueando el cron o el registro.
_URI = os.getenv("MONGODB_URI", "mongodb://localhost:27017")
_cliente = MongoClient(_URI, serverSelectionTimeoutMS=1500, connect=False)
coleccion = _cliente[chofer_db.name][COLECCION]

_memoria: deque[dict] = deque(maxlen=_MAX_MEMORIA)
_lock = threading.Lock()
_indice_listo = False


def _ahora() -> datetime:
    return datetime.now(timezone.utc)


def _crear_indice() -> None:
    """Indice TTL: los avisos viejos se borran sin intervencion."""
    global _indice_listo
    if _indice_listo or coleccion is None:
        return
    try:
        coleccion.create_index(
            "creado",
            expireAfterSeconds=TTL_DIAS * 86400,
            name="ttl_eventos_admin",
        )
        _indice_listo = True
    except Exception:  # noqa: BLE001 - el aviso es best-effort
        logger.warning("No se pudo crear el indice TTL de eventos_admin",
                       exc_info=True)


def _object_id(valor: Optional[str]) -> Optional[ObjectId]:
    texto = (valor or "").strip()
    if not texto:
        return None
    try:
        return ObjectId(texto)
    except (InvalidId, TypeError):
        return None


def _serializar(doc: dict) -> dict:
    creado = doc.get("creado")
    if isinstance(creado, datetime):
        if creado.tzinfo is None:
            creado = creado.replace(tzinfo=timezone.utc)
        creado_iso = creado.isoformat()
        creado_ms = int(creado.timestamp() * 1000)
    else:
        creado_iso = str(creado or "")
        creado_ms = 0
    return {
        "id": str(doc.get("_id") or ""),
        "tipo": doc.get("tipo") or "",
        "titulo": doc.get("titulo") or "",
        "mensaje": doc.get("mensaje") or "",
        "datos": doc.get("datos") or {},
        "creado": creado_iso,
        "ts": creado_ms,
    }


def _coincide(doc: dict, rol: str) -> bool:
    if not rol or rol == "super_admin":
        return True
    return rol in (doc.get("roles") or [])


def _mas_nuevo(rol: str) -> Optional[dict]:
    filtro: dict[str, Any] = {}
    if rol and rol != "super_admin":
        filtro["roles"] = rol
    try:
        if coleccion is not None:
            cursor = coleccion.find(filtro).sort("_id", -1).limit(1)
            docs = list(cursor)
            if docs:
                return docs[0]
    except Exception:  # noqa: BLE001
        logger.warning("No se pudo leer el ultimo evento de Mongo",
                       exc_info=True)
    with _lock:
        for doc in reversed(_memoria):
            if _coincide(doc, rol):
                return doc
    return None


def publicar(
    tipo: str,
    titulo: str,
    mensaje: str,
    *,
    datos: Optional[dict] = None,
    roles: Optional[list[str]] = None,
) -> Optional[dict]:
    """Publica un evento para el panel. Nunca lanza: es best-effort.

    `roles` limita quien lo ve: `super_admin` ve todo; el resto solo los
    eventos donde aparezca su rol (trip_operator para viajes, user_operator
    para registros de chofer).
    """
    doc = {
        "tipo": str(tipo or "")[:40],
        "titulo": str(titulo or "")[:120],
        "mensaje": str(mensaje or "")[:400],
        "datos": datos if isinstance(datos, dict) else {},
        "roles": [str(r) for r in (roles or [])],
        "creado": _ahora(),
    }

    if coleccion is not None:
        _crear_indice()
        try:
            resultado = coleccion.insert_one(doc)
            doc["_id"] = resultado.inserted_id
            with _lock:
                _memoria.append(doc)
            logger.info("Evento admin publicado: %s (%s)", tipo, doc["_id"])
            return _serializar(doc)
        except Exception:  # noqa: BLE001
            logger.warning("No se pudo guardar el evento %r en Mongo",
                           tipo, exc_info=True)

    doc["_id"] = ObjectId()
    with _lock:
        _memoria.append(doc)
    return _serializar(doc)


def listar(
    desde: str = "",
    *,
    rol: str = "",
    limite: int = 20,
) -> dict:
    """Devuelve los eventos posteriores a `desde` y el puntero para el siguiente.

    Sin `desde` no devuelve eventos: solo el identificador mas reciente. Asi un
    F5 o una apertura nueva del panel no dispara avisos de eventos viejos.
    """
    try:
        limite = int(limite)
    except (TypeError, ValueError):
        limite = 20
    limite = max(1, min(limite, LIMITE_MAXIMO))
    rol = (rol or "").strip()

    desde_oid = _object_id(desde)
    if desde_oid is None:
        ultimo = _mas_nuevo(rol)
        return {
            "eventos": [],
            "ultimo": _serializar(ultimo)["id"] if ultimo else None,
            "ttl_dias": TTL_DIAS,
        }

    filtro: dict[str, Any] = {"_id": {"$gt": desde_oid}}
    if rol and rol != "super_admin":
        filtro["roles"] = rol

    docs: list[dict] = []
    if coleccion is not None:
        try:
            cursor = coleccion.find(filtro).sort("_id", 1).limit(limite)
            docs = list(cursor)
        except Exception:  # noqa: BLE001
            logger.warning("No se pudieron leer los eventos de Mongo",
                           exc_info=True)
    if not docs:
        with _lock:
            docs = [
                d for d in _memoria
                if _coincide(d, rol) and d["_id"] > desde_oid
            ][:limite]

    eventos = [_serializar(d) for d in docs]
    ultimo = eventos[-1]["id"] if eventos else str(desde_oid)
    return {"eventos": eventos, "ultimo": ultimo, "ttl_dias": TTL_DIAS}
