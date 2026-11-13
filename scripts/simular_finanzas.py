"""Simulacion de la liquidacion de viajes (Fase 3).

Reproduce, con Decimal y ROUND_HALF_UP, el mismo orden de calculo que
`routers/Solicitud_de_viajes_v4.py::complete_trip`:

    1. precio base del trayecto (base + distancia + tiempo)
    2. recargo por reintento (+10 % sobre el trayecto, sin propina)
    3. precio bruto (+ propina)
    4. descuento de promocion (si esta activo)
    5. descuento de referido (10 %, solo si NO hay descuento de promocion)
    6. recargo por transferencia (+10 % sobre lo que paga el cliente)
    7. liquidacion segun el metodo de pago (misma regla para los tres)
         comision nominal = tasa * precio bruto
         comision nominal >  descuento -> la plataforma absorbe el descuento
         comision nominal <= descuento -> el chofer asume el descuento y la
                                          comision se cobra sobre lo que paga
                                          el cliente

No toca Mongo ni Postgres: son numeros para revisar antes de desplegar.

Uso:
    python scripts/simular_finanzas.py
"""

from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP

CENT = Decimal("0.01")
REFERRAL_DISCOUNT_RATE = Decimal("0.10")
RETRY_SURCHARGE_RATE = Decimal("0.10")


def money(valor) -> Decimal:
    """Centimos con ROUND_HALF_UP, igual que `_a_dinero` del backend."""
    return Decimal(str(valor)).quantize(CENT, rounding=ROUND_HALF_UP)


def calcular(
    *,
    base: float,
    tip: float = 0.0,
    is_retry: bool = False,
    payment_method: str = "Efectivo",
    promo: dict,
    descuentos_referido: int = 0,
    saldo_cliente: float = 0.0,
    comision_rate: float | None = None,
) -> dict:
    """Liquida un viaje con las mismas reglas que `complete_trip`."""
    comision_rate = (promo["comision_porcentaje"]
                     if comision_rate is None else comision_rate)

    # 1-3. Trayecto, reintento y precio bruto.
    precio_base_viaje = money(base)
    recargo_reintento = (money(precio_base_viaje * RETRY_SURCHARGE_RATE)
                         if is_retry else Decimal("0"))
    precio_bruto = money(precio_base_viaje + recargo_reintento
                         + Decimal(str(tip)))

    # 4. Descuento de promocion: solo si esta activo, no expiro y hay comision
    #    de donde pagarlo. Nunca supera la comision nominal.
    descuento_promo = Decimal("0")
    if (promo.get("descuento_activo") and not promo.get("expirada")
            and Decimal(str(promo["comision_porcentaje"])) > 0
            and promo.get("descuento_porcentaje", 0) > 0):
        descuento_promo = money(
            precio_bruto * Decimal(str(promo["descuento_porcentaje"])))
        tope = money(precio_bruto * Decimal(str(promo["comision_porcentaje"])))
        descuento_promo = min(descuento_promo, tope)

    # 5. Descuento de referido: 10 %, NO acumulable con la promocion.
    descuento_referido = Decimal("0")
    if (promo.get("referidos_activos", True) and descuentos_referido > 0
            and descuento_promo == 0):
        descuento_referido = money(precio_bruto * REFERRAL_DISCOUNT_RATE)

    precio_neto = money(precio_bruto - descuento_promo - descuento_referido)

    # 6. Recargo por transferencia: +10 % sobre lo que pagaria el cliente.
    recargo_transferencia = Decimal("0")
    if payment_method == "Transferencia":
        recargo_transferencia = money(
            precio_neto * Decimal(str(promo["recargo_transferencia"])))
    total_fare = money(precio_neto + recargo_transferencia)

    # 7. Liquidacion con la regla unica (igual que `liquidar_comision`).
    def liquidar(tasa, cobrado):
        nominal = money(precio_bruto * Decimal(str(tasa)))
        descuento = descuento_promo + descuento_referido
        if nominal > descuento:
            cobrada = money(nominal - descuento)
        else:
            cobrada = money(Decimal(str(cobrado)) * Decimal(str(tasa)))
        cobrada = max(Decimal("0"), min(cobrada, Decimal(str(cobrado))))
        return nominal, cobrada

    comision_nominal = Decimal("0")
    comision_cobrada = Decimal("0")
    neto_chofer = Decimal("0")
    saldo_debitado = Decimal("0")
    nota = ""

    if payment_method == "Billetera":
        saldo_debitado = money(min(saldo_cliente, float(total_fare)))
        comision_nominal, comision_cobrada = liquidar(
            promo["comision_billetera"], saldo_debitado)
        neto_chofer = money(saldo_debitado - comision_cobrada)
        abono_chofer = saldo_debitado
        nota = ("Fondo del chofer +%s (total) y -%s (comision) = +%s"
                % (saldo_debitado, comision_cobrada, neto_chofer))
    elif payment_method == "Transferencia":
        # Igual que efectivo: el chofer ya tiene el dinero de la transferencia
        # y la comision se le descuenta del Fondo.
        comision_nominal, comision_cobrada = liquidar(
            comision_rate, total_fare)
        neto_chofer = money(total_fare - comision_cobrada)
        abono_chofer = total_fare
        nota = ("El chofer cobra %s por transferencia; se le descuentan %s "
                "del Fondo" % (total_fare, comision_cobrada))
    else:
        comision_nominal, comision_cobrada = liquidar(
            comision_rate, total_fare)
        # El pasajero le paga `total_fare` en efectivo y la plataforma le
        # descuenta la comision del Fondo: neto = cobrado - comision.
        neto_chofer = money(total_fare - comision_cobrada)
        abono_chofer = total_fare
        nota = ("El chofer cobra %s en efectivo; se le descuentan %s del Fondo"
                % (total_fare, comision_cobrada))

    return {
        "precio_base_viaje": precio_base_viaje,
        "recargo_reintento": recargo_reintento,
        "tip": money(tip),
        "precio_bruto": precio_bruto,
        "descuento_promo": descuento_promo,
        "descuento_referido": descuento_referido,
        "precio_neto": precio_neto,
        "recargo_transferencia": recargo_transferencia,
        "total_fare": total_fare,
        "saldo_debitado": saldo_debitado,
        "comision_nominal": comision_nominal,
        "comision_cobrada": comision_cobrada,
        "abono_chofer": abono_chofer,
        "neto_chofer": neto_chofer,
        "nota": nota,
    }


