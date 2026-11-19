# FASE 0 — Auditoría de seguridad + Tarea 0 — Inspección real del repo

> Documento de trabajo **previo a tocar código**. Nada de lo aquí descrito se ha aplicado.
> Repo: `E:\Taxi_Rapid` · commit base: `a6df3c3` · Backend prod: `https://rapitaxi-api-fws6.onrender.com`
>
> Leyenda: **[T]** = tenemos · **[F]** = falta · **[?]** = no verificable desde el repositorio (requiere dashboard).

---

## 1. Bases de datos — acceso de red y privilegios mínimos

| # | Punto | Estado | Evidencia |
|---|-------|--------|-----------|
| 1.1 | Credenciales fuera del repo | **[T]** parcial | `POSTGRES_URL`, `DB_PASSWORD`, `MONGODB_URI`, `REDIS_URL` se leen de entorno (`routers/Solicitud_de_viajes_v4.py:447-456`). `.env.local` está ignorado por git y solo tiene esas 4 claves. |
| 1.2 | Allowlist de IP en Atlas | **[?]** | No hay nada en el repo que lo declare ni lo controle. Depende del dashboard de Atlas. |
| 1.3 | Allowlist / restricción de red en Supabase | **[?]** | El DSN viene de `POSTGRES_URL`. Supabase no ofrece allowlist de IP en el pooler (PgBouncer); se controla con SSL + contraseña + RLS. Verificable solo en dashboard. |
| 1.4 | Usuario de Postgres con privilegios mínimos | **[F]** | El DSN de Supabase normalmente usa el rol `postgres` (superusuario del proyecto). El código **no** crea ni usa un rol de aplicación (`app_wallet`). |
| 1.5 | Usuario de Mongo con privilegios mínimos | **[F]** | No hay evidencia de un usuario dedicado. Si `MONGODB_URI` usa el usuario admin de Atlas, un leak da control total del cluster. |
| 1.6 | TLS obligatorio | **[T]** parcial | Atlas obliga TLS. En Postgres no se fuerza `sslmode=require` en código; se confía en el DSN. |
| 1.7 | Rotación de contraseñas | **[F]** | No hay procedimiento documentado ni fecha de rotación. |

**Riesgo real:** Render (plan actual) **no tiene IP de salida fija**, así que una allowlist estricta en Atlas rompería producción. Opciones: (a) plan de Render con static outbound IPs, (b) allowlist amplia + TLS + usuario dedicado con `readWrite` solo sobre `Cliente`, `Chofer`, `Administración`, `Geo`, (c) Atlas Private Endpoint (requiere plan dedicado).

**Acción propuesta (no bloquea Tareas 1-7, sí la Fase Final):**
- Crear rol PG `app_wallet` (sin `SUPERUSER`, sin `CREATEROLE`; `CONNECT` en `taxi_db`, `USAGE` en `public`, `SELECT/INSERT/UPDATE` solo en `trips`, `wallet_*`, `outbox`, `tariffs`, `transactions`, `wallet_movements`). El DDL de migraciones se corre con el rol admin, la app corre con `app_wallet`.
- Crear usuario Mongo `rapitaxi_app` con `readWrite` sobre las 4 bases, `SCRAM-SHA-256`, contraseña de 64+ chars.
- Documentar en `docs/REPORTE_SEGURIDAD.md` con capturas de los dashboards.

---

## 2. Backend — Rate limiting

| # | Punto | Estado | Evidencia |
|---|-------|--------|-----------|
| 2.1 | Librería de límites instalada | **[F]** | `requirements.txt` no tiene `slowapi` ni `limits`. |
| 2.2 | Middleware activo | **[F]** | `grep -i "slowapi\|Limiter\|rate_limit\|limits"` sobre `*.py` → **0 resultados**. |
| 2.3 | Límite en login/refresh/reset | **[F]** | `POST /login` (`routers/CRUD_MONGODB.py`), `POST /auth/refresh` (`routers/auth_refresh.py`), reset de contraseña: sin límite. |
| 2.4 | Storage distribuido | **[F]** | `REDIS_URL` ya existe y está en `requirements.txt` (`redis==7.4.0`), pero no se usa para límites. |

