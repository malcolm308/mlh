-- =====================================================================
--  0001_wallet_core_rollback.sql
--  Reversión EXACTA de 0001_wallet_core.sql
-- =====================================================================
--  ⚠️  LEER ANTES DE EJECUTAR
--
--  Este script BORRA wallet_ledger y wallet_holds. Si ya hay dinero real
--  registrado, ejecutarlo destruye el libro mayor y no hay forma de
--  reconstruirlo desde MongoDB (Mongo solo tendrá un espejo parcial).
--
--  Regla operativa:
--    * Antes del cutover (lecturas y cobros siguen en Mongo) → este script
--      es seguro.
--    * Después del cutover → NO se ejecuta. El rollback es apagar los
--      feature flags (WALLET_*), no borrar tablas. Ver PLAN_DESPLIEGUE.md.
--
--  Como protección, el script se niega a borrar datos si wallet_ledger
--  tiene filas. Para forzarlo, descomenta el SET LOCAL de abajo.
-- =====================================================================

BEGIN;

-- Descomentar SOLO si se sabe lo que se hace (borra el libro mayor):
-- SET LOCAL rapitaxi.force_drop_wallet = 'yes';

DO $$
DECLARE
    filas BIGINT;
BEGIN
    IF to_regclass('public.wallet_ledger') IS NOT NULL THEN
        EXECUTE 'SELECT COUNT(*) FROM wallet_ledger' INTO filas;
        IF filas > 0
           AND COALESCE(current_setting('rapitaxi.force_drop_wallet', TRUE),
                        'no') <> 'yes' THEN
            RAISE EXCEPTION
                'Rollback abortado: wallet_ledger tiene % asientos. '
                'Si de verdad quieres borrar el libro mayor, ejecuta '
                'SET LOCAL rapitaxi.force_drop_wallet = ''yes'';', filas;
        END IF;
    END IF;
END
$$;

-- 1. Vista de saldos
DROP VIEW IF EXISTS v_wallet_saldos;

-- 2. Funciones
DROP FUNCTION IF EXISTS wallet_lock_user(TEXT);
DROP FUNCTION IF EXISTS saldo_disponible(TEXT, TEXT);

-- 3. Tablas nuevas (primero las que dependen de trips)
DROP TABLE IF EXISTS outbox;
DROP TABLE IF EXISTS wallet_holds;
DROP TABLE IF EXISTS wallet_ledger;

-- 4. Restricción añadida a trips
ALTER TABLE trips DROP CONSTRAINT IF EXISTS chk_trips_status;

-- 5. Columnas añadidas a trips
ALTER TABLE trips
    DROP COLUMN IF EXISTS monto_cents,
    DROP COLUMN IF EXISTS fare_snapshot,
    DROP COLUMN IF EXISTS client_display,
    DROP COLUMN IF EXISTS driver_display;

-- 6. Enum
DROP TYPE IF EXISTS trip_status;

-- 7. Registro de la migración
DELETE FROM schema_migrations WHERE version = '0001_wallet_core';

COMMIT;
