"""Conversión exacta entre el dinero de MongoDB y los centavos de PostgreSQL.

Regla: **nunca** se opera con `float`. Los saldos de Mongo llegan como
`float`, `int` o `Decimal128`; se convierten a `Decimal` pasando por `str()`
y se redondean a 2 decimales con `ROUND_HALF_UP`. A partir de ahí todo el
sistema trabaja en `int` de centavos.
"""
from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any

try:  # bson solo hace falta para Decimal128; los tests no lo requieren.
    from bson.decimal128 import Decimal128
except Exception:  # pragma: no cover
    Decimal128 = ()  # type: ignore[assignment]

CENTAVOS = Decimal("0.01")


def a_decimal(valor: Any) -> Decimal:
    """Convierte lo que venga de Mongo a Decimal con 2 decimales."""
    if valor is None or valor == "":
        return Decimal("0.00")
    if isinstance(valor, Decimal):
        base = valor
    elif Decimal128 and isinstance(valor, Decimal128):
        base = valor.to_decimal()
    elif isinstance(valor, bool):
        raise TypeError("Un booleano no es un importe")
    else:
        base = Decimal(str(valor))
    try:
        return base.quantize(CENTAVOS, rounding=ROUND_HALF_UP)
    except InvalidOperation as exc:
        raise ValueError(f"Importe inválido: {valor!r}") from exc


def a_cents(valor: Any) -> int:
    """Saldo de Mongo → centavos enteros. `100.50` → `10050`."""
    return int(a_decimal(valor) * 100)


def de_cents(monto_cents: int) -> Decimal:
    """Centavos → Decimal con 2 decimales. `10050` → `Decimal('100.50')`."""
    return (Decimal(int(monto_cents)) / 100).quantize(CENTAVOS)


def formatear(monto_cents: int) -> str:
    """Representación legible para logs y respuestas de API."""
    return f"{de_cents(monto_cents):.2f}"
