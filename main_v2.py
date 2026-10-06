from fastapi import FastAPI
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
from services.traccar_listener import listen_traccar

# Funciones que necesitamos del modulo de viajes
from routers.Solicitud_de_viajes_v4 import (
    get_connection,
    publish_trip_event,
    init_pool,
    init_db,
    TRIP_ACCEPT_TIMEOUT_SECS,
)

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

# Tabla de conteo de cancelaciones por chofer y dia.
chofer_cancelaciones.asegurar_tabla_cancelaciones()

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


@app.on_event("startup")
async def startup_event():
    # Inicializacion de la BD de viajes
    init_pool()
    init_db()
    billetera.init_wallet_db()

    # Traccar listener (lo que ya tenias)
    asyncio.create_task(listen_traccar())

    # Arrancar scheduler de expiracion
    scheduler.add_job(sweep_expired_trips, "interval", seconds=30)
    scheduler.start()
    logger.info("Scheduler de expiracion de viajes iniciado")


@app.on_event("shutdown")
async def shutdown_event():
    if scheduler.running:
        scheduler.shutdown()