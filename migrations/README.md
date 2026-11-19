# Migraciones de base de datos

Cada migración es **aditiva e idempotente** y tiene su `*_rollback.sql`.
Se aplican con `scripts/aplicar_migraciones.py` (lee `POSTGRES_URL` o las
variables `DB_*` de la app).

## Aplicar

```powershell
$env:POSTGRES_URL = "postgresql://usuario:clave@host:5432/taxi_db"
python scripts/aplicar_migraciones.py migrations/0001_wallet_core.sql
```

En Supabase el DDL se ejecuta con el rol administrador del proyecto. La
aplicación, en cambio, debe usar un rol con privilegios mínimos (ver
`docs/REPORTE_SEGURIDAD.md`).

## Revertir

```powershell
python scripts/aplicar_migraciones.py migrations/0001_wallet_core_rollback.sql --si
```

El rollback de `0001` **se niega a borrar el libro mayor si tiene asientos**.
Antes del cutover es seguro; después del cutover el rollback real es apagar
los feature flags `WALLET_*`, nunca borrar tablas.

## Base de pruebas local

Los tests de `tests/test_wallet_*.py` necesitan un PostgreSQL con el esquema
real de `trips`. La forma de crearlo sin inventar DDL es ejecutar el mismo
`init_db()` que corre la app:

```powershell
python tools/crear_bd_pruebas.py taxi_db_test
$env:TEST_POSTGRES_URL = "postgresql://postgres@localhost:5432/taxi_db_test"
python -m unittest tests.test_wallet_schema -v
```

## Orden

| Versión | Contenido | Reversible |
|---------|-----------|------------|
| `0001_wallet_core` | enum `trip_status`, columnas de `trips`, `wallet_ledger`, `wallet_holds`, `outbox`, `saldo_disponible()`, `wallet_lock_user()`, `v_wallet_saldos` | Sí |
| `0002_zones_postgis` | tabla `zones` (`MultiPolygon` + GiST); datos desde `promociones` (Postgres) | Sí |
| `0003_holds_expiry_pgcron` | función `expirar_holds_y_viajes()` + job `pg_cron` | Sí |
| `0004_commission_discount_claims` | tabla `driver_commission_discounts` (reclamo diario atómico) | Sí |
| `0005_streets_postgis` | tabla `streets` (`LineString` + GiST); datos desde Mongo `Geo.calles` | Sí |

> Nota de orden: `0005_streets_postgis` se numeró después de `0003`/`0004`, que ya existían.
> La carga de datos NO la hace el `.sql`: `0002` usa `scripts/migrar_zonas_postgis.py`
> (solo Postgres) y `0005` usa `scripts/migrar_calles_postgis.py` (única lectura de Mongo).
