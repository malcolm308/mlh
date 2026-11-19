"""Migración de saldos de MongoDB a `wallet_ledger` y cuadre posterior.

Dos operaciones, ambas de solo lectura sobre Mongo:

* `ejecutar_backfill` — abre un asiento `ajuste` por cada saldo existente.
  Es idempotente (clave `mig:{user_type}:{user_id}:{campo}`), por lotes y
  reanudable mediante un checkpoint.
* `comparar_cuadre` — compara el saldo de Mongo con el del ledger y devuelve
  la lista de diferencias.

Qué se migra (los tres saldos reales del sistema):

| Colección | Campo | user_type |
|-----------|-------|-----------|
| `Cliente.users` | `Fondo` | `client` |
| `Cliente.users` | `saldo_promocional` | `client` |
| `Chofer.users` | `Fondo` | `driver` |

Las claves de idempotencia llevan el tipo de usuario y el campo porque un
mismo ObjectId puede existir a la vez en `Cliente.users` y en `Chofer.users`
(la misma persona con las dos apps) y porque un cliente puede tener a la vez
`Fondo` y `saldo_promocional`. Una clave `mig:{user_id}` a secas colisionaría
y perdería dinero en la migración.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Callable, Iterator, Optional

from psycopg2.extensions import connection as PgConnection

from app.money import a_cents, de_cents
from app.wallet.ledger import insertar_asiento

#: (user_type, campo de Mongo, sufijo de la clave de idempotencia)
CAMPOS_CLIENTE = (
    ("client", "Fondo", "fondo"),
    ("client", "saldo_promocional", "promo"),
)
CAMPOS_CHOFER = (
    ("driver", "Fondo", "fondo"),
)


def _id_a_texto(valor: Any) -> str:
    return str(valor)


def clave_migracion(user_type: str, user_id: str, sufijo: str) -> str:
    return f"mig:{user_type}:{user_id}:{sufijo}"


def _ahora_utc() -> datetime:
    """Ahora en UTC naive, igual que lo guarda Mongo."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _a_utc_naive(valor: Any) -> Optional[datetime]:
    """Normaliza una fecha de Mongo a UTC naive (misma regla que el router)."""
    if valor is None:
        return None
    if isinstance(valor, datetime):
        if valor.tzinfo is not None:
            return valor.astimezone(timezone.utc).replace(tzinfo=None)
        return valor
    if isinstance(valor, str):
        texto = valor.strip().replace("Z", "+00:00")
        try:
            return _a_utc_naive(datetime.fromisoformat(texto))
        except ValueError:
            return None
    return None


def promo_vigente(fecha_expiracion: Any,
                  ahora: Optional[datetime] = None) -> bool:
    """Réplica de `campana_promocional.campana_vigente`.

    Sin fecha de expiración el saldo NO está vigente: la campaña se apaga
    sola. Importar el router aquí traería FastAPI y Mongo a un script que
    debe poder correr aislado, así que se duplica la regla (3 líneas).
    """
    expira = _a_utc_naive(fecha_expiracion)
    if expira is None:
        return False
    return (ahora or _ahora_utc()) <= expira


def iterar_saldos(
    cliente_col,
    chofer_col,
    *,
    desde: Optional[dict[str, str]] = None,
    limite: Optional[int] = None,
    incluir_ceros: bool = False,
) -> Iterator[dict[str, Any]]:
    """Genera un registro por cada saldo no nulo de Mongo.

    Cada registro incluye `_orden` (el `_id`) para que el llamador pueda
    guardar el checkpoint y reanudar sin repetir.
    """
    desde = desde or {}
    for col, user_type, campos, etiqueta in (
        (cliente_col, "client", CAMPOS_CLIENTE, "cliente"),
        (chofer_col, "driver", CAMPOS_CHOFER, "chofer"),
    ):
        filtro: dict[str, Any] = {}
        ultimo = desde.get(etiqueta)
        if ultimo:
            from bson import ObjectId
            filtro["_id"] = {"$gt": ObjectId(ultimo)}
        proyeccion = {campo: 1 for _, campo, _ in campos}
        # Hace falta para decidir si el saldo promocional sigue vigente.
        if any(campo == "saldo_promocional" for _, campo, _ in campos):
            proyeccion["fecha_expiracion_promocional"] = 1
        cursor = col.find(filtro, proyeccion).sort("_id", 1)
        if limite:
            cursor = cursor.limit(int(limite))
        for doc in cursor:
            user_id = _id_a_texto(doc["_id"])
            for utype, campo, sufijo in campos:
                if campo not in doc or doc[campo] is None:
                    continue
                utype_final = utype if utype else user_type
                expira = (doc.get("fecha_expiracion_promocional")
                          if campo == "saldo_promocional" else None)
                base = {
                    "user_type": utype_final,
                    "user_id": user_id,
                    "campo": campo,
                    "sufijo": sufijo,
                    "_orden": user_id,
                    "_coleccion": etiqueta,
                    "expira_en": (_a_utc_naive(expira).isoformat()
                                  if _a_utc_naive(expira) else None),
                }

                try:
                    monto = a_cents(doc[campo])
                except Exception as exc:  # noqa: BLE001 - se reporta y se sigue
                    yield {**base, "monto_cents": 0,
                           "mongo_valor": doc[campo],
                           "error": f"{type(exc).__name__}: {exc}"}
                    continue
                if monto == 0 and not incluir_ceros:
                    continue

                # El saldo promocional vencido vale 0 para la app. Migrarlo
                # como saldo real regalaría dinero, así que se omite.
                if campo == "saldo_promocional" and not promo_vigente(expira):
                    yield {**base, "monto_cents": 0,
                           "mongo_valor": doc[campo],
                           "omitido": "promo_vencida"}
                    continue

                yield {**base, "monto_cents": monto, "mongo_valor": doc[campo]}


