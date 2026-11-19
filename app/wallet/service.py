"""Operaciones de dinero de la billetera.

Reglas que este módulo hace cumplir y que no se pueden relajar:

1. **Nunca lee MongoDB.** El saldo sale de PostgreSQL, en la misma
   transacción que la operación. Un fallo de Mongo no puede hacer que alguien
   gaste dinero que no tiene.
2. **Todo es idempotente.** Cada movimiento lleva una `idempotency_key`
   única; reintentar no cobra dos veces.
3. **El saldo se serializa por usuario** con `wallet_lock_user()` antes de
   leerlo. Sin eso, dos viajes simultáneos ven el mismo saldo y los dos pasan.
4. **El llamador manda la transacción.** Estas funciones reciben una conexión
   psycopg2 ya abierta y no hacen `commit` ni `rollback`: así el hold se crea
   en la misma transacción que el viaje y, si no hay saldo, el viaje
   desaparece con el rollback.

Flujo de un viaje pagado con billetera:

    create_trip   → reservar_hold()        (saldo retenido, aún no cobrado)
    cancel_trip   → liberar_hold()         (el saldo vuelve)
    complete_trip → capturar_hold()        (se convierte en asiento -monto)
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from psycopg2.extensions import connection as PgConnection

from app.outbox.events import WalletChangedV1, encolar
from app.wallet import ledger
from app.wallet.errors import (EstadoViajeInvalido, MontoInvalido,
                               SaldoInsuficiente)

#: Cuánto vive una reserva si el viaje no se cierra. Es más largo que el TTL
#: de la oferta (6 min) para no soltar saldo de un viaje que sigue vivo; las
#: que quedan colgadas las libera `expirar_holds()`.
HOLD_TTL_MINUTOS = 30


def _filas_afectadas(cur) -> int:
    return int(cur.rowcount or 0)


def clave_captura(trip_id: str) -> str:
    """Clave de idempotencia del cobro de un viaje."""
    return f"trip:{trip_id}:captura"


# ---------------------------------------------------------------------
# Reservas (holds)
# ---------------------------------------------------------------------
def reservar_hold(
    conn: PgConnection,
    *,
    user_id: str,
    trip_id: str,
    monto_cents: int,
    user_type: str = "client",
    ttl_minutos: int = HOLD_TTL_MINUTOS,
    cur=None,
) -> dict[str, Any]:
    """Reserva saldo para un viaje.

    Debe llamarse **después** de insertar el viaje y **antes** del commit: el
    FK de `wallet_holds.trip_id` exige que la fila exista.

    Lanza `SaldoInsuficiente` si el saldo disponible no cubre el monto; el
    llamador debe propagar el error para que la transacción se revierta y el
    viaje no llegue a existir.

    Si el viaje ya tiene una reserva activa (reintento), la devuelve en vez de
    crear otra.
    """
    if not user_id:
        raise MontoInvalido("Falta el user_id de la reserva")
    monto_cents = int(monto_cents)
    if monto_cents <= 0:
        raise MontoInvalido("El monto de la reserva debe ser mayor que 0")

    ledger.bloquear_usuario(conn, user_id)

    cursor = cur or conn.cursor()
    propio = cur is None
    try:
        # Reintento sobre el mismo viaje: devolver la reserva existente sin
        # volver a comprobar el saldo (la reserva ya lo está descontando).
        cursor.execute(
            "SELECT id, monto_cents, expires_at, estado "
            "FROM wallet_holds WHERE trip_id = %s",
            (trip_id,))
        previa = cursor.fetchone()
        if previa is not None:
            if previa[3] != "activa":
                raise EstadoViajeInvalido(
                    f"El viaje {trip_id} ya tiene una reserva {previa[3]}")
            return {
                "hold_id": int(previa[0]),
                "monto_cents": int(previa[1]),
                "expires_at": previa[2],
                "saldo_disponible_cents": _saldo_disponible_cur(
                    cursor, user_id, user_type),
                "creada": False,
            }

        disponible = _saldo_disponible_cur(cursor, user_id, user_type)
        if disponible < monto_cents:
            raise SaldoInsuficiente(monto_cents, disponible)

        expires_at = datetime.now(timezone.utc) + timedelta(
            minutes=max(1, int(ttl_minutos)))
        cursor.execute(
            """
            INSERT INTO wallet_holds
                (user_id, user_type, trip_id, monto_cents, expires_at)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (trip_id) DO NOTHING
            RETURNING id, monto_cents, expires_at
            """,
            (user_id, user_type, trip_id, monto_cents, expires_at),
        )
        fila = cursor.fetchone()
        if fila is None:  # pragma: no cover - cubierto por la consulta previa
            raise MontoInvalido(
                f"No se pudo crear la reserva del viaje {trip_id}")

        return {
            "hold_id": int(fila[0]),
            "monto_cents": int(fila[1]),
            "expires_at": fila[2],
            "saldo_disponible_cents": _saldo_disponible_cur(
                cursor, user_id, user_type),
            "creada": True,
        }
    finally:
        if propio:
            cursor.close()


def liberar_hold(
    conn: PgConnection,
    *,
    trip_id: str,
    estado: str = "liberada",
    cur=None,
) -> bool:
    """Suelta la reserva de un viaje. El saldo vuelve a estar disponible.

    No inserta ningún asiento: la reserva nunca movió dinero. Es idempotente:
    si ya estaba liberada (o capturada) devuelve `False`.
    """
    if estado not in ("liberada", "expirada"):
        raise ValueError(f"estado de liberación inválido: {estado!r}")

    cursor = cur or conn.cursor()
    propio = cur is None
    try:
        cursor.execute(
            "UPDATE wallet_holds SET estado = %s, updated_at = NOW() "
            "WHERE trip_id = %s AND estado = 'activa'",
            (estado, trip_id))
        return _filas_afectadas(cursor) > 0
    finally:
        if propio:
            cursor.close()


def capturar_hold(
    conn: PgConnection,
    *,
    trip_id: str,
    user_type: str = "client",
    monto_cents: Optional[int] = None,
    permitir_parcial: bool = False,
    idempotency_key: Optional[str] = None,
    descripcion: Optional[str] = None,
    metadata: Optional[dict[str, Any]] = None,
    cur=None,
) -> dict[str, Any]:
    """Convierte la reserva en un cobro real.

    Marca la reserva como `capturada` e inserta el asiento negativo en el
    ledger, todo en la transacción del llamador. Devuelve
    `{"capturada": bool, "monto_cents": int}`; `capturada=False` significa que
    el viaje no tenía reserva o ya se había capturado, y en ese caso **no se
    vuelve a cobrar**.

    `monto_cents` permite cobrar el importe final del viaje (que puede diferir
    del estimado). Si no se pasa, se cobra exactamente lo reservado.

    * `permitir_parcial=False` (cobros explícitos): si el importe supera el
      saldo libre se lanza `SaldoInsuficiente` y el llamador revierte.
    * `permitir_parcial=True` (cierre de viaje): se cobra el mínimo entre el
      importe pedido y el saldo libre. El resto es excedente que se cobra por
      fuera; nunca se deja la cuenta en negativo.
    """
    cursor = cur or conn.cursor()
    propio = cur is None
    try:
        cursor.execute(
            "SELECT id, user_id, monto_cents, estado "
            "FROM wallet_holds WHERE trip_id = %s FOR UPDATE",
            (trip_id,))
        hold = cursor.fetchone()
        if hold is None:
            return {"capturada": False, "monto_cents": 0,
                    "motivo": "sin_hold"}
        hold_id, user_id, monto_hold, estado = hold[0], hold[1], int(hold[2]), hold[3]
        if estado == "capturada":
            return {"capturada": False, "monto_cents": monto_hold,
                    "motivo": "ya_capturada"}
        if estado != "activa":
            raise EstadoViajeInvalido(
                f"La reserva del viaje {trip_id} está {estado}")

        # Orden de bloqueo: fila del hold → advisory del usuario. `reservar_hold`
        # toma el advisory antes de insertar, pero nunca bloquea una fila
        # existente, así que no hay ciclo.
        ledger.bloquear_usuario(conn, user_id)

        pedido = int(monto_cents) if monto_cents is not None else monto_hold
        if pedido <= 0:
            raise MontoInvalido("El importe a capturar debe ser mayor que 0")

        # La reserva propia sigue contando en `saldo_disponible`; para saber
        # cuánto hay realmente libre se le suma de vuelta el monto reservado.
        disponible = _saldo_consumible_cur(cursor, user_id, user_type) + monto_hold
        if permitir_parcial:
            cobro = min(pedido, disponible)
        else:
            if pedido > disponible:
                raise SaldoInsuficiente(pedido, disponible)
            cobro = pedido

        if cobro > 0:
            cursor.execute(
                "UPDATE wallet_holds SET estado = 'capturada', "
                "monto_cents = %s, updated_at = NOW() WHERE id = %s",
                (cobro, hold_id))
        else:
            # Sin saldo libre: el viaje se cobra entero por fuera. La reserva
            # se cierra igual para que deje de retener dinero.
            cursor.execute(
                "UPDATE wallet_holds SET estado = 'capturada', "
                "updated_at = NOW() WHERE id = %s", (hold_id,))
            return {"capturada": False, "monto_cents": 0,
                    "motivo": "sin_saldo"}

        clave = idempotency_key or clave_captura(trip_id)
        insertado = ledger.insertar_asiento(
            conn,
            user_id=user_id,
            user_type=user_type,
            tipo="captura_viaje",
            monto_cents=-cobro,
            idempotency_key=clave,
            trip_id=trip_id,
            descripcion=descripcion or f"Cobro del viaje {trip_id}",
            metadata=metadata,
            cur=cursor,
        )
        if not insertado:
            # La clave ya existía: alguien cobró antes. No se duplica.
            return {"capturada": False, "monto_cents": cobro,
                    "motivo": "ya_cobrado"}

        saldo = _saldo_ledger_cur(cursor, user_id, user_type)
        encolar(
            conn,
            event_type="wallet.changed",
            aggregate_type="user",
            aggregate_id=user_id,
            payload=WalletChangedV1(
                user_id=user_id, user_type=user_type, tipo="captura_viaje",
                monto_cents=-cobro, saldo_cents=saldo),
            cur=cursor,
        )
        return {"capturada": True, "monto_cents": cobro,
                "saldo_cents": saldo}
    finally:
        if propio:
            cursor.close()


# ---------------------------------------------------------------------
# Reparto del chofer al cerrar un viaje
# ---------------------------------------------------------------------
def acreditar_chofer_viaje(
    conn: PgConnection,
    *,
    trip_id: str,
    driver_id: str,
    chofer_credito_cents: int,
    comision_cents: int,
    cur=None,
) -> dict[str, Any]:
    """Asientos del chofer al cerrar un viaje (Tarea 4).

    Dos movimientos, cada uno con su clave de idempotencia:

    * ``trip:{trip_id}:chofer_credito`` → ``+chofer_credito``: lo que el
      viaje le paga al chofer (promo + saldo real + bono).
    * ``trip:{trip_id}:comision`` → ``-comision``: la parte de la plataforma.

    Un importe de 0 no genera asiento (el ledger lo prohíbe). Devuelve las
    claves insertadas y el saldo contable resultante del chofer.
    """
    if not driver_id:
        raise MontoInvalido("Falta el driver_id del abono")
    chofer_credito_cents = int(chofer_credito_cents)
    comision_cents = int(comision_cents)
    if chofer_credito_cents < 0 or comision_cents < 0:
        raise MontoInvalido("Los importes del reparto no pueden ser negativos")

    cursor = cur or conn.cursor()
    propio = cur is None
    try:
        ledger.bloquear_usuario(conn, driver_id)
        insertadas = []
        if chofer_credito_cents > 0:
            if ledger.insertar_asiento(
                conn, user_id=driver_id, user_type="driver",
                tipo="captura_viaje", monto_cents=chofer_credito_cents,
                idempotency_key=f"trip:{trip_id}:chofer_credito",
                trip_id=trip_id,
                descripcion=f"Abono del viaje {trip_id}",
                cur=cursor,
            ):
                insertadas.append("chofer_credito")
        if comision_cents > 0:
            if ledger.insertar_asiento(
                conn, user_id=driver_id, user_type="driver",
                tipo="comision", monto_cents=-comision_cents,
                idempotency_key=f"trip:{trip_id}:comision",
                trip_id=trip_id,
                descripcion=f"Comisión del viaje {trip_id}",
                cur=cursor,
            ):
                insertadas.append("comision")
        return {
            "insertadas": insertadas,
            "saldo_cents": _saldo_ledger_cur(cursor, driver_id, "driver"),
        }
    finally:
        if propio:
            cursor.close()


# ---------------------------------------------------------------------
# Recargas, descargos y ajustes
# ---------------------------------------------------------------------
def ajustar_saldo(
    conn: PgConnection,
    *,
    user_id: str,
    user_type: str,
    monto_cents: int,
    tipo: str,
    idempotency_key: str,
    descripcion: Optional[str] = None,
    metadata: Optional[dict[str, Any]] = None,
    cur=None,
) -> dict[str, Any]:
    """Inserta un asiento y emite `wallet.changed`.

    `monto_cents` lleva signo: positivo entra, negativo sale. Los tipos
    válidos están en `wallet_ledger.tipo` (`recarga`, `ajuste`,
    `liquidacion`, ...). Devuelve `insertado=False` si la clave ya existía.
    """
    monto_cents = int(monto_cents)
    if monto_cents == 0:
        raise MontoInvalido("Un movimiento de dinero no puede ser 0")
    if not idempotency_key:
        raise MontoInvalido("Falta la idempotency_key")

    cursor = cur or conn.cursor()
    propio = cur is None
    try:
        ledger.bloquear_usuario(conn, user_id)
        insertado = ledger.insertar_asiento(
            conn,
            user_id=user_id,
            user_type=user_type,
            tipo=tipo,
            monto_cents=monto_cents,
            idempotency_key=idempotency_key,
            descripcion=descripcion,
            metadata=metadata,
            cur=cursor,
        )
        saldo = _saldo_ledger_cur(cursor, user_id, user_type)
        if insertado:
            encolar(
                conn,
                event_type="wallet.changed",
                aggregate_type="user",
                aggregate_id=user_id,
                payload=WalletChangedV1(
                    user_id=user_id, user_type=user_type, tipo=tipo,
                    monto_cents=monto_cents, saldo_cents=saldo),
                cur=cursor,
            )
        return {"insertado": insertado, "saldo_cents": saldo,
                "monto_cents": monto_cents}
    finally:
        if propio:
            cursor.close()


def recargar_saldo(conn: PgConnection, **kwargs) -> dict[str, Any]:
    """Atajo de `ajustar_saldo` para entradas de dinero."""
    kwargs["tipo"] = "recarga"
    if int(kwargs.get("monto_cents", 0)) <= 0:
        raise MontoInvalido("Una recarga debe ser positiva")
    return ajustar_saldo(conn, **kwargs)


def descargar_saldo(conn: PgConnection, **kwargs) -> dict[str, Any]:
    """Atajo para sacar dinero del saldo (descargo o liquidación).

    Se pasa el monto en positivo y aquí se le pone el signo; además se
    comprueba que haya saldo suficiente, porque un descargo no puede dejar la
    cuenta en negativo.
    """
    monto = int(kwargs.pop("monto_cents", 0))
    if monto <= 0:
        raise MontoInvalido("Un descargo debe ser positivo")
    kwargs.setdefault("tipo", "ajuste")
    user_id = kwargs["user_id"]
    user_type = kwargs.get("user_type", "client")
    disponible = saldo_disponible(conn, user_id, user_type)
    if disponible < monto:
        raise SaldoInsuficiente(monto, disponible)
    if kwargs["tipo"] not in ("ajuste", "liquidacion"):
        raise MontoInvalido(
            f"tipo inválido para un descargo: {kwargs['tipo']!r}")
    return ajustar_saldo(conn, monto_cents=-monto, **kwargs)


# ---------------------------------------------------------------------
# Expiración de reservas
# ---------------------------------------------------------------------
def expirar_holds(conn: PgConnection, *, limite: int = 500) -> list[str]:
    """Marca como expiradas las reservas vencidas y devuelve sus viajes.

    Usa `FOR UPDATE SKIP LOCKED`: dos instancias del cron pueden correr a la
    vez sin pisarse ni bloquearse.
    """
    limite = max(1, int(limite))
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH vencidas AS (
                SELECT id
                  FROM wallet_holds
                 WHERE estado = 'activa' AND expires_at <= NOW()
                 ORDER BY expires_at
                 LIMIT %s
                   FOR UPDATE SKIP LOCKED
            )
            UPDATE wallet_holds h
               SET estado = 'expirada', updated_at = NOW()
              FROM vencidas v
             WHERE h.id = v.id
         RETURNING h.trip_id
            """,
            (limite,))
        return [fila[0] for fila in cur.fetchall()]


