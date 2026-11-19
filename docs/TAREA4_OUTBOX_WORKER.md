# Tarea 4 — Worker Outbox → MongoDB (idempotente) y reparto congelado

> Estado: **completada en código y pruebas locales** (no desplegada).
> Fecha: 2026-11-19

## Objetivo

Cerrar la consistencia eventual del saldo del chofer sin falsos positivos en el
cuadre, aplicando los eventos de dinero en MongoDB desde el outbox de
PostgreSQL y moviendo el cálculo del reparto al momento previo al `COMMIT`.

## Archivos tocados / creados

| Archivo | Estado | Contenido |
|---|---|---|
| `app/outbox/events.py` | modificado | `TripCompletedV2` (schema v2) con reparto completo en centavos, `DriverPayoutV1`, `MODELOS` ampliado y validación estricta en `encolar()` |
| `app/outbox/worker.py` | nuevo | Worker Postgres→Mongo: claim con `FOR UPDATE SKIP LOCKED`, lease, backoff exponencial, procesamiento por lote y CLI (`--una-pasada`/`--loop`) |
| `app/wallet/service.py` | modificado | `acreditar_chofer_viaje()` escribe en el ledger los asientos del chofer (`captura_viaje` + `comision`) con claves idempotentes por viaje |
| `app/wallet/backfill.py` | modificado | `pendientes_outbox()` y `comparar_cuadre(..., tolerar_outbox=True)` para tolerar eventos pendientes/errores del chofer |
| `scripts/verificar_cuadre.py` | modificado | Tolerancia outbox por defecto, flag `--estricto`, resumen con `tolerados_por_outbox` y `pendiente_outbox_cents` |
| `routers/Solicitud_de_viajes_v4.py` | modificado | `_calcular_reparto_viaje()` (puro, antes del commit), `get_daily_trip_count`/`resolve_commission` con `incluir_actual`, refactor de `complete_trip` |
| `tests/test_outbox_worker.py` | nuevo | Worker, idempotencia, backoff/error, ledger de chofer, cuadre tolerante y reparto congelado (17 tests) |

## Diseño aplicado

### 1. Reparto congelado antes del `COMMIT`

En `complete_trip`, cuando `WALLET_DUAL_WRITE` está activo:

1. Se calcula el reparto exacto con `_calcular_reparto_viaje(...)` **antes** del
   `COMMIT` (precio, promo/saldo real, excedente, bono, crédito al chofer,
   comisión y neto), usando la captura real del hold cuando aplica.
2. Se registran en PostgreSQL, en la misma transacción, los asientos del chofer:
   - `trip:{trip_id}:chofer_credito` → `+chofer_credito_cents` (`captura_viaje`)
   - `trip:{trip_id}:comision` → `-comision_cents` (`comision`)
3. Se encola `trip.completed` (schema v2) con el JSON del reparto completo y
   `mongo_aplicado = WALLET_LEGACY_MONGO_WRITES`.
4. `COMMIT`.

El **worker no calcula dinero**: solo aplica el neto que llega en el payload.

Para no romper la regla del tercer viaje al calcular antes de persistir el
conteo, `resolve_commission(..., incluir_actual=True)` suma el viaje que se está
cerrando (`get_daily_trip_count(..., incluir_actual=True)`).

Si Mongo no responde al leer el cliente durante el reparto, el cierre no se
aborta: se degrada a lo capturado en PostgreSQL (sin separar promo/saldo real,
sin bono) y el desfase queda visible en el cuadre.

### 2. Worker idempotente (Outbox → Mongo)

- **Claim**: `UPDATE outbox ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED)`
  toma un evento pendiente vencido y le fija un lease (`next_retry_at`). Varios
  workers pueden correr sin pisarse.
- **Idempotencia en Mongo**: antes de mover dinero se inserta `event_id` en
  `processed_events` (colección `Chofer`, índice único `ux_processed_event_id`).
  - inserción OK → aplica el movimiento;
  - `DuplicateKeyError` → el evento ya fue procesado: se omite el `$inc` y solo
    se marca `procesado` en Postgres.
- **Movimiento atómico**: `trip.completed` hace
  `$inc: {"Fondo": chofer_neto_cents}` (neto ya calculado en Postgres);
  `driver.payout` hace `$inc: {"Fondo": -monto_cents}`.