def ejecutar_backfill(
    conn: PgConnection,
    cliente_col,
    chofer_col,
    *,
    dry_run: bool = False,
    batch_size: int = 200,
    limite: Optional[int] = None,
    desde: Optional[dict[str, str]] = None,
    incluir_ceros: bool = False,
    progreso: Optional[Callable[[str, str, dict], None]] = None,
    log: Optional[Callable[[str], None]] = None,
) -> dict[str, Any]:
    """Recorre Mongo e inserta los asientos de apertura.

    Devuelve estadísticas. Nunca escribe en Mongo.
    """
    log = log or (lambda msg: None)
    stats = {
        "revisados": 0,
        "con_saldo": 0,
        "insertados": 0,
        "ya_existian": 0,
        "omitidos": 0,
        "errores": 0,
        "dry_run": dry_run,
        "empezado_en": datetime.now(timezone.utc).isoformat(),
    }
    pendientes = 0
    ultimo_orden: dict[str, str] = {}

    for fila in iterar_saldos(cliente_col, chofer_col, desde=desde,
                              limite=limite, incluir_ceros=incluir_ceros):
        stats["revisados"] += 1
        ultimo_orden[fila["_coleccion"]] = fila["_orden"]

        if fila.get("error"):
            stats["errores"] += 1
            log(f"[X] {fila['user_type']} {fila['user_id']} "
                f"{fila['campo']}: {fila['error']}")
            continue

        if fila.get("omitido"):
            stats["omitidos"] += 1
            if stats["omitidos"] <= 5:
                log(f"[i] omitido {fila['user_type']} {fila['user_id']} "
                    f"{fila['campo']}: {fila['omitido']}")
            continue

        stats["con_saldo"] += 1

        if dry_run:
            stats["insertados"] += 1
            continue

        clave = clave_migracion(fila["user_type"], fila["user_id"],
                                fila["sufijo"])
        metadata = {
            "origen": "migracion_mongo",
            "coleccion": fila["_coleccion"],
            "campo": fila["campo"],
            "valor_mongo": str(fila["mongo_valor"]),
        }
        if fila.get("expira_en"):
            metadata["expira_en"] = fila["expira_en"]
        try:
            insertado = insertar_asiento(
                conn,
                user_id=fila["user_id"],
                user_type=fila["user_type"],
                tipo="ajuste",
                monto_cents=fila["monto_cents"],
                idempotency_key=clave,
                descripcion=f"Saldo inicial migrado desde MongoDB "
                            f"({fila['campo']})",
                metadata=metadata,
            )
        except Exception as exc:  # noqa: BLE001 - se reporta y se sigue
            conn.rollback()
            stats["errores"] += 1
            log(f"[X] {fila['user_type']} {fila['user_id']} "
                f"{fila['campo']}: {type(exc).__name__}: {exc}")
            continue

        if insertado:
            stats["insertados"] += 1
        else:
            stats["ya_existian"] += 1

        pendientes += 1
        if pendientes >= batch_size:
            conn.commit()
            pendientes = 0
            log(f"[..] {stats['insertados']} insertados, "
                f"{stats['ya_existian']} ya existían")
            if progreso:
                progreso(fila["_coleccion"], fila["_orden"], dict(stats))

    if not dry_run and pendientes:
        conn.commit()
        if progreso and ultimo_orden:
            for coleccion, orden in ultimo_orden.items():
                progreso(coleccion, orden, dict(stats))

    stats["terminado_en"] = datetime.now(timezone.utc).isoformat()
    stats["ultimo_orden"] = ultimo_orden
    return stats


