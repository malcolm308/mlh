# Despliegue y cierre — Migración dual Postgres (wallet/ledger/outbox) + Mongo (read-model)

> Estado del código: T0–T4, T5 (zonas PostGIS), T6 (expiración/cron + outbox in-process) y ajustes de hardening/corte parcial implementados y probados localmente.  
> **No cubre acceso a producción:** aplicar en Supabase/Render, activar `pg_cron`, configurar secretos/envs reales y validar con datos reales debe hacerse en el entorno objetivo.

## 1. Pre-despliegue
- [ ] Revisar y commitear los cambios del repositorio (código, migraciones, scripts, tests, docs, apps Flutter).
- [ ] Backup de Postgres (Supabase) y datos relevantes en Mongo.
- [ ] Confirmar disponibilidad de extensiones: `postgis`, `pg_cron` (y permisos de `cron.schedule` si aplica).

## 2. Migraciones en Postgres (orden)
Ejecutar contra la BD objetivo:
1. [ ] `migrations/0001_wallet_core.sql` (si no aplicada).
2. [ ] `migrations/0002_zones_postgis.sql`.
3. [ ] `python scripts/migrar_zonas_postgis.py` (`--dry-run` opcional). Validar `airport_special` y `ST_Contains` dentro/fuera.
4. [ ] `migrations/0003_holds_expiry_pgcron.sql`.
   - [ ] Verificar: `SELECT * FROM cron.job WHERE jobname = 'expirar_holds_y_viajes';`
   - [ ] Si no se programó, crear schedule manual/UI: cada minuto `SELECT * FROM expirar_holds_y_viajes(500);`
   - [ ] Prueba: `SELECT * FROM expirar_holds_y_viajes(500);`
5. [ ] `migrations/0004_commission_discount_claims.sql`.

Rollbacks: `migrations/*_rollback.sql` (no revierten datos ya procesados/expirados; rollback de 0002 elimina `zones`).

## 3. Configuración del servicio (Render, transición segura)
- **Comando:** `uvicorn ... --workers 1` (requerido para el loop outbox in-process).
- **Base/flags (sin cambiar comportamiento de dinero):**
  - `POSTGRES_URL` (o `DB_*`), `MONGODB_URI`
  - `WALLET_DUAL_WRITE=1`
  - `WALLET_ENFORCE_HOLD=0`
  - `WALLET_LEGACY_MONGO_WRITES=1`
  - `WALLET_READ_SOURCE=mongo`
- **Outbox:** `OUTBOX_WORKER_ENABLED=1`, `OUTBOX_LOOP_BATCH_SIZE=100`, `OUTBOX_LOOP_SLEEP_EMPTY_S=5`, `OUTBOX_LOOP_HEARTBEAT_S=60`, `OUTBOX_LOOP_ALERT_PENDING=500`, `OUTBOX_LOOP_ALERT_SUSTAINED_S=60`, `OUTBOX_CRON_SECRET=<secreto>`
- **Hardening:** `CORS_ALLOWED_ORIGINS=<orígenes>`, `RATE_LIMIT_PER_MINUTE=100`, `EXPOSE_ERROR_DETAILS=0` (ajustar `CORS_ALLOW_*` si aplica)
- **Alertas (opcional):** configuración Telegram existente para envío a admins.

## 4. Verificación en entorno desplegado
- [ ] **Outbox loop:** heartbeats cada minuto, pendientes estables/decrecientes, sin backlog sostenido > umbral.
- [ ] **Trigger manual:** `POST /internal/outbox/run` con `X-Cron-Secret` devuelve stats.
- [ ] **Expiración (pg_cron):** holds vencidas → `expirada`, viajes `requested` → `expired`, eventos `trip.status_changed` en outbox (incluso con web caído); eventos procesados al volver la app.
- [ ] **Cuadre diario:** job 04:30 (America/Havana) ejecuta y registra resultado.
- [ ] **Cuadre manual:** `python scripts/verificar_cuadre.py`
  - Cliente: 0 diferencias (estricto).
  - Chofer: tolera pendientes/error del outbox; usar `--estricto` con cola vacía.
- [ ] **Zonas:** estimate/create/complete correctos dentro/fuera de zona (`ST_Contains`).
- [ ] **Seguridad:** CORS efectivo, rate limit (429), respuestas 500 sin detalles internos.

## 5. Rollout progresivo (tras cuadre estable)
Avanzar una etapa a la vez, observando cuadre/métricas:
1. [ ] `WALLET_ENFORCE_HOLD=1`
2. [ ] `WALLET_LEGACY_MONGO_WRITES=0` (chofer vía ledger/outbox/worker)
3. [ ] `WALLET_READ_SOURCE=postgres`

Criterios en cada paso: sin saldos negativos, sin doble cobro, idempotencia en reprocesos, cuadre consistente.

## 6. Cierre y limpieza (post-validación en producción)
- [ ] **Precios de zona:** `scripts/init_prices_usd.py` y `scripts/update_daily_prices.py` sincronizan `zones` desde `promociones`; re-sincronizar si hay cambios fuera del router.
- [ ] **Legacy zonas:** retirar campos `zona_especial_*` de `promociones` y fallback solo tras validación.
- [ ] **`driver.payout`:** actualmente encola evento con `mongo_aplicado=True` (sin movimiento de saldo); definir/cablear semántica financiera si debe aplicarse.
- [ ] **Auxiliares restantes:** completar alineación de estados/escrituras auxiliares aún en Mongo según modelo final (p. ej. flujos específicos de transferencias/bonos/cliente) validando con cuadre.
- [ ] **Hardening:** ampliar validación Pydantic estricta y políticas de no-log/PII al resto de la API según necesidad.

## 7. Pendiente de definición
- [ ] **Tarea 7:** alcance no especificado.

## Verificaciones locales ya realizadas (referencia)
- `python -m py_compile` de módulos modificados principales.
- Suites: `tests.test_outbox_worker`, `tests.test_wallet_*`, `tests.test_backfill_cuadre`, `tests.test_tarifas_espera`, `tests.test_zones_postgis`, `tests.test_holds_expiry` (118 pruebas OK en entorno local con Postgres de pruebas).
- Migraciones 0002/0004 aplicadas y validadas en `taxi_db_test`; `0003` validada por función en pruebas.