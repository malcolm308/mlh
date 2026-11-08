"""Utilidades de interfaz compartidas por las pestanas del panel web.

Aqui viven tres cosas que, si estuvieran repetidas en cada pestana, se
desincronizarian a la primera:

* el formato de dinero, fechas y tiempos de espera,
* la cache por sesion con TTL (para que el auto-refresco de 10 s no dispare
  seis peticiones al backend cada vez),
* el aviso de un solo uso (`flash`) que sobrevive a un `st.rerun`.
"""

from __future__ import annotations

import io
import time
from datetime import date, datetime
from typing import Any, Callable, Iterable, Optional

import pandas as pd
import streamlit as st

ESTADOS_VIAJE = {
    "requested": "Solicitado",
    "accepted": "Aceptado",
    "driver_arrived": "Chofer llegó",
    "in_progress": "En curso",
    "completed": "Completado",
    "cancelled": "Cancelado",
    "expired": "Expirado",
}

ESTADOS_CUENTA = {
    "pendiente": "Pendiente",
    "aprobado": "Aprobado",
    "rechazado": "Rechazado",
}

FOTO_LABELS = {
    "vehiculo_exterior_frente": "Exterior · frente",
    "vehiculo_exterior_atras": "Exterior · atrás",
    "vehiculo_interior_frente": "Interior · frente",
    "vehiculo_interior_atras": "Interior · atrás",
    "circulacion": "Circulación",
}


# ===================== FORMATO =====================

def dinero(valor: Any, sufijo: str = " CUP") -> str:
    """1234.5 -> '1,234.50 CUP'. Un valor vacio se pinta como raya."""
    if valor is None or valor == "":
        return "—"
    try:
        numero = float(valor)
    except (TypeError, ValueError):
        return "—"
    texto = "{:,.2f}".format(numero)
    return texto + sufijo


def numero(valor: Any, decimales: int = 2) -> str:
    if valor is None or valor == "":
        return "—"
    try:
        return ("{:,.%df}" % decimales).format(float(valor))
    except (TypeError, ValueError):
        return "—"


def _parsear(valor: Any) -> Optional[datetime]:
    if valor is None or valor == "":
        return None
    if isinstance(valor, datetime):
        return valor
    if isinstance(valor, date):
        return datetime(valor.year, valor.month, valor.day)
    texto = str(valor).strip().replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(texto)
    except ValueError:
        return None


def fecha_hora(valor: Any) -> str:
    momento = _parsear(valor)
    if not momento:
        return "—"
    return momento.strftime("%d/%m/%Y %H:%M")


def fecha(valor: Any) -> str:
    momento = _parsear(valor)
    if not momento:
        return "—"
    return momento.strftime("%d/%m/%Y")


def espera(segundos: Any) -> str:
    """Segundos -> '4 min 12 s'. Lo que usa la tabla de huerfanos."""
    if segundos is None:
        return "—"
    try:
        total = max(0, int(segundos))
    except (TypeError, ValueError):
        return "—"
    if total < 60:
        return "%d s" % total
    minutos, resto = divmod(total, 60)
    if minutos < 60:
        return "%d min %02d s" % (minutos, resto)
    horas, minutos = divmod(minutos, 60)
    return "%d h %02d min" % (horas, minutos)


def estado_viaje(valor: Any) -> str:
    return ESTADOS_VIAJE.get(str(valor or ""), str(valor or "—"))


def estado_cuenta(valor: Any) -> str:
    return ESTADOS_CUENTA.get(str(valor or "").lower(),
                             str(valor or "—").capitalize())


def tipo_vehiculo(valor: Any) -> str:
    texto = str(valor or "").strip()
    if not texto:
        return "—"
    return texto[0].upper() + texto[1:]


def recortar(valor: Any, largo: int = 34) -> str:
    texto = str(valor or "").strip() or "—"
    if len(texto) <= largo:
        return texto
    return texto[: largo - 1].rstrip() + "…"


# ===================== CACHE POR SESION =====================

