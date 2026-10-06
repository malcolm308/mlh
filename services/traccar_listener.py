import asyncio
import os
import websockets
import json
import logging
from db.Chofer.connection import chofer_db  # Asegurate de tener esta coleccion exportada
from routers.cache import update_driver_location, set_driver_status, get_driver_status

logger = logging.getLogger(__name__)

"""
Listener de Traccar: convierte posiciones GPS en estado del conductor.

Schema del campo `traccar_device_id` (coleccion Mongo `Chofer.users`):

- Que significa: el ID numerico del dispositivo dentro del servidor Traccar
  (NO el `uniqueId` ni el `id` de Mongo). Ej: el device 1 de Traccar es el que
  aparece como "Taxi Test" con uniqueId "taxi-001".
- Como se asigna: cada chofer tiene su propio device. Se escribe a mano una
  sola vez, con el shell de Mongo:

      db.getSiblingDB("Chofer").users.updateOne(
          { _id: ObjectId("<id del chofer>") },
          { $set: { traccar_device_id: 1 } }
      )

  Si ademas se quiere que el backend empuje posiciones del chofer hacia
  Traccar durante el viaje (protocolo OsmAnd, puerto 5055), hace falta tambien
  el `uniqueId` del dispositivo:

      $set: { traccar_device_id: 1, traccar_device_uid: "taxi-001" }

  Un mismo device no debe asignarse a dos choferes: el listener toma el
  primero que encuentre con find_one.
- Si no esta asignado: el listener recibe las posiciones del device, no
  encuentra ningun chofer y las descarta (log "Device X sin chofer asignado").
  El chofer sigue funcionando, simplemente no aparece en elMatching por
  geolocalizacion ni tiene trazado de ruta.
- Relacion con el router: `_get_traccar_route` e
  `_forward_driver_position_to_traccar` en routers/Solicitud_de_viajes_v4.py
  leen los mismos campos del mismo documento.
"""


def procesar_posicion(pos: dict) -> str | None:
    """Procesa una posicion de Traccar y devuelve el driver_id afectado.

    Devuelve None si el device no tiene chofer asignado. No lanza excepcion
    por datos ausentes: una posicion incompleta se ignora.
    """
    device_id = pos.get("deviceId")
    lon = pos.get("longitude")
    lat = pos.get("latitude")
    if device_id is None or lon is None or lat is None:
        logger.warning("Posicion de Traccar incompleta, ignorando: %s", pos)
        return None

    driver = chofer_db["users"].find_one({"traccar_device_id": device_id})
    if not driver:
        logger.info("Device %s sin chofer asignado, ignorando evento", device_id)
        return None

    driver_id = str(driver["_id"])
    update_driver_location(driver_id, lon, lat)
    # Si no esta en un viaje, lo marcamos disponible
    status = get_driver_status(driver_id)
    if status != "on_trip":
        set_driver_status(driver_id, "available")
    return driver_id


async def listen_traccar():
    traccar_token = os.getenv("TRACCAR_TOKEN")
    traccar_ws = os.getenv("TRACCAR_WS", "ws://localhost:8082/api/socket")
    if not traccar_token:
        logger.error(
            "TRACCAR_TOKEN no esta definido: el listener no puede conectarse. "
            "Definir la variable de entorno con el token de Traccar."
        )
        return
    uri = f"{traccar_ws}?token={traccar_token}"
    while True:
        try:
            async with websockets.connect(uri) as ws:
                print("Conectado a Traccar WebSocket")
                async for msg in ws:
                    data = json.loads(msg)
                    positions = data.get("positions", [])
                    for pos in positions:
                        try:
                            procesar_posicion(pos)
                        except Exception:
                            logger.exception("Error procesando posicion del device %s",
                                             pos.get("deviceId"))
        except Exception as e:
            print(f"Error en listener Traccar: {e}. Reintentando en 5 segundos...")
            await asyncio.sleep(5)
