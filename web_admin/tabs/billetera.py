"""Billetera de los choferes: saldo, recargas, descargos y movimientos."""

from __future__ import annotations

import pandas as pd
import streamlit as st

import ui
from api_client import ApiError, explicar_error

METODOS_RECARGA = ["efectivo", "transferencia", "pasarela", "promocion",
                   "ajuste"]
METODOS_DESCARGO = ["ajuste", "efectivo", "transferencia", "penalizacion"]

TIPOS_MOVIMIENTO = {
    "recarga": "Recarga",
    "debito": "Débito",
    "bono": "Bono",
    "pago": "Pago",
}


def _fila(c: dict) -> dict:
    return {
        "Chófer": c.get("nombre") or "—",
        "Correo": c.get("email") or "—",
        "Saldo": ui.dinero(c.get("saldo")),
    }


def _etiqueta(c: dict) -> str:
    return "%s · %s" % (c.get("nombre") or "Chófer sin nombre",
                        c.get("email") or "sin correo")


def _movimientos(api, driver_id: str) -> None:
    st.markdown("#### Últimos movimientos")
    try:
        filas = ui.cargar("billetera:movimientos:%s" % driver_id, 45,
                          lambda: api.billetera_movimientos(driver_id, 100))
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    if not filas:
        st.info("Ese chófer no tiene movimientos todavía.")
        return

    tabla = [{
        "Fecha": ui.fecha_hora(m.get("created_at")),
        "Tipo": TIPOS_MOVIMIENTO.get(str(m.get("tipo") or "").lower(),
                                     str(m.get("tipo") or "—")),
        "Monto": ui.dinero(m.get("monto")),
        "Saldo antes": ui.dinero(m.get("saldo_anterior")),
        "Saldo después": ui.dinero(m.get("saldo_nuevo")),
        "Método": (m.get("metodo") or "—").capitalize(),
        "Nota": m.get("nota") or m.get("referencia") or "—",
        "Admin": m.get("admin_email") or "—",
    } for m in filas]
    st.dataframe(pd.DataFrame(tabla), hide_index=True)


def _acciones(api, chofer: dict) -> None:
    driver_id = chofer["driver_id"]
    with st.container(border=True):
        st.markdown("#### %s" % (chofer.get("nombre") or "Chófer"))
        c1, c2 = st.columns(2)
        c1.metric("Saldo actual", ui.dinero(chofer.get("saldo")))
        c2.metric("Correo", chofer.get("email") or "—")

        recarga_col, descargo_col = st.columns(2)

        with recarga_col:
            st.markdown("##### ➕ Recargar")
            with st.form("form_recarga"):
                monto = st.number_input("Monto a recargar (CUP)",
                                        min_value=0.01, step=50.0,
                                        format="%.2f", key="recarga_monto")
                metodo = st.selectbox("Método", METODOS_RECARGA,
                                      key="recarga_metodo")
                referencia = st.text_input("Referencia (opcional)",
                                           key="recarga_referencia")
                nota = st.text_input("Nota (opcional)", key="recarga_nota")
                recargar = st.form_submit_button("Aplicar recarga",
                                                 type="primary")

            if recargar:
                try:
                    resultado = api.billetera_recarga(
                        driver_id, monto, metodo, referencia, nota)
                except ApiError as exc:
                    st.error(explicar_error(exc))
                else:
                    ui.flash("success", resultado.get("message")
                             or "Recarga aplicada.")
                    ui.invalidar("billetera")
                    st.rerun()

        with descargo_col:
            st.markdown("##### ➖ Descontar")
            with st.form("form_descargo"):
                monto_d = st.number_input("Monto a descontar (CUP)",
                                          min_value=0.01, step=50.0,
                                          format="%.2f", key="descargo_monto")
                metodo_d = st.selectbox("Método", METODOS_DESCARGO,
                                        key="descargo_metodo")
                nota_d = st.text_input("Nota (opcional)", key="descargo_nota")
                descontar = st.form_submit_button("Aplicar descuento")

            if descontar:
                try:
                    resultado = api.billetera_descargo(
                        driver_id, monto_d, metodo_d, nota_d)
                except ApiError as exc:
                    st.error(explicar_error(exc))
                else:
                    ui.flash("success", resultado.get("message")
                             or "Descuento aplicado.")
                    ui.invalidar("billetera")
                    st.rerun()

    _movimientos(api, driver_id)


def render(api) -> None:
    st.subheader("💰 Billetera de chóferes")
    st.caption(
        "El saldo es el fondo del chófer. Cada recarga y cada descuento "
        "quedan registrados con el administrador que los aplicó."
    )

    with st.form("buscar_billetera"):
        busqueda = st.text_input("Buscar chófer por nombre o correo",
                                 placeholder="Ej.: Carlos o carlos@correo.com")
        st.form_submit_button("Buscar")

    try:
        choferes = ui.cargar(
            "billetera:choferes:%s" % busqueda.strip().lower(), 60,
            lambda: api.billetera_choferes(busqueda.strip() or None),
        )
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    if not choferes:
        st.info("No se encontraron chóferes.")
        return

    st.dataframe(pd.DataFrame([_fila(c) for c in choferes]),
                 hide_index=True)

    opciones = {"%d. %s" % (i, _etiqueta(c)): c
                for i, c in enumerate(choferes, start=1)}
    elegido = st.selectbox("Chófer", list(opciones), key="billetera_elegido")
    chofer = opciones[elegido]

    try:
        actual = ui.cargar("billetera:saldo:%s" % chofer["driver_id"], 30,
                           lambda: api.billetera_saldo(chofer["driver_id"]))
    except ApiError:
        actual = chofer
    _acciones(api, actual)
