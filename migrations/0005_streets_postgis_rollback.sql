-- =====================================================================
--  0005_streets_postgis_rollback.sql
--  RapiTaxi · Tarea 5 — Reversión de la malla de calles en PostGIS
-- =====================================================================
--  Elimina la tabla `streets` y su registro de migración.
--  NO elimina PostGIS (lo usan `zones`/`trips`), NO toca `zones`,
--  NO modifica Mongo (Geo.calles sigue intacta y es la fuente de re-import).
--
--  Requiere confirmación: python scripts/aplicar_migraciones.py
--      migrations/0005_streets_postgis_rollback.sql --si
-- =====================================================================

BEGIN;

DROP TABLE IF EXISTS streets;

DELETE FROM schema_migrations WHERE version = '0005_streets_postgis';

COMMIT;
