"""Errores de dominio de la billetera.

No importan FastAPI: los routers los traducen a códigos HTTP. Así el servicio
se puede probar sin levantar la app.
"""
from __future__ import annotations


class ErrorWallet(Exception):
    """Base de todos los errores de dinero."""


class SaldoInsuficiente(ErrorWallet):
    def __init__(self, requerido_cents: int, disponible_cents: int):
        self.requerido_cents = int(requerido_cents)
        self.disponible_cents = int(disponible_cents)
        super().__init__(
            f"Saldo insuficiente: se necesitan "
            f"{self.requerido_cents / 100:.2f} CUP y hay "
            f"{max(0, self.disponible_cents) / 100:.2f} CUP disponibles")


class ViajeNoEncontrado(ErrorWallet):
    pass


class EstadoViajeInvalido(ErrorWallet):
    pass


class MontoInvalido(ErrorWallet):
    pass
