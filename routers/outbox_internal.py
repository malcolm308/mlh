"""Trigger manual del outbox (uso operativo, sin cron externo)."""

from __future__ import annotations

import asyncio
import os

from fastapi import APIRouter, Header, HTTPException

from app import config
from app.outbox import worker

router = APIRouter(tags=["internal"])


@router.post("/internal/outbox/run", include_in_schema=False)
async def run_outbox_once(
    x_cron_secret: str | None = Header(default=None, alias="X-Cron-Secret"),
):
    esperado = (config.OUTBOX_CRON_SECRET or "").strip()
    recibido = (x_cron_secret or "").strip()
    if not esperado or recibido != esperado:
        raise HTTPException(status_code=403, detail="forbidden")

    mongo_uri = os.getenv("MONGODB_URI", "").strip()
    if not mongo_uri:
        raise HTTPException(status_code=503, detail="MONGODB_URI no configurado")

    def _run() -> dict:
        cliente, chofer_col, processed_col = worker.conectar_mongo(mongo_uri)
        worker.asegurar_indice(processed_col)
        conn = worker.conectar_pg()
        try:
            stats = worker.procesar_lote(
                conn,
                chofer_col,
                processed_col,
                limite=max(1, int(config.OUTBOX_LOOP_BATCH_SIZE)),
            )
            stats["pendientes_total"] = worker.contar_pendientes(conn)
            return stats
        finally:
            try:
                conn.close()
            finally:
                cliente.close()

    stats = await asyncio.to_thread(_run)
    return {"status": "ok", **stats}
