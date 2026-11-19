# Tarea 6 — Expiración de holds (pg_cron) y cuadre diario (APScheduler)

## 1) Expiración de holds y viajes (Postgres / pg_cron, Supabase)

### Migración
- `migrations/0003_holds_expiry_pgcron.sql` (idempotente, transaccional en DDL/función)
  - `CREATE EXTENSION IF NOT EXISTS pg_cron`
  - Función `expirar_holds_y_viajes(p_limite integer DEFAULT 500)`:
    - Selecciona holds `estado='activa'` vencidas (`expires_at <= NOW()`) con `FOR UPDATE SKIP LOCKED`.
    - Marca holds como `expirada`.
    - Marca viajes asociados como `expired` **solo si** `status='requested'` (timeout/no aceptación). No afecta viajes en curso.
    - Inserta evento `trip.status_changed` (schema v1, `status='expired'`) en `outbox` por cada viaje expirado.
    - Retorna conteos `(holds_expirados, viajes_expirados, eventos_encolados)`.
  - Programa `cron.schedule('expirar_holds_y_viajes', '* * * * *', 'SELECT * FROM expirar_holds_y_viajes(500);')` (reprograma si ya existe). Si `pg_cron` no está disponible/permisos, la función queda creada (NOTICE) para ejecución/programación manual.
- Rollback: `migrations/0003_holds_expiry_pgcron_rollback.sql` (unschedule, drop function, limpia `schema_migrations`).

### Garantías
- Funciona en BD aunque el servicio web (Render) esté caído.
- Idempotente por estado: re-ejecuciones no re-expiran ni re-encolan lo ya procesado.
- No libera saldo insertando asientos: un hold no activo deja de contar en `saldo_disponible()`.

### Operación
- Requiere `pg_cron` habilitado en Supabase. Verificar: `SELECT * FROM cron.job WHERE jobname='expirar_holds_y_viajes';`
- Prueba manual: `SELECT * FROM expirar_holds_y_viajes(500);`

## 2) Cuadre diario (APScheduler en app, 04:30)

- `main_v2.py`: job `cuadre_diario` con `CronTrigger(hour=4, minute=30, timezone=America/Havana)`.
- Ejecuta `app.wallet.backfill.comparar_cuadre` (Mongo `Cliente.users`/`Chofer.users` vs `wallet_ledger` en Postgres).
- **Tolerante al outbox del chofer**: cliente estricto; chofer ajusta por eventos `trip.completed`/`driver.payout` pendientes o en error (`mongo_aplicado=False`).
- Registra resumen en logs (`OK` o `ERROR` con conteos). Requiere `MONGODB_URI` y Postgres accesible.

## 3) Outbox in-process (Render Starter) y trigger manual

- Loop `asyncio` en lifespan (`main_v2.py`) controlado por `OUTBOX_WORKER_ENABLED=1` (requiere `uvicorn --workers 1`).
  - `app/outbox/worker.py`: claim `FOR UPDATE SKIP LOCKED` con lease, backoff, `MAX_INTENTOS`, idempotencia por `processed_events` (insert antes de `$inc` atómico).
  - Lote configurable (`OUTBOX_LOOP_BATCH_SIZE`, def. 100), sleep si cola vacía (`OUTBOX_LOOP_SLEEP_EMPTY_S`, def. 5s).
  - Heartbeat cada `OUTBOX_LOOP_HEARTBEAT_S` (def. 60s) con pendientes.
  - Alerta si pendientes > `OUTBOX_LOOP_ALERT_PENDING` (def. 500) sostenidos `OUTBOX_LOOP_ALERT_SUSTAINED_S` (def. 60s): log crítico y, si hay integración/config Telegram, envío a admins.
  - Shutdown limpio al detener la app.
- Trigger manual: `POST /internal/outbox/run` (`routers/outbox_internal.py`, `include_in_schema=False`) con header `X-Cron-Secret` == `OUTBOX_CRON_SECRET`; ejecuta una pasada y devuelve stats.
- CLI: `python -m app.outbox.worker --una-pasada|--loop` (útil para tests/operación).

## Configuración relevante (env)
- `OUTBOX_WORKER_ENABLED`, `OUTBOX_LOOP_BATCH_SIZE`, `OUTBOX_LOOP_SLEEP_EMPTY_S`, `OUTBOX_LOOP_HEARTBEAT_S`, `OUTBOX_LOOP_ALERT_PENDING`, `OUTBOX_LOOP_ALERT_SUSTAINED_S`, `OUTBOX_CRON_SECRET`
- `MONGODB_URI`, `POSTGRES_URL`/`DB_*`, flags `WALLET_*`

## Notas
- La expiración por pg_cron es la fuente de verdad aunque la app esté caída. El loop in-process procesa el outbox (incluye eventos generados por la expiración) cuando la app está arriba.