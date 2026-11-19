-- =====================================================================
--  0001_wallet_core.sql
--  RapiTaxi · Tarea 1 — Esquema wallet en PostgreSQL
-- =====================================================================
--  Qué hace
--  --------
--  * Crea el enum `trip_status` con los estados REALES del sistema.
--  * Añade a `trips` las columnas que faltaban para el ledger y los snapshots.
--  * Crea `wallet_ledger` (fuente única de verdad del dinero, append-only).
--  * Crea `wallet_holds` (reservas de saldo por viaje).
--  * Crea `outbox` (eventos pendientes hacia MongoDB).
--  * Crea `saldo_disponible()` y `v_wallet_saldos`.
--
--  Garantías
--  ---------
--  * 100 % ADITIVA: no borra, no renombra y no cambia el tipo de nada
--    existente. Se puede ejecutar con la aplicación en producción.
--  * IDEMPOTENTE: se puede correr dos veces sin error.
--  * NO toca `trips.status`: se queda como VARCHAR(20) para no romper las
--    ~40 comparaciones del código y las apps. El enum se usa para validar
--    los valores y lo usarán las tablas nuevas.
--  * Dinero en CENTAVOS enteros (BIGINT). Dirección: NUMERIC(10,2) → cents
--    se hace en `app/money.py`, nunca con float.
--
--  Reversión: `0001_wallet_core_rollback.sql`.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0. Control de migraciones
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notas       TEXT
);

COMMENT ON TABLE schema_migrations IS
    'Registro de migraciones aplicadas. Una fila por archivo de migrations/.';

-- ---------------------------------------------------------------------
-- 1. Enum trip_status
-- ---------------------------------------------------------------------
--  Los valores son los que ya usa el backend (en inglés). Se crea el tipo
--  para las tablas nuevas y para validar `trips.status` con un CHECK, pero
--  NO se convierte la columna existente: un enum + parámetros de psycopg2
--  obligaría a castear en cada consulta.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'trip_status') THEN
        CREATE TYPE trip_status AS ENUM (
            'requested',
            'accepted',
            'driver_on_the_way',
            'driver_arrived',
            'in_progress',
            'completed',
            'cancelled',
            'expired'
        );
    END IF;
END
$$;

COMMENT ON TYPE trip_status IS
    'Estados posibles de un viaje. Mismos valores que trips.status (VARCHAR).';

-- CHECK NOT VALID sobre la columna real: valida las filas NUEVAS sin fallar
-- por datos historicos. Se puede validar despues con:
--   ALTER TABLE trips VALIDATE CONSTRAINT chk_trips_status;
--
-- Se usa una lista explicita en vez de `status::trip_status` porque el cast
-- lanzaria 22P02 (invalid_text_representation) en lugar de un 23514 limpio.
-- Si se anade un estado al enum hay que anadirlo aqui tambien.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chk_trips_status'
    ) THEN
        ALTER TABLE trips
            ADD CONSTRAINT chk_trips_status
            CHECK (status IN ('requested', 'accepted', 'driver_on_the_way',
                              'driver_arrived', 'in_progress', 'completed',
                              'cancelled', 'expired')) NOT VALID;
    END IF;
END
$$;

COMMENT ON CONSTRAINT chk_trips_status ON trips IS
    'Restringe trips.status a los valores de trip_status. NOT VALID para no '
    'fallar con estados historicos; aplica a filas nuevas.';

-- ---------------------------------------------------------------------
-- 2. Columnas nuevas en trips
-- ---------------------------------------------------------------------
--  No se duplican `request_location` / `pickup_location` / `dropoff_location`:
--  ya son GEOGRAPHY(Point,4326). Solo se añade lo que no existe.
ALTER TABLE trips
    ADD COLUMN IF NOT EXISTS monto_cents     BIGINT,
    ADD COLUMN IF NOT EXISTS fare_snapshot   JSONB,
    ADD COLUMN IF NOT EXISTS client_display  JSONB,
    ADD COLUMN IF NOT EXISTS driver_display  JSONB;

COMMENT ON COLUMN trips.monto_cents IS
    'Importe final del viaje en centavos de CUP. Cobro real, no estimado.';
COMMENT ON COLUMN trips.fare_snapshot IS
    'Snapshot inmutable de la tarifa aplicada: base, km, minutos, recargos, '
    'descuentos y coeficiente. Se escribe al cerrar el viaje.';
COMMENT ON COLUMN trips.client_display IS
    'Copia del perfil visible del pasajero (nombre, foto) al crear el viaje. '
    'Evita depender de MongoDB para mostrar el historial.';
COMMENT ON COLUMN trips.driver_display IS
    'Copia del perfil visible del chofer (nombre, foto, placa, vehiculo) al '
    'asignar o cerrar el viaje.';

