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
import time
from datetime import date, datetime, timedelta
from typing import Optional

# Permite `streamlit run app.py` desde cualquier directorio y que los imports
# relativos del paquete (`config`, `api_client`, `tabs...`) resuelvan.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import streamlit as st

import ui
from api_client import ApiClient, ApiError, SesionExpirada, explicar_error
from config import get_api_base_url
from tabs import billetera, choferes, configuracion, vehiculos, viajes
from tabs import viajes_criticos
from tabs import admins, clientes

# Pestañas permitidas por rol. `super_admin` ve TODO (incluida la de CRUD de
# admins). Un rol de operador ve lo suyo; quien no tenga opcion, ve aviso.
TABS_BASE = [
    ("🚨 Viajes críticos", viajes_criticos.render),
    ("🚗 Vehículos", vehiculos.render),
    ("🎁 Promociones y tarifas", configuracion.render),
    ("🧑‍✈️ Chóferes", choferes.render),
    ("💰 Billetera", billetera.render),
    ("📊 Viajes", viajes.render),
    ("👤 Clientes", clientes.render),
    ("👥 Gestión de Admins", admins.render),
]

TABS_POR_ROL = {
    "super_admin": [t[0] for t in TABS_BASE],
    "trip_operator": ["🚨 Viajes críticos", "📊 Viajes"],
    "user_operator": ["🚗 Vehículos", "🧑‍✈️ Chóferes", "👤 Clientes"],
    "wallet_operator": ["💰 Billetera"],
}

# Nombre visible -> slug estable para `?tab=...`. Los emojis no van en la URL:
# se verian escapados y el enlace dejaria de ser legible/compartible.
TAB_SLUGS = {
    "🚨 Viajes críticos": "criticos",
    "🚗 Vehículos": "vehiculos",
    "🎁 Promociones y tarifas": "promociones",
    "🧑‍✈️ Chóferes": "choferes",
    "💰 Billetera": "billetera",
    "📊 Viajes": "viajes",
    "👤 Clientes": "clientes",
    "👥 Gestión de Admins": "admins",
}
SLUG_A_TAB = {slug: nombre for nombre, slug in TAB_SLUGS.items()}


st.set_page_config(
    page_title="Rapitaxi · Administración",
    page_icon="🚕",
    layout="wide",
    initial_sidebar_state="expanded",
)
ui.inyectar_css()


# ===================== SESION =====================
#
# El access token dura 2 h. Ademas del refresco transparente de `ApiClient`
# (401 -> POST /auth/refresh), el refresh token se guarda en una cookie para
# que un F5 no obligue al administrador a escribir la contrasena otra vez.

_COOKIE_REFRESH = "rapitaxi_refresh"
_COOKIE_ADMIN = "rapitaxi_admin"
_COOKIE_DIAS = 30


def _cookie_manager():
    """Componente que escribe cookies. Si el paquete no esta, el panel sigue
    funcionando solo con la sesion en memoria."""
    try:
        import extra_streamlit_components as stx
    except Exception:
        return None
    try:
        return stx.CookieManager(key="rapitaxi_cookies")
    except Exception:
        return None


def _guardar_cookies(api: ApiClient) -> None:
    gestor = _cookie_manager()
    if gestor is None or not api.refresh_token:
        return
    expira = datetime.now() + timedelta(days=_COOKIE_DIAS)
    try:
        gestor.set(_COOKIE_REFRESH, api.refresh_token,
                   expires_at=expira, path="/")
        if api.admin_email:
            gestor.set(_COOKIE_ADMIN, api.admin_email,
                       expires_at=expira, path="/")
    except Exception:
        pass


