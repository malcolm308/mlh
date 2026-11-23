"""Simulacion: cobro estricto con saldo promocional + metodo de pago.

Reglas implementadas (las mismas de `calcular_pago_mixto` en el backend):
- El saldo promocional se aplica SIEMPRE primero, hasta el precio.
- monto_excedente = precio_final - saldo_promocional_usado.
- Efectivo / Transferencia: el saldo real del cliente NO se toca. Todo el
  excedente se cobra por fuera con ese metodo.
- Billetera: el excedente se descuenta del saldo real; si no alcanza, la parte
  que falta queda como excedente sin metodo externo.
- monto_billetera_chofer = promo + saldo real usado + bono (solo si uso promo).

Escenario principal:
  Viaje 500 CUP, cliente con 200 promo y 150 fondo, pago en Efectivo.
  Verificar: chofer recibe 200 + Bono en billetera y cobra 300 en efectivo.
  El Fondo real del cliente NO cambia (antes se debitaban 150 y habia doble
  cobro).
"""
from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP

CENT = Decimal("0.01")


def money(v) -> Decimal:
    return Decimal(str(v)).quantize(CENT, rounding=ROUND_HALF_UP)


def liquidar(precio_final, saldo_promo, saldo_real, metodo="Efectivo",
             bono_config=Decimal("500.00")):
    precio = money(precio_final)
    promo = money(max(Decimal("0"), saldo_promo))
    real = money(max(Decimal("0"), saldo_real))
    bono_config = money(bono_config)

    # 1. Promo primero, sin importar el metodo.
    promo_usado = money(min(promo, precio))
    resto = money(precio - promo_usado)

    # 2. El resto solo sale del Fondo real con Billetera.
    if metodo == "Billetera":
        real_usado = money(min(resto, real))
        monto_excedente = money(resto - real_usado)
        metodo_excedente = None
    else:
        real_usado = Decimal("0.00")
        monto_excedente = resto
        metodo_excedente = metodo if monto_excedente > 0 else None

    pago_billetera_total = money(promo_usado + real_usado)
    promo_restante = money(promo - promo_usado)
    real_restante = money(real - real_usado)

    # 3. Bono solo si uso saldo promocional.
    bono = money(bono_config) if promo_usado > 0 else Decimal("0.00")
    monto_billetera_chofer = money(pago_billetera_total + bono)

    return {
        "precio_final": precio,
        "metodo": metodo,
        "pago_billetera_total": pago_billetera_total,
        "monto_excedente": monto_excedente,
        "metodo_pago_excedente": metodo_excedente,
        "promo_usado": promo_usado,
        "real_usado": real_usado,
        "promo_restante": promo_restante,
        "real_restante": real_restante,
        "bono_campana": bono,
        "monto_billetera_chofer": monto_billetera_chofer,
        "cobro_excedente": monto_excedente,
    }


def check(name, got, exp):
    got = money(got)
    exp = money(exp)
    if got != exp:
        raise AssertionError(f"{name}: esperado {exp} obtenido {got}")
    print(f"  OK {name}: {got} CUP")


def main():
    bono = Decimal("500.00")

    # --- Efectivo: la promo cubre 200 y el chofer cobra 300 en mano. ---
    r = liquidar(500, 200, 150, metodo="Efectivo", bono_config=bono)
    print("Efectivo: viaje 500, promo 200, fondo 150, bono 500")
    for k, v in r.items():
        print(f"  {k}: {v}")

    check("pago_billetera_total", r["pago_billetera_total"], 200)
    check("monto_excedente", r["monto_excedente"], 300)
    check("promo_usado", r["promo_usado"], 200)
    check("real_usado (no se toca el Fondo)", r["real_usado"], 0)
    check("real_restante", r["real_restante"], 150)
    check("bono_campana", r["bono_campana"], 500)
    check("monto_billetera_chofer (200+Bono)", r["monto_billetera_chofer"], 700)
    check("cobro efectivo excedente", r["cobro_excedente"], 300)
    assert r["metodo_pago_excedente"] == "Efectivo"

    # --- Efectivo sin promo: nada virtual, todo en mano. ---
    r2 = liquidar(500, 0, 150, metodo="Efectivo", bono_config=bono)
    check("sin promo: bono", r2["bono_campana"], 0)
    check("sin promo: billetera chofer", r2["monto_billetera_chofer"], 0)
    check("sin promo: excedente", r2["monto_excedente"], 500)
    check("sin promo: real usado", r2["real_usado"], 0)

    # --- Transferencia: la promo se aplica y el resto va por fuera. ---
    r3 = liquidar(550, 300, 250, metodo="Transferencia", bono_config=bono)
    check("transferencia: excedente", r3["monto_excedente"], 250)
    check("transferencia: promo usado", r3["promo_usado"], 300)
    check("transferencia: real usado", r3["real_usado"], 0)
    check("transferencia: billetera chofer", r3["monto_billetera_chofer"], 800)
    assert r3["metodo_pago_excedente"] == "Transferencia"

    # --- Billetera: aqui si se descuenta el Fondo real. ---
    r4 = liquidar(500, 200, 300, metodo="Billetera", bono_config=bono)
    check("billetera: pago total", r4["pago_billetera_total"], 500)
    check("billetera: promo", r4["promo_usado"], 200)
    check("billetera: real usado", r4["real_usado"], 300)
    check("billetera: excedente", r4["monto_excedente"], 0)
    check("billetera: chofer", r4["monto_billetera_chofer"], 1000)
    assert r4["metodo_pago_excedente"] is None

    # --- Billetera sin saldo suficiente: el resto no se inventa. ---
    r5 = liquidar(500, 100, 50, metodo="Billetera", bono_config=bono)
    check("billetera corta: pago total", r5["pago_billetera_total"], 150)
    check("billetera corta: real usado", r5["real_usado"], 50)
    check("billetera corta: excedente", r5["monto_excedente"], 350)
    assert r5["metodo_pago_excedente"] is None

    print("\nTODAS LAS COMPROBACIONES PASARON")


if __name__ == "__main__":
    main()
