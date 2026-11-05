"""Hora oficial de Cuba para todo el backend.

En 2026 el pais decidio **no retrasar el reloj** al terminar el horario de
verano: se quedo en UTC-4 durante todo el ano. La base de datos de zonas
horarias (`America/Havana`) sigue diciendo UTC-5 en invierno, asi que usarla
partia el dia a la hora equivocada y las ganancias de la noche se contaban en
el dia siguiente.

Para no volver a depender de una decision administrativa que puede cambiar sin
aviso, el desfase vive en una variable de entorno:

    CUBA_UTC_OFFSET=-4   # horario de verano (el vigente hoy)
    CUBA_UTC_OFFSET=-5   # horario de invierno

Cambiarlo y reiniciar el servicio basta; no hay que recompilar nada.
"""

from __future__ import annotations

import os
from datetime import date, datetime, time, timedelta, timezone

_DEFECTO = -4


def offset_cuba() -> int:
    """Desfase de Cuba respecto a UTC, en horas (negativo)."""
    try:
        return int(os.getenv("CUBA_UTC_OFFSET", str(_DEFECTO)))
    except (TypeError, ValueError):
        return _DEFECTO


# `timezone` con desfase fijo: no consulta tzdata ni cambia con el DST.
CUBA_TZ = timezone(timedelta(hours=offset_cuba()), "Cuba")


def ahora_cuba() -> datetime:
    """Ahora en hora oficial de Cuba (aware)."""
    return datetime.now(CUBA_TZ)


def fecha_cuba() -> date:
    """Fecha (dia) en hora oficial de Cuba."""
    return ahora_cuba().date()


def rango_dia_utc(dia: date) -> tuple[datetime, datetime]:
    """Devuelve [inicio, fin) del dia local, como datetimes **naive en UTC**.

    Las columnas `requested_at`, `started_at` y `completed_at` son TIMESTAMP
    sin zona y guardan `datetime.now(timezone.utc)`, es decir, UTC naive. Por
    eso no se puede usar `AT TIME ZONE 'America/Havana'` en SQL: el corte del
    dia se calcula aqui y se compara directamente contra la columna.
    """
    inicio = datetime.combine(dia, time.min, tzinfo=CUBA_TZ).astimezone(timezone.utc)
    fin = datetime.combine(dia + timedelta(days=1), time.min, tzinfo=CUBA_TZ).astimezone(timezone.utc)
    return inicio.replace(tzinfo=None), fin.replace(tzinfo=None)
