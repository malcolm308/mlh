"""Feature flags y configuración de la migración dual Postgres + Mongo.

Todos los flags se leen del entorno y arrancan **apagados/sin corte** para no
cambiar el comportamiento actual al desplegar.

| Flag | Efecto |
|------|--------|
| `WALLET_DUAL_WRITE` | además de Mongo, escribe ledger/holds/outbox |
| `WALLET_READ_SOURCE` | `mongo` (actual) o `postgres` para leer saldos |
| `WALLET_ENFORCE_HOLD` | exige hold y devuelve 402 si no alcanza |
| `WALLET_LEGACY_MONGO_WRITES` | si es `0`, deja de escribir `Fondo` en Mongo |
| `OUTBOX_WORKER_ENABLED` | arranca el loop in-process del outbox en la app |
| `ZONAS_LEGACY_FALLBACK` | si es `0`, el pricing no vuelve al JSON de `promociones` cuando falla `zones` |
"""
from __future__ import annotations

import os

_VERDADEROS = {"1", "true", "yes", "si", "on"}


def _flag(nombre: str, defecto: str = "0") -> bool:
    return os.getenv(nombre, defecto).strip().lower() in _VERDADEROS


def _entero(nombre: str, defecto: int, *, minimo: int, maximo: int) -> int:
    try:
        valor = int(os.getenv(nombre, str(defecto)).strip())
    except Exception:
        valor = defecto
    return max(minimo, min(maximo, valor))


def _flotante(nombre: str, defecto: float, *, minimo: float, maximo: float) -> float:
    try:
        valor = float(os.getenv(nombre, str(defecto)).strip())
    except Exception:
        valor = defecto
    return max(minimo, min(maximo, valor))


WALLET_DUAL_WRITE = _flag("WALLET_DUAL_WRITE")
WALLET_ENFORCE_HOLD = _flag("WALLET_ENFORCE_HOLD")
WALLET_LEGACY_MONGO_WRITES = _flag("WALLET_LEGACY_MONGO_WRITES", "1")
OUTBOX_WORKER_ENABLED = _flag("OUTBOX_WORKER_ENABLED")

#: Transición T5: mientras sea 1, si `zones` no está disponible el pricing
#: vuelve al polígono JSON de `promociones`. Poner 0 tras validar la migración
#: para que TODA decisión de zona venga de Postgres.
ZONAS_LEGACY_FALLBACK = _flag("ZONAS_LEGACY_FALLBACK", "1")

#: `mongo` mientras la migración no esté cerrada.
WALLET_READ_SOURCE = os.getenv("WALLET_READ_SOURCE", "mongo").strip().lower()

# --- Outbox loop in-process (Render Starter, uvicorn --workers 1) ---
OUTBOX_LOOP_BATCH_SIZE = _entero("OUTBOX_LOOP_BATCH_SIZE", 100, minimo=1, maximo=100)
OUTBOX_LOOP_SLEEP_EMPTY_S = _flotante("OUTBOX_LOOP_SLEEP_EMPTY_S", 5.0, minimo=1.0, maximo=30.0)
OUTBOX_LOOP_HEARTBEAT_S = _flotante("OUTBOX_LOOP_HEARTBEAT_S", 60.0, minimo=10.0, maximo=600.0)
OUTBOX_LOOP_ALERT_PENDING = _entero("OUTBOX_LOOP_ALERT_PENDING", 500, minimo=1, maximo=1_000_000)
OUTBOX_LOOP_ALERT_SUSTAINED_S = _flotante(
    "OUTBOX_LOOP_ALERT_SUSTAINED_S", 60.0, minimo=10.0, maximo=3600.0)

#: Secreto para el trigger manual POST /internal/outbox/run (X-Cron-Secret).
OUTBOX_CRON_SECRET = os.getenv("OUTBOX_CRON_SECRET", "").strip()