# ---------------------------------------------------------------------
# Consultas
# ---------------------------------------------------------------------
def saldo_disponible(conn: PgConnection, user_id: str,
                     user_type: str = "client") -> int:
    """Saldo real menos reservas activas, en centavos."""
    return ledger.saldo_disponible(conn, user_id, user_type)


def saldo(conn: PgConnection, user_id: str,
          user_type: str = "client") -> dict[str, int]:
    """Desglose para la API: contable, retenido y disponible."""
    with conn.cursor() as cur:
        contable = _saldo_ledger_cur(cur, user_id, user_type)
        retenido = _holds_activos_cur(cur, user_id, user_type)
    return {"saldo_cents": contable, "retenido_cents": retenido,
            "disponible_cents": contable - retenido}


def _saldo_ledger_cur(cur, user_id: str, user_type: str) -> int:
    cur.execute(
        "SELECT COALESCE(SUM(monto_cents), 0) FROM wallet_ledger "
        "WHERE user_id = %s AND user_type = %s",
        (user_id, user_type))
    return int(cur.fetchone()[0])


def _holds_activos_cur(cur, user_id: str, user_type: str) -> int:
    cur.execute(
        "SELECT COALESCE(SUM(monto_cents), 0) FROM wallet_holds "
        "WHERE user_id = %s AND user_type = %s AND estado = 'activa'",
        (user_id, user_type))
    return int(cur.fetchone()[0])


def _saldo_disponible_cur(cur, user_id: str, user_type: str) -> int:
    """`saldo_disponible()` dentro del cursor del llamador."""
    cur.execute("SELECT saldo_disponible(%s, %s)", (user_id, user_type))
    return int(cur.fetchone()[0])


def _saldo_consumible_cur(cur, user_id: str, user_type: str) -> int:
    """Saldo que se puede gastar sin contar reservas activas."""
    return (_saldo_ledger_cur(cur, user_id, user_type)
            - _holds_activos_cur(cur, user_id, user_type))
