"""
Tiempo real: WebSocket unico para choferes y pasajeros (`/ws/{rol}/{id}`).

Hoy la app del chofer sondea ofertas cada 4 s y el pasajero sondea su viaje
cada 3 s: en redes cubanas eso es un ping constante y las ofertas/posiciones
llegan tarde. Este canal empuja los eventos que YA se publican en el
pub/sub de Garnet:

  * `driver:{id}:offers`      -> oferta para un chofer (despacho natural)
  * `trip:{trip_id}:events`   -> ciclo del viaje y POSICION del chofer
  * `ws:{rol}:{id}`           -> canal propio (reservado)

Contrato:
  * El cliente se conecta a `/ws/{rol}/{id}?token=JWT`.
  * Chofer: manda `{"posicion": {"lat":..., "lng":..., "bearing":...}}`;
    el servidor actualiza el mismo estado que el endpoint HTTP y la
    retransmite al canal `trip:{trip_id}:events` del viaje activo.
  * Cliente: manda `{"suscribir_viaje": "trip_id"}` y recibe los eventos del
    viaje, incluidas las posiciones del chofer (lat, lng, bearing).
  * `{"ping": true}` responde `{"pong": true}`.

El HTTP queda como RESPALDO: si el WS cae, los sondeos existentes siguen
trabajando sin cambios.
"""
import asyncio
import json
import logging
from typing import Optional

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
import redis.asyncio as aioredis

from db.Cliente.auth import verify_token as verify_token_cliente
from db.Cliente.connection import cliente_db
from db.Chofer.auth import verify_token as verify_token_chofer
from db.Chofer.connection import chofer_db
from routers.Solicitud_de_viajes_v4 import (
    garnet,
    get_connection,
    update_driver_location,
    publish_trip_event,
)

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Tiempo real"])


def _viaje_activo_de(driver_id: str) -> Optional[str]:
    """trip del viaje activo del chofer (accepted/arrived/in_progress)."""
    try:
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT trip_id FROM trips WHERE driver_id = %s AND status IN "
                "('accepted','driver_arrived','in_progress') "
                "ORDER BY requested_at DESC LIMIT 1",
                (driver_id,),
            )
            fila = cur.fetchone()
            cur.close()
        return fila[0] if fila else None
    except Exception:
        logger.exception("No se pudo leer el viaje activo de %s", driver_id)
        return None


async def _posicion_chofer(driver_id: str, datos: dict) -> None:
    """Update de posicion por WS: misma logica que el endpoint HTTP."""
    lat = datos.get("lat")
    lng = datos.get("lng")
    bearing = datos.get("bearing")
    if not isinstance(lat, (int, float)) or not isinstance(lng, (int, float)):
        return
    try:
        await update_driver_location(driver_id, float(lng), float(lat))
        if isinstance(bearing, (int, float)):
            await garnet.set(
                f"driver:bearing:{driver_id}",
                str(round(float(bearing) % 360, 1)),
                ex=120,
            )
    except Exception:
        logger.exception("No se pudo registrar la posicion de %s", driver_id)
        return
    trip_id = await asyncio.to_thread(_viaje_activo_de, driver_id)
    if trip_id:
        await publish_trip_event(trip_id, "driver_position", {
            "trip_id": trip_id,
            "driver_id": driver_id,
            "lat": float(lat),
            "lng": float(lng),
            "bearing": (float(bearing) if isinstance(bearing, (int, float)) else None),
        })


@router.websocket("/ws/{rol}/{user_id}")
async def ws_tiempo_real(
    ws: WebSocket,
    rol: str,
    user_id: str,
    token: str = Query(""),
):
    if rol not in ("cliente", "chofer"):
        await ws.close(code=1008)
        return

    payload = None
    if rol == "cliente":
        payload = verify_token_cliente(token)
    else:
        payload = verify_token_chofer(token)
    if not payload:
        await ws.close(code=1008)
        return

    # El id conectado debe coincidir con el token (sub = email).
    coleccion = cliente_db["users"] if rol == "cliente" else chofer_db["users"]
    user = coleccion.find_one({"_id": __import__("bson").ObjectId(user_id)})
    if not user or (user.get("email") or "").lower() != (payload.get("sub") or "").lower():
        await ws.close(code=1008)
        return

    await ws.accept()

    canal_propio = f"ws:{rol}:{user_id}"
    canales = {canal_propio}
    if rol == "chofer":
        canales.add(f"driver:{user_id}:offers")

    pubsub = aioredis.client.PubSub(
        connection_pool=garnet.connection_pool,
        # decode_responses viene heredado del cliente base.
    )
    try:
        await pubsub.subscribe(*canales)

        async def bombeo() -> None:
            async for msg in pubsub.listen():
                if msg.get("type") != "message":
                    continue
                canal = msg.get("channel") or ""
                resto = msg.get("data")
                try:
                    datos = json.loads(resto) if isinstance(resto, str) else None
                except (TypeError, ValueError):
                    datos = None
                await ws.send_text(json.dumps({
                    "canal": canal,
                    "datos": datos or {"raw": resto},
                }, ensure_ascii=False, default=str))

        async def receptor() -> None:
            """Mensajes del cliente: suscripcion al viaje / posiciones."""
            while True:
                crudo = await ws.receive_text()
                try:
                    datos = json.loads(crudo)
                except ValueError:
                    continue
                if not isinstance(datos, dict):
                    continue
                if datos.get("ping"):
                    await ws.send_text(json.dumps({"pong": True}))
                    continue
                if rol == "cliente":
                    viaje = datos.get("suscribir_viaje")
                    if viaje:
                        await pubsub.subscribe(f"trip:{viaje}:events")
                        await ws.send_text(json.dumps(
                            {"suscripcion": viaje}))
                elif rol == "chofer" and isinstance(datos.get("posicion"), dict):
                    await _posicion_chofer(user_id, datos["posicion"])

        bombeo_task = asyncio.create_task(bombeo())
        receptor_task = asyncio.create_task(receptor())
        done, _ = await asyncio.wait(
            {bombeo_task, receptor_task},
            return_when=asyncio.FIRST_EXCEPTION,
        )
        for t in done:
            exc = t.exception()
            if exc is not None and not isinstance(exc, WebSocketDisconnect):
                logger.exception("ws %s/%s fallo: %s", rol, user_id, exc)
    except Exception as e:
        if not isinstance(e, (WebSocketDisconnect, asyncio.CancelledError,
                              RuntimeError)):
            logger.exception("ws %s/%s fallo: %s", rol, user_id, e)
    finally:
        await pubsub.close()
        try:
            await ws.close()
        except Exception:
            pass
        logger.info("ws %s/%s cerrado", rol, user_id)
