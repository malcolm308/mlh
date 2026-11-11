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
from routers import tiempo_real
from routers import app_init
from services import indices
from services.traccar_listener import listen_traccar

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
import sys

# La consola de Windows usa cp1252: cualquier print con emoji/acento hacia que
# la salida se redirija a un archivo revienta el arranque. Se fuerza UTF-8.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

logger = logging.getLogger(__name__)

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

# ---- CORS (pruebas locales: flutter web en otro puerto) ----
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
# ---- GZip ----
# El territorio manda: desde Cuba cada JSON viaja por 3G/GPRS, y las respuestas
# de listas (ofertas, historial, tarifas) pesan 3-6x lo necesario sin comprimir.
# El cliente de Dart (package:http con HttpClient) ya declara
# `Accept-Encoding: gzip` y descomprime solo, asi que no hace falta tocar
# nada en las apps para beneficiarse. Brotli NO se anuncia: dart:io no
# descomprime br de forma transparente y se romperia.
app.add_middleware(GZipMiddleware, minimum_size=1024)

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
app.include_router(tiempo_real.router)

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


# ===================== DIAGNOSTICO DE 500 =====================
# Temporal: el 500 generico de FastAPI se come el mensaje y desde el movil no
# hay forma de saber QUE endpoint y por que fallo. Con este handler el snackbar
# de la app muestra `TipoError: mensaje` y el despliegue se depura en un solo
# intento. Quitar cuando la causa del 500 este cerrada.
from fastapi.responses import JSONResponse  # noqa: E402


@app.exception_handler(Exception)
async def handler_500_generico(request, exc):
    logger.exception("500 en %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=500,
        content={"detail": f"[{type(exc).__name__}] {exc}"},
    )


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

    # Scheduler: expiracion de viajes + autorreparacion de tablas
    scheduler.add_job(sweep_expired_trips, "interval", seconds=15, id="sweep_expired_trips")
    try:
        if tablas_faltantes():
            scheduler.add_job(job_reintento_bd, "interval", seconds=60, id="reintento_bd")
            logger.warning("Faltan tablas en la BD; job de reintento cada 60 s activo")
    except Exception:
        scheduler.add_job(job_reintento_bd, "interval", seconds=60, id="reintento_bd")
        logger.warning("No se pudo comprobar las tablas al arrancar; job de reintento activo",
                       exc_info=True)
    scheduler.start()
    logger.info("Scheduler de expiracion de viajes iniciado")


@app.on_event("shutdown")
async def shutdown_event():
    if scheduler.running:
        scheduler.shutdown()