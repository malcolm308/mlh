"""Simulacion del Pago Mixto de campana: saldo promocional + bono al chofer.

Reproduce, con la misma aritmetica que el backend, las formulas de:

    routers/Solicitud_de_viajes_v4.py   (desglose_campana_cotizacion,
                                         create_trip, complete_trip)
    routers/campana_promocional.py      (saldo_promocional_vigente,
                                         bono_promocional)

Reglas que se comprueban aqui:

1. El recargo por transferencia (10 %) se aplica al precio base ANTES de usar
   la bolsa promocional.
2. La bolsa promocional es acumulativa: se descuenta carrera por carrera y el
   resto queda para el proximo viaje hasta agotarse o expirar.
3. `monto_billetera` (lo que la plataforma le abona al chofer por la promo) es
   `min(saldo_promocional, precio_final)`.
4. `monto_efectivo` es `precio_final - monto_billetera` y el chofer lo cobra en
   mano (Efectivo) o por fuera (Transferencia).
5. El bono es el `monto_bono_chofer` configurado en la campana y SOLO se paga
   si el cliente uso saldo promocional en ese viaje. Si no uso promo, es 0.
6. Al chofer se le acredita en su Fondo: `monto_billetera + bono`.
7. Al cliente se le resta de su saldo promocional: `monto_billetera`.

Escenario obligatorio (bono 500 CUP, saldo promocional 1500 CUP):

    Viaje 1  base 500 por Transferencia (+10 % = 550), usa promo
    Viaje 2  base 300 en Efectivo, usa promo
    Viaje 3  base 200 en Efectivo, sin promo (la campana ya expiro)

El script no toca la base de datos ni la red: es una simulacion pura que se
puede correr en cualquier maquina con Python 3.

Uso:
    python scripts/test_pagos.py
"""

from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP

CENT = Decimal("0.01")

# Valores configurados en la campana.
BONO_CHOFER_CAMPANA = Decimal("500.00")
SALDO_PROMOCIONAL_INICIAL = Decimal("1500.00")

# Recargo configurado para pago por Transferencia (panel de promociones).
RECARGO_TRANSFERENCIA = Decimal("0.10")


def money(valor) -> Decimal:
    """Redondea a centimos como el backend (ROUND_HALF_UP)."""
    return Decimal(str(valor)).quantize(CENT, rounding=ROUND_HALF_UP)


def precio_con_recargo(base: Decimal, metodo: str) -> tuple[Decimal, Decimal]:
    """Precio final del viaje y recargo aplicado.

    El recargo por transferencia entra en el precio ANTES de la promo, que es
    la regla nueva: la bolsa tambien puede cubrir el recargo.
    """
    recargo = (
        money(base * RECARGO_TRANSFERENCIA)
        if metodo == "Transferencia"
        else Decimal("0.00")
    )
    return money(base + recargo), recargo


def liquidar_viaje(
    *,
    base: float,
    metodo: str,
    saldo_promocional: Decimal,
    usar_promo: bool = True,
    bono_config: Decimal = BONO_CHOFER_CAMPANA,
) -> dict:
    """Reparte un viaje entre bolsa promocional, efectivo y bono.

    `usar_promo=False` modela un viaje sin campana (expirada o cliente sin
    saldo): el pasajero paga todo con su metodo y el chofer no recibe bono.
    """
    precio_base = money(base)
    precio_final, recargo = precio_con_recargo(precio_base, metodo)

    saldo_guardado = money(max(Decimal("0"), saldo_promocional))
    saldo = saldo_guardado if usar_promo else Decimal("0.00")

    # monto_billetera = min(saldo_promocional, precio_final)
    promo_usado = min(saldo, precio_final)
    # monto_efectivo = precio_final - monto_billetera
    monto_efectivo = money(precio_final - promo_usado)

    # El bono solo existe si el cliente uso saldo promocional.
    bono = money(bono_config) if promo_usado > 0 else Decimal("0.00")

    abono_billetera = money(promo_usado + bono)
    saldo_restante = money(saldo_guardado - promo_usado)

    # Lo que el chofer cobra por fuera de la billetera: en Efectivo lo cobra
    # en mano; en Transferencia lo recibe externo. En ambos casos no entra al
    # Fondo virtual, que solo recibe promo + bono.
    cobro_fuera = monto_efectivo

    return {
        "metodo": metodo,
        "precio_base": precio_base,
        "recargo_transferencia": recargo,
        "precio_final": precio_final,
        "saldo_promocional_disponible": saldo,
        "monto_billetera": promo_usado,
        "monto_efectivo": monto_efectivo,
        "saldo_promocional_restante": saldo_restante,
        "bono_chofer": bono,
        "abono_billetera_chofer": abono_billetera,
        "cobro_fuera_billetera": cobro_fuera,
        "total_chofer": money(abono_billetera + cobro_fuera),
        "costo_plataforma": money(promo_usado + bono),
    }


