"""Eventos del outbox, tipados y versionados.

El `event_type` determina qué modelo valida el payload. Si mañana cambia la
forma de un evento, se añade `XxxV2` y se sube `schema_version`: el worker
puede seguir entendiendo los eventos viejos que queden en la cola.

Regla de oro: **el worker no calcula dinero**. Los importes llegan ya
repartidos desde el router, que los calcula dentro de la transacción de
PostgreSQL antes del COMMIT. El worker solo los aplica a MongoDB.
"""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field
from psycopg2.extensions import connection as PgConnection


class EventoBase(BaseModel):
    schema_version: int = 1


class TripEventV1(EventoBase):
    """`trip.created` y `trip.cancelled`."""
    trip_id: str
    client_id: str
    driver_id: Optional[str] = None
    status: str
    monto_cents: int = 0
    payment_method: Optional[str] = None


class TripCompletedV2(EventoBase):
    """Cierre de un viaje con el reparto exacto del dinero.

    Todos los importes van en centavos y con signo positivo (son magnitudes).
    `chofer_neto_cents` es lo único que el worker suma al `Fondo` del chofer:

        chofer_neto_cents = chofer_credito_cents - comision_cents

    `mongo_aplicado=True` significa que el bloque legacy ya movió el dinero en
    MongoDB de forma síncrona; el worker solo registra el evento como
    procesado para no acreditarlo dos veces.
    """
    schema_version: int = 2
    trip_id: str
    client_id: str
    driver_id: Optional[str] = None
    status: str = "completed"
    payment_method: Optional[str] = None

    # Precio final del viaje.
    total_cents: int = 0

    # Reparto del cliente (lo que salió de su billetera).
    cliente_promo_cents: int = 0
    cliente_saldo_cents: int = 0
    cliente_billetera_cents: int = 0

    # Lo que se cobra por fuera de la billetera (efectivo/transferencia).
    excedente_cents: int = 0
    efectivo_cents: int = 0
    metodo_excedente: Optional[str] = None

    # Reparto del chofer y de la plataforma.
    chofer_credito_cents: int = 0
    chofer_bono_cents: int = 0
    comision_cents: int = 0
    chofer_neto_cents: int = 0

    # El bloque legacy ya aplicó este movimiento en Mongo.
    mongo_aplicado: bool = False


class DriverPayoutV1(EventoBase):
    """Liquidación pagada al chofer.

    `monto_cents` es la magnitud que sale del `Fondo` del chofer. El worker
    hace `$inc {"Fondo": -monto}`. `mongo_aplicado=True` si el camino legacy
    ya lo descontó.
    """
    schema_version: int = 1
    payout_id: str
    driver_id: str
    monto_cents: int = Field(..., ge=0)
    mongo_aplicado: bool = False
    descripcion: Optional[str] = None


class TripStatusEventV1(EventoBase):
    """Cambios de estado que no mueven dinero (aceptado, en curso...)."""
    trip_id: str
    client_id: Optional[str] = None
    driver_id: Optional[str] = None
    status: str


class WalletChangedV1(EventoBase):
    """Un movimiento del ledger que Mongo debe reflejar en el perfil."""
    user_id: str
    user_type: Literal["client", "driver"]
    tipo: str
    monto_cents: int
    saldo_cents: int


MODELOS = {
    "trip.created": TripEventV1,
    "trip.completed": TripCompletedV2,
    "trip.cancelled": TripEventV1,
    "trip.status_changed": TripStatusEventV1,
    "wallet.changed": WalletChangedV1,
    "driver.payout": DriverPayoutV1,
}


def encolar(
    conn: PgConnection,
    *,
    event_type: str,
    aggregate_type: str,
    aggregate_id: str,
    payload: BaseModel,
    cur=None,
) -> str:
    """Inserta el evento en la cola. Debe correr en la misma transacción.

    Valida el tipo contra `MODELOS` para que un evento mal formado no llegue
    nunca a la cola.
    """
    modelo = MODELOS.get(event_type)
    if modelo is None:
        raise ValueError(f"event_type desconocido: {event_type!r}")
    if not isinstance(payload, modelo):
        raise TypeError(
            f"{event_type} espera {modelo.__name__}, "
            f"llegó {type(payload).__name__}")

    cursor = cur or conn.cursor()
    propio = cur is None
    try:
        cursor.execute(
            """
            INSERT INTO outbox
                (event_type, aggregate_type, aggregate_id, payload,
                 schema_version)
            VALUES (%s, %s, %s, %s::jsonb, %s)
            RETURNING id::text
            """,
            (event_type, aggregate_type, aggregate_id,
             payload.model_dump_json(), payload.schema_version),
        )
        return cursor.fetchone()[0]
    finally:
        if propio:
            cursor.close()


def evento_trip(event_type: str, *, trip_id: str, client_id: str,
                driver_id: Optional[str], status: str,
                monto_cents: int = 0,
                payment_method: Optional[str] = None) -> TripEventV1:
    return TripEventV1(
        trip_id=trip_id, client_id=client_id, driver_id=driver_id,
        status=status, monto_cents=int(monto_cents),
        payment_method=payment_method)
