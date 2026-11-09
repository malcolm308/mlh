"""Gestion de Administradores (SOLO super_admin).

La contrasena la CREA el backend: el super_admin solo declara el correo y el
rol, pide la cuenta y recibe la contrasena generada UNA VEZ (opo despues no
es recuperable; se puede pedir otra con el boton de reset de cada fila).
"""

from __future__ import annotations

import streamlit as st

import ui
from api_client import ApiError, explicar_error

ROLES_OPERADOR = (
    ("trip_operator", "🚨 Operador de viajes"),
    ("user_operator", "🧾 Operador de registros"),
    ("wallet_operator", "💰 Operador de cartera"),
)

ETIQUETAS_ROL = {
    "super_admin": "👑 Super admin",
    "trip_operator": "🚨 Op. viajes",
    "user_operator": "🧾 Op. registros",
    "wallet_operator": "💰 Op. cartera",
}


def render(api) -> None:
    st.markdown("### 👥 Gestión de Admins")
    st.caption(
        "Los operadores solo pueden ver sus pestañas. La contraseña la "
        "genera el backend y se muestra una sola vez.")

    # ---------- Tabla de administradores ----------
    try:
        datos = ui.cargar("admins:lista", 20, api.listar_administradores)
    except ApiError as exc:
        st.error(explicar_error(exc))
        return
    admins = datos.get("administradores") or []

    if not admins:
        st.info("Todavía no hay otros administradores registrados.")
    else:
        st.markdown("#### Administradores actuales")
        for a in admins:
            es_super = (a.get("rol") or "") == "super_admin"
            es_yo = (a.get("email") or "").strip().lower() == \
                (api.admin_email or "").strip().lower()
            with st.container(border=True):
                col_info, col_pass, col_baja = st.columns([5, 2, 2])
                with col_info:
                    st.markdown(
                        "**%s** · %s" % (a.get("nombre") or "—",
                                         ETIQUETAS_ROL.get(a.get("rol"),
                                                           a.get("rol") or "?")))
                    st.caption("%s · desde %s" % (
                        a.get("email") or "—",
                        ui.fecha_hora(a.get("created_at")) or "—"))
                with col_pass:
                    if not es_yo:
                        if st.button("🔑 Contraseña",
                                     key="pass_%s" % a["id"],
                                     help="El backend genera una contraseña "
                                          "nueva. Se muestra una sola vez."):
                            try:
                                res = api.asignar_password_admin(a["id"])
                                st.session_state["pass_generada"] = {
                                    "email": a.get("email"),
                                    "clave": res.get("password_generada")}
                                st.rerun()
                            except ApiError as exc:
                                st.error(explicar_error(exc))
                with col_baja:
                    if not es_yo and not es_super:
                        if st.button("🚪 Despedir", key="del_%s" % a["id"],
                                     help="Elimina la cuenta de este "
                                          "administrador."):
                            st.session_state["despedir_pendiente"] = a
                            st.rerun()
                    elif es_yo:
                        st.caption("(tu cuenta)")

    pendiente = st.session_state.get("despedir_pendiente")
    if pendiente:
        st.warning("¿Confirmas DESPEDIR a **%s** (%s)? Es irreversible." % (
            pendiente.get("nombre") or "—", pendiente.get("email")))
        c1, c2 = st.columns(2)
        if c1.button("Sí, eliminar", type="primary"):
            try:
                res = api.despedir_administrador(pendiente["id"])
                ui.flash("ok", res.get("message") or "Administrador eliminado")
                ui.invalidar("admins:lista")
                st.session_state.pop("despedir_pendiente", None)
            except ApiError as exc:
                ui.flash("error", explicar_error(exc))
            st.rerun()
        if c2.button("Cancelar"):
            st.session_state.pop("despedir_pendiente", None)
            st.rerun()

    generada = st.session_state.get("pass_generada")
    if generada:
        st.success("Contraseña de **%s** — cópiala y pásala por un canal "
                   "seguro. No se volverá a mostrar." % generada["email"])
        st.code(generada["clave"], language="")
        if st.button("Ya la guardé"):
            st.session_state.pop("pass_generada", None)
            st.rerun()

    st.divider()

    # ---------- Alta de un operador ----------
    st.markdown("#### ➕ Alta de un nuevo administrador")
    st.caption("Ellos solo te pasan el correo: tú pides la cuenta y el "
               "backend genera la contraseña.")
    with st.form("form_alta_admin", clear_on_submit=True):
        email = st.text_input("Correo del operador *",
                              placeholder="operador@rapitaxi.cu")
        rol = st.selectbox("Rol del operador *",
                           options=[r for r, _ in ROLES_OPERADOR],
                           format_func=lambda r: dict(ROLES_OPERADOR)[r])
        c1, c2 = st.columns(2)
        nombre = c1.text_input("Nombre (opcional)")
        telefono = c2.text_input("Teléfono (opcional)")
        password = st.text_input("Contraseña (opcional: deja vacío para que "
                                 "el backend la genere)",
                                 type="password")
        enviar = st.form_submit_button("Crear operador", type="primary",
                                       disabled=not email)
    if enviar:
        try:
            res = api.crear_administrador(
                email=email, rol=rol, nombre=nombre, telefono=telefono,
                password=password or None)
            st.session_state["pass_generada"] = {
                "email": res.get("email"),
                "clave": res.get("password_generada") or password}
            ui.invalidar("admins:lista")
        except ApiError as exc:
            ui.flash("error", explicar_error(exc))

    st.divider()

    # ---------- Mi propia contrasena ----------
    st.markdown("#### 🔒 Cambiar mi contraseña")
    with st.form("form_mi_pass"):
        actual = st.text_input("Contraseña actual", type="password")
        nueva = st.text_input("Contraseña nueva (min. 8)", type="password")
        repetir = st.text_input("Repite la nueva", type="password")
        ok = st.form_submit_button("Actualizar mi contraseña")
    if ok:
        if nueva != repetir:
            ui.flash("error", "Las contraseñas nuevas no coinciden.")
        elif len(nueva) < 8:
            ui.flash("error", "La contraseña nueva es demasiado corta.")
        else:
            try:
                res = api.cambiar_mi_password(actual, nueva)
                ui.flash("ok", res.get("message") or "Contraseña actualizada")
            except ApiError as exc:
                ui.flash("error", explicar_error(exc))
