"""Simulacion: pago con saldo promocional + saldo real (Fondo) y desglose chofer.

Reglas implementadas:
- pago_billetera_total = min(precio_final, saldo_promocional + saldo_real)
- monto_excedente = precio_final - pago_billetera_total
- monto_billetera_chofer = pago_billetera_total + bono_campana (bono solo si uso promo)
- Al cliente se le descuenta primero saldo_promocional y luego saldo_real.
- metodo_pago_excedente: Efectivo o Transferencia (segun metodo del viaje).

Escenario pedido:
  Viaje 500 CUP, cliente con 200 promo y 150 fondo (virtual 350), excedente 150 Efectivo.
  Verificar: chofer recibe 350 + Bono en billetera y cobra 150 en efectivo.
"""
from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP

CENT = Decimal("0.01")


def money(v) -> Decimal:
    return Decimal(str(v)).quantize(CENT, rounding=ROUND_HALF_UP)


def liquidar(precio_final, saldo_promo, saldo_real, metodo_excedente="Efectivo", bono_config=Decimal("500.00")):
    precio = money(precio_final)
    promo = money(max(Decimal("0"), saldo_promo))
    real = money(max(Decimal("0"), saldo_real))
    bono_config = money(bono_config)

    virtual = money(promo + real)
    pago_billetera_total = money(min(precio, virtual))
    monto_excedente = money(precio - pago_billetera_total)

    # descuento al cliente: primero promo, luego real
    promo_usado = money(min(promo, pago_billetera_total))
    real_usado = money(pago_billetera_total - promo_usado)
    promo_restante = money(promo - promo_usado)
    real_restante = money(real - real_usado)

    # bono solo si uso saldo promocional
    bono = money(bono_config) if promo_usado > 0 else Decimal("0.00")
    monto_billetera_chofer = money(pago_billetera_total + bono)

    return {
        "precio_final": precio,
        "pago_billetera_total": pago_billetera_total,
        "monto_excedente": monto_excedente,
        "metodo_pago_excedente": metodo_excedente if monto_excedente > 0 else None,
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
    # Bono de ejemplo (campana). Si no usara promo seria 0.
    bono = Decimal("500.00")
    r = liquidar(500, 200, 150, metodo_excedente="Efectivo", bono_config=bono)

    print("Escenario: viaje 500, promo 200, fondo 150, excedente Efectivo, bono 500")
    for k, v in r.items():
        print(f"  {k}: {v}")

    check("pago_billetera_total", r["pago_billetera_total"], 350)
    check("monto_excedente", r["monto_excedente"], 150)
    check("promo_usado", r["promo_usado"], 200)
    check("real_usado", r["real_usado"], 150)
    check("promo_restante", r["promo_restante"], 0)
    check("real_restante", r["real_restante"], 0)
    check("bono_campana", r["bono_campana"], 500)
    check("monto_billetera_chofer (350+Bono)", r["monto_billetera_chofer"], 850)
    check("cobro efectivo excedente", r["cobro_excedente"], 150)
    assert r["metodo_pago_excedente"] == "Efectivo"

    # Extra: sin promo usada (promo 0) -> bono 0, real cubre parte
    r2 = liquidar(500, 0, 150, metodo_excedente="Efectivo", bono_config=bono)
    check("sin promo: bono", r2["bono_campana"], 0)
    check("sin promo: billetera chofer", r2["monto_billetera_chofer"], 150)
    check("sin promo: excedente", r2["monto_excedente"], 350)

    # Extra: todo cubierto por virtual en Transferencia -> sin excedente
    r3 = liquidar(500, 300, 250, metodo_excedente="Transferencia", bono_config=bono)
    check("cubierto: excedente", r3["monto_excedente"], 0)
    check("cubierto: promo usado", r3["promo_usado"], 300)
    check("cubierto: real usado", r3["real_usado"], 200)
    assert r3["metodo_pago_excedente"] is None

    print("\nTODAS LAS COMPROBACIONES PASARON")


if __name__ == "__main__":
    main()
