from fastapi import FastAPI, Header, HTTPException
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from fastapi.middleware.cors import CORSMiddleware

from routers import billetera
from routers import CRUD_MONGODB
from routers import Solicitud_de_viajes_v4
from routers import admin_panel
from routers import documentos
from routers import pois
from routers import geo
from routers import routing
from routers import vehiculos
from routers import chofer_cancelaciones
from routers import tariffs
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

app = FastAPI()

# ---- CORS (pruebas locales: flutter web en otro puerto) ----
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---- Routers ----
# El panel de administracion va antes que CRUD_MONGODB: si no, el GET /admin/{id}
# se traga las rutas /admin/choferes, /admin/trips, etc.
app.include_router(admin_panel.router)
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

# Tabla de conteo de cancelaciones por chofer y dia. Si la BD no responde, la
# app arranca igualmente: lo reintentan el startup y el job de APScheduler.
try:
    chofer_cancelaciones.asegurar_tabla_cancelaciones()
except Exception:
    logger.warning("No se pudo asegurar la tabla de cancelaciones en el import; se reintentara",
                   exc_info=True)

# ---- Scheduler para expiracion de viajes ----
scheduler = AsyncIOScheduler(timezone="America/Havana")


async def sweep_expired_trips():
    """
    Marca como 'expired' los viajes 'requested' que superaron el timeout
    de aceptacion. Se ejecuta cada 30s.
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
    "wallet_movements", "driver_cancellations",
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
    """Liveness: solo confirma que la app arranco (sin tocar las bases)."""
    return {"status": "ok"}


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

    # Scheduler: expiracion de viajes + autorreparacion de tablas
    scheduler.add_job(sweep_expired_trips, "interval", seconds=30, id="sweep_expired_trips")
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