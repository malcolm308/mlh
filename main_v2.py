from pathlib import Path
from typing import Any
from datetime import datetime, timezone

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import ORJSONResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.staticfiles import StaticFiles
from apscheduler.schedulers.asyncio import AsyncIOScheduler

from tiempo_cuba import CUBA_TZ

from routers import billetera
from routers import CRUD_MONGODB
from routers import Solicitud_de_viajes_v4
from routers import admin_panel
from routers import admin_web
from routers import promociones
from routers import documentos
from routers import pois
from routers import geo
from routers import routing
from routers import vehiculos
from routers import chofer_cancelaciones
from routers import tariffs
from routers import garaje
from routers import cuenta_chofer
from routers import telegram_webhook
from routers import favoritos
from routers import incidencias
from routers import soporte
from routers import referidos
from routers import users
from routers import auth_reset
from routers import auth_refresh
from routers import app_init
from routers import app_updates
from routers import descargas
from routers import tiempo_real
from routers import campana_promocional
from routers import outbox_internal
from services import indices
from services.traccar_listener import listen_traccar

from app import config as app_config
from app.http_compat import compat_query_middleware
from app.logging_setup import configurar_logging
from app.outbox import worker as outbox_worker

# Funciones que necesitamos del modulo de viajes
from routers.Solicitud_de_viajes_v4 import (
    get_connection,
    publish_trip_event,
    init_pool,
    init_db,
    TRIP_ACCEPT_TIMEOUT_SECS,
)

import os
import secrets
import asyncio
import logging
import re
import sys
import time
import json
from collections import defaultdict, deque

import httpx
from apscheduler.triggers.cron import CronTrigger
from starlette.requests import Request
from starlette.responses import JSONResponse as StarletteJSONResponse

# La consola de Windows usa cp1252: cualquier print con emoji/acento hacia que
# la salida se redirija a un archivo revienta el arranque. Se fuerza UTF-8.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# Uvicorn no da handler a los loggers de la app: sin esto los INFO del
# arranque y del heartbeat del outbox no aparecen en Render (si los WARNING).
configurar_logging()

logger = logging.getLogger(__name__)


_SENSITIVE_LOG_PATTERNS = [
    (re.compile(r"(Bearer\s+)[A-Za-z0-9\-._~+/]+=*", re.I), r"\1[REDACTED]"),
    (re.compile(
        r"((?:password|contrasena|contraseña|secret|token|refresh_token|access_token|authorization|x-admin-token|x-cron-secret|api[_-]?key)\s*[=:]\s*)([^\s,;\"']+)",
        re.I,
    ), r"\1[REDACTED]"),
    (re.compile(
        r"(\"(?:password|contrasena|contraseña|secret|token|refresh_token|access_token|authorization|api_key)\"\s*:\s*\")[^\"]*(\")",
        re.I,
    ), r"\1[REDACTED]\2"),
]


class _RedactSensitiveFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
            redacted = msg
            for pattern, repl in _SENSITIVE_LOG_PATTERNS:
                redacted = pattern.sub(repl, redacted)
            if redacted != msg:
                record.msg = redacted
                record.args = ()
        except Exception:
            pass
        return True


try:
    logging.getLogger().addFilter(_RedactSensitiveFilter())
except Exception:
    pass

app = FastAPI(
    # orjson: serializacion ~2-4x mas rapida que el json de stdlib en cada
    # respuesta JSON, la mayoria es listas de ofertas/estado para redes
    # moviles lentas.
    default_response_class=ORJSONResponse,
)

from fastapi.encoders import jsonable_encoder  # noqa: E402
import orjson  # noqa: E402


class RespuestaJSON(ORJSONResponse):
    """orjson, pero pasando antes `jsonable_encoder`.

    El `ORJSONResponse` por defecto lanza `TypeError: Object of type Decimal
    is not JSON serializable` si un endpoint deja escapar un Decimal (lo que
    pasaba en POST /trips cuando habia chofres cerca y la respuesta traia el
    bloque de despacho). Antes el `JSONResponse` de FastAPI pasaba TODO por
    `jsonable_encoder`, que convierte Decimal->float, ObjectId->str, etc.
    Con esta subclase conservamos la velocidad de orjson SIN perder esa
    conversion, y cualquier endpoint sigue viendo su contenido igual que
    antes.
    """

    def render(self, content: Any) -> bytes:
        return orjson.dumps(
            jsonable_encoder(content),
            option=orjson.OPT_SERIALIZE_NUMPY,
        )

