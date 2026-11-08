"""Configuracion del panel web de Rapitaxi.

La URL del backend se lee de `API_BASE_URL` (variable de entorno en Render) y,
como comodidad en local, tambien de `.streamlit/secrets.toml`. Nunca se
hardcodea una IP de desarrollo: el panel es un cliente HTTP y tiene que poder
apuntar a produccion o a un backend local sin tocar codigo.
"""

from __future__ import annotations

import os

DEFAULT_API_BASE_URL = "https://rapitaxi-api-fws6.onrender.com"

# El backend gratuito de Render se duerme a los 15 min sin trafico y la primera
# peticion tarda 30-60 s en despertarlo. El timeout de lectura tiene que cubrir
# ese arranque o el panel dira "sin conexion" cuando solo estaba despertando.
CONNECT_TIMEOUT = int(os.getenv("API_CONNECT_TIMEOUT", "15"))
READ_TIMEOUT = int(os.getenv("API_READ_TIMEOUT", "90"))

# Intervalo del auto-refresco de Viajes Criticos.
AUTO_REFRESH_MS = int(os.getenv("AUTO_REFRESH_MS", "10000"))


def _desde_secrets(nombre: str) -> str | None:
    """Lee un valor de Streamlit secrets sin romper si no existe el archivo."""
    try:
        import streamlit as st

        valor = st.secrets.get(nombre)
        return str(valor) if valor else None
    except Exception:
        return None


def get_api_base_url() -> str:
    valor = (
        os.getenv("API_BASE_URL")
        or _desde_secrets("API_BASE_URL")
        or DEFAULT_API_BASE_URL
    )
    return valor.rstrip("/")