def cargar(clave: str, ttl: int, loader: Callable[[], Any],
           forzar: bool = False) -> Any:
    """Devuelve el dato cacheado o lo pide al backend y lo guarda.

    La cache vive en `st.session_state`, asi que es por sesion de navegador y
    nunca se comparte entre administradores. `ttl` en segundos.
    """
    cache = st.session_state.setdefault("_cache", {})
    ahora = time.time()
    entrada = cache.get(clave)
    if not forzar and entrada and (ahora - entrada["t"]) < ttl:
        return entrada["data"]
    dato = loader()
    cache[clave] = {"t": ahora, "data": dato}
    return dato


def invalidar(*prefijos: str) -> None:
    """Borra la cache. Sin argumentos, la vacia entera.

    Con prefijos borra todas las claves que empiecen por ellos, porque las
    pestanas usan claves como `vehiculos:pendiente` o `viajes:resumen:2026-11-08`.
    """
    cache = st.session_state.get("_cache")
    if not cache:
        return
    if not prefijos:
        st.session_state["_cache"] = {}
        return
    for clave in list(cache):
        if any(clave.startswith(p) for p in prefijos):
            cache.pop(clave, None)


# ===================== AVISOS =====================

def flash(tipo: str, texto: str) -> None:
    """Guarda un aviso para mostrarlo despues del `st.rerun`."""
    st.session_state["_flash"] = (tipo, texto)


def mostrar_flash() -> None:
    aviso = st.session_state.pop("_flash", None)
    if not aviso:
        return
    tipo, texto = aviso
    funcion = getattr(st, tipo, st.info)
    funcion(texto)


# ===================== TABLAS =====================

def tabla(filas: Iterable[dict], vacio: str = "No hay datos para mostrar.",
          altura: Optional[int] = None) -> None:
    datos = list(filas)
    if not datos:
        st.info(vacio)
        return
    marco = pd.DataFrame(datos)
    st.dataframe(marco, hide_index=True, height=altura)


def etiqueta_viaje(v: dict) -> str:
    """Etiqueta legible para un selectbox. Nunca incluye ids."""
    pasajero = v.get("client_name") or v.get("client_phone") or "Pasajero"
    origen = recortar(v.get("request_address"), 30)
    destino = recortar(v.get("dropoff_address"), 30)
    return "%s · %s → %s" % (pasajero, origen, destino)


# ===================== IMAGENES =====================

def imagen_desde_bytes(datos: bytes):
    """Convierte JPEG/WebP/HEIC a algo que `st.image` entienda.

    Los iPhone suben HEIC y Streamlit no lo abre solo. Si Pillow no esta
    disponible se devuelven los bytes tal cual: es preferible intentarlo a
    romper la pestana entera.
    """
    try:
        from PIL import Image
    except Exception:
        return datos

    try:
        from pillow_heif import register_heif_opener

        register_heif_opener()
    except Exception:
        pass

    try:
        imagen = Image.open(io.BytesIO(datos))
        imagen.load()
        if imagen.mode not in ("RGB", "RGBA"):
            imagen = imagen.convert("RGB")
        return imagen
    except Exception:
        return datos


# ===================== ESTILOS =====================

def inyectar_css() -> None:
    st.markdown(
        """
        <style>
        .block-container { padding-top: 1.4rem; padding-bottom: 2rem; }
        div[data-testid="stMetric"] {
            background: #16243a;
            border: 1px solid #24374f;
            border-radius: 12px;
            padding: 10px 14px;
        }
        div[data-testid="stMetricLabel"] { color: #9fb3c8; }
        .alerta-critica {
            background: #5b1418;
            border: 1px solid #ff5555;
            border-left: 8px solid #ff2d2d;
            color: #ffe8e8;
            padding: 16px 20px;
            border-radius: 10px;
            font-weight: 700;
            font-size: 1.35rem;
            line-height: 1.35;
            margin: 4px 0 14px;
        }
        .alerta-critica small {
            display: inline-block;
            margin-top: 6px;
            color: #ffc9c9;
            font-weight: 400;
            font-size: 0.95rem;
        }
        .alerta-critica small { color: #ffc9c9; font-weight: 400; }
        .nota-suave { color: #9fb3c8; font-size: 0.88rem; }
        </style>
        """,
        unsafe_allow_html=True,
    )