# ---- Archivos estaticos ----
# Aqui vive el APK que se comparte desde el menu de las apps. Se monta antes de
# los routers para que /static nunca compita con ninguna ruta de la API. El
# directorio se crea si no existe para que el arranque no falle en un clon
# nuevo (el APK se copia despues con el comando documentado en el README).
STATIC_DIR = Path(__file__).resolve().parent / "static"
STATIC_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

# ---- CORS (configurable; estricto por defecto si se definen orígenes) ----
_cors_origenes_raw = os.getenv("CORS_ALLOWED_ORIGINS", "*").strip()
_cors_origenes = [o.strip() for o in _cors_origenes_raw.split(",") if o.strip()]
if not _cors_origenes or _cors_origenes == ["*"]:
    _cors_allow_origins = ["*"]
    # Navegadores rechazan wildcard con credenciales; mantener compatibilidad segura.
    _cors_allow_credentials = False
else:
    _cors_allow_origins = _cors_origenes
    _cors_allow_credentials = os.getenv("CORS_ALLOW_CREDENTIALS", "0").strip().lower() in {
        "1", "true", "yes", "si", "on",
    }
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_allow_origins,
    allow_credentials=_cors_allow_credentials,
    allow_methods=os.getenv("CORS_ALLOW_METHODS", "GET,POST,PUT,PATCH,DELETE,OPTIONS").split(","),
    allow_headers=[h.strip() for h in os.getenv(
        "CORS_ALLOW_HEADERS",
        "Authorization,Content-Type,Accept,X-Admin-Token,X-Cron-Secret",
    ).split(",") if h.strip()],
)
# ---- GZip ----
# El territorio manda: desde Cuba cada JSON viaja por 3G/GPRS, y las respuestas
# de listas (ofertas, historial, tarifas) pesan 3-6x lo necesario sin comprimir.
# El cliente de Dart (package:http con HttpClient) ya declara
# `Accept-Encoding: gzip` y descomprime solo, asi que no hace falta tocar
# nada en las apps para beneficiarse. Brotli NO se anuncia: dart:io no
# descomprime br de forma transparente y se romperia.
app.add_middleware(GZipMiddleware, minimum_size=1024)

# ---- Compatibilidad con APK de chofer desactualizada (422 intermitente) ----
# La query rota (`lat=...lng=...radius_km=5`) se repara aqui, antes de que
# FastAPI intente convertir `lat` a float. No toca peticiones bien formadas.
app.middleware("http")(compat_query_middleware)

# ---- Rate limiting simple por IP (~100 req/min por defecto) ----
_RATE_LIMIT_PER_MINUTE = max(0, int(os.getenv("RATE_LIMIT_PER_MINUTE", "100") or "100"))
_rate_limit_hits: dict[str, deque[float]] = defaultdict(deque)


@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    if _RATE_LIMIT_PER_MINUTE <= 0:
        return await call_next(request)
    forwarded = (request.headers.get("x-forwarded-for") or "").split(",")[0].strip()
    ip = forwarded or (request.client.host if request.client else "unknown")
    ahora = time.monotonic()
    ventana = 60.0
    limite_ventana = ahora - ventana
    cola = _rate_limit_hits[ip]
    while cola and cola[0] < limite_ventana:
        cola.popleft()
    if len(cola) >= _RATE_LIMIT_PER_MINUTE:
        return StarletteJSONResponse(
            status_code=429,
            content={"detail": "Demasiadas solicitudes. Intente más tarde."},
            headers={"Retry-After": "60"},
        )
    cola.append(ahora)
    if len(_rate_limit_hits) > 10000:
        for k in [k for k, v in _rate_limit_hits.items() if not v or v[-1] < limite_ventana]:
            _rate_limit_hits.pop(k, None)
    return await call_next(request)

