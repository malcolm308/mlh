-- =====================================================================
--  0003_holds_expiry_pgcron.sql
--  RapiTaxi · Tarea 6 — Expiración de holds y viajes vía pg_cron (Supabase)
-- =====================================================================
--  Qué hace
--  --------
--  * Habilita `pg_cron` (si está disponible en el entorno).
--  * Crea la función `expirar_holds_y_viajes()` que, de forma atómica:
--      1. Selecciona holds ACTIVAS vencidas (`expires_at <= NOW()`).
--      2. Marca esos holds como `expirada`.
--      3. Marca los viajes asociados como `expired` SOLO si siguen en
--         `requested` (expiración por no aceptación / timeout de oferta).
--      4. Inserta un evento `trip.status_changed` en `outbox` por cada viaje
--         que pasó a `expired`.
--  * Programa la ejecución cada minuto con `cron.schedule`.
--
--  Garantías
--  ---------
--  * Funciona en la base de datos aunque el servicio web (Render) esté caído.
--  * Idempotente: re-ejecuciones no duplican efectos (condiciones por estado
--    y `ON CONFLICT DO NOTHING` no aplica a outbox, pero el viaje/hold ya no
--    cumplen la condición tras la primera ejecución).
--  * No toca viajes en curso (`in_progress`, `driver_arrived`, etc.) ni
--    holds ya capturadas/liberadas.
--  * Liberación de saldo: al marcar el hold como no activo deja de restar en
--    `saldo_disponible()` (no se inserta asiento en ledger).
--
--  Reversión: `0003_holds_expiry_pgcron_rollback.sql`.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0. Extensión de cron (Supabase)
-- ---------------------------------------------------------------------
DO $ext$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
EXCEPTION
    WHEN undefined_file OR insufficient_privilege OR feature_not_supported THEN
        RAISE NOTICE 'pg_cron no disponible: %', SQLERRM;
END;
$ext$;

-- ---------------------------------------------------------------------
-- 1. Control de migraciones
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notas       TEXT
);

-- ---------------------------------------------------------------------
-- 2. Función de expiración
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION expirar_holds_y_viajes(p_limite integer DEFAULT 500)
RETURNS TABLE(holds_expirados integer, viajes_expirados integer, eventos_encolados integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_holds integer := 0;
    v_viajes integer := 0;
    v_eventos integer := 0;
BEGIN
    WITH holds_vencidos AS (
        SELECT h.id, h.trip_id
          FROM wallet_holds h
         WHERE h.estado = 'activa'
           AND h.expires_at <= NOW()
         ORDER BY h.expires_at
         LIMIT GREATEST(1, COALESCE(p_limite, 500))
         FOR UPDATE SKIP LOCKED
    ),
    holds_actualizados AS (
        UPDATE wallet_holds h
           SET estado = 'expirada', updated_at = NOW()
          FROM holds_vencidos v
         WHERE h.id = v.id
        RETURNING h.trip_id
    ),
    viajes_actualizados AS (
        UPDATE trips t
           SET status = 'expired',
               completed_at = COALESCE(t.completed_at, NOW())
          FROM (SELECT DISTINCT trip_id FROM holds_actualizados) hv
         WHERE t.trip_id = hv.trip_id
           AND t.status = 'requested'
        RETURNING t.trip_id, t.client_id, t.driver_id
    ),
    eventos AS (
        INSERT INTO outbox (event_type, aggregate_type, aggregate_id, payload, schema_version, estado)
        SELECT 'trip.status_changed',
               'trip',
               va.trip_id,
               jsonb_build_object(
                   'schema_version', 1,
                   'trip_id', va.trip_id,
                   'client_id', va.client_id,
                   'driver_id', va.driver_id,
                   'status', 'expired'
               ),
               1,
               'pendiente'
          FROM viajes_actualizados va
        RETURNING 1
    )
    SELECT
        (SELECT COUNT(*)::int FROM holds_actualizados),
        (SELECT COUNT(*)::int FROM viajes_actualizados),
        (SELECT COUNT(*)::int FROM eventos)
      INTO v_holds, v_viajes, v_eventos;

    RETURN QUERY SELECT v_holds, v_viajes, v_eventos;
END;
$$;

COMMENT ON FUNCTION expirar_holds_y_viajes(integer) IS
    'Expira holds activas vencidas, marca viajes requested como expired y encola '
    'trip.status_changed. Diseñada para pg_cron; segura ante re-ejecución.';

-- ---------------------------------------------------------------------
-- 3. Programación (cada minuto)
-- ---------------------------------------------------------------------
-- Si el job ya existe, se reprograma (idempotente por nombre).
DO $do$
DECLARE
    v_jobid bigint;
BEGIN
    SELECT jobid INTO v_jobid
      FROM cron.job
     WHERE jobname = 'expirar_holds_y_viajes'
     LIMIT 1;

    IF v_jobid IS NOT NULL THEN
        PERFORM cron.unschedule(v_jobid);
    END IF;

    PERFORM cron.schedule(
        'expirar_holds_y_viajes',
        '* * * * *',
        $cmd$SELECT * FROM expirar_holds_y_viajes(500);$cmd$
    );
EXCEPTION
    WHEN undefined_table OR invalid_schema_name OR insufficient_privilege THEN
        -- pg_cron no disponible o sin permisos en este entorno: la función queda
        -- creada y puede invocarse manualmente o programarse desde Supabase UI.
        RAISE NOTICE 'pg_cron no disponible para programar expirar_holds_y_viajes: %', SQLERRM;
END;
$do$;

-- ---------------------------------------------------------------------
-- 4. Registro de migración
-- ---------------------------------------------------------------------
INSERT INTO schema_migrations (version, notas)
VALUES ('0003_holds_expiry_pgcron',
        'pg_cron: expirar_holds_y_viajes() cada minuto; expira holds, marca trips '
        'requested como expired y encola trip.status_changed en outbox')
ON CONFLICT (version) DO NOTHING;

COMMIT;
