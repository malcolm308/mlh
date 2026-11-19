-- =====================================================================
--  0002_zones_postgis.sql
--  RapiTaxi · Tarea 5 — Zonas en PostGIS (geography/MultiPolygon)
-- =====================================================================
--  Qué hace
--  --------
--  * Habilita PostGIS (idempotente).
--  * Crea la tabla `zones` para zonas/polígonos de negocio (p.ej. zona
--    especial aeropuerto) con geometría `geography(MultiPolygon,4326)`.
--  * Crea índice GiST para consultas espaciales (ST_Contains / ST_Covers).
--  * Registra la migración en `schema_migrations`.
--
--  Garantías
--  ---------
--  * 100 % ADITIVA: no modifica ni elimina tablas/columnas existentes.
--    `promociones.zona_especial_coords` y precios de zona se mantienen
--    durante la transición para compatibilidad con panel/app_init.
--  * IDEMPOTENTE: se puede ejecutar varias veces sin error.
--  * Datos: esta migración solo crea el esquema. La carga inicial se hace
--    con `scripts/migrar_zonas_postgis.py` (fuente: `promociones`).
--
--  Reversión: `0002_zones_postgis_rollback.sql`.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0. Extensión espacial
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------------------------------------------------------------------
-- 1. Control de migraciones (idempotente, por si 0001 no corrió aquí)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notas       TEXT
);

COMMENT ON TABLE schema_migrations IS
    'Registro de migraciones aplicadas. Una fila por archivo de migrations/.';

-- ---------------------------------------------------------------------
-- 2. Tabla zones
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS zones (
    id                      BIGSERIAL PRIMARY KEY,
    -- Identificador estable de negocio (upsert/migración). Ej: airport_special
    code                    TEXT        NOT NULL UNIQUE,
    name                    TEXT        NOT NULL,
    active                  BOOLEAN     NOT NULL DEFAULT TRUE,
    -- Polígono(s) en WGS84. Se usa geography para consistencia con trips.*_location.
    -- El cálculo de pertenencia usa ST_Contains sobre geom::geometry (o ST_Covers
    -- sobre geography) según la consulta del servicio.
    geom                    geography(MultiPolygon, 4326) NOT NULL,
    -- Precios por km de la zona (misma semántica que promociones.precio_km_zona_*).
    precio_km_zona_basico   NUMERIC(12,2),
    precio_km_zona_confort  NUMERIC(12,2),
    precio_km_zona_triciclo NUMERIC(12,2),
    precio_km_zona_moto     NUMERIC(12,2),
    -- Metadatos/extensibilidad (origen, versión, reglas futuras, etc.).
    properties              JSONB       NOT NULL DEFAULT '{}'::jsonb,
    source                  TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_zones_geom_valid CHECK (ST_IsValid(geom::geometry))
);

COMMENT ON TABLE zones IS
    'Zonas geográficas de negocio (MultiPolygon). Fuente de verdad para cálculo '
    'de pertenencia con ST_Contains/ST_Covers. Durante la transición coexiste con '
    'promociones.zona_especial_*.';
COMMENT ON COLUMN zones.code IS
    'Clave estable para idempotencia de migraciones y referencia en código.';
COMMENT ON COLUMN zones.geom IS
    'Geografía MultiPolygon SRID 4326. Indexada con GiST para consultas espaciales.';
COMMENT ON COLUMN zones.precio_km_zona_basico IS
    'Precio por km en la zona para vehículo básico (compatibilidad con promociones).';
COMMENT ON COLUMN zones.properties IS
    'Metadatos libres y campos futuros sin migración de esquema.';

-- ---------------------------------------------------------------------
-- 3. Índices
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_zones_geom
    ON zones USING GIST (geom);

CREATE INDEX IF NOT EXISTS idx_zones_active
    ON zones (active)
    WHERE active = TRUE;

-- ---------------------------------------------------------------------
-- 4. Registro de migración
-- ---------------------------------------------------------------------
INSERT INTO schema_migrations (version, notas)
VALUES ('0002_zones_postgis',
        'PostGIS extension, tabla zones geography(MultiPolygon,4326) + GiST; '
        'carga inicial vía scripts/migrar_zonas_postgis.py desde promociones')
ON CONFLICT (version) DO NOTHING;

COMMIT;
