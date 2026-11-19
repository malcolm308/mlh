-- =====================================================================
--  0005_streets_postgis.sql
--  RapiTaxi · Tarea 5 — Malla de calles en PostGIS (geography/LineString)
-- =====================================================================
--  Qué hace
--  --------
--  * Crea la tabla `streets` con geometría `geography(LineString,4326)`.
--  * Crea índice GiST para consultas espaciales (ST_Intersects/ST_DWithin).
--  * Registra la migración en `schema_migrations`.
--
--  Garantías
--  ---------
--  * 100 % ADITIVA: no modifica `zones`, `promociones` ni colecciones Mongo.
--  * IDEMPOTENTE: se puede ejecutar varias veces sin error.
--  * Datos: la carga se hace con `scripts/migrar_calles_postgis.py`.
--    Esa es la ÚNICA lectura de Mongo (`Geo.calles`); el destino es Postgres.
--
--  Reversión: `0005_streets_postgis_rollback.sql`.
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notas       TEXT
);

-- ---------------------------------------------------------------------
-- 1. Tabla streets
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS streets (
    id           BIGSERIAL PRIMARY KEY,
    -- ObjectId hex de Geo.calles: clave estable para upsert idempotente.
    mongo_id     TEXT        NOT NULL UNIQUE,
    nombre       TEXT,
    -- Tramo de calle en WGS84 (lon, lat). Una fila = un LineString.
    geom         geography(LineString, 4326) NOT NULL,
    puntos       INTEGER,
    properties   JSONB       NOT NULL DEFAULT '{}'::jsonb,
    source       TEXT        NOT NULL DEFAULT 'Geo.calles',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_streets_geom_valid CHECK (ST_IsValid(geom::geometry))
);

COMMENT ON TABLE streets IS
    'Malla de calles importada desde Mongo (Geo.calles) a PostGIS. '
    'Destino de la migración Tarea 5; Mongo queda como read-model/legacy.';
COMMENT ON COLUMN streets.mongo_id IS
    'ObjectId (hex) del documento de origen. Garantiza idempotencia del import.';
COMMENT ON COLUMN streets.geom IS
    'LineString WGS84 indexado con GiST. Longitud/latitud en grados (EPSG:4326).';

-- ---------------------------------------------------------------------
-- 2. Índices
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_streets_geom
    ON streets USING GIST (geom);

CREATE INDEX IF NOT EXISTS idx_streets_nombre
    ON streets (nombre);

-- ---------------------------------------------------------------------
-- 3. Registro de migración
-- ---------------------------------------------------------------------
INSERT INTO schema_migrations (version, notas)
VALUES ('0005_streets_postgis',
        'Tabla streets geography(LineString,4326) + GiST; carga desde Mongo Geo.calles '
        'vía scripts/migrar_calles_postgis.py')
ON CONFLICT (version) DO NOTHING;

COMMIT;
