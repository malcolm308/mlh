"""Simulacion del pago mixto de la campana "Sabado de RapiTaxi".

No toca MongoDB ni PostgreSQL: son numeros en memoria para revisar la regla
que implementa `routers/Solicitud_de_viajes_v4.py`.

Regla vigente
-------------
El cliente tiene dos bolsas y la campana las usa en este orden:

    1. saldo_promocional   saldo virtual que regala la campana
    2. Fondo               su billetera real (SOLO si paga con Billetera)

El saldo promocional se aplica sobre el precio SIN el recargo por
transferencia. El excedente (`monto_restante`) se paga con el metodo elegido:

    Efectivo       lo cobra el chofer en mano
    Transferencia  lo recibe el chofer por fuera de la app
    Billetera      se debita del `Fondo` real del cliente y se acredita al
                   chofer en su `Fondo`

Al chofer se le abona SIEMPRE en su billetera virtual:

    abono = saldo_promocional_usado + monto_bono_chofer

El bono lo paga la plataforma y solo se abona cuando la campana esta vigente
y el cliente uso saldo promocional.

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
RECARGO_TRANSFERENCIA = 0.10


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
                   metodo: str = "Efectivo",
                   saldo_promocional: float = 0.0,
                   fondo: float = 0.0,
                   bono_chofer: float = 0.0,
                   expira_promocional: datetime | None = None,
                   ahora: datetime | None = None) -> dict:
    """Reparte el precio entre saldo promocional y el metodo de pago.

    Es puro: no toca ninguna base de datos. `fondo` solo se debita cuando el
    metodo es Billetera; en Efectivo/Transferencia se comprueba que quede
    intacto.
    """
    ahora = ahora or datetime.now(CUBA_TZ)
    metodo = (metodo or "Efectivo").strip().capitalize()
    if metodo not in ("Efectivo", "Transferencia", "Billetera"):
        raise ValueError(f"Metodo de pago desconocido: {metodo}")

    precio_base = money(precio_viaje)
    recargo = (money(precio_base * Decimal(str(RECARGO_TRANSFERENCIA)))
               if metodo == "Transferencia" else Decimal("0.00"))
    total = money(precio_base + recargo)

    promo_disponible = saldo_promocional_vigente(
        saldo_promocional, expira_promocional, ahora)
    fondo_disponible = money(max(0.0, fondo))
    bono = money(max(0.0, bono_chofer))

    # 1. Primero la bolsa promocional, sobre el precio SIN el recargo.
    promo_usado = min(promo_disponible, precio_base)
    restante = money(total - promo_usado)

    # 2. El excedente se paga con el metodo elegido.
    if metodo == "Billetera":
        cobrado = min(fondo_disponible, restante)
        fondo_restante = money(fondo_disponible - cobrado)
        efectivo_cliente = Decimal("0.00")
    elif metodo == "Efectivo":
        cobrado = restante
        fondo_restante = fondo_disponible
        efectivo_cliente = restante
    else:  # Transferencia: el dinero no pasa por la app
        cobrado = restante
        fondo_restante = fondo_disponible
        efectivo_cliente = Decimal("0.00")

    bono_aplicado = bono if promo_usado > 0 else Decimal("0.00")
    abono_billetera_chofer = money(promo_usado + bono_aplicado)

    return {
        "metodo": metodo,
        "precio_base": precio_base,
        "recargo": recargo,
        "precio_viaje": total,
        "saldo_promocional_disponible": promo_disponible,
        "fondo_disponible": fondo_disponible,
        "promocional_usado": promo_usado,
        "monto_restante": restante,
        "faltante": money(restante - cobrado),
        "efectivo_cliente": efectivo_cliente,
        "cobrado_cliente": cobrado,
        "saldo_promocional_restante": money(promo_disponible - promo_usado),
        "fondo_restante": fondo_restante,
        "bono_chofer": bono_aplicado,
        "abono_billetera_chofer": abono_billetera_chofer,
        "total_chofer": money(abono_billetera_chofer + cobrado),
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
    for clave in ("metodo", "precio_base", "recargo", "precio_viaje",
                  "saldo_promocional_disponible", "fondo_disponible",
                  "bono_chofer"):
        valor = r[clave]
        if isinstance(valor, Decimal):
            print("    %-30s %12.2f CUP" % (clave, float(valor)))
        else:
            print("    %-30s %12s" % (clave, valor))
    print("  Lo que paga el cliente")
    for clave in ("promocional_usado", "cobrado_cliente", "efectivo_cliente"):
        print("    %-30s %12.2f CUP" % (clave, float(r[clave])))
    print("  Lo que recibe el chofer")
    for clave in ("abono_billetera_chofer", "total_chofer"):
        print("    %-30s %12.2f CUP" % (clave, float(r[clave])))
    print("  Saldos que quedan")
    for clave in ("saldo_promocional_restante", "fondo_restante"):
        print("    %-30s %12.2f CUP" % (clave, float(r[clave])))
    print("  Costo de la campana para la plataforma")
    print("    %-30s %12.2f CUP" % ("costo_plataforma",
                                    float(r["costo_plataforma"])))

    # Invariantes generales: el cliente cubre exactamente el precio con la
    # bolsa promocional mas el excedente, y el chofer recibe ese excedente
    # mas el abono virtual (promocional + bono). En el caso de billetera sin
    # saldo el cliente queda debiendo `faltante`, asi que ese control se
    # omite (el backend solo cobra lo que hay y deja constancia).
    if r["faltante"] == 0:
        comprobar("cliente cubre el precio",
                  r["promocional_usado"] + r["cobrado_cliente"],
                  r["precio_viaje"])
    comprobar("abono = promocional usado + bono",
              r["abono_billetera_chofer"],
              r["promocional_usado"] + r["bono_chofer"])
    comprobar("chofer recibe excedente + abono",
              r["total_chofer"],
              r["cobrado_cliente"] + r["abono_billetera_chofer"])


def main() -> None:
    print("SIMULACION DE PAGOS - CAMPANA SABADO DE RAPITAXI")
    print("Regla: saldo promocional + excedente por el metodo elegido.")
    print("Sin conexion a MongoDB ni PostgreSQL. Todo en memoria.")

    # ------------------------------------------------------------------
    # CASO A: el viaje cuesta MENOS que el saldo promocional.
    # El cliente no pone nada de su bolsillo; el chofer cobra todo virtual
    # y su bono.
    # ------------------------------------------------------------------
    a = liquidar_viaje(
        precio_viaje=150.00,
        metodo="Efectivo",
        saldo_promocional=300.00,
        fondo=0.00,
        bono_chofer=50.00,
    )
    imprimir("CASO A - EL PROMOCIONAL CUBRE TODO EL VIAJE", a)
    comprobar("A promo usado", a["promocional_usado"], Decimal("150.00"))
    comprobar("A restante", a["monto_restante"], Decimal("0.00"))
    comprobar("A efectivo cliente", a["efectivo_cliente"], Decimal("0.00"))
    comprobar("A promo restante", a["saldo_promocional_restante"],
              Decimal("150.00"))
    comprobar("A billetera chofer", a["abono_billetera_chofer"],
              Decimal("200.00"))

    # ------------------------------------------------------------------
    # CASO B: efectivo. El viaje cuesta MAS que el promocional. Se usa todo
    # el promocional y el resto se paga en mano. El Fondo del cliente tiene
    # saldo, pero NO se toca.
    # ------------------------------------------------------------------
    b = liquidar_viaje(
        precio_viaje=500.00,
        metodo="Efectivo",
        saldo_promocional=300.00,
        fondo=250.00,
        bono_chofer=50.00,
    )
    imprimir("CASO B - PROMOCIONAL + EFECTIVO (Fondo intacto)", b)
    comprobar("B promo usado", b["promocional_usado"], Decimal("300.00"))
    comprobar("B restante", b["monto_restante"], Decimal("200.00"))
    comprobar("B efectivo cliente", b["efectivo_cliente"], Decimal("200.00"))
    comprobar("B promo restante", b["saldo_promocional_restante"],
              Decimal("0.00"))
    comprobar("B fondo intacto", b["fondo_restante"], Decimal("250.00"))
    comprobar("B billetera chofer", b["abono_billetera_chofer"],
              Decimal("350.00"))
    comprobar("B total chofer", b["total_chofer"], Decimal("550.00"))

    # ------------------------------------------------------------------
    # CASO C: transferencia. El recargo del 10 % se suma al precio y lo
    # paga el excedente: la bolsa promocional NO cubre el recargo.
    # ------------------------------------------------------------------
    c = liquidar_viaje(
        precio_viaje=500.00,
        metodo="Transferencia",
        saldo_promocional=300.00,
        fondo=250.00,
        bono_chofer=50.00,
    )
    imprimir("CASO C - PROMOCIONAL + TRANSFERENCIA (recargo 10%)", c)
    comprobar("C recargo", c["recargo"], Decimal("50.00"))
    comprobar("C precio total", c["precio_viaje"], Decimal("550.00"))
    comprobar("C promo usado", c["promocional_usado"], Decimal("300.00"))
    comprobar("C restante", c["monto_restante"], Decimal("250.00"))
    comprobar("C fondo intacto", c["fondo_restante"], Decimal("250.00"))
    comprobar("C billetera chofer", c["abono_billetera_chofer"],
              Decimal("350.00"))
    comprobar("C total chofer", c["total_chofer"], Decimal("600.00"))

    # ------------------------------------------------------------------
    # CASO D: billetera. El excedente se debita del Fondo real del cliente
    # y se acredita al chofer. El bono se paga aparte.
    # ------------------------------------------------------------------
    d = liquidar_viaje(
        precio_viaje=500.00,
        metodo="Billetera",
        saldo_promocional=300.00,
        fondo=250.00,
        bono_chofer=50.00,
    )
    imprimir("CASO D - PROMOCIONAL + BILLETERA REAL", d)
    comprobar("D promo usado", d["promocional_usado"], Decimal("300.00"))
    comprobar("D restante", d["monto_restante"], Decimal("200.00"))
    comprobar("D cobrado de la billetera", d["cobrado_cliente"],
              Decimal("200.00"))
    comprobar("D fondo restante", d["fondo_restante"], Decimal("50.00"))
    comprobar("D billetera chofer", d["abono_billetera_chofer"],
              Decimal("350.00"))
    comprobar("D total chofer", d["total_chofer"], Decimal("550.00"))

    # ------------------------------------------------------------------
    # CASO E: billetera con Fondo insuficiente. Solo se cobra lo que hay;
    # el viaje no se rechaza (la app valida antes contra el excedente).
    # ------------------------------------------------------------------
    e = liquidar_viaje(
        precio_viaje=500.00,
        metodo="Billetera",
        saldo_promocional=300.00,
        fondo=150.00,
        bono_chofer=50.00,
    )
    imprimir("CASO E - BILLETERA SIN SALDO SUFICIENTE", e)
    comprobar("E cobrado de la billetera", e["cobrado_cliente"],
              Decimal("150.00"))
    comprobar("E fondo restante", e["fondo_restante"], Decimal("0.00"))
    comprobar("E billetera chofer", e["abono_billetera_chofer"],
              Decimal("350.00"))

    # ------------------------------------------------------------------
    # CONTROL: expiracion perezosa. La campana se lanza a las 10:00 con
    # 12 horas: vence a las 22:00. A las 21:59 sigue viva; a las 22:01 ya
    # no, y el viaje se cobra completo, sin bono.
    # ------------------------------------------------------------------
    lanzada = datetime(2026, 11, 14, 10, 0, tzinfo=CUBA_TZ)
    expira = lanzada + timedelta(hours=12)

    antes = liquidar_viaje(
        precio_viaje=500.00, metodo="Efectivo", saldo_promocional=300.00,
        fondo=100.00, bono_chofer=50.00, expira_promocional=expira,
        ahora=expira - timedelta(minutes=1),
    )
    imprimir("CONTROL - UN MINUTO ANTES DE EXPIRAR (21:59)", antes)
    comprobar("control vigente promo usado", antes["promocional_usado"],
              Decimal("300.00"))
    comprobar("control vigente bono", antes["bono_chofer"],
              Decimal("50.00"))

    # ------------------------------------------------------------------
    # CASO F: la campana ya expiro. El saldo promocional vale 0, el viaje
    # se paga completo con el metodo elegido y el chofer no recibe bono.
    # ------------------------------------------------------------------
    f = liquidar_viaje(
        precio_viaje=500.00, metodo="Efectivo", saldo_promocional=300.00,
        fondo=100.00, bono_chofer=50.00, expira_promocional=expira,
        ahora=expira + timedelta(minutes=1),
    )
    imprimir("CASO F - CAMPANA EXPIRADA (22:01)", f)
    comprobar("F promo usado", f["promocional_usado"], Decimal("0.00"))
    comprobar("F efectivo cliente", f["efectivo_cliente"],
              Decimal("500.00"))
    comprobar("F bono", f["bono_chofer"], Decimal("0.00"))
    comprobar("F fondo intacto", f["fondo_restante"], Decimal("100.00"))
    comprobar("F billetera chofer", f["abono_billetera_chofer"],
              Decimal("0.00"))
    comprobar("F total chofer", f["total_chofer"], Decimal("500.00"))

    print("\n" + "=" * 68)
    print("TODAS LAS COMPROBACIONES PASARON")
    print("=" * 68)


if __name__ == "__main__":
    main()