**Impacto medido:** `bcrypt==5.0.0` con coste por defecto (~250 ms/hash). Sin límite, ~4 req/s por worker saturan la CPU; un atacante con 50 req/s tumba la API entera (DoS trivial, no hace falta fuerza bruta exitosa).

**Acción propuesta:** `slowapi` con `storage_uri=REDIS_URL` (si falta, `memory://` con aviso en el log), límites por IP **y** por usuario:
- global `100/minute`
- `/login`, `/auth/refresh`, `/auth/reset*` → `5/minute`
- endpoints de dinero (`/billetera/*`, `/trips*` POST) → `20/minute`
- `/healthz`, `/readyz` → exentos
- respuesta `429` con `Retry-After`.

---

## 3. Autenticación

| # | Punto | Estado | Evidencia |
|---|-------|--------|-----------|
| 3.1 | Hash de contraseñas | **[T]** | `bcrypt.hashpw` / `bcrypt.checkpw` en registro y login (`routers/CRUD_MONGODB.py:377,317`) y en admin (`routers/admin_panel.py:24`). No hay Argon2, pero bcrypt es aceptable. |
| 3.2 | Contraseña nunca se devuelve | **[T]** | `doc.pop("password", None)` y proyección `{"password": 0}` (`CRUD_MONGODB.py:208,388,405,422`). |
| 3.3 | Expiración de access token | **[T]** pero larga | 120 min (`db/tokens.py:34-35`). Para móvil se recomienda 15-30 min. |
| 3.4 | Refresh token | **[F]** | 30 días **sin rotación, sin `jti`, sin denylist** (`db/tokens.py:63-66`, `routers/auth_refresh.py`). Un refresh robado es válido 30 días y no se puede revocar. |
| 3.5 | Secreto JWT | **[F] crítico** | Fallback **hardcodeado en el repo**: `db/tokens.py:29-31`. Si en Render falta `JWT_SECRET_KEY`, cualquiera con acceso al repo forja tokens de cualquier usuario. |
| 3.6 | Aislamiento entre apps (cliente/chofer/admin) | **[F]** | Se emite el claim `app` (`db/tokens.py:52-53`) pero **`verify_token` nunca lo valida** (`db/tokens.py:69-86`). Un token de cliente sirve en endpoints de chofer si el endpoint solo confía en `sub`/`id`. |
| 3.7 | Política de contraseñas | **[F]** | `db/Cliente/models.py:9` → `password: str` sin `min_length`; lo mismo en chofer. Se acepta `"1234"`. Solo el admin exige 8 (`admin_panel.py:236`). |
| 3.8 | Logout / revocación | **[F]** | No existe endpoint de logout ni invalidación de tokens. |

**Acción propuesta (Fase Final, sin romper sesiones abiertas):**
- Quitar el fallback de `SECRET_KEY` → `RuntimeError` al arrancar si falta (con `JWT_SECRET_KEY` ya definido en Render **antes** del deploy).
- Validar `app` en `verify_token` **solo para tokens nuevos** (los viejos no lo llevan) → ventana de gracia documentada.
- Access a 30 min, refresh con rotación + `jti` + tabla `refresh_tokens` (revocable) o denylist en Redis.
- `min_length=8` + rechazo de contraseñas en lista negra en cliente/chofer.

---

## 4. Secretos en el código

| # | Secreto | Estado | Evidencia |
|---|---------|--------|-----------|
| 4.1 | Clave MapTiler | **[F] crítico** | Hardcodeada: `scripts/compilar_apks.ps1:16` → `'ZsGcg7EJ3Ml7wgFfXwAt'`. Está en el historial de git ⇒ **hay que rotarla**, no solo borrarla. |
| 4.2 | Secreto JWT | **[F] crítico** | `db/tokens.py:31` (fallback). |
| 4.3 | Telegram / Cloudinary / Mongo / Postgres | **[T]** | Leídos de `os.getenv`. |
| 4.4 | QvaPay / Supabase | **[T]** | No hay claves de QvaPay en el repo; Supabase entra por `POSTGRES_URL`. |
| 4.5 | Claves reales en Render | **[?]** | No verificable desde el repo. Requiere revisión del dashboard. |
| 4.6 | `.env` versionado | **[T]** | `.env.local` ignorado; `git ls-files` no lista ningún `.env`. |