def imprimir(titulo: str, r: dict) -> None:
    print("\n" + "=" * 68)
    print(titulo)
    print("-" * 68)
    for clave in (
        "precio_base_viaje", "recargo_reintento", "tip", "precio_bruto",
        "descuento_promo", "descuento_referido", "precio_neto",
        "recargo_transferencia", "total_fare", "saldo_debitado",
        "comision_nominal", "comision_cobrada", "abono_chofer", "neto_chofer",
    ):
        print("  %-24s %10.2f CUP" % (clave, float(r[clave])))
    if r["nota"]:
        print("  %-24s %s" % ("movimiento", r["nota"]))


def main() -> None:
    # Configuracion REAL de produccion en el momento de esta prueba:
    # comision de plataforma 0 %, comision de billetera 0 %, recargo 10 %,
    # referidos activos. El panel puede cambiar estos valores.
    prod = {
        "comision_porcentaje": 0.0,
        "comision_billetera": 0.0,
        "recargo_transferencia": 0.10,
        "descuento_activo": False,
        "descuento_porcentaje": 0.0,
        "referidos_activos": True,
        "expirada": False,
    }

    print("CONFIGURACION DE PRODUCCION")
    print("  comision plataforma   : 0.00 %")
    print("  comision billetera    : 0.00 %")
    print("  recargo transferencia : 10.00 %")
    print("  descuento referido    : 10.00 % (no acumulable)")
    print("  bono chofer referido  : 500.00 CUP (fijo)")

    # ---------------- Los 3 viajes pedidos ----------------
    v1 = calcular(base=1000, payment_method="Efectivo", promo=prod)
    imprimir("VIAJE 1 - EFECTIVO NORMAL (base 1000, sin descuentos)", v1)

    v2 = calcular(base=1000, payment_method="Transferencia", promo=prod)
    imprimir("VIAJE 2 - TRANSFERENCIA (base 1000, recargo +10 %)", v2)

    v3 = calcular(base=1000, payment_method="Billetera", promo=prod,
                  descuentos_referido=1, saldo_cliente=2000)
    imprimir("VIAJE 3 - BILLETERA + REFERIDO (base 1000, 1 credito)", v3)

    # ---------------- Controles de las reglas ----------------
    reintento = calcular(base=1000, is_retry=True,
                         payment_method="Transferencia", promo=prod)
    imprimir("CONTROL - REINTENTO + TRANSFERENCIA (1000 +10 % +10 %)", reintento)

    promo_activa = dict(prod, descuento_activo=True,
                        comision_porcentaje=0.15,
                        descuento_porcentaje=0.10)
    no_acumula = calcular(base=1000, payment_method="Efectivo",
                          promo=promo_activa, descuentos_referido=1)
    imprimir("CONTROL - PROMOCION 10 % + REFERIDO (no deben acumularse)",
             no_acumula)

    con_comision = dict(prod, comision_porcentaje=0.15,
                        comision_billetera=0.10)
    cash_15 = calcular(base=1000, payment_method="Efectivo",
                       promo=con_comision, descuentos_referido=1)
    imprimir("CONTROL - EFECTIVO 15 % + REFERIDO (la plataforma lo asume)",
             cash_15)

    wallet_10 = calcular(base=1000, payment_method="Billetera",
                         promo=con_comision, saldo_cliente=2000)
    imprimir("CONTROL - BILLETERA CON COMISION 10 % (cambiable en el panel)",
             wallet_10)

    transfer_15 = calcular(base=1000, payment_method="Transferencia",
                           promo=con_comision, descuentos_referido=1)
    imprimir("CONTROL - TRANSFERENCIA 15 % + REFERIDO (plataforma absorbe)",
             transfer_15)

    cash_5 = calcular(base=1000, payment_method="Efectivo",
                      promo=dict(prod, comision_porcentaje=0.05),
                      descuentos_referido=1)
    imprimir("CONTROL - EFECTIVO 5 % + REFERIDO (comision <= descuento: "
             "asume el chofer)", cash_5)

    cash_0 = calcular(base=1000, payment_method="Efectivo", promo=prod,
                      descuentos_referido=1)
    imprimir("CONTROL - EFECTIVO 0 % + REFERIDO (chofer recibe 900)", cash_0)

    # ---------------- Assertions ----------------
    def eq(nombre, real, esperado):
        real = money(real)
        esperado = money(esperado)
        assert real == esperado, "%s: %s != %s" % (nombre, real, esperado)
        print("  OK  %-38s %10.2f" % (nombre, float(real)))

    print("\n" + "=" * 68)
    print("VERIFICACIONES")
    print("-" * 68)
    eq("Viaje 1 total", v1["total_fare"], 1000)
    eq("Viaje 1 comision plataforma", v1["comision_cobrada"], 0)
    eq("Viaje 1 neto chofer", v1["neto_chofer"], 1000)

    eq("Viaje 2 total (1000 + 10 %)", v2["total_fare"], 1100)
    eq("Viaje 2 recargo transferencia", v2["recargo_transferencia"], 100)
    eq("Viaje 2 comision plataforma (0 %)", v2["comision_cobrada"], 0)
    eq("Viaje 2 neto chofer", v2["neto_chofer"], 1100)

    eq("Viaje 3 descuento referido (10 %)", v3["descuento_referido"], 100)
    eq("Viaje 3 total (1000 - 100)", v3["total_fare"], 900)
    eq("Viaje 3 comision billetera (0 %)", v3["comision_cobrada"], 0)
    eq("Viaje 3 neto chofer", v3["neto_chofer"], 900)

    eq("Reintento: recargo 10 %", reintento["recargo_reintento"], 100)
    eq("Reintento + transferencia: total", reintento["total_fare"], 1210)
    eq("Reintento + transferencia: recargo", reintento["recargo_transferencia"], 110)
    eq("Promocion 10 % (referido NO se suma)", no_acumula["descuento_promo"], 100)
    eq("Promocion 10 % (referido = 0)", no_acumula["descuento_referido"], 0)

    eq("Efectivo 15 %: comision nominal", cash_15["comision_nominal"], 150)
    eq("Efectivo 15 % - referido 10 %", cash_15["comision_cobrada"], 50)
    eq("Efectivo 15 % - cobrado al cliente", cash_15["total_fare"], 900)
    eq("Efectivo 15 % - neto chofer", cash_15["neto_chofer"], 850)

    eq("Billetera 10 %: comision", wallet_10["comision_cobrada"], 100)
    eq("Billetera 10 %: abono total al chofer", wallet_10["abono_chofer"], 1000)
    eq("Billetera 10 %: neto chofer", wallet_10["neto_chofer"], 900)
    eq("Billetera 10 %: abono - comision = neto",
       wallet_10["abono_chofer"] - wallet_10["comision_cobrada"],
       wallet_10["neto_chofer"])

    # Comision 15 % > descuento 10 %: la plataforma absorbe el descuento.
    eq("Transferencia 15 %: comision nominal", transfer_15["comision_nominal"], 150)
    eq("Transferencia 15 % + referido: comision cobrada",
       transfer_15["comision_cobrada"], 50)
    eq("Transferencia 15 %: total con recargo", transfer_15["total_fare"], 990)
    eq("Transferencia 15 %: neto chofer (bruto - nominal + recargo)",
       transfer_15["neto_chofer"], 940)

    # Comision 5 % < descuento 10 %: el chofer asume el descuento.
    eq("Efectivo 5 %: comision nominal", cash_5["comision_nominal"], 50)
    eq("Efectivo 5 % + referido: comision sobre lo cobrado",
       cash_5["comision_cobrada"], 45)
    eq("Efectivo 5 %: neto chofer", cash_5["neto_chofer"], 855)

    # Comision 0 %: el chofer asume todo el descuento (caso actual).
    eq("Efectivo 0 % + referido: comision", cash_0["comision_cobrada"], 0)
    eq("Efectivo 0 % + referido: total", cash_0["total_fare"], 900)
    eq("Efectivo 0 % + referido: chofer recibe", cash_0["neto_chofer"], 900)

    bono_referido_chofer = money(500)
    eq("Bono fijo al chofer referidor", bono_referido_chofer, 500)

    print("\nTodas las verificaciones pasaron.")


if __name__ == "__main__":
    main()