def comprobar(nombre: str, real, esperado) -> None:
    real = money(real)
    esperado = money(esperado)
    if real != esperado:
        raise AssertionError(
            "%s: se esperaba %s CUP y salieron %s CUP"
            % (nombre, esperado, real)
        )
    print("    OK  %-32s %12.2f CUP" % (nombre, float(real)))


def imprimir(titulo: str, r: dict, saldo_antes: Decimal) -> None:
    print("\n" + "=" * 72)
    print(titulo)
    print("-" * 72)
    print("  Datos del viaje")
    print("    %-32s %12s" % ("metodo de pago", r["metodo"]))
    print("    %-32s %12.2f CUP" % ("precio base", float(r["precio_base"])))
    print("    %-32s %12.2f CUP" % (
        "recargo transferencia", float(r["recargo_transferencia"])))
    print("    %-32s %12.2f CUP" % ("precio final", float(r["precio_final"])))
    print("    %-32s %12.2f CUP" % (
        "saldo promocional antes", float(saldo_antes)))
    print("  Lo que paga el cliente")
    print("    %-32s %12.2f CUP" % (
        "bolsa promocional usada", float(r["monto_billetera"])))
    print("    %-32s %12.2f CUP" % (
        "a pagar por el metodo", float(r["monto_efectivo"])))
    print("    %-32s %12.2f CUP" % (
        "saldo promocional restante", float(r["saldo_promocional_restante"])))
    print("  Lo que recibe el chofer")
    print("    %-32s %12.2f CUP" % (
        "abono a billetera (promo)", float(r["monto_billetera"])))
    print("    %-32s %12.2f CUP" % ("bono de campana", float(r["bono_chofer"])))
    print("    %-32s %12.2f CUP" % (
        "total abonado a billetera", float(r["abono_billetera_chofer"])))
    print("    %-32s %12.2f CUP" % (
        "cobrado fuera (mano/transf.)", float(r["cobro_fuera_billetera"])))
    print("    %-32s %12.2f CUP" % ("total del chofer", float(r["total_chofer"])))
    print("  Costo de la campana para la plataforma")
    print("    %-32s %12.2f CUP" % (
        "promo + bono", float(r["costo_plataforma"])))