**Acción propuesta:** rotar MapTiler y JWT en Render, pasar la clave por `-MaptilerKey $env:MAPTILER_API_KEY` o `--dart-define` desde CI, y añadir un test que falle si aparece un patrón de secreto en el árbol (`tests/test_sin_secretos.py`).

---

## 5. Logs — datos sensibles

| # | Punto | Estado | Evidencia |
|---|-------|--------|-----------|
| 5.1 | Teléfonos en logs | **[F]** | `routers/Solicitud_de_viajes_v4.py:3173` (`"No se pudo buscar por telefono %s"`), `routers/telegram_webhook.py:468` y `:1242` (`"Fallo la busqueda del telefono %s"`). |
| 5.2 | Volcado de excepción de conexión | **[F]** | `print(f"   Detalle: {e}")` en `init_db` (`Solicitud_de_viajes_v4.py:712-713`): un `OperationalError` de psycopg2 incluye host, usuario y a veces el DSN. |
| 5.3 | `exc_info=True` en bloques con credenciales | **[F]** | `main_v2.py:179-181` y varios `logger.exception` de Mongo pueden arrastrar la URI con usuario:contraseña. |
| 5.4 | Tokens en logs | **[T]** | No se encontró `logger.*token` con valor. |
| 5.5 | Filtro central de redacción | **[F]** | No existe. Cada módulo configura su logger por separado. |
| 5.6 | `print()` en producción | **[F]** | `init_db` usa `print` (8 sitios) en vez de `logger`. |

**Acción propuesta:** `app/logging_config.py` con un `logging.Filter` que enmascara `mongodb(+srv)://…`, `postgres(ql)://…`, `Bearer …`, `+53\d{8,}`, `password=…`, y `jwt` de 3 segmentos. Reemplazar los 3 `logger.*telefono` por `telefono_enmascarado()` (últimos 4 dígitos) y los `print()` de `init_db` por `logger`.

---

## 6. Tokens en el cliente Flutter

| # | Punto | Estado | Evidencia |
|---|-------|--------|-----------|
| 6.1 | Refresh token en almacenamiento seguro | **[T]** | `frontend/taxi_client/lib/services/token_store.dart:20` y `frontend/taxi_driver/lib/services/token_store.dart:19` (`flutter_secure_storage`). |
| 6.2 | Access token en almacenamiento seguro | **[T]** parcial | También se guarda en secure storage. |
| 6.3 | **Espejo del access en `SharedPreferences`** | **[F]** | `client_token` (`token_store.dart:23`) y `driver_token` (`token_store.dart:22`). En Android queda en un XML legible con `run-as`/backup; en Web es `localStorage`. Token con acceso total durante 2 h. |
| 6.4 | Refresh en `SharedPreferences` | **[T]** | No se espeja: solo el access. |

**Acción propuesta:** el isolate de ofertas (`ofertas_background_service`) lee el token de `flutter_secure_storage` (soportado en background isolate) y se elimina el espejo. Requiere build + prueba en `R58M22C0QBV`; por eso va en la Fase Final, no en las Tareas 1-7.

---

## Resumen de riesgo

| Severidad | Hallazgo |
|-----------|----------|
| **Crítico** | Secreto JWT hardcodeado como fallback (`db/tokens.py:31`) |
| **Crítico** | Clave MapTiler en el repo y en el historial de git (`scripts/compilar_apks.ps1:16`) |
| **Crítico** | Sin rate limiting: DoS trivial sobre bcrypt |
| **Alto** | `app` del JWT no se valida → token de cliente en endpoints de chofer |
| **Alto** | Refresh de 30 días sin rotación ni revocación |
| **Alto** | Access token espejado en `SharedPreferences` |
| **Medio** | Sin política de contraseñas en cliente/chofer |
| **Medio** | Teléfonos y DSN en logs |
| **Medio** | Sin usuario de BD con privilegios mínimos |
| **?** | Allowlist de IP en Atlas/Supabase (dashboard) |

---

# TAREA 0 — Inspección del repositorio

## 0.1 Stack real (no el del prompt)

