# Tarea 3 — Billetera transaccional

> Estado: **completada**. Todo el código nuevo está detrás de flags apagados:
> desplegarlo no cambia el comportamiento actual.
>
> Fecha: 2026-11-19

## Qué se construyó

| Archivo | Estado | Contenido |
|---|---|---|
| `app/wallet/service.py` | nuevo | Reservas, capturas, liberaciones, recargas, descargos y expiración |
| `app/wallet/errors.py` | nuevo | Errores de dominio (`SaldoInsuficiente`, `EstadoViajeInvalido`, `MontoInvalido`, `ViajeNoEncontrado`) |
| `app/outbox/events.py` | nuevo | Payloads Pydantic versionados + `encolar()` |
| `app/outbox/__init__.py` | nuevo | Paquete del worker (Tarea 4) |
| `routers/Solicitud_de_viajes_v4.py` | modificado | `create_trip`, `complete_trip`, `cancel_trip`, `get_connection` |
| `routers/billetera.py` | modificado | Dual-write en las 4 operaciones de caja + bono de referido |
| `tests/test_wallet_service.py` | nuevo | 12 pruebas del servicio |
| `tests/test_wallet_api.py` | nuevo | 3 pruebas del cableado HTTP |

## Garantías implementadas

1. **Ninguna decisión de cobro lee MongoDB.**
   Con `WALLET_ENFORCE_HOLD` encendido, la validación legacy contra Mongo se
   salta y el saldo lo decide `saldo_disponible()` en PostgreSQL, dentro de la
   misma transacción del viaje.

2. **El hold y el viaje son atómicos.**
   `create_trip` inserta el viaje y luego llama a `reservar_hold` **antes del
   commit**. Si no hay saldo, `SaldoInsuficiente` dispara el `rollback`: no
   queda viaje, ni reserva, ni evento. El endpoint devuelve **402**.

3. **Serialización por usuario.**
   `wallet_lock_user()` toma un advisory lock de transacción antes de leer el
   saldo. Dos viajes simultáneos del mismo cliente no pueden ver el mismo
   disponible.

4. **Cobro idempotente.**
   La captura usa `trip:{trip_id}:captura` como `idempotency_key` con
   `ON CONFLICT DO NOTHING`. Reintentar no cobra dos veces. La reserva pasa de
   `activa` a `capturada`; un segundo intento devuelve `ya_capturada`.

5. **Cancelar libera sin mover dinero.**
   `cancel_trip` marca la reserva como `liberada` en la misma transacción de
   la cancelación. No se inserta ningún asiento: la reserva nunca fue un
   cobro.

6. **Outbox transaccional.**
   `trip.created`, `trip.completed`, `trip.cancelled` y `wallet.changed` se
   escriben con `encolar()` en la misma transacción que el dinero. Si la
   transacción revierte, el evento desaparece con ella.

7. **Cierre con tarifa auditable.**
   `complete_trip` guarda `monto_cents` y `fare_snapshot` (base, distancia,
   propina, descuentos, recargos, coeficiente, espera) en el mismo `UPDATE` que
   marca el viaje como `completed`.

## Flags

| Flag | Efecto en este código |
|---|---|
| `WALLET_DUAL_WRITE` | escribe ledger, holds y eventos; Mongo sigue escribiéndose igual |
| `WALLET_ENFORCE_HOLD` | exige saldo en PostgreSQL y devuelve 402; ignora la validación legacy contra Mongo |
| `WALLET_LEGACY_MONGO_WRITES` | todavía no se consulta aquí: el bloque de dinero de Mongo sigue activo |
| `OUTBOX_WORKER_ENABLED` | lo usará la Tarea 4 |

Los flags se leen al arrancar el proceso: cambiarlos exige reiniciar el
servicio.

### Orden de despliegue recomendado

1. `WALLET_DUAL_WRITE=1` — se llenan ledger/holds/outbox mientras la app sigue
   leyendo Mongo. El cuadre de **clientes** debe quedar en 0 diferencias.
2. Observar una semana (holds que expiran, capturas, cancelaciones).
3. `WALLET_ENFORCE_HOLD=1` — el 402 pasa a ser la fuente de verdad.
4. Tarea 4 (worker) y luego `WALLET_LEGACY_MONGO_WRITES=0`.
5. `WALLET_READ_SOURCE=postgres` en los endpoints de saldo.

## Criterios de aceptación

| Criterio | Prueba | Resultado |
|---|---|---|
| Saldo exacto → hold y disponible 0 | `test_saldo_exacto_reserva_todo_y_disponible_queda_en_cero` | OK |
| Saldo menor → 402 sin viaje | `test_saldo_menor_no_crea_viaje_ni_reserva` + `test_saldo_insuficiente_devuelve_402` | OK |
| Cancelación libera el hold | `test_cancelar_libera_la_reserva` + `test_cancelar_libera_el_hold_y_encola_el_evento` | OK |
| Reproceso sin duplicar | `test_capturar_cobra_una_sola_vez`, `test_reserva_duplicada_devuelve_la_misma`, `test_recarga_y_descargo_con_idempotencia` | OK |
| 20 viajes concurrentes sin negativo ni doble cobro | `test_veinte_viajes_concurrentes_no_sobregiran` | OK |
| Tarifa final mayor que el saldo no deja negativo | `test_captura_parcial_nunca_deja_saldo_negativo` | OK |
| Evento y dinero revierten juntos | `test_outbox_se_revierte_con_la_transaccion` | OK |

Ejecución completa: **44 tests OK** (`test_wallet_schema`, `test_backfill_cuadre`,
`test_wallet_service`, `test_wallet_api`).

```
Ran 44 tests in 2.406s
OK
```

## Cambio de comportamiento en `get_connection()`

El context manager ahora hace `rollback()` si el bloque lanza. Antes devolvía
la conexión al pool con una transacción abortada y la siguiente petición que
la reutilizara fallaba con `current transaction is aborted`. No cambia ningún
flujo exitoso: los `commit()` siguen siendo explícitos.

## Deuda consciente (no es un olvido)

* **El abono al chofer sigue solo en Mongo.** En `complete_trip`, el crédito
  `monto_billetera_chofer` y la comisión se calculan **después** del commit y
  leyendo Mongo. Moverlos antes del commit es un refactor del reparto de
  dinero que corresponde a la Tarea 4, cuando el worker ya pueda aplicar el
  evento. Mientras tanto, el cuadre de **choferes** puede mostrar diferencias
  por los viajes nuevos; el de **clientes** debe quedar en 0.
* **`saldo_promocional`**: el backfill solo migró promociones vigentes. Un
  cliente con promo activa en Mongo que no esté en el ledger vería un 402 si
  se enciende `WALLET_ENFORCE_HOLD` antes de re-ejecutar el backfill.
* **Expiración**: `expirar_holds()` está listo pero nadie lo llama todavía.
  Se conecta al cron en la Tarea 6 (`pg_cron` no está instalado; se usará
  APScheduler).
