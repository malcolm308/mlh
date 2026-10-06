import redis
from typing import List, Tuple, Optional
import json

# Conexion a Garnet (localhost:6379 por defecto)
garnet_client = redis.Redis(host='localhost', port=6379, decode_responses=True)

# --- 1. UBICACIONES DE CONDUCTORES ----------------------

def update_driver_location(driver_id: str, longitude: float, latitude: float):
    """
    Actualiza (o anade) la posicion de un conductor en el indice geoespacial.
    Se llama desde el listener de Traccar cada vez que llega una nueva coordenada.
    """
    garnet_client.geoadd("driver:locations", (longitude, latitude, driver_id))


def get_nearby_drivers(
    longitude: float, latitude: float, radius_km: float = 3.0, count: Optional[int] = None
) -> List[Tuple[str, float]]:
    """
    Devuelve lista de (driver_id, distancia_km) de los conductores dentro del radio.
    Opcionalmente se puede limitar la cantidad con 'count'.
    Se usa para el matching cuando un pasajero pide un taxi.
    """
    results = garnet_client.georadius(
        "driver:locations",
        longitude,
        latitude,
        radius_km,
        unit="km",
        withdist=True,
        sort="ASC",
        count=count,
    )
    # results es una lista de [b'id', b'distancia'] y las decodificamos
    return [(item[0], item[1]) for item in results]


def remove_driver_location(driver_id: str):
    """Elimina la ubicacion de un conductor (cuando se desconecta o finaliza turno)."""
    garnet_client.zrem("driver:locations", driver_id)


# --- 2. ESTADO DEL CONDUCTOR ----------------------------

def set_driver_status(driver_id: str, status: str):
    """
    Establece el estado actual del conductor.
    Valores tipicos: 'available', 'on_trip', 'offline', 'busy'.
    """
    garnet_client.set(f"driver:status:{driver_id}", status)


def get_driver_status(driver_id: str) -> Optional[str]:
    """Devuelve el estado del conductor o None si no existe."""
    return garnet_client.get(f"driver:status:{driver_id}")


# --- 3. PUBLICACION / SUSCRIPCION (Pub/Sub) ------------

def publish_event(channel: str, message: dict):
    """
    Publica un evento en un canal.
    Util para notificar a otros servicios o al WebSocket del backend.
    """
    garnet_client.publish(channel, json.dumps(message))


def subscribe_channel(channel: str):
    """
    Devuelve un objeto PubSub suscrito al canal.
    Se usa en tareas asincronas (por ejemplo, el listener de Traccar o el WebSocket).
    """
    pubsub = garnet_client.pubsub()
    pubsub.subscribe(channel)
    return pubsub


# --- 4. SESIONES (opcional, para guardar tokens JWT) ----

def set_session(user_id: str, token: str, ttl_seconds: int = 3600):
    """Guarda un token de sesion con expiracion (TTL)."""
    garnet_client.setex(f"session:{user_id}", ttl_seconds, token)


def get_session(user_id: str) -> Optional[str]:
    """Obtiene el token de sesion si existe y no ha expirado."""
    return garnet_client.get(f"session:{user_id}")


def delete_session(user_id: str):
    """Elimina la sesion (logout)."""
    garnet_client.delete(f"session:{user_id}")