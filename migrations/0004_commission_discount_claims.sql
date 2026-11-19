-- =====================================================================
--  0004_commission_discount_claims.sql
--  RapiTaxi · Estado auxiliar de descuento de comisión (3er viaje/día)
-- =====================================================================
--  Objetivo
--  --------
--  Persistir en Postgres el reclamo diario del descuento de comisión del chofer
--  (antes solo en Mongo: `last_commission_discount_date`) para alinear el
--  corte de escrituras auxiliares en Mongo y mantener idempotencia/atomicidad.
--
--  Reversión: 0004_commission_discount_claims_rollback.sql
-- =====================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notas       TEXT
);

CREATE TABLE IF NOT EXISTS driver_commission_discounts (
    driver_id    TEXT NOT NULL,
    travel_date  DATE NOT NULL,
    trip_id      TEXT,
    claimed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    source       TEXT NOT NULL DEFAULT 'app',
    PRIMARY KEY (driver_id, travel_date)
);

CREATE INDEX IF NOT EXISTS idx_driver_commission_discounts_trip
    ON driver_commission_discounts (trip_id);

INSERT INTO schema_migrations (version, notas)
VALUES ('0004_commission_discount_claims',
        'Tabla driver_commission_discounts para reclamo atómico diario del descuento de comisión')
ON CONFLICT (version) DO NOTHING;

COMMIT;
