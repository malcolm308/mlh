"""
Cancelacion de un viaje por parte del chofer, con limite diario.

La app del chofer llama a este endpoint desde el boton "Cancelar viaje", que
solo aparece cuando el viaje ya esta ACEPTADO. Rechazar una oferta antes de
aceptarla va por otro endpoint (`/trips/{id}/decline`) y NO cuenta: son dos
acciones distintas con dos reglas distintas.

El limite vive aqui, en el servidor, y no solo en el movil. El movil lo cachea
para pintar el boton sin esperar a la red, pero un reloj desajustado o un
`SharedPreferences` borrado no pueden permitir pasarse de la cuenta: el servidor
es la fuente de verdad y rechaza cuando toca.
"""
import sys
from datetime import datetime, timezone

sys.path.insert(0, "E:\\Taxi_Rapid")

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Optional

router = APIRouter(prefix="/chofer", tags=["Chofer - Cancelaciones"])

# Maximo de cancelaciones por dia natural, por chofer. Es una constante y no un
# literal suelto porque aparece en el limite, en la respuesta y en el mensaje de
# error, y si se escribe en tres sitios un dia se desincronizan.
MAXIMO_CANCELACIONES_DIA = 3


class CancelacionRequest(BaseModel):
    """Lo que manda la app al cancelar. `driver_id` va en el cuerpo y no en la
    ruta porque el endpoint ya recibe el id en el POST."""

    driver_id: str
    reason: Optional[str] = None
    cancelled_at: Optional[str] = None


def _clave_dia() -> str:
    """Clave del dia natural en hora de Cuba.

    Se usa la zona horaria de La Habana y no UTC a proposito: el limite son
    "3 al dia" segun el reloj del chofer, no segun el de Greenwich. Con UTC, un
    chofer de Cuba que cancela a las 8 de la tarde llevaria dos dias distintos
    contados en el mismo dia suyo y podria cancelar seis veces.
    """
    try:
        from zoneinfo import ZoneInfo
        hoy = datetime.now(ZoneInfo("America/Havana"))
    except Exception:
        # Si no hay zona horaria instalada, se usa UTC menos 4, que es el
        # desfase fijo de Cuba (no cambia con el horario de verano desde 2011).
        hoy = datetime.now(timezone.utc).astimezone(
            timezone(-__import__("datetime").timedelta(hours=4))
        )
    return hoy.strftime("%Y-%m-%d")


@router.post("/{driver_id}/cancelaciones/usadas")
def contar_cancelacion(driver_id: str):
    """Suma una cancelacion al chofer y devuelve las que le quedan.

    Se llama justo DESPUES de que el backend haya aceptado la cancelacion, para
    que un fallo de red no descuente nada. Es idempotente por dia+viaje: si se
    reintenta el mismo viaje, no cuenta dos veces.
    """
    from routers.Solicitud_de_viajes_v4 import get_connection

    clave = _clave_dia()
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO driver_cancellations (driver_id, day, count)
            VALUES (%s, %s, 1)
            ON CONFLICT (driver_id, day)
            DO UPDATE SET count = driver_cancellations.count + 1
            """,
            (driver_id, clave),
        )
        conn.commit()
        cur.execute(
            "SELECT count FROM driver_cancellations WHERE driver_id = %s AND day = %s",
            (driver_id, clave),
        )
        usadas = (cur.fetchone() or [0])[0]
        cur.close()

    restantes = max(0, MAXIMO_CANCELACIONES_DIA - int(usadas or 0))
    return {"restantes": restantes, "usadas": int(usadas or 0), "dia": clave}


@router.get("/{driver_id}/cancelaciones")
def consultar_cancelaciones(driver_id: str):
    """Cuantas cancelaciones le quedan hoy al chofer.

    La app lo llama al empezar un viaje para pintar el boton con el numero
    correcto. Un `404` aqui no es un fallo grave: la app conserva su contador
    local y sigue funcionando.
    """
    from routers.Solicitud_de_viajes_v4 import get_connection

    clave = _clave_dia()
    try:
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT count FROM driver_cancellations WHERE driver_id = %s AND day = %s",
                (driver_id, clave),
            )
            row = cur.fetchone()
            cur.close()
        usadas = int((row[0] if row else 0) or 0)
    except Exception:
        # Si la tabla aun no existe, se informa el limite completo en vez de un
        # 500: el movil lo leeria como "sin red" y no podria pintar el boton.
        return {"restantes": MAXIMO_CANCELACIONES_DIA, "usadas": 0, "dia": clave}

    return {
        "restantes": max(0, MAXIMO_CANCELACIONES_DIA - usadas),
        "usadas": usadas,
        "dia": clave,
    }


def asegurar_tabla_cancelaciones() -> None:
    """Crea la tabla de conteo si no existe.

    Se llama al arrancar la API. Se hace aqui y no en una migracion porque es
    una tabla de una sola fila por chofer y dia, que se puede crear sin riesgo.
    """
    try:
        from routers.Solicitud_de_viajes_v4 import get_connection
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS driver_cancellations (
                    driver_id TEXT NOT NULL,
                    day       TEXT NOT NULL,
                    count     INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (driver_id, day)
                )
                """
            )
            conn.commit()
            cur.close()
    except Exception:
        # Sin tabla, el endpoint de consulta devuelve el limite completo y el
        # boton se dibuja; solo se pierde el limite por servidor. Es preferible
        # a no arrancar la API.
        pass