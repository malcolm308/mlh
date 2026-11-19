-- =====================================================================
--  0003_holds_expiry_pgcron_rollback.sql
--  RapiTaxi · Tarea 6 — Reversión de expiración por pg_cron
-- =====================================================================
--  Qué hace
--  --------
--  * Desprograma el job `expirar_holds_y_viajes` si existe.
--  * Elimina la función `expirar_holds_y_viajes(integer)`.
--  * Borra el registro en `schema_migrations`.
--
--  Qué NO hace
--  -----------
--  * NO revierte holds/viajes ya expirados ni eventos ya insertados.
--  * NO elimina la extensión `pg_cron`.
-- =====================================================================

BEGIN;

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
EXCEPTION
    WHEN undefined_table OR invalid_schema_name OR insufficient_privilege THEN
        RAISE NOTICE 'pg_cron no disponible al revertir schedule: %', SQLERRM;
END;
$do$;

DROP FUNCTION IF EXISTS expirar_holds_y_viajes(integer);

DELETE FROM schema_migrations WHERE version = '0003_holds_expiry_pgcron';

COMMIT;