# ---- Routers ----
# El panel de administracion va antes que CRUD_MONGODB: si no, el GET /admin/{id}
# se traga las rutas /admin/choferes, /admin/trips, etc.
app.include_router(admin_panel.router)
# Endpoints del panel web (alertas, asignacion forzada y configuracion
# agregada). Van antes del CRUD por el mismo motivo que los anteriores.
app.include_router(admin_web.router)
# Promociones antes que CRUD_MONGODB: ese router tiene un `GET /admin/{id}` que
# se tragaria `/admin/promociones`.
app.include_router(promociones.router)
# Campana con saldo promocional por cliente (/admin/promos/...). Va antes del
# CRUD por el mismo motivo que promociones.
app.include_router(campana_promocional.router)
# El garaje va tambien antes que CRUD_MONGODB: ese CRUD tiene un GET
# /admin/{id} que se tragaria los /admin/vehicles del garaje.
app.include_router(garaje.router)
# Cuenta del chofer (DELETE /driver/account) junto al garaje: antes del CRUD
# por el mismo motivo, para que sus rutas no las tape otro router.
app.include_router(cuenta_chofer.router)
app.include_router(CRUD_MONGODB.router)
app.include_router(Solicitud_de_viajes_v4.router)
app.include_router(billetera.router)
app.include_router(documentos.router)
app.include_router(pois.router)
app.include_router(geo.router)
app.include_router(routing.router)
app.include_router(vehiculos.router)
app.include_router(chofer_cancelaciones.router)
app.include_router(tariffs.router, prefix="/api", tags=["tariffs"])
app.include_router(telegram_webhook.router)
app.include_router(favoritos.router)
app.include_router(incidencias.router)
app.include_router(soporte.router)
app.include_router(referidos.router)
app.include_router(users.router)
app.include_router(auth_reset.router)
app.include_router(auth_refresh.router)
app.include_router(app_init.router)
# OTA: /healthz, /readyz y /app/version. Va antes de cualquier router con
# parametros de ruta para que /app/version nunca se confunda con otra ruta.
app.include_router(app_updates.router)
# Enlaces cortos de descarga (/c64, /c32, /d64, /d32) que se comparten por
# WhatsApp en lugar de un acortador externo.
app.include_router(descargas.router)
app.include_router(tiempo_real.router)
# Trigger manual del outbox (operación interna, sin esquema público).
app.include_router(outbox_internal.router)

# Tabla de conteo de cancelaciones por chofer y dia. Si la BD no responde, la
# app arranca igualmente: lo reintentan el startup y el job de APScheduler.
try:
    chofer_cancelaciones.asegurar_tabla_cancelaciones()
    promociones.asegurar_tabla_promociones()
    auth_reset.init_password_resets()
except Exception:
    logger.warning("No se pudo asegurar la tabla de cancelaciones o la de "
                   "promociones en el import; se reintentara", exc_info=True)

# ---- Scheduler para expiracion de viajes ----
scheduler = AsyncIOScheduler(timezone=CUBA_TZ)


async def sweep_expired_trips():
    """
    Marca como 'expired' los viajes 'requested' que superaron el timeout
    de aceptacion (360 s por defecto). Se ejecuta cada 15 s: asi el pasajero
    no espera mas de ~15 s extra antes de ver «Volver a pedir viaje».
    """
    try:
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute("""
                UPDATE trips
                   SET status = 'expired', completed_at = NOW()
                 WHERE status = 'requested'
                   AND requested_at < NOW() - (%s * INTERVAL '1 second')
                RETURNING trip_id;
            """, (TRIP_ACCEPT_TIMEOUT_SECS,))
            expired = [r[0] for r in cur.fetchall()]
            conn.commit()
            cur.close()

        for tid in expired:
            await publish_trip_event(tid, "trip_expired", {"reason": "timeout"})
            logger.info("Viaje %s expirado por timeout", tid)

    except Exception:
        logger.exception("Error en sweep_expired_trips")


# ===================== Autorreparacion de la BD =====================
BD_ESPERADAS = {
    "trips", "transactions", "driver_payouts", "tariffs",
    "daily_trip_metrics", "time_pricing_rules",
    "wallet_movements", "driver_cancellations", "promociones",
}


