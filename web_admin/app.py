"""Panel de administración web de Rapitaxi.

Ejecutar en local desde `web_admin/`:

    streamlit run app.py

En Render, el Start Command es:

    streamlit run app.py --server.port $PORT --server.address 0.0.0.0

El panel es solo un cliente HTTP: no importa pymongo ni psycopg2 y no toca
Mongo/Postgres directamente. La URL del backend se toma de `API_BASE_URL`.
"""

from __future__ import annotations

import os
import sys
from datetime import date

# Permite `streamlit run app.py` desde cualquier directorio y que los imports
# relativos del paquete (`config`, `api_client`, `tabs...`) resuelvan.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import streamlit as st

import ui
from api_client import ApiClient, ApiError, SesionExpirada, explicar_error
from config import get_api_base_url
from tabs import billetera, choferes, configuracion, vehiculos, viajes
from tabs import viajes_criticos


st.set_page_config(
    page_title="Rapitaxi · Administración",
    page_icon="🚕",
    layout="wide",
    initial_sidebar_state="expanded",
)
ui.inyectar_css()


# ===================== SESION =====================

def _cerrar_sesion(api: ApiClient, aviso: str = "") -> None:
    try:
        api.logout()
    except Exception:
        pass
    st.session_state.pop("api", None)
    ui.invalidar()
    if aviso:
        ui.flash("warning", aviso)


def _manejar_sesion(exc: SesionExpirada) -> None:
    api = st.session_state.get("api")
    if api is not None:
        _cerrar_sesion(api)
    ui.flash("warning", explicar_error(exc))
    st.rerun()


def _seguro(funcion, api: ApiClient) -> None:
    """Ejecuta una pestaña y traduce los errores de red a algo legible."""
    try:
        funcion(api)
    except SesionExpirada as exc:
        _manejar_sesion(exc)
    except ApiError as exc:
        st.error(explicar_error(exc))


# ===================== LOGIN =====================

def _login() -> None:
    st.markdown(
        """
        <div style="text-align:center; padding: 2.2rem 0 1.2rem;">
          <div style="font-size:3rem; line-height:1;">🚕</div>
          <h1 style="color:#ffc107; margin:.4rem 0 0;">RAPITAXI</h1>
          <p style="color:#9fb3c8; margin:.2rem 0 0;">Panel de administración</p>
        </div>
        """,
        unsafe_allow_html=True,
    )

    ui.mostrar_flash()

    izquierda, centro, derecha = st.columns([1, 1.15, 1])
    with centro:
        with st.form("form_login"):
            email = st.text_input("Correo de administrador",
                                  placeholder="admin@correo.com")
            password = st.text_input("Contraseña", type="password")
            entrar = st.form_submit_button("Entrar", type="primary")

        st.caption("Servidor: %s" % get_api_base_url())
        st.caption(
            "La primera petición del día puede tardar hasta 90 s: el backend "
            "gratuito de Render se duerme a los 15 min sin uso."
        )

    if not entrar:
        return
    if not email.strip() or not password:
        st.error("Escribe tu correo y tu contraseña.")
        return

    cliente = ApiClient(get_api_base_url())
    try:
        with st.spinner("Conectando con el servidor..."):
            cliente.login(email, password)
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    st.session_state["api"] = cliente
    ui.invalidar()
    st.rerun()


# ===================== PANEL =====================

def _cabecera(api: ApiClient) -> None:
    st.title("Panel de administración")
    st.caption("Hoy es %s · Backend: %s"
               % (date.today().strftime("%d/%m/%Y"), get_api_base_url()))
    ui.mostrar_flash()

    try:
        resumen = ui.cargar("resumen_dia", 30, api.ping)
    except SesionExpirada:
        raise
    except ApiError as exc:
        st.warning("No se pudo cargar el resumen del día: %s"
                   % explicar_error(exc))
        return

    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Viajes hoy", resumen.get("viajes", 0))
    c2.metric("Completados", resumen.get("completados", 0))
    c3.metric("Activos", resumen.get("activos", 0))
    c4.metric("Facturado", ui.dinero(resumen.get("facturado")))
    c5.metric("Chóferes", resumen.get("choferes", 0))


def _sidebar(api: ApiClient) -> None:
    with st.sidebar:
        st.markdown("## 🚕 Rapitaxi")
        st.caption("Panel de administración")
        st.markdown("**%s**" % (api.admin_email or "Administrador"))
        st.caption(get_api_base_url())
        st.divider()

        if st.button("🔄 Actualizar datos"):
            ui.invalidar()
            st.rerun()

        st.caption(
            "Viajes críticos se actualiza solo cada 10 s. Las demás pestañas "
            "usan caché para no saturar el backend."
        )
        st.divider()

        if st.button("Cerrar sesión"):
            _cerrar_sesion(api)
            st.rerun()


def _panel(api: ApiClient) -> None:
    _sidebar(api)

    try:
        _cabecera(api)
    except SesionExpirada as exc:
        _manejar_sesion(exc)

    st.divider()

    pestanas = st.tabs([
        "🚨 Viajes críticos",
        "🚗 Vehículos",
        "🎁 Promociones y tarifas",
        "🧑‍✈️ Chóferes",
        "💰 Billetera",
        "📊 Viajes",
    ])

    with pestanas[0]:
        _seguro(viajes_criticos.render, api)
    with pestanas[1]:
        _seguro(vehiculos.render, api)
    with pestanas[2]:
        _seguro(configuracion.render, api)
    with pestanas[3]:
        _seguro(choferes.render, api)
    with pestanas[4]:
        _seguro(billetera.render, api)
    with pestanas[5]:
        _seguro(viajes.render, api)


# ===================== ARRANQUE =====================

def main() -> None:
    api = st.session_state.get("api")
    if api is None or not api.autenticado:
        _login()
        return
    _panel(api)


main()
