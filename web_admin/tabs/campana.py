"""Gestion de la campana "Sabado de RapiTaxi".

Aqui se lanza la campana masiva que da saldo promocional a todos los clientes.
Es independiente de las promociones comerciales de `configuracion.py`.
"""

from __future__ import annotations

import streamlit as st

import ui
from api_client import ApiError, explicar_error


def render(api, admin_email: str = "") -> None:
    st.header("Gestion de Promociones")
    st.caption(
        "Campana 'Sabado de RapiTaxi': saldo promocional por cliente, con "
        "expiracion y bono al chofer. El Fondo del cliente no se toca."
    )

    # Estado actual.
    try:
        estado = api.promos_estado()
    except ApiError as exc:
        st.error(explicar_error(exc))
        estado = {}

    activa = bool(estado.get("campana_promocional_activa"))
    expira = estado.get("fecha_expiracion")
    afectados = int(estado.get("clientes_afectados") or 0)
    con_saldo = int(estado.get("clientes_con_saldo") or 0)
    saldo_total = estado.get("saldo_promocional_total") or 0

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Clientes afectados", afectados)
    c2.metric("Con saldo vigente", con_saldo)
    c3.metric("Saldo total en juego", ui.dinero(saldo_total))
    if activa:
        c4.metric("Estado", "ACTIVA")
    else:
        c4.metric("Estado", "INACTIVA")

    if expira:
        st.info("Promocion Activa hasta: %s" % ui.fecha_hora(expira))
    else:
        st.warning("No hay promocion masiva lanzada.")

    if estado.get("monto_cliente"):
        st.caption(
            "Ultima campana: %.2f CUP por cliente, bono al chofer %.2f CUP, "
            "lanzada por %s el %s."
            % (float(estado.get("monto_cliente") or 0),
               float(estado.get("monto_bono_chofer") or 0),
               estado.get("lanzada_por") or "—",
               ui.fecha_hora(estado.get("lanzada_at")))
        )

    st.divider()
    st.subheader("🚀 Lanzar Promocion Masiva")

    with st.form("form_lanzar_promo"):
        monto_cliente = st.number_input(
            "Saldo promocional por cliente (CUP)",
            min_value=0.01, value=100.0, step=10.0, format="%.2f")
        monto_bono_chofer = st.number_input(
            "Bono al chofer por viaje (CUP)",
            min_value=0.0, value=50.0, step=10.0, format="%.2f")
        horas_expiracion = st.number_input(
            "Horas de expiracion", min_value=1.0, value=24.0, step=1.0,
            format="%.1f")
        lanzar = st.form_submit_button("🚀 Lanzar Promocion Masiva",
                                       use_container_width=True)

    if lanzar:
        try:
            res = api.lanzar_promo(monto_cliente, monto_bono_chofer,
                                   horas_expiracion)
            st.write("RESPUESTA BACKEND:", res)
        except ApiError as exc:
            st.error(explicar_error(exc))
            st.write("ERROR:", str(exc))
        else:
            st.success(
                "Promocion lanzada: %s clientes afectados, vence el %s."
                % (res.get("clientes_afectados"),
                   ui.fecha_hora(res.get("fecha_expiracion"))))
            st.rerun()