| Aspecto | Prompt asume | Realidad en el repo |
|---------|--------------|---------------------|
| Driver Postgres | `asyncpg` / SQLAlchemy | **`psycopg2-binary==2.9.12`** síncrono, `ThreadedConnectionPool(minconn=1, maxconn=20)` |
| Driver Mongo | `motor` | **`pymongo==4.17.0`** síncrono |
| Transacciones | `async with conn.transaction()` | `with get_connection() as conn:` + `conn.commit()/rollback()`; no hay bloque `with conn:` |
| IDs | `uuid` | `VARCHAR(50)` con **ObjectId hex de 24 chars** |
| Estados | español (`solicitado`, `en_curso`…) | inglés: `requested`, `accepted`, `driver_on_the_way`, `driver_arrived`, `in_progress`, `completed`, `cancelled`, `expired` |
| Tests | `pytest` | Hay 12 archivos en `tests/`, pero **`pytest` no está instalado** en el entorno actual |
| Zonas | polígonos | `Geo.calles` son **calles/líneas** (índice `geom_geojson_2dsphere`), **no hay polígonos de zona** |

## 0.2 Postgres — objetos reales

| Tabla | Rol | Notas |
|-------|-----|-------|
| `trips` | viajes | `trip_id VARCHAR(50) PK`, `client_id/driver_id VARCHAR(50)`, `status VARCHAR(20)`, `request_location`/`pickup_location`/`dropoff_location GEOGRAPHY(Point,4326)`, `precio_estimado`, `total_fare`, `tip`, `monto_cobrado`, `payment_method`, `descuento_cliente/referido/primer_viaje`, `comision_*`, `saldo_promocional_usado`, `efectivo_cliente`, `bono_chofer_campana` (`init_db`, líneas 492-700) |
| `transactions` | libro auxiliar | `transaction_id`, `trip_id → trips(trip_id)`, `user_id`, `amount`, `transaction_type`, `status` |
| `driver_payouts` | liquidaciones | `payout_id`, `driver_id`, `net_amount` |
| `tariffs` | tarifas | `vehicle_type UNIQUE`, `base_fare`, `price_per_km`, `price_per_minute` |
| `time_pricing_rules` | multiplicadores por hora | |
| `daily_trip_metrics` | métricas | |
| `wallet_movements` | **libro actual de billetera** | `user_type` (`driver`/`client`), `driver_id`, `tipo`, `monto`, `saldo_anterior`, … (`routers/billetera.py:107-141`) |
| `driver_cancellations` | cancelaciones | |
| `promociones` | campañas | |
| `password_resets` | reset | |

## 0.3 Mongo — colecciones reales

| Base.Colección | Contenido | Dónde se usa |
|----------------|-----------|--------------|
| `Cliente.users` | perfiles de pasajeros + **`Fondo`** + **`saldo_promocional`** | `db/Cliente/connection.py`, `routers/billetera.py`, `routers/Solicitud_de_viajes_v4.py:305-309` |
| `Chofer.users` | perfiles de choferes + **`Fondo`** + documentos | `db/Chofer/connection.py` |
| `Administración.users` | admins | `db/Administración/connection.py` |
| `Geo.calles` | malla de calles (LineString) | `routers/geo.py:40-42` |
| `Geo.progreso_calles` | estado de descarga | `routers/geo.py:42` |

## 0.4 Dónde vive el dinero hoy (mapa exacto de escrituras)

| Archivo | Líneas | Qué hace |
|---------|--------|----------|
| `routers/billetera.py` | 275, 288, 337-428, 539-672 | `$inc {"Fondo": ±monto}` para chofer y cliente; `wallet_movements` como bitácora |
| `routers/Solicitud_de_viajes_v4.py` | ~1373 | **valida saldo leyendo Mongo** antes de crear el viaje |
| `routers/Solicitud_de_viajes_v4.py` | ~1993+ (`complete_trip`) | descuenta `Fondo` del cliente y liquida al chofer |
| `routers/Solicitud_de_viajes_v4.py` | ~5015, ~5449 | transferencias billetera→billetera |
| `routers/campana_promocional.py` | `saldo_promocional_vigente`, `bono_promocional` | bonos y expiración del saldo promocional |
| `routers/admin_panel.py:182`, `routers/app_init.py:50,65` | | **lecturas** de `Fondo` para el panel y el bootstrap |

> Conclusión: hoy hay **tres** saldos en Mongo (Fondo cliente, Fondo chofer, saldo promocional) y **cero** garantías atómicas con `trips`.

