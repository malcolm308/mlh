# Tarea 5 — Zonas especiales en PostGIS (`zones` + `ST_Contains`)

## Objetivo
Migrar la zona especial (p.ej. aeropuerto) desde el polígono JSON almacenado en `promociones` a una tabla PostGIS `zones` y resolver pertenencia con `ST_Contains` en estimate, creación y cierre de viajes, manteniendo compatibilidad transitoria.

## Esquema y migración
- Migración: `migrations/0002_zones_postgis.sql` (aditiva, idempotente)
  - `CREATE EXTENSION IF NOT EXISTS postgis`
  - `schema_migrations` + registro `0002_zones_postgis`
  - Tabla `zones`:
    - `id bigserial PK`, `code text UNIQUE`, `name text`, `active boolean`
    - `geom geography(MultiPolygon,4326)` con `CHECK (ST_IsValid(geom::geometry))`
    - `precio_km_zona_basico|confort|triciclo|moto numeric(12,2)`
    - `properties jsonb`, `source`, `created_at`, `updated_at`
  - Índices: GiST `idx_zones_geom`, parcial `idx_zones_active`
- Rollback: `migrations/0002_zones_postgis_rollback.sql` (elimina `zones` y registro; no elimina `postgis` ni campos legacy en `promociones`).

## Datos iniciales
- Script: `python scripts/migrar_zonas_postgis.py [--dry-run] [--code airport_special] [--name ...]`
  - Fuente: `promociones.zona_especial_coords`, `zona_especial_activa`, `precio_km_zona_*`
  - Convierte `[[lat,lng],...]` a GeoJSON `MultiPolygon` (lng,lat), cierra anillo, normaliza con `ST_MakeValid/ST_CollectionExtract(…,3)`
  - Upsert idempotente por `code` (`airport_special`)
  - Fallback a coordenadas/defaults si falta configuración (útil en BD de pruebas)
  - **Sin Mongo** (no hay fuente de zonas en Mongo; TODO: import opcional futuro si aparece)

## Lógica de pricing
- `routers/Solicitud_de_viajes_v4.py` resuelve zona activa con:
  - `ST_Contains(geom::geometry, ST_SetSRID(ST_MakePoint(lng,lat),4326))`
  - Aplicado en cálculo de precio por km de zona usado por estimate/creación/cierre (`_zona_especial_precio`, `_precio_km_por_zona`, `_price_breakdown`, reparto).
- **Fallback transitorio**: si la tabla/consulta `zones` no está disponible, se usa el polígono JSON de `promociones` (misma regla: destino o recogida dentro aplica tarifa de zona). Si `zones` existe pero no hay coincidencia, no se usa fallback.
- **Corte del fallback**: con `ZONAS_LEGACY_FALLBACK=0` (default `1` durante la transición) el pricing **no vuelve al JSON** aunque falle la consulta: toda decisión de zona viene de Postgres. Activar solo tras validar la migración.

## Compatibilidad y sincronización
- Campos legacy se mantienen en `promociones`: `zona_especial_coords`, `zona_especial_activa`, `precio_km_zona_*` (panel/`app_init` siguen leyéndolos).
- `routers/promociones.py` sincroniza best-effort `airport_special` en `zones` al guardar promociones/tarifas (`_sincronizar_zona_postgis`).
- `scripts/init_prices_usd.py` y `scripts/update_daily_prices.py` actualizan precios CUP/USD en `promociones` y sincronizan `zones.precio_km_zona_*`/estado desde `promociones` (best-effort si `zones` no existe).

## Despliegue / operación
1. Aplicar `0002_zones_postgis.sql` en Supabase (PostGIS requerido).
2. Ejecutar `python scripts/migrar_zonas_postgis.py` y validar: punto dentro/fuera devuelve esperado.
3. Verificar endpoints de estimate/create/complete con ubicaciones dentro y fuera de la zona.
4. Tras validación en producción, retirar campos legacy `zona_especial_*` de `promociones` y el fallback en código.

## Malla de calles en PostGIS (`streets`)
- Migración: `migrations/0005_streets_postgis.sql` (aditiva, idempotente; numerada `0005` porque `0003`/`0004` ya existían).
  - Tabla `streets`: `id bigserial PK`, `mongo_id text UNIQUE` (ObjectId hex), `nombre`, `geom geography(LineString,4326)` con `CHECK (ST_IsValid(...))`, `puntos`, `properties jsonb`, `source`, timestamps.
  - Índices: GiST `idx_streets_geom` y `idx_streets_nombre`.
  - Rollback: `migrations/0005_streets_postgis_rollback.sql` (no toca PostGIS, `zones` ni Mongo).
- Script: `python scripts/migrar_calles_postgis.py`
  - **Única lectura de Mongo del proyecto T5**: BD `Geo`, colección `calles` (~17,037 docs), solo lectura, con cursor *streaming*.
  - Prefiere `geom_geojson` (LineString/MultiLineString `[lon,lat]`); si falta usa `geom` (`[[lat,lon],...]`).
  - Escribe en Postgres con upsert por `mongo_id` → idempotente; normaliza geometrías con `ST_MakeValid`/`ST_CollectionExtract(...,2)`/`ST_Dump` y conserva el tramo más largo.
  - Opciones: `--dry-run`, `--limit N` (smoke test), `--batch-size N` (default 500), `--db`, `--collection`, `--uri`, `--verificar`.
  - No imprime la URI de Mongo (solo host:puerto).
- Verificación: `python scripts/migrar_calles_postgis.py --verificar` devuelve filas, inválidas, bbox, índices y registro de migración.
- `routers/geo.py` (buscador “entre calles”) **sigue leyendo Mongo** para no cambiar comportamiento; moverlo a `streets` es un paso posterior separado.

## Secuencia operativa (T5 completa)
1. Aplicar `0002_zones_postgis.sql` → `python scripts/migrar_zonas_postgis.py` (zona `airport_special`).
2. Aplicar `0005_streets_postgis.sql` → `python scripts/migrar_calles_postgis.py --dry-run --limit 100` y luego la migración completa.
3. Verificar zonas con `ST_Contains` (dentro/fuera) y calles con `--verificar`.
4. Solo tras validación en producción: retirar campos `zona_especial_*` de `promociones`, el fallback legacy y el lector de Mongo en `routers/geo.py`.

## Pruebas locales realizadas
- Compilación Python de módulos tocados.
- `python -m unittest tests.test_outbox_worker tests.test_wallet_schema tests.test_backfill_cuadre tests.test_wallet_service tests.test_wallet_api tests.test_tarifas_espera` → 111/111 OK.
- `python -m unittest tests.test_zones_postgis tests.test_calles_postgis -v` → zonas y streets (PostGIS local).
- Smoke en `taxi_db_test`: migración `0002` aplicada, `airport_special` válida, `ST_Contains` correcto (dentro/fuera).