def _borrar_cookies() -> None:
    """Borra las cookies y marca que hay que IGNORAR la restauracion.

    El delete lo ejecuta JS en el navegador y el `CookieManager` puede tardar
    mas que el `st.rerun()`: si solo confiamos en el borrado, el siguiente
    `st.context.cookies` AUN traeria el refresh token y el panel reentraria
    con la sesion que acabamos de cerrar (ese era el bug de "cerrar sesion no
    funciona"). El flag `_logout_en_curso` corta esa ventana.
    """
    st.session_state["_logout_en_curso"] = True
    gestor = _cookie_manager()
    if gestor is None:
        return
    for nombre in (_COOKIE_REFRESH, _COOKIE_ADMIN):
        try:
            gestor.delete(nombre, path="/")
        except TypeError:
            try:
                gestor.delete(nombre)
            except Exception:
                pass
        except Exception:
            pass
    # El borrado lo ejecuta JS en el navegador: se le da un instante antes de
    # que el llamador haga st.rerun() y desmonte el componente.
    time.sleep(0.25)


def _restaurar_sesion() -> Optional[ApiClient]:
    """Recupera la sesion desde la cookie de refresh, sin pedir contrasena."""
    # Un cierre de sesion acaba de pasar: ni reintentar, aunque la cookie aun
    # viva en el navegador (el borrado via JS puede correr despues del rerun).
    if st.session_state.pop("_logout_en_curso", False):
        return None

    gestor = _cookie_manager()
    refresh = ""
    admin_email = ""
    cookie_keys = []

    # Camino rapido: Streamlit expone las cookies del request inicial. En Render
    # suele estar vacio, pero se intenta primero porque es sincrono.
    try:
        cookies = st.context.cookies
        cookie_keys = sorted(cookies.keys())
        refresh = (cookies.get(_COOKIE_REFRESH) or "").strip()
        admin_email = (cookies.get(_COOKIE_ADMIN) or "").strip()
    except Exception as exc:
        pass

    # Camino lento (el que funciona en Render): el CookieManager carga la cookie
    # de forma asincrona. La primera llamada devuelve None y programa un rerun;
    # en el segundo run ya tenemos el valor.
    if not refresh and gestor is not None:
        try:
            valor = gestor.get(_COOKIE_REFRESH)
            if valor:
                refresh = str(valor).strip()
            valor_admin = gestor.get(_COOKIE_ADMIN)
            if valor_admin:
                admin_email = str(valor_admin).strip()
        except Exception as exc:
            pass


    if not refresh:
        return None

    cliente = ApiClient(get_api_base_url())
    try:
        with st.spinner("Restaurando sesión..."):
            cliente.restaurar(refresh, admin_email)
    except SesionExpirada as exc:
        _borrar_cookies()
        return None
    except ApiError as exc:
        st.warning("No se pudo restaurar la sesión: %s" % explicar_error(exc))
        return None
    st.session_state["api"] = cliente
    _cargar_rol(cliente)
    return cliente


def _cerrar_sesion(api: ApiClient, aviso: str = "") -> None:
    try:
        api.logout()
    except Exception:
        pass
    _borrar_cookies()
    st.session_state.pop("api", None)
    st.session_state.pop("admin_rol", None)
    # La pestana recordada es por sesion: al entrar otra cuenta no debe heredar
    # la seccion del administrador que acaba de salir. NO se borra aqui: el
    # `st.radio` con key `pestana_activa` ya se creo en este run y Streamlit
    # prohibe tocar su estado despues. Se marca y se limpia al inicio del
    # siguiente run (antes de crear el widget).
    st.session_state["_olvidar_pestana"] = True
    try:
        st.query_params.pop("tab", None)
    except Exception:
        pass
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
            _cargar_rol(cliente)
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    st.session_state["api"] = cliente
    ui.invalidar()
    st.rerun()


def _cargar_rol(cliente: ApiClient) -> None:
    """Consulta el rol del admin y lo deja en session_state.

    Si falla la consulta no bloquea el login: el panel refresca el rol al
    mostrar las pestanas.
    """
    try:
        perfil = cliente.perfil_admin()
        st.session_state["admin_rol"] = (perfil.get("rol") or "").strip()
    except ApiError:
        st.session_state["admin_rol"] = ""


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