---

# MAPEO DE ARCHIVOS (a validar)

## A crear

| Archivo | Contenido |
|---------|-----------|
| `migrations/0001_wallet_core.sql` | `trip_status` (valores reales en inglés), columnas nuevas de `trips`, `wallet_ledger`, `wallet_holds`, `outbox`, `saldo_disponible()`, índices, `COMMENT ON` |
| `migrations/0001_wallet_core_rollback.sql` | `DROP` en orden inverso + `DROP TYPE`; documentado como seguro porque nada más depende |
| `migrations/0002_zones.sql` + `_rollback` | **solo si se aprueba** la reinterpretación de la Tarea 5 (calles → `geography(LineString,4326)`, no polígonos) |
| `app/__init__.py` | paquete |
| `app/db.py` | pool único reutilizando el `ThreadedConnectionPool` existente + helper `transaccion()` |
| `app/money.py` | conversión `Decimal`/`NUMERIC(10,2)` ↔ `monto_cents int` con redondeo bancario |
| `app/wallet/__init__.py` | paquete |
| `app/wallet/service.py` | `crear_viaje`, `finalizar_viaje`, `cancelar_viaje`, `recargar_saldo`, `saldo_disponible`, `reservar_hold` |
| `app/wallet/schemas.py` | Pydantic de entrada/salida de cada flujo |
| `app/wallet/errors.py` | `SaldoInsuficiente`, `ViajeNoEncontrado`, mapeo a HTTP 402/404/409 |
| `app/outbox/__init__.py` | paquete |
| `app/outbox/events.py` | payloads Pydantic **versionados** (`schema_version: int`) por `event_type` |
| `app/outbox/worker.py` | loop `SELECT … FOR UPDATE SKIP LOCKED`, backoff exponencial, `processed_events` en Mongo |
| `app/logging_config.py` | filtro de redacción (Fase Final) |
| `scripts/backfill_saldo.py` | lotes reanudables, `idempotency_key = 'mig:{user_id}'` |
| `scripts/verificar_cuadre.py` | comparación Mongo vs Postgres, salida JSON estructurada |
| `tests/conftest.py` | fixtures de BD de prueba + flag `--run-db` |
| `tests/test_wallet_saldo.py` | caso 1 (saldo exacto / 402 sin trip) |
| `tests/test_wallet_cancelacion.py` | caso 4 (cancelar libera hold) |
| `tests/test_wallet_concurrencia.py` | caso 5 (20 viajes concurrentes) |
| `tests/test_outbox_idempotencia.py` | casos 2 y 3 (caída de Mongo y reproceso) |
| `tests/test_backfill_cuadre.py` | caso 6 (0 diferencias) |
| `tests/test_sin_secretos.py` | guardarraíl de la Fase 0 |
| `PLAN_DESPLIEGUE.md` | orden, flags, cutover, rollback |
| `docs/REPORTE_SEGURIDAD.md` | cierre de la Fase Final |

## B modificar

| Archivo | Cambio |
|---------|--------|
| `routers/Solicitud_de_viajes_v4.py` | `create_trip`, `complete_trip`, `cancel_trip` y las 2 transferencias delegan en `app/wallet/service.py`; saldo se lee de Postgres; `print()` → `logger` |
| `routers/billetera.py` | `recarga`/`descargo` de chofer y cliente escriben `wallet_ledger`; lecturas de saldo usan `saldo_disponible()` |
| `routers/campana_promocional.py` | bono y consumo de saldo promocional → ledger (`tipo='bono'`), sin escrituras de `saldo_promocional` |
| `routers/admin_panel.py`, `routers/app_init.py` | leen saldo de Postgres en vez de `doc["Fondo"]` |
| `main_v2.py` | flag de arranque del worker, `slowapi`, logging de redacción, CORS estricto |
| `db/tokens.py` | quitar fallback, validar `app`, TTL configurable |
| `routers/auth_refresh.py` | rotación de refresh (si se aprueba) |
| `requirements.txt` | `pytest`, `pytest-asyncio`, `slowapi`, `limits[redis]` |
| `frontend/taxi_client/lib/services/token_store.dart`, `frontend/taxi_driver/lib/services/token_store.dart` | eliminar espejo en `SharedPreferences` |
| `scripts/compilar_apks.ps1` | clave MapTiler desde entorno |

