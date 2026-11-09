"""Gestion de cuentas de CLIENTES (pasajeros) para super_admin/user_operator.

Casos de uso: buscar una cuenta por telefono/correo y BORRAR su perfil en
Mongo (el caso "borre mi cuenta y aun asi se puede abrir"). El borrado es
FISICO: los viajes guardan solo el id y la facturacion vive en Postgres.

La busqueda ya filtra desde el backend con regex; aqui solo se muestra.
"""

from __future__ import annotations

import streamlit as st

import ui
from api_client import ApiError, explicar_error


def _fila(c: dict) -> dict:
    estado = "🚫 eliminado" if c.get("eliminado") else (
        "✅ activa" if c.get("enable") else "⛔ deshabilitada")
    return {
        "Cliente": c.get("nombre") or "—",
        "Teléfono": c.get("telefono") or "—",
        "Correo": c.get("email") or "—",
        "Viajes": c.get("viajes", 0),
        "Estado": estado,
        "Alta": ui.fecha_hora(c.get("creado")) or "—",
    }


def render(api) -> None:
    st.markdown("### 👤 Clientes")
    st.caption("Busca la cuenta y borra el perfil. Es un borrado FÍSICO: "
               "irreversible (los viajes históricos solo quedan con su id).")

    q = st.text_input("Buscar cliente (teléfono, correo o nombre)",
                      placeholder="50354275, emily... o el correo",
                      key="clientes:q")
    if not q:
        st.info("Escribe un teléfono (los últimos 8 dígitos bastan), un "
                "correo o un nombre para buscar.")
        return

    try:
        datos = ui.cargar("clientes:busca:%s" % q.strip().lower(), 30,
                          lambda: api.buscar_clientes(q.strip()))
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    clientes = datos.get("clientes") or []
    if not clientes:
        st.info("Sin resultados para «%s»." % q)
        return

    ui.tabla([_fila(c) for c in clientes], vacio="Sin resultados.")

    for c in clientes:
        if c.get("eliminado"):
            continue
        etiqueta = "%s (%s)" % (c.get("nombre") or "Sin nombre",
                               c.get("telefono") or c.get("email") or c["id"])
        if st.button("🗑 Borrar cuenta", key="borrar_%s" % c["id"],
                     help="Borra el perfil de Mongo. Los viajes se quedan "
                          "con el id; es irreversible."):
            st.session_state["borrar_cliente"] = c
            st.rerun()

    target = st.session_state.get("borrar_cliente")
    if target:
        st.error("¿Borrar FÍSICAMENTE la cuenta de **%s** (%s)? No se puede "
                 "deshacer." % (target.get("nombre") or "—",
                                target.get("telefono") or target.get("email")))
        c1, c2 = st.columns(2)
        if c1.button("Sí, borrar cuenta", type="primary",
                     key="confirmar_borrar"):
            try:
                res = api.borrar_cliente(target["id"])
                ui.flash("ok", res.get("message") or "Cuenta borrada")
                ui.invalidar("clientes:")
                ui.invalidar("clientes:busca:")
            except ApiError as exc:
                ui.flash("error", explicar_error(exc))
            st.rerun()
        if c2.button("Cancelar", key="cancelar_borrar"):
            st.rerun()
