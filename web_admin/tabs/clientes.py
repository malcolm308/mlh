"""Clientes (pasajeros) de la app del cliente, para super_admin/user_operator.

La pestana abre con la tabla COMPLETA de cuentas (sin escribir nada), ordenada
de la mas reciente a la mas antigua. El buscador filtra desde el backend por
telefono, correo o nombre, y la tabla se puede descargar en CSV.

Tambien permite BORRAR una cuenta: es un borrado FISICO en Mongo (los viajes
guardan solo el id y la facturacion vive en Postgres), irreversible. Las
cuentas borradas se anonimizan y quedan ocultas salvo que se marque
"Incluir cuentas eliminadas", para poder auditar una baja.
"""

from __future__ import annotations

import pandas as pd
import streamlit as st

import ui
from api_client import ApiError, explicar_error


def _estado(c: dict) -> str:
    if c.get("eliminado"):
        return "🚫 eliminada"
    return "✅ activa" if c.get("enable") else "⛔ deshabilitada"


def _fila(c: dict) -> dict:
    return {
        "Cliente": c.get("nombre") or "—",
        "Teléfono": c.get("telefono") or "—",
        "Correo": c.get("email") or "—",
        "Viajes": c.get("viajes", 0),
        "Fondo": ui.dinero(c.get("fondo")),
        "Código": c.get("codigo_referido") or "—",
        "Estado": _estado(c),
        "Alta": ui.fecha_hora(c.get("creado")) or "—",
    }


def _etiqueta(c: dict) -> str:
    return "%s (%s)" % (c.get("nombre") or "Sin nombre",
                        c.get("telefono") or c.get("email") or c["id"])


def render(api) -> None:
    st.markdown("### 👤 Clientes")
    st.caption("Todas las cuentas de la app del cliente. El buscador filtra "
               "por teléfono, correo o nombre; aquí también puedes borrar una "
               "cuenta (borrado FÍSICO e irreversible).")

    col_q, col_limite, col_boton = st.columns([3, 1, 1])
    q = col_q.text_input("Buscar cliente", key="clientes:q",
                         placeholder="50354275, emily... o el correo")
    limite = col_limite.selectbox("Máximo", (100, 300, 1000), index=1,
                                  key="clientes:limite")
    if col_boton.button("🔄 Actualizar", use_container_width=True):
        ui.invalidar("clientes:")
        st.rerun()

    incluir_eliminados = st.checkbox(
        "Incluir cuentas eliminadas", key="clientes:eliminados",
        help="Las cuentas dadas de baja se anonimizan y se ocultan de la "
             "tabla. Márcalo solo para auditar un borrado.")

    texto = q.strip()
    clave = "clientes:lista:%s:%s:%s" % (texto.lower(), limite,
                                         int(incluir_eliminados))
    try:
        datos = ui.cargar(
            clave, 20,
            lambda: api.buscar_clientes(texto, limit=limite,
                                        incluir_eliminados=incluir_eliminados))
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    clientes = datos.get("clientes") or []
    total = int(datos.get("total") or 0)

    activas = sum(1 for c in clientes
                  if c.get("enable") and not c.get("eliminado"))
    con_viajes = sum(1 for c in clientes if int(c.get("viajes") or 0) > 0)

    m1, m2, m3, m4 = st.columns(4)
    m1.metric("Clientes", total)
    m2.metric("En la tabla", len(clientes))
    m3.metric("Activas (tabla)", activas)
    m4.metric("Con viajes (tabla)", con_viajes)

    if not clientes:
        if texto:
            st.info("Sin resultados para «%s»." % texto)
        else:
            st.info("Todavía no hay clientes registrados.")
        return

    filas = [_fila(c) for c in clientes]
    ui.tabla(filas, altura=min(560, 42 + 35 * len(filas)))
    st.caption("Mostrando %d de %d%s." % (
        len(clientes), total,
        "" if not texto else " para «%s»" % texto))

    csv = pd.DataFrame(filas).to_csv(index=False).encode("utf-8-sig")
    st.download_button("⬇️ Descargar CSV", csv,
                       file_name="clientes_rapitaxi.csv", mime="text/csv")

    _zona_borrado(api, clientes)


def _zona_borrado(api, clientes: list) -> None:
    """Borrado manual, separado de la tabla para no llenarla de botones."""
    borrables = [c for c in clientes if not c.get("eliminado")]
    with st.expander("🗑 Zona de riesgo: borrar una cuenta"):
        if not borrables:
            st.caption("No hay cuentas activas en la lista para borrar.")
            return
        elegido = st.selectbox(
            "Cliente", borrables, format_func=_etiqueta,
            key="clientes:borrar_elegido")
        st.caption("Se borra el perfil de Mongo. Los viajes históricos se "
                   "quedan con su id. No se puede deshacer.")
        if st.button("Borrar cuenta seleccionada", type="primary"):
            st.session_state["borrar_cliente"] = elegido
            st.rerun()

    target = st.session_state.get("borrar_cliente")
    if not target:
        return
    st.error("¿Borrar FÍSICAMENTE la cuenta de **%s** (%s)? No se puede "
             "deshacer." % (target.get("nombre") or "—",
                            target.get("telefono") or target.get("email")))
    c1, c2 = st.columns(2)
    if c1.button("Sí, borrar cuenta", type="primary", key="confirmar_borrar"):
        try:
            res = api.borrar_cliente(target["id"])
            ui.flash("ok", res.get("message") or "Cuenta borrada")
            ui.invalidar("clientes:")
        except ApiError as exc:
            ui.flash("error", explicar_error(exc))
        st.session_state.pop("borrar_cliente", None)
        st.rerun()
    if c2.button("Cancelar", key="cancelar_borrar"):
        st.session_state.pop("borrar_cliente", None)
        st.rerun()