def main() -> None:
    saldo = SALDO_PROMOCIONAL_INICIAL

    print("=" * 72)
    print("SIMULACION PAGO MIXTO DE CAMPANA")
    print("bono por viaje: %.2f CUP | saldo promocional: %.2f CUP | "
          "recargo transferencia: %.0f %%"
          % (float(BONO_CHOFER_CAMPANA), float(SALDO_PROMOCIONAL_INICIAL),
             float(RECARGO_TRANSFERENCIA * 100)))
    print("=" * 72)

    # ------------------------------------------------------------------
    # Viaje 1: base 500 por Transferencia (550). Usa promo.
    # ------------------------------------------------------------------
    viaje1 = liquidar_viaje(
        base=500, metodo="Transferencia", saldo_promocional=saldo)
    imprimir("VIAJE 1 - base 500 CUP por Transferencia (+10 %), usa promo",
             viaje1, saldo)
    comprobar("recargo transferencia", viaje1["recargo_transferencia"], 50)
    comprobar("precio final transferencia", viaje1["precio_final"], 550)
    comprobar("promo usada", viaje1["monto_billetera"], 550)
    comprobar("paga el cliente", viaje1["monto_efectivo"], 0)
    comprobar("saldo del cliente", viaje1["saldo_promocional_restante"], 950)
    comprobar("bono del chofer", viaje1["bono_chofer"], 500)
    comprobar("abono a billetera del chofer",
              viaje1["abono_billetera_chofer"], 1050)
    comprobar("efectivo/transferencia en mano",
              viaje1["cobro_fuera_billetera"], 0)

    saldo = viaje1["saldo_promocional_restante"]

    # ------------------------------------------------------------------
    # Viaje 2: base 300 en Efectivo. Usa promo.
    # ------------------------------------------------------------------
    viaje2 = liquidar_viaje(
        base=300, metodo="Efectivo", saldo_promocional=saldo)
    imprimir("VIAJE 2 - base 300 CUP en Efectivo, usa promo", viaje2, saldo)
    comprobar("precio final", viaje2["precio_final"], 300)
    comprobar("promo usada", viaje2["monto_billetera"], 300)
    comprobar("paga el cliente", viaje2["monto_efectivo"], 0)
    comprobar("saldo del cliente", viaje2["saldo_promocional_restante"], 650)
    comprobar("bono del chofer", viaje2["bono_chofer"], 500)
    comprobar("abono a billetera del chofer",
              viaje2["abono_billetera_chofer"], 800)
    comprobar("efectivo/transferencia en mano",
              viaje2["cobro_fuera_billetera"], 0)

    saldo = viaje2["saldo_promocional_restante"]

    # ------------------------------------------------------------------
    # Viaje 3: base 200 en Efectivo. Sin promo (campana expirada).
    # ------------------------------------------------------------------
    viaje3 = liquidar_viaje(
        base=200, metodo="Efectivo", saldo_promocional=saldo, usar_promo=False)
    imprimir("VIAJE 3 - base 200 CUP en Efectivo, sin promo (campana expirada)",
             viaje3, saldo)
    comprobar("precio final", viaje3["precio_final"], 200)
    comprobar("promo usada", viaje3["monto_billetera"], 0)
    comprobar("paga el cliente en mano", viaje3["monto_efectivo"], 200)
    comprobar("saldo del cliente (no se toca)", 
              viaje3["saldo_promocional_restante"], 650)
    comprobar("bono del chofer (sin promo)", viaje3["bono_chofer"], 0)
    comprobar("abono a billetera del chofer",
              viaje3["abono_billetera_chofer"], 0)
    comprobar("efectivo en mano", viaje3["cobro_fuera_billetera"], 200)
    comprobar("total del chofer", viaje3["total_chofer"], 200)

    # ------------------------------------------------------------------
    # Resumen de la jornada.
    # ------------------------------------------------------------------
    total_billetera = money(
        viaje1["abono_billetera_chofer"] + viaje2["abono_billetera_chofer"]
        + viaje3["abono_billetera_chofer"])
    total_mano = money(
        viaje1["cobro_fuera_billetera"] + viaje2["cobro_fuera_billetera"]
        + viaje3["cobro_fuera_billetera"])
    total_bono = money(
        viaje1["bono_chofer"] + viaje2["bono_chofer"] + viaje3["bono_chofer"])
    total_promo = money(
        viaje1["monto_billetera"] + viaje2["monto_billetera"]
        + viaje3["monto_billetera"])

    print("\n" + "=" * 72)
    print("RESUMEN DE LA JORNADA")
    print("-" * 72)
    comprobar("promo total usada por el cliente", total_promo, 850)
    comprobar("saldo promocional final del cliente", saldo, 650)
    comprobar("bonos pagados al chofer", total_bono, 1000)
    comprobar("acreditado en billetera del chofer", total_billetera, 1850)
    comprobar("cobrado en mano", total_mano, 200)
    comprobar("total del chofer en los 3 viajes",
              total_billetera + total_mano, 2050)

    print("\n" + "=" * 72)
    print("TODAS LAS COMPROBACIONES PASARON")
    print("=" * 72)


if __name__ == "__main__":
    main()