def saldos_postgres(conn: PgConnection) -> dict[tuple[str, str], int]:
    """Saldo contable (ledger, sin holds) por (user_type, user_id)."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT user_type, user_id, SUM(monto_cents) "
            "FROM wallet_ledger GROUP BY user_type, user_id")
        return {(ut, uid): int(total) for ut, uid, total in cur.fetchall()}


def saldos_mongo(cliente_col, chofer_col,
                 incluir_ceros: bool = False) -> dict[tuple[str, str], dict]:
    """Saldo de Mongo por (user_type, user_id), con el desglose por campo."""
    resultado: dict[tuple[str, str], dict] = {}
    for fila in iterar_saldos(cliente_col, chofer_col,
                              incluir_ceros=incluir_ceros):
        if fila.get("error") or fila.get("omitido"):
            continue
        clave = (fila["user_type"], fila["user_id"])
        entrada = resultado.setdefault(clave, {
            "user_type": fila["user_type"],
            "user_id": fila["user_id"],
            "total_cents": 0,
            "desglose": {},
        })
        entrada["total_cents"] += fila["monto_cents"]
        entrada["desglose"][fila["campo"]] = fila["monto_cents"]
    return resultado


def pendientes_outbox(conn: PgConnection) -> dict[str, int]:
    """Centavos que el outbox aún debe aplicar al `Fondo` de cada chofer.

    Solo cuentan `trip.completed` y `driver.payout` **sin** `mongo_aplicado`:
    son los eventos que mueven dinero del chofer y que el worker aplica con
    `$inc`. Un evento en `pendiente` o `error` significa que MongoDB todavía
    no lo refleja, así que el cuadre lo tolera en vez de dar un falso
    positivo de descuadre.

    Para `trip.completed` el ajuste es `chofer_neto_cents`; para
    `driver.payout` es `-monto_cents` (una liquidación resta saldo).
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT payload->>'driver_id' AS driver_id,
                   SUM(CASE event_type
                         WHEN 'trip.completed'
                           THEN (payload->>'chofer_neto_cents')::bigint
                         WHEN 'driver.payout'
                           THEN -(payload->>'monto_cents')::bigint
                       END) AS ajuste_cents
              FROM outbox
             WHERE estado IN ('pendiente', 'error')
               AND event_type IN ('trip.completed', 'driver.payout')
               AND COALESCE((payload->>'mongo_aplicado')::boolean, false)
                   = false
               AND payload->>'driver_id' IS NOT NULL
             GROUP BY payload->>'driver_id'
            """)
        return {driver_id: int(ajuste)
                for driver_id, ajuste in cur.fetchall()
                if driver_id and ajuste is not None}


def comparar_cuadre(conn: PgConnection, cliente_col, chofer_col,
                    tolerancia_cents: int = 0,
                    tolerar_outbox: bool = True) -> dict[str, Any]:
    """Compara Mongo contra el ledger. `ok` es True solo si no hay diferencias.

    El dinero del cliente se comprueba de forma **estricta**: el cliente
    sigue siendo síncrono en Mongo. El chofer, en cambio, se actualiza de
    forma asíncrona mediante el outbox, así que se acepta un desfase igual a
    los eventos `pendiente`/`error` de `trip.completed` y `driver.payout`
    (Tarea 4). Con `tolerar_outbox=False` el cuadre es estricto para todos.
    """
    pg = saldos_postgres(conn)
    mg = saldos_mongo(cliente_col, chofer_col)
    pendientes = pendientes_outbox(conn) if tolerar_outbox else {}

    claves = set(pg) | set(mg) | {("driver", uid) for uid in pendientes}

    diferencias: list[dict[str, Any]] = []
    tolerados: list[dict[str, Any]] = []
    for clave in sorted(claves):
        user_type, user_id = clave
        obtenido = pg.get(clave, 0)
        entrada_mongo = mg.get(clave) or {}
        mongo_cents = int(entrada_mongo.get("total_cents") or 0)
        pendiente = (pendientes.get(user_id, 0)
                     if user_type == "driver" else 0)
        esperado = mongo_cents + pendiente
        delta = obtenido - esperado
        if abs(delta) > tolerancia_cents:
            diferencias.append({
                "user_type": user_type,
                "user_id": user_id,
                "mongo_cents": mongo_cents,
                "postgres_cents": obtenido,
                "pendiente_outbox_cents": pendiente,
                "delta_cents": delta,
                "mongo": {k: float(de_cents(v))
                          for k, v in (entrada_mongo.get("desglose")
                                       or {}).items()},
                "postgres": float(de_cents(obtenido)),
            })
        elif pendiente:
            tolerados.append({
                "user_type": user_type,
                "user_id": user_id,
                "mongo_cents": mongo_cents,
                "postgres_cents": obtenido,
                "pendiente_outbox_cents": pendiente,
            })

    solo_en_postgres = [
        {"user_type": ut, "user_id": uid, "postgres_cents": total}
        for (ut, uid), total in pg.items()
        if (ut, uid) not in mg
        and not (ut == "driver" and uid in pendientes)
    ]

    return {
        "revisado_en": datetime.now(timezone.utc).isoformat(),
        "usuarios_mongo": len(mg),
        "usuarios_postgres": len(pg),
        "diferencias": diferencias,
        "solo_en_postgres": solo_en_postgres,
        "tolerados_por_outbox": tolerados,
        "pendientes_outbox_cents": pendientes,
        "tolerar_outbox": tolerar_outbox,
        "tolerancia_cents": tolerancia_cents,
        "ok": not diferencias and not solo_en_postgres,
    }
