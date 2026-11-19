# Informe de migración de saldos — dry-run sobre datos reales

> Ejecutado el 2026-11-19 con `scripts/backfill_saldo.py --dry-run`.
> **Modo solo lectura**: no se escribió nada en MongoDB ni en PostgreSQL.

## Resultado

| Métrica | Valor |
|---------|-------|
| Documentos con saldo revisados | 28 |
| Saldos reales a migrar | **1** |
| Saldos omitidos | **27** |
| Errores de conversión | 0 |
| Total a migrar | **154.975,92 CUP** |

## Qué hay realmente en MongoDB

### `Cliente.users` — 29 documentos

| Campo | Documentos con el campo | Saldo distinto de 0 | Suma |
|-------|------------------------|---------------------|------|
| `Fondo` | 29 | **0** | 0,00 CUP |
| `saldo_promocional` | 28 | 27 | 32.400,00 CUP (1.200 × 27) |

Los 27 saldos promocionales **están vencidos**: `fecha_expiracion_promocional`
ya pasó, y `saldo_promocional_vigente()` los devuelve como 0. La app ya los
trata como saldo muerto; el campo en Mongo conserva el número por la
expiración perezosa.

> **Consecuencia**: migrarlos como saldo real habría regalado 32.400 CUP.
> El backfill ahora aplica la misma regla de vigencia y los omite
> (`stats.omitidos`), guardando `metadata.expira_en` en los que sí estén
> vigentes para que el cron de la Tarea 6 los expire.

### `Chofer.users` — 66 documentos

| Campo | Documentos con el campo | Saldo distinto de 0 | Suma |
|-------|------------------------|---------------------|------|
| `Fondo` | 66 | **1** | 154.975,92 CUP |

El único chofer con saldo está `Enable: True` (cuenta activa). Es dinero real
que se le debe.

## Solapamiento de identificadores

Ningún `_id` existe a la vez en `Cliente.users` y `Chofer.users`, así que no
hay ambigüedad de tipo de usuario en esta base.

## Bloqueante encontrado

`POSTGRES_URL` en `.env.local` apunta a Supabase
`aws-0-us-east-1.pooler.supabase.com` con tenant `postgres.foexdaedzxmgeiddrfw`,
que **ya no existe**:

```
FATAL: (ENOTFOUND) tenant/user postgres.foexdaedzxmgeiddrfw not found
```

El backend en Render funciona, así que allí debe haber otro DSN. Hace falta el
`POSTGRES_URL` vigente para:

1. aplicar `0001_wallet_core.sql` en Supabase,
2. ejecutar el backfill real (`--escribir`),
3. correr `verificar_cuadre.py` y cerrar la Tarea 2 con 0 diferencias.

## Lo que escribirá el backfill cuando se autorice

Un solo asiento:

```
user_type      driver
user_id        (el único chofer con Fondo ≠ 0)
tipo           ajuste
monto_cents    15497592
idempotency    mig:driver:{id}:fondo
descripción    Saldo inicial migrado desde MongoDB (Fondo)
```

Ninguna escritura en Mongo. Ningún cliente recibe saldo por la campaña
vencida.

---

# Ejecución real (2026-11-19)

`POSTGRES_URL` vigente facilitado y guardado en `.env.local` (ignorado por
git). Proyecto Supabase accesible: PostgreSQL 17.11, 288 viajes.

### 1. Migración aplicada en Supabase

```
python scripts/aplicar_migraciones.py migrations/0001_wallet_core.sql
→ [OK]
```

Verificado: `schema_migrations` tiene `0001_wallet_core`; existen
`wallet_ledger`, `wallet_holds`, `outbox`, `v_wallet_saldos`; `trips` tiene
`monto_cents`, `fare_snapshot`, `client_display`, `driver_display`.
Los estados en uso (`cancelled`, `completed`, `expired`, `in_progress`)
cumplen el CHECK.

### 2. Backfill

```
python scripts/backfill_saldo.py --escribir
→ revisados 28 · insertados 1 · omitidos 27 · errores 0
```

### 3. Idempotencia comprobada

```
python scripts/backfill_saldo.py --escribir --reiniciar
→ insertados 0 · ya_existian 1 · omitidos 27 · errores 0
```

### 4. Cuadre

```
python scripts/verificar_cuadre.py
→ {"ok": true, "usuarios_mongo": 1, "usuarios_postgres": 1,
   "diferencias": 0, "solo_en_postgres": 0}
→ exit 0
```

### 5. Asiento resultante en Supabase

| Campo | Valor |
|-------|-------|
| `user_id` | `6abd9fa0aac15d405abc183a` |
| `user_type` | `driver` |
| `tipo` | `ajuste` |
| `monto_cents` | `15497592` |
| `moneda` | `CUP` |
| `idempotency_key` | `mig:driver:6abd9fa0aac15d405abc183a:fondo` |

Un asiento, 154.975,92 CUP. Ninguna escritura en MongoDB.

### Nota de seguridad

La cadena de conexión se compartió por chat. Conviene rotar la contraseña de
la base en Supabase y actualizarla en Render y `.env.local` cuando se haga la
Fase Final de seguridad.