-- ---------------------------------------------------------------------
-- 3. wallet_ledger — fuente única de verdad del dinero
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wallet_ledger (
    id               BIGSERIAL PRIMARY KEY,
    user_id          TEXT        NOT NULL,
    user_type        TEXT        NOT NULL
                                 CHECK (user_type IN ('client', 'driver')),
    trip_id          TEXT        REFERENCES trips(trip_id) ON DELETE SET NULL,
    tipo             TEXT        NOT NULL
                                 CHECK (tipo IN ('recarga', 'captura_viaje',
                                                 'reembolso', 'ajuste', 'bono',
                                                 'comision', 'liquidacion')),
    -- Signo: + entra dinero al usuario, - sale. Nunca se guarda 0.
    monto_cents      BIGINT      NOT NULL CHECK (monto_cents <> 0),
    moneda           CHAR(3)     NOT NULL DEFAULT 'CUP',
    -- Clave de idempotencia: el UNIQUE es lo que impide cobrar dos veces.
    idempotency_key  TEXT        NOT NULL UNIQUE,
    descripcion      TEXT,
    metadata         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE wallet_ledger IS
    'Libro mayor append-only del dinero. Es la ÚNICA fuente de verdad de '
    'saldos. Nunca se hace UPDATE ni DELETE sobre esta tabla.';
COMMENT ON COLUMN wallet_ledger.user_id IS
    'ObjectId hex (24 chars) del usuario en MongoDB, guardado como text.';
COMMENT ON COLUMN wallet_ledger.user_type IS
    'client = pasajero, driver = chofer.';
COMMENT ON COLUMN wallet_ledger.tipo IS
    'recarga, captura_viaje, reembolso, ajuste, bono, comision, liquidacion.';
COMMENT ON COLUMN wallet_ledger.monto_cents IS
    'Importe con signo en centavos. Positivo suma al saldo, negativo resta.';
COMMENT ON COLUMN wallet_ledger.idempotency_key IS
    'Identificador único de la operación. Reintentar con la misma clave no '
    'duplica el asiento. Ej: trip:{id}:captura, mig:{user_id}.';
COMMENT ON COLUMN wallet_ledger.metadata IS
    'Contexto auditable: admin que recargó, método de pago, saldo previo, etc.';

CREATE INDEX IF NOT EXISTS idx_wallet_ledger_user_created
    ON wallet_ledger (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_ledger_user_type_created
    ON wallet_ledger (user_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_ledger_trip
    ON wallet_ledger (trip_id) WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_wallet_ledger_idem
    ON wallet_ledger (idempotency_key);

-- ---------------------------------------------------------------------
-- 4. wallet_holds — reservas de saldo
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wallet_holds (
    id           BIGSERIAL PRIMARY KEY,
    user_id      TEXT        NOT NULL,
    user_type    TEXT        NOT NULL DEFAULT 'client'
                             CHECK (user_type IN ('client', 'driver')),
    -- Un viaje tiene como máximo una reserva: así el UNIQUE evita dobles holds.
    trip_id      TEXT        NOT NULL UNIQUE REFERENCES trips(trip_id),
    monto_cents  BIGINT      NOT NULL CHECK (monto_cents > 0),
    estado       TEXT        NOT NULL DEFAULT 'activa'
                             CHECK (estado IN ('activa', 'capturada',
                                               'liberada', 'expirada')),
    expires_at   TIMESTAMPTZ NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE wallet_holds IS
    'Reserva temporal de saldo mientras el viaje está abierto. Se crea en la '
    'misma transacción que el viaje; al cerrar pasa a capturada y al cancelar '
    'a liberada. No mueve dinero por sí sola.';
COMMENT ON COLUMN wallet_holds.monto_cents IS
    'Importe reservado en centavos. Se compara contra saldo_disponible().';
COMMENT ON COLUMN wallet_holds.estado IS
    'activa = retiene saldo; capturada = consumida por el viaje; '
    'liberada = cancelada; expirada = venció sin cerrar.';
COMMENT ON COLUMN wallet_holds.expires_at IS
    'Momento en que el cron de expiración libera la reserva.';

CREATE INDEX IF NOT EXISTS idx_wallet_holds_activas
    ON wallet_holds (user_id, user_type)
    WHERE estado = 'activa';
CREATE INDEX IF NOT EXISTS idx_wallet_holds_expira
    ON wallet_holds (expires_at)
    WHERE estado = 'activa';

-- ---------------------------------------------------------------------
-- 5. outbox — eventos Postgres → MongoDB
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outbox (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type     TEXT        NOT NULL,
    aggregate_type TEXT,
    aggregate_id   TEXT,
    payload        JSONB       NOT NULL,
    -- Versionado del payload: permite que el worker entienda eventos viejos
    -- aunque la forma cambie.
    schema_version INTEGER     NOT NULL DEFAULT 1 CHECK (schema_version > 0),
    estado         TEXT        NOT NULL DEFAULT 'pendiente'
                               CHECK (estado IN ('pendiente', 'procesado',
                                                 'error')),
    intentos       INTEGER     NOT NULL DEFAULT 0 CHECK (intentos >= 0),
    next_retry_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_error     TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at   TIMESTAMPTZ
);

COMMENT ON TABLE outbox IS
    'Cola transaccional de eventos. Se escribe en la MISMA transacción que el '
    'cambio de dinero; el worker los aplica en MongoDB de forma asíncrona.';
COMMENT ON COLUMN outbox.event_type IS
    'trip.created, trip.completed, trip.cancelled, wallet.changed, etc.';
COMMENT ON COLUMN outbox.payload IS
    'Cuerpo del evento validado con Pydantic (app/outbox/events.py).';
COMMENT ON COLUMN outbox.schema_version IS
    'Versión del payload. El worker decide cómo interpretarlo.';
COMMENT ON COLUMN outbox.estado IS
    'pendiente = por procesar; procesado = aplicado en Mongo; error = agotó '
    'los reintentos y requiere intervención.';
COMMENT ON COLUMN outbox.next_retry_at IS
    'Backoff exponencial: el worker solo toma eventos con esta fecha vencida.';

CREATE INDEX IF NOT EXISTS idx_outbox_pendientes
    ON outbox (next_retry_at, created_at)
    WHERE estado = 'pendiente';
CREATE INDEX IF NOT EXISTS idx_outbox_aggregate
    ON outbox (aggregate_type, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_outbox_errores
    ON outbox (created_at DESC)
    WHERE estado = 'error';

-- ---------------------------------------------------------------------
-- 6. saldo_disponible()
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION saldo_disponible(
    p_user_id   TEXT,
    p_user_type TEXT DEFAULT 'client'
) RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE((
               SELECT SUM(monto_cents)
                 FROM wallet_ledger
                WHERE user_id = p_user_id
                  AND user_type = p_user_type
           ), 0)
         - COALESCE((
               SELECT SUM(monto_cents)
                 FROM wallet_holds
                WHERE user_id = p_user_id
                  AND user_type = p_user_type
                  AND estado = 'activa'
           ), 0);
$$;

COMMENT ON FUNCTION saldo_disponible(TEXT, TEXT) IS
    'Saldo real menos reservas activas, en centavos. STABLE: puede usarse '
    'dentro de la misma transacción del viaje. Nunca lee MongoDB.';

-- ---------------------------------------------------------------------
-- 7. wallet_lock_user() — serializa operaciones por usuario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wallet_lock_user(p_user_id TEXT)
RETURNS VOID
LANGUAGE sql
VOLATILE
AS $$
    SELECT pg_advisory_xact_lock(hashtextextended('wallet:' || p_user_id, 0));
$$;

COMMENT ON FUNCTION wallet_lock_user(TEXT) IS
    'Toma un advisory lock de transacción por usuario. Evita que dos viajes '
    'concurrentes del mismo cliente vean el mismo saldo y lo sobregiren. Se '
    'libera solo al terminar la transacción.';

-- ---------------------------------------------------------------------
-- 8. Vista de saldos (auditoría y cuadre)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_wallet_saldos AS
SELECT l.user_id,
       l.user_type,
       l.total_ledger_cents,
       COALESCE(h.total_holds_cents, 0) AS total_holds_cents,
       l.total_ledger_cents - COALESCE(h.total_holds_cents, 0)
           AS saldo_disponible_cents,
       l.ultimo_movimiento
  FROM (SELECT user_id,
               user_type,
               SUM(monto_cents) AS total_ledger_cents,
               MAX(created_at)  AS ultimo_movimiento
          FROM wallet_ledger
         GROUP BY user_id, user_type) l
  LEFT JOIN (SELECT user_id,
                    user_type,
                    SUM(monto_cents) AS total_holds_cents
               FROM wallet_holds
              WHERE estado = 'activa'
              GROUP BY user_id, user_type) h
         ON h.user_id = l.user_id AND h.user_type = l.user_type;

COMMENT ON VIEW v_wallet_saldos IS
    'Saldo contable por usuario: suma del ledger menos holds activas. Base '
    'para scripts/verificar_cuadre.py.';

-- ---------------------------------------------------------------------
-- 9. Registrar la migración
-- ---------------------------------------------------------------------
INSERT INTO schema_migrations (version, notas)
VALUES ('0001_wallet_core',
        'enum trip_status, columnas de trips, wallet_ledger, wallet_holds, '
        'outbox, saldo_disponible, v_wallet_saldos')
ON CONFLICT (version) DO NOTHING;

COMMIT;
