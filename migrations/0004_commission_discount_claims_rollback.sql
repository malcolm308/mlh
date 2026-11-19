-- =====================================================================
--  0004_commission_discount_claims_rollback.sql
-- =====================================================================

BEGIN;

DROP TABLE IF EXISTS driver_commission_discounts;
DELETE FROM schema_migrations WHERE version = '0004_commission_discount_claims';

COMMIT;