def _tablas_publicas(conn) -> set:
    """Devuelve el conjunto de tablas existentes en el schema public."""
    cur = conn.cursor()
    cur.execute("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
    tablas = {r[0] for r in cur.fetchall()}
    cur.close()
    return tablas


def inicializar_bd() -> dict:
    """
    Crea las 8 tablas si no existen (CREATE TABLE IF NOT EXISTS). Compartida
    por el startup, el job de APScheduler y el endpoint POST /admin/init.
    Devuelve {"tables_created": [...], "faltantes": [...], "total": N}.
    """
    init_pool()
    with get_connection() as conn:
        antes = _tablas_publicas(conn)
    init_db()
    billetera.init_wallet_db()
    chofer_cancelaciones.asegurar_tabla_cancelaciones()
    promociones.asegurar_tabla_promociones()
    with get_connection() as conn:
        despues = _tablas_publicas(conn)
    return {
        "tables_created": sorted(despues - antes),
        "faltantes": sorted(BD_ESPERADAS - despues),
        "total": len(despues),
    }


def tablas_faltantes() -> set:
    init_pool()
    with get_connection() as conn:
        return BD_ESPERADAS - _tablas_publicas(conn)


async def job_reintento_bd():
    """Job de APScheduler: reintenta crear las tablas cada 60 s y se elimina
    solo cuando las 8 existan."""
    try:
        resultado = inicializar_bd()
        if not resultado["faltantes"]:
            try:
                scheduler.remove_job("reintento_bd")
            except Exception:
                pass
            logger.info("Tablas aseguradas: %s; job de reintento eliminado",
                        resultado["tables_created"])
    except Exception:
        logger.warning("Reintento de inicializacion de BD fallo; pendiente el proximo tick",
                       exc_info=True)


@app.get("/health")
def health():
    """Liveness + hora del servidor.

    `server_time` permite a las apps corregir el reloj del telefono. En Cuba
    los moviles que no aplicaron el cambio de hora van una hora adelantados y
    eso hacia que dieran por vencido un viaje recien aceptado.
    """
    from tiempo_cuba import ahora_cuba, offset_cuba

    return {
        "status": "ok",
        "server_time": datetime.now(timezone.utc).isoformat(),
        "cuba_time": ahora_cuba().isoformat(),
        "utc_offset_hours": offset_cuba(),
    }


# ===================== Outbox loop in-process + cuadre diario =====================
_outbox_stop_event: asyncio.Event | None = None
_outbox_task: asyncio.Task | None = None
_outbox_alert_since: float | None = None


async def _outbox_enviar_alerta(mensaje: str) -> None:
    """Alerta crítica por Telegram si la integración está configurada."""
    try:
        if not os.getenv("TELEGRAM_BOT_TOKEN"):
            return
        chats = telegram_webhook._chats_admin()
        if not chats:
            return
        bot = telegram_webhook._cliente()
        for chat_id in chats:
            try:
                await bot.enviar(chat_id, mensaje)
            except Exception:
                logger.exception("Outbox: no se pudo enviar alerta Telegram a %s", chat_id)
    except Exception:
        logger.exception("Outbox: fallo al preparar alerta Telegram")


async def _outbox_loop() -> None:
    """Loop in-process del worker outbox (Postgres → Mongo).

    Requisitos: uvicorn --workers 1 (instancia única). Lote 50-100, sleep 3-5s
    cuando la cola está vacía, heartbeat cada minuto con pendientes, alerta si
    pendientes > umbral sostenidos. Si Mongo/Postgres no están listos al
    arrancar (o se caen a mitad de turno), reintenta cada 10 s en vez de morir
    en silencio: antes un fallo de conexión cerraba el loop para siempre y no
    aparecía ningún heartbeat.
    """
    global _outbox_alert_since
    stop = _outbox_stop_event
    mongo_uri = os.getenv("MONGODB_URI", "").strip()
    cliente = chofer_col = processed_col = conn = None

    def _abrir():
        c, cc, pc = outbox_worker.conectar_mongo(mongo_uri)
        outbox_worker.asegurar_indice(pc)
        pg = outbox_worker.conectar_pg()
        return c, cc, pc, pg

    def _cerrar() -> None:
        nonlocal cliente, conn
        for cierre in (lambda: conn.close() if conn is not None else None,
                       lambda: cliente.close() if cliente is not None else None):
            try:
                cierre()
            except Exception:
                pass
        cliente = conn = None

    async def _esperar(segundos: float) -> bool:
        """True si pidieron parar; False si solo venció el timeout."""
        if stop is None:
            await asyncio.sleep(segundos)
            return False
        try:
            await asyncio.wait_for(stop.wait(), timeout=segundos)
            return True
        except asyncio.TimeoutError:
            return False

    async def _conectar_con_reintento() -> bool:
        """Abre Mongo+PG, reintentando cada 10 s hasta conectar o parar."""
        nonlocal cliente, chofer_col, processed_col, conn
        intento = 0
        while True:
            if stop is not None and stop.is_set():
                return False
            intento += 1
            if not mongo_uri:
                logger.error(
                    "Outbox: No se pudo conectar a Mongo (MONGODB_URI no configurado)")
            else:
                try:
                    cliente, chofer_col, processed_col, conn = await asyncio.to_thread(_abrir)
                    logger.info("Outbox: conexiones listas (intento %s)", intento)
                    return True
                except Exception:
                    logger.exception(
                        "Outbox: No se pudo conectar a Mongo (intento %s)", intento)
            if await _esperar(10.0):
                return False

    if not await _conectar_con_reintento():
        logger.info("Outbox loop detenido (sin conexiones)")
        return

    logger.info(
        "Outbox loop iniciado (batch=%s sleep_vacio=%.1fs heartbeat=%.1fs umbral=%s)",
        app_config.OUTBOX_LOOP_BATCH_SIZE,
        app_config.OUTBOX_LOOP_SLEEP_EMPTY_S,
        app_config.OUTBOX_LOOP_HEARTBEAT_S,
        app_config.OUTBOX_LOOP_ALERT_PENDING,
    )

    ultimo_heartbeat = time.monotonic()
    fallos = 0
    try:
        while stop is None or not stop.is_set():
            try:
                stats = await asyncio.to_thread(
                    outbox_worker.procesar_lote,
                    conn,
                    chofer_col,
                    processed_col,
                    limite=max(1, int(app_config.OUTBOX_LOOP_BATCH_SIZE)),
                )
                fallos = 0
            except Exception:
                fallos += 1
                logger.exception("Outbox loop: error en pasada (fallo %s)", fallos)
                stats = {"tomados": 0}
                try:
                    conn.rollback()
                except Exception:
                    pass
                if fallos >= 3:
                    # La conexión puede estar muerta; reabrir en vez de girar
                    # sobre un socket roto durante horas.
                    logger.error("Outbox: No se pudo conectar a Mongo; reabriendo conexiones")
                    _cerrar()
                    if not await _conectar_con_reintento():
                        break
                    fallos = 0
                elif await _esperar(min(5.0, app_config.OUTBOX_LOOP_SLEEP_EMPTY_S)):
                    break
                continue

            ahora = time.monotonic()
            if (ahora - ultimo_heartbeat) >= app_config.OUTBOX_LOOP_HEARTBEAT_S:
                try:
                    pendientes = await asyncio.to_thread(outbox_worker.contar_pendientes, conn)
                except Exception:
                    logger.exception("Outbox loop: no se pudo contar pendientes")
                    pendientes = -1

                logger.info(
                    "Outbox heartbeat: pendientes=%s ultima_pasada=%s",
                    pendientes,
                    json.dumps(stats, ensure_ascii=False),
                )

                umbral = app_config.OUTBOX_LOOP_ALERT_PENDING
                sostenido = app_config.OUTBOX_LOOP_ALERT_SUSTAINED_S
                if pendientes > umbral:
                    if _outbox_alert_since is None:
                        _outbox_alert_since = ahora
                    if (ahora - _outbox_alert_since) >= sostenido:
                        msg = (
                            f"[CRITICO] Outbox: {pendientes} eventos pendientes sostenidos "
                            f"(umbral {umbral}, >={sostenido:.0f}s)"
                        )
                        logger.critical(msg)
                        await _outbox_enviar_alerta(msg)
                        _outbox_alert_since = ahora
                else:
                    _outbox_alert_since = None

                ultimo_heartbeat = ahora

            if int(stats.get("tomados", 0) or 0) == 0:
                if await _esperar(max(1.0, float(app_config.OUTBOX_LOOP_SLEEP_EMPTY_S))):
                    break
    except asyncio.CancelledError:
        logger.info("Outbox loop cancelado")
        raise
    finally:
        _cerrar()
        logger.info("Outbox loop detenido")


async def job_cuadre_diario() -> None:
    """Cuadre diario Mongo vs wallet_ledger (tolerante al outbox del chofer)."""
    mongo_uri = os.getenv("MONGODB_URI", "").strip()
    if not mongo_uri:
        logger.warning("Cuadre diario: MONGODB_URI no configurado")
        return

    def _ejecutar():
        from pymongo import MongoClient

        from app.wallet.backfill import comparar_cuadre

        cliente = MongoClient(mongo_uri, serverSelectionTimeoutMS=10000)
        try:
            col_cliente = cliente["Cliente"]["users"]
            col_chofer = cliente["Chofer"]["users"]
            init_pool()
            with get_connection() as conn:
                return comparar_cuadre(conn, col_cliente, col_chofer)
        finally:
            cliente.close()

    try:
        informe = await asyncio.to_thread(_ejecutar)
    except Exception:
        logger.exception("Cuadre diario: fallo al ejecutar")
        return

    pendientes_outbox = informe.get("pendientes_outbox_cents") or {}
    resumen = {
        "ok": informe.get("ok"),
        "diferencias": len(informe.get("diferencias", [])),
        "solo_en_postgres": len(informe.get("solo_en_postgres", [])),
        "tolerados_por_outbox": len(informe.get("tolerados_por_outbox", [])),
        "pendiente_outbox_cents": sum(pendientes_outbox.values()),
    }
    if informe.get("ok"):
        logger.info("Cuadre diario OK: %s", json.dumps(resumen, ensure_ascii=False))
    else:
        logger.error(
            "Cuadre diario con diferencias: %s",
            json.dumps(resumen, ensure_ascii=False),
        )


# ===================== Manejo de errores (sanitizado) =====================
from fastapi.responses import JSONResponse  # noqa: E402


_EXPOSE_ERROR_DETAILS = os.getenv("EXPOSE_ERROR_DETAILS", "0").strip().lower() in {
    "1", "true", "yes", "si", "on",
}


@app.exception_handler(Exception)
async def handler_500_generico(request, exc):
    # No exponer detalles internos al cliente; el traceback queda en logs del servidor.
    logger.exception("500 en %s %s", request.method, request.url.path)
    if _EXPOSE_ERROR_DETAILS:
        detalle = f"[{type(exc).__name__}] {exc}"
    else:
        detalle = "Error interno del servidor"
    return JSONResponse(status_code=500, content={"detail": detalle})


@app.post("/admin/init")
def admin_init(x_admin_token: str = Header(..., alias="X-Admin-Token")):
    """Fuerza la creacion de las 8 tablas. Protegido por ADMIN_INIT_TOKEN."""
    esperado = os.getenv("ADMIN_INIT_TOKEN")
    if not esperado:
        raise HTTPException(status_code=503, detail="ADMIN_INIT_TOKEN no esta definido")
    if not secrets.compare_digest(x_admin_token, esperado):
        raise HTTPException(status_code=401, detail="Token invalido")
    try:
        return {"status": "ok", **inicializar_bd()}
    except Exception as e:
        logger.exception("POST /admin/init fallo")
        raise HTTPException(status_code=500, detail=str(e))


@app.on_event("startup")
async def startup_event():
    logger.info("=== INICIANDO APLICACIÓN ===")
    # Inicializacion resiliente de la BD: si una base falla, la app arranca
    # igualmente y el job de reintento la termina de levantar.
    for _nombre, _fn in (
        ("init_pool", init_pool),
        ("init_db", init_db),
        ("init_wallet_db", billetera.init_wallet_db),
    ):
        try:
            _fn()
        except Exception:
            logger.warning("Fallo al inicializar %s en el arranque; se reintentara",
                           _nombre, exc_info=True)

    # Traccar listener (lo que ya tenias)
    asyncio.create_task(listen_traccar())

    # Base de calles lista para el buscador "entre": en produccion puede faltar
    # geom_geojson/indice 2dsphere (la migracion se corre aqui, sin bloquear).
    async def _migrar_calles():
        while True:
            try:
                resumen = await asyncio.to_thread(geo.asegurar_geometrias)
                if not resumen.get("pendientes"):
                    logger.info("Geo.calles lista: %s", resumen)
                    return
                logger.warning("Geo.calles migrando: %s", resumen)
            except Exception:
                logger.warning("No se pudo migrar Geo.calles; reintento",
                               exc_info=True)
            await asyncio.sleep(30)

    asyncio.create_task(_migrar_calles())

    # Indice unico del vinculo con Telegram. Se asegura aqui y no al importar el
    # modulo: si el indice no se puede crear por datos duplicados, el bot sigue
    # funcionando y solo queda el aviso en el log.
    try:
        telegram_webhook.asegurar_indice_telegram()
    except Exception:
        logger.warning("No se pudo asegurar el indice de telegram_chat_id",
                       exc_info=True)

    # Telefono unico en choferes y pasajeros. Impide dar de alta dos cuentas con
    # el mismo numero. Si ya hay repetidos, avisa en el log con cuales y sigue:
    # es un problema de datos que se resuelve a mano, no un fallo de arranque.
    try:
        indices.asegurar_indices_de_identidad()
    except Exception:
        logger.warning("No se pudieron asegurar los indices de identidad",
                       exc_info=True)

    # Publica los comandos del bot en el menu de Telegram. Solo si el bot esta
    # configurado: sin token no hay a quien preguntar. Si falla, el bot sigue
    # funcionando, solo que el movil no sugiere los comandos.
    if os.getenv("TELEGRAM_BOT_TOKEN"):
        try:
            asyncio.create_task(telegram_webhook._registrar_comandos(
                telegram_webhook._cliente()))
        except Exception:
            logger.warning("No se pudieron publicar los comandos del bot",
                           exc_info=True)

    # Outbox loop in-process (requiere uvicorn --workers 1). Se encola ANTES
    # del scheduler: un fallo de APScheduler no debe impedir que arranque.
    global _outbox_stop_event, _outbox_task, _outbox_alert_since
    _outbox_stop_event = None
    _outbox_task = None
    _outbox_alert_since = None
    try:
        if app_config.OUTBOX_WORKER_ENABLED:
            _outbox_stop_event = asyncio.Event()
            _outbox_task = asyncio.create_task(_outbox_loop(), name="outbox-loop")
            logger.info("Outbox loop encolado (OUTBOX_WORKER_ENABLED=1)")
        else:
            # Log explicito para diagnosticar en Render si el flag no llego.
            logger.info("Outbox loop desactivado (OUTBOX_WORKER_ENABLED=0)")
    except Exception:
        logger.exception("Error inicializando Outbox")

    # Scheduler: expiracion de viajes + autorreparacion de tablas + cuadre diario
    scheduler.add_job(sweep_expired_trips, "interval", seconds=15, id="sweep_expired_trips")
    try:
        if tablas_faltantes():
            scheduler.add_job(job_reintento_bd, "interval", seconds=60, id="reintento_bd")
            logger.warning("Faltan tablas en la BD; job de reintento cada 60 s activo")
    except Exception:
        scheduler.add_job(job_reintento_bd, "interval", seconds=60, id="reintento_bd")
        logger.warning("No se pudo comprobar las tablas al arrancar; job de reintento activo",
                       exc_info=True)
    try:
        scheduler.add_job(
            job_cuadre_diario,
            CronTrigger(hour=4, minute=30, timezone=CUBA_TZ),
            id="cuadre_diario",
            replace_existing=True,
        )
    except Exception:
        logger.exception("No se pudo programar el cuadre diario")
    try:
        scheduler.start()
        logger.info("Scheduler de expiracion de viajes iniciado")
    except Exception:
        logger.exception("No se pudo iniciar el scheduler (el outbox sigue activo)")


@app.on_event("shutdown")
async def shutdown_event():
    global _outbox_stop_event, _outbox_task
    if _outbox_stop_event:
        _outbox_stop_event.set()
    if _outbox_task:
        _outbox_task.cancel()
        try:
            await _outbox_task
        except asyncio.CancelledError:
            pass
        except Exception:
            logger.exception("Error al detener outbox loop")
    if scheduler.running:
        scheduler.shutdown()