def _resolver_pestana(permitidas: list[str]) -> str:
    """Devuelve la pestana activa y la deja en `session_state`.

    Prioridad: `?tab=` de la URL (sobrevive a un F5) -> ultima pestana usada en
    `session_state` (sobrevive a los reruns que dispara cada accion) -> la
    primera permitida para el rol.

    Se llama ANTES de crear el widget. Asi un `st.rerun()` tras crear un
    operador o aprobar un vehiculo NO devuelve al usuario a la primera pestana.
    """
    por_url = SLUG_A_TAB.get((st.query_params.get("tab") or "").strip())
    guardada = st.session_state.get("pestana_activa")
    for candidata in (por_url, guardada):
        if candidata in permitidas:
            st.session_state["pestana_activa"] = candidata
            return candidata
    st.session_state["pestana_activa"] = permitidas[0]
    return permitidas[0]


def _al_cambiar_pestana() -> None:
    """Refleja la pestana elegida en la URL para que un F5 no la pierda."""
    slug = TAB_SLUGS.get(st.session_state.get("pestana_activa") or "")
    if slug:
        st.query_params["tab"] = slug


def _sidebar(api: ApiClient, permitidas: Optional[list[str]] = None) -> None:
    with st.sidebar:
        st.markdown("## 🚕 Rapitaxi")
        st.caption("Panel de administración")
        st.markdown("**%s**" % (api.admin_email or "Administrador"))
        st.caption(get_api_base_url())
        st.divider()

        # Selector de seccion: sustituye al `st.tabs` estatico, que reiniciaba
        # a la primera pestana en cada recarga. La eleccion vive en
        # `session_state` (reruns) y en `?tab=` (F5, enlace compartido).
        if permitidas:
            st.radio(
                "Sección",
                permitidas,
                key="pestana_activa",
                on_change=_al_cambiar_pestana,
            )
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


@st.fragment(run_every=240)
def _keep_alive(api: ApiClient) -> None:
    """Ping periodico para mantener Render despierto y renovar el access token."""
    try:
        api.ping()
    except Exception:
        pass


def _panel(api: ApiClient) -> None:
    # Refresca la cookie de sesion en cada carga (si el paquete esta instalado).
    _guardar_cookies(api)
    # Keep-alive: evita que Render duerma la instancia y renueva el access
    # token de forma proactiva cada 4 min (antes de que caduque a las 2 h).
    _keep_alive(api)
    if not st.session_state.get("admin_rol"):
        _cargar_rol(api)

    rol = (st.session_state.get("admin_rol") or "").strip()
    permitidas = TABS_POR_ROL.get(rol, [])

    if not permitidas:
        _sidebar(api)
        st.error(
            "Tu cuenta de administrador no tiene un rol operativo asignado. "
            "Pide al **super_admin** (malcolmlamar308@gmail.com) que te asigne "
            "uno: trip_operator, user_operator o wallet_operator."
            if rol else
            "No se pudo identificar el rol de tu cuenta. Inicia sesión de nuevo.")
        return

    activa = _resolver_pestana(permitidas)
    _sidebar(api, permitidas)

    try:
        _cabecera(api)
    except SesionExpirada as exc:
        _manejar_sesion(exc)

    st.divider()

    render_por_nombre = dict(TABS_BASE)
    _seguro(render_por_nombre[activa], api)


# ===================== ARRANQUE =====================

def main() -> None:
    # Primer punto del run: aqui el `st.radio` de pestanas aun no existe, asi
    # que es el unico sitio seguro para borrar su clave tras un cierre de
    # sesion.
    if st.session_state.pop("_olvidar_pestana", False):
        st.session_state.pop("pestana_activa", None)
    api = st.session_state.get("api")
    if api is None or not api.autenticado:
        api = _restaurar_sesion()
        if api is None:
            _login()
            return
    _panel(api)


main()