- **`mongo_aplicado=True`**: el worker no toca `Fondo` y marca el evento como
  procesado (el camino legacy ya lo aplicó).
- **Reintentos**: backoff exponencial (30s, 60s, 120s, …, máx 1h). Al agotar
  `MAX_INTENTOS=8` el evento pasa a `estado='error'` con `last_error` (no se
  descarta). Los errores transitorios vuelven a `pendiente`.

### 3. Gating del camino legacy

- **Cliente (Mongo)**: sigue siendo **síncrono** en `complete_trip` (descuento
  de `saldo_promocional`/`Fondo`) para mantener cuadre estricto y compatibilidad.
- **Chofer (Mongo `Fondo`)**: cuando `WALLET_LEGACY_MONGO_WRITES=0`, el abono y
  la comisión del chofer dejan de escribirse en línea y los aplica el worker a
  partir del evento V2 (`mongo_aplicado=False`). Con el flag en `1` (defecto), se
  mantiene el comportamiento histórico y el evento viaja con `mongo_aplicado=True`.
- **Postgres**: el reparto/asientos del chofer y el evento V2 se generan con
  `WALLET_DUAL_WRITE=1` (independiente del legacy de Mongo).

### 4. Cuadre tolerante al outbox

`scripts/verificar_cuadre.py`:

- **Cliente**: diferencia estricta 0.
- **Chofer**: se suma al saldo de Mongo el ajuste de eventos `pendiente`/`error`
  no aplicados (`mongo_aplicado=false`) de tipo:
  - `trip.completed` → `+chofer_neto_cents`
  - `driver.payout` → `-monto_cents`
  Si `Mongo + pendiente_outbox == Postgres`, el cuadre es OK (tolerado).
- `--estricto` desactiva la tolerancia (útil para diagnóstico puntual).

> Nota: `driver_payouts` no tiene productor de `driver.payout` todavía; la
> tolerancia y el worker están listos, pero no se cableó para no cambiar
> comportamiento.

## Cómo ejecutar

```bash
# Tests (requieren TEST_POSTGRES_URL y TEST_MONGODB_URI)
python -m unittest tests.test_outbox_worker -v
python -m unittest tests.test_wallet_schema tests.test_backfill_cuadre tests.test_wallet_service tests.test_wallet_api tests.test_outbox_worker

# Cuadre (tolerante por defecto)
python scripts/verificar_cuadre.py
python scripts/verificar_cuadre.py --estricto

# Worker
python -m app.outbox.worker --una-pasada
python -m app.outbox.worker --loop
python -m app.outbox.worker --mongo-prefix test_ --una-pasada   # solo pruebas
```

## Resultados de pruebas (local)

- `tests.test_outbox_worker`: **17/17 OK**.
- `tests.test_wallet_schema`, `test_backfill_cuadre`, `test_wallet_service`,
  `test_wallet_api`: **44/44 OK**.
- Suite combinada (wallet + outbox): **61/61 OK** (55 + 6 reparto añadidos en
  la corrida final de outbox; ver logs de ejecución).

`tests.test_tarifas_espera`: 6 errores preexistentes de entorno en la BD de
pruebas (`promociones` sin columna `comision_billetera` en el esquema de ese
test DB), no relacionados con Tarea 4.

## Limitaciones y siguientes pasos

- **`driver.payout` sin productor**: no se emite aún desde `driver_payouts`.
- **`commit_commission` / `claim_commission_discount`** siguen escribiendo en
  Mongo (descuento del 3er viaje, `last_commission_discount_date`); su
  migración completa y el corte `WALLET_LEGACY_MONGO_WRITES=0` requieren
  validar el worker en entorno real y ajustar esas escrituras auxiliares.
- **Refactor de `complete_trip`**: el cierre sigue commiteando el viaje antes de
  la lógica de dinero/post-commit legacy en algunos tramos; el reparto/evento
  nuevo queda en la transacción del cierre, pero conviene seguir simplificando
  el flujo.
- **`tests/test_tarifas_espera`**: alinear el esquema de `promociones` en la BD
  de pruebas con las columnas actuales para recuperar esos 6 casos.
- Siguiente: **Tarea 5** (`streets` + GiST) y **Tarea 6** (cron de
  `expirar_holds`/cuadre con APScheduler; `pg_cron` no disponible).
