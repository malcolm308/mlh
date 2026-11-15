"""Simulacion del pago mixto de la campana "Sabado de RapiTaxi" (Fase 4).

No toca MongoDB ni PostgreSQL: son numeros en memoria para revisar la regla
ANTES de implementarla en `routers/Solicitud_de_viajes_v4.py`.

Regla aprobada
--------------
El cliente tiene dos bolsas, pero la campana usa SOLO la primera:

    saldo_promocional   saldo virtual que regala la campana
    Fondo               su billetera normal (NO se toca en esta campana)

Al completar un viaje se cobra en este orden:

    1. saldo_promocional   (primero el regalo)
    2. efectivo            (lo que falte se lo paga en mano al chofer)

El Fondo del cliente queda intacto. El chofer recibe:

    billetera = saldo_promocional usado + monto_bono_chofer
    efectivo  = lo que el cliente pago en mano

El bono del chofer lo paga la plataforma y solo se abona cuando la campana
esta vigente y el cliente uso saldo promocional.

Expiracion perezosa
-------------------
`saldo_promocional` no se borra con un cron: al consultar el perfil, si
`ahora > fecha_expiracion_promocional`, el saldo se trata como 0. El script
comprueba el borde exacto (un minuto antes / un minuto despues).

Uso:
    python scripts/test_pagos.py
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

CENT = Decimal("0.01")
CUBA_TZ = timezone(timedelta(hours=-4), "Cuba")


def money(valor) -> Decimal:
    """Centimos con ROUND_HALF_UP, igual que `_a_dinero` del backend."""
    return Decimal(str(valor)).quantize(CENT, rounding=ROUND_HALF_UP)


def saldo_promocional_vigente(saldo: float, expira: datetime | None,
                              ahora: datetime) -> Decimal:
    """Expiracion perezosa: si ya vencio, el saldo vale 0."""
    if expira is not None and ahora > expira:
        return Decimal("0.00")
    return money(max(0.0, saldo))


def liquidar_viaje(*, precio_viaje: float,
                   saldo_promocional: float = 0.0,
                   fondo: float = 0.0,
                   bono_chofer: float = 0.0,
                   expira_promocional: datetime | None = None,
                   ahora: datetime | None = None) -> dict:
    """Reparte el precio entre saldo promocional y efectivo.

    `fondo` se recibe solo para comprobar que NO se modifica. Es puro: no
    toca ninguna base de datos.
    """
    ahora = ahora or datetime.now(CUBA_TZ)
    precio = money(precio_viaje)
    promo_disponible = saldo_promocional_vigente(
        saldo_promocional, expira_promocional, ahora)
    fondo_disponible = money(max(0.0, fondo))
    bono = money(max(0.0, bono_chofer))

    # 1. Primero el saldo promocional. El Fondo no participa.
    promo_usado = min(promo_disponible, precio)
    resto = money(precio - promo_usado)

    # 2. Lo que sobre se paga en efectivo al chofer.
    efectivo = resto

    # El bono solo aplica si la campana estaba vigente y el cliente uso el
    # saldo promocional. Si expiro, es un viaje normal.
    bono_aplicado = bono if promo_usado > 0 else Decimal("0.00")

    abono_billetera_chofer = money(promo_usado + bono_aplicado)

    return {
        "precio_viaje": precio,
        "saldo_promocional_disponible": promo_disponible,
        "fondo_disponible": fondo_disponible,
        "promocional_usado": promo_usado,
        "efectivo_cliente": efectivo,
        "saldo_promocional_restante": money(promo_disponible - promo_usado),
        "fondo_restante": fondo_disponible,  # intacto: la campana no lo toca
        "bono_chofer": bono_aplicado,
        "abono_billetera_chofer": abono_billetera_chofer,
        "efectivo_chofer": efectivo,
        "total_chofer": money(abono_billetera_chofer + efectivo),
        "costo_plataforma": money(promo_usado + bono_aplicado),
    }


def comprobar(nombre: str, real: Decimal, esperado: Decimal) -> None:
    if money(real) != money(esperado):
        raise AssertionError(
            "%s: se esperaba %.2f y salio %.2f" % (nombre, esperado, real))


def imprimir(titulo: str, r: dict) -> None:
    print("\n" + "=" * 68)
    print(titulo)
    print("-" * 68)
    print("  Datos del caso")
    for clave in ("precio_viaje", "saldo_promocional_disponible",
                  "fondo_disponible", "bono_chofer"):
        print("    %-30s %12.2f CUP" % (clave, float(r[clave])))
    print("  Lo que paga el cliente")
    for clave in ("promocional_usado", "efectivo_cliente"):
        print("    %-30s %12.2f CUP" % (clave, float(r[clave])))
    print("  Lo que recibe el chofer")
    for clave in ("abono_billetera_chofer", "efectivo_chofer", "total_chofer"):
        print("    %-30s %12.2f CUP" % (clave, float(r[clave])))
    print("  Saldos que quedan")
    for clave in ("saldo_promocional_restante", "fondo_restante"):
        print("    %-30s %12.2f CUP" % (clave, float(r[clave])))
    print("  Costo de la campana para la plataforma")
    print("    %-30s %12.2f CUP" % ("costo_plataforma",
                                    float(r["costo_plataforma"])))

    # Invariantes: el cliente paga exactamente el precio con promocional +
    # efectivo, el chofer recibe ese precio mas el bono, y el Fondo no cambia.
    comprobar("cliente paga el precio",
              r["promocional_usado"] + r["efectivo_cliente"],
              r["precio_viaje"])
    comprobar("chofer recibe precio + bono",
              r["total_chofer"], r["precio_viaje"] + r["bono_chofer"])
    comprobar("abono = promocional usado + bono",
              r["abono_billetera_chofer"],
              r["promocional_usado"] + r["bono_chofer"])
    comprobar("el Fondo no se toca",
              r["fondo_restante"], r["fondo_disponible"])


def main() -> None:
    print("SIMULACION DE PAGOS - CAMPANA SABADO DE RAPITAXI")
    print("Regla: saldo promocional -> efectivo. El Fondo no se toca.")
    print("Sin conexion a MongoDB ni PostgreSQL. Todo en memoria.")

    # ------------------------------------------------------------------
    # CASO A: el viaje cuesta MENOS que el saldo promocional.
    # El cliente no pone nada de su bolsillo; el chofer cobra todo virtual
    # y su bono.
    # ------------------------------------------------------------------
    a = liquidar_viaje(
        precio_viaje=150.00,
        saldo_promocional=300.00,
        fondo=0.00,
        bono_chofer=50.00,
    )
    imprimir("CASO A - EL PROMOCIONAL CUBRE TODO EL VIAJE", a)
    comprobar("A promo usado", a["promocional_usado"], Decimal("150.00"))
    comprobar("A efectivo cliente", a["efectivo_cliente"], Decimal("0.00"))
    comprobar("A promo restante", a["saldo_promocional_restante"],
              Decimal("150.00"))
    comprobar("A billetera chofer", a["abono_billetera_chofer"],
              Decimal("200.00"))

    # ------------------------------------------------------------------
    # CASO B: el viaje cuesta MAS que el promocional. Se usa todo el
    # promocional y el resto se paga en efectivo. El Fondo del cliente
    # tiene saldo, pero NO se toca.
    # ------------------------------------------------------------------
    b = liquidar_viaje(
        precio_viaje=500.00,
        saldo_promocional=300.00,
        fondo=250.00,
        bono_chofer=50.00,
    )
    imprimir("CASO B - PROMOCIONAL + EFECTIVO (Fondo intacto)", b)
    comprobar("B promo usado", b["promocional_usado"], Decimal("300.00"))
    comprobar("B efectivo cliente", b["efectivo_cliente"], Decimal("200.00"))
    comprobar("B promo restante", b["saldo_promocional_restante"],
              Decimal("0.00"))
    comprobar("B fondo intacto", b["fondo_restante"], Decimal("250.00"))
    comprobar("B billetera chofer", b["abono_billetera_chofer"],
              Decimal("350.00"))
    comprobar("B efectivo chofer", b["efectivo_chofer"], Decimal("200.00"))

    # ------------------------------------------------------------------
    # CONTROL: expiracion perezosa. La campana se lanza a las 10:00 con
    # 12 horas: vence a las 22:00. A las 21:59 sigue viva; a las 22:01 ya
    # no, y el viaje se cobra completo en efectivo, sin bono.
    # ------------------------------------------------------------------
    lanzada = datetime(2026, 11, 14, 10, 0, tzinfo=CUBA_TZ)
    expira = lanzada + timedelta(hours=12)

    antes = liquidar_viaje(
        precio_viaje=500.00, saldo_promocional=300.00, fondo=100.00,
        bono_chofer=50.00, expira_promocional=expira,
        ahora=expira - timedelta(minutes=1),
    )
    imprimir("CONTROL - UN MINUTO ANTES DE EXPIRAR (21:59)", antes)
    comprobar("control vigente promo usado", antes["promocional_usado"],
              Decimal("300.00"))
    comprobar("control vigente bono", antes["bono_chofer"],
              Decimal("50.00"))

    # ------------------------------------------------------------------
    # CASO C: la campana ya expiro. El saldo promocional vale 0, el viaje
    # se paga completo en efectivo y el chofer no recibe bono.
    # ------------------------------------------------------------------
    c = liquidar_viaje(
        precio_viaje=500.00, saldo_promocional=300.00, fondo=100.00,
        bono_chofer=50.00, expira_promocional=expira,
        ahora=expira + timedelta(minutes=1),
    )
    imprimir("CASO C - CAMPANA EXPIRADA (22:01)", c)
    comprobar("C promo usado", c["promocional_usado"], Decimal("0.00"))
    comprobar("C efectivo cliente", c["efectivo_cliente"], Decimal("500.00"))
    comprobar("C bono", c["bono_chofer"], Decimal("0.00"))
    comprobar("C fondo intacto", c["fondo_restante"], Decimal("100.00"))
    comprobar("C billetera chofer", c["abono_billetera_chofer"],
              Decimal("0.00"))
    comprobar("C efectivo chofer", c["efectivo_chofer"], Decimal("500.00"))

    print("\n" + "=" * 68)
    print("TODAS LAS COMPROBACIONES PASARON")
    print("=" * 68)


if __name__ == "__main__":
    main()