## C eliminar / desactivar (nunca borrar tablas ni colecciones)

| Qué | Cómo |
|-----|------|
| `$inc {"Fondo": …}` en `billetera.py` y `Solicitud_de_viajes_v4.py` | detrás de `WALLET_LEGACY_MONGO_WRITES` (default `true` durante la transición) |
| lectura de `Fondo` en `create_trip` | detrás de `WALLET_READ_SOURCE=postgres` |
| `print()` de `init_db` | reemplazo directo, sin flag |
| fallback de `JWT_SECRET_KEY` | eliminación directa con `RuntimeError` |

---

# DESVIACIONES NECESARIAS (requieren tu decisión)

1. **IDs**: el prompt pide `uuid`; la realidad son ObjectId hex de 24 chars en `VARCHAR(50)`, y `trips.client_id` ya guarda eso. Propongo `text` en `wallet_ledger.client_id` / `trip_id` y `REFERENCES trips(trip_id)`. Convertir a `uuid` obliga a reescribir todas las FKs y migrar 3 bases ⇒ riesgo alto sin beneficio.
2. **`trip_status`**: el prompt lo pide en español; el código compara contra `in_progress`, `completed`, etc. Propongo enum en **inglés** con los valores reales. Si se crea en español, hay que tocar ~40 comparaciones y las apps.
3. **`trips` ya tiene geografía**: `request_location`/`pickup_location`/`dropoff_location` son `GEOGRAPHY(Point,4326)`. Propongo **no** duplicar con `origen`/`destino`; solo añadir `monto_cents`, `fare_snapshot jsonb`, `client_display jsonb`, `driver_display jsonb`.
4. **Hold vs. comportamiento actual**: hoy un viaje con billetera puede cerrarse con saldo insuficiente y el resto se cobra en efectivo (`monto_cobrado`, `efectivo_cliente`). El prompt exige **402 al crear**. Opciones: (a) hold solo si `payment_method='Billetera'`; (b) hold siempre por `precio_estimado`. Recomiendo (a) para no romper el flujo mixto que ya está en producción.
5. **Alcance del dinero**: el prompt habla del "saldo del cliente", pero la regla "el dinero vive solo en Postgres" obliga a mover también `Chofer.users.Fondo` y `Cliente.users.saldo_promocional`. Propongo incluirlos en el mismo ledger (`user_type`).
6. **Tarea 5 (mallas → PostGIS)**: `Geo.calles` son **líneas** de calles para geocodificar, no polígonos de zona, y no existe ningún dataset de zonas. Tal cual está pedida no se puede ejecutar. Propongo reinterpretarla como tabla `streets` (`LineString` + GiST) o **dejarla fuera** del alcance.
7. **Patrón de transacción**: no hay `asyncpg` ni SQLAlchemy. Uso `psycopg2` con `with conn:` (commit/rollback automático) + `SET LOCAL statement_timeout`. El `FOR UPDATE SKIP LOCKED` del outbox es SQL puro, no cambia.
8. **Tests**: `pytest` no está instalado y no hay BD de pruebas. Necesito saber si hay un Postgres local/Docker disponible para el test de 20 viajes concurrentes (no se puede simular con SQLite).
9. **`pg_cron`**: existe en Supabase pero no en local; para que el mismo código sirva en ambos, la expiración sigue en APScheduler (cada 15 s ya) y `pg_cron` queda como opción documentada.

---

# ORDEN DE EJECUCIÓN PROPUESTO

```
Tarea 1  migración + rollback + tests de esquema        (aditiva, sin efecto en producción)
Tarea 2  backfill + verificar_cuadre en modo sombra     (no cambia lecturas)
Tarea 3  servicio wallet + endpoints detrás de flag     (dual-write)
Tarea 4  worker outbox                                  (solo procesa lo que ya se escribe)
Tarea 5  (pendiente de decisión)
Tarea 6  crons de expiración y cuadre
Tarea 7  snapshots y lecturas desde Postgres
Fase Final  CORS, rate limiting, logs, Pydantic, Flutter
```

Cada tarea termina con: diff resumido + comando de prueba + criterio de aceptación cumplido. No se pasa a la siguiente sin eso.
