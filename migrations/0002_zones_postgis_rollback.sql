-- =====================================================================
--  0002_zones_postgis_rollback.sql
--  RapiTaxi · Tarea 5 — Reversión de zonas PostGIS
-- =====================================================================
--  Qué hace
--  --------
--  * Elimina la tabla `zones` y sus índices.
--  * Borra el registro de versión en `schema_migrations`.
--
--  Qué NO hace
--  -----------
--  * NO elimina la extensión `postgis` (puede ser usada por otras tablas,
--    p.ej. `trips` con columnas geography).
--  * NO modifica `promociones.zona_especial_*` (se mantienen como
--    compatibilidad durante la transición).
--
--  Esta reversión es destructiva para los datos de `zones`. Tras ejecutarla,
--  el cálculo de zona debe volver a la lógica anterior (si aún existe) o la
--  tabla debe recrearse y re-migrarse.
-- =====================================================================

BEGIN;

DROP TABLE IF EXISTS zones;

DELETE FROM schema_migrations WHERE version = '0002_zones_postgis';

COMMIT;
