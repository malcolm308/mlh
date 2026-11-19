"""Acceso al libro mayor (`wallet_ledger`).

Este módulo es el único sitio autorizado a escribir asientos. No conoce
MongoDB ni FastAPI: recibe una conexión psycopg2 ya abierta y trabaja dentro
de la transacción de quien lo llama.

Invariante: un asiento se inserta **una sola vez** por `idempotency_key`.
El `ON CONFLICT DO NOTHING` no es un detalle: es lo que garantiza que
reintentar un cobro no cobre dos veces.
"""
from __future__ import annotations

import json
from typing import Any, Optional

from psycopg2.extensions import connection as PgConnection

from app.money import a_cents

TIPOS_VALIDOS = frozenset({
    "recarga", "captura_viaje", "reembolso", "ajuste", "bono",
    "comision", "liquidacion",
})
TIPOS_USUARIO = frozenset({"client", "driver"})


def insertar_asiento(
    conn: PgConnection,
    *,
    user_id: str,
    user_type: str,
    tipo: str,
    monto_cents: int,
    idempotency_key: str,
    trip_id: Optional[str] = None,
    descripcion: Optional[str] = None,
    metadata: Optional[dict[str, Any]] = None,
    cur=None,
) -> bool:
    """Inserta un asiento si no existía.

    Devuelve `True` si lo insertó y `False` si la clave ya estaba (reintento
    o backfill repetido). No abre ni cierra transacción: eso es del llamador.
    """
    if user_type not in TIPOS_USUARIO:
        raise ValueError(f"user_type inválido: {user_type!r}")
    if tipo not in TIPOS_VALIDOS:
        raise ValueError(f"tipo inválido: {tipo!r}")
    monto_cents = int(monto_cents)
    if monto_cents == 0:
        raise ValueError("Un asiento no puede ser de 0 centavos")

    cursor = cur or conn.cursor()
    propio = cur is None
    try:
        cursor.execute(
            """
            INSERT INTO wallet_ledger
                (user_id, user_type, trip_id, tipo, monto_cents,
                 idempotency_key, descripcion, metadata)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s::jsonb)
            ON CONFLICT (idempotency_key) DO NOTHING
            RETURNING id
            """,
            (user_id, user_type, trip_id, tipo, monto_cents,
             idempotency_key, descripcion,
             json.dumps(metadata or {}, ensure_ascii=False)),
        )
        return cursor.fetchone() is not None
    finally:
        if propio:
            cursor.close()


def saldo_ledger(conn: PgConnection, user_id: str,
                 user_type: str = "client") -> int:
    """Suma del ledger sin descontar holds."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT COALESCE(SUM(monto_cents), 0) FROM wallet_ledger "
            "WHERE user_id = %s AND user_type = %s",
            (user_id, user_type))
        return int(cur.fetchone()[0])


def saldo_disponible(conn: PgConnection, user_id: str,
                     user_type: str = "client") -> int:
    """Ledger menos holds activas, en centavos."""
    with conn.cursor() as cur:
        cur.execute("SELECT saldo_disponible(%s, %s)", (user_id, user_type))
        return int(cur.fetchone()[0])


def bloquear_usuario(conn: PgConnection, user_id: str) -> None:
    """Serializa las operaciones de dinero de un usuario.

    Debe llamarse al principio de la transacción que crea un hold o cobra.
    Sin esto, dos peticiones simultáneas pueden leer el mismo saldo y las dos
    pasan la comprobación.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT wallet_lock_user(%s)", (user_id,))


def centavos(valor: Any) -> int:
    """Atajo para que los llamadores no importen dos módulos."""
    return a_cents(valor)
