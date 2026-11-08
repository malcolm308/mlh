"""Viajes por dia: totales, grafico y detalle del dia elegido."""

from __future__ import annotations

from datetime import date

import pandas as pd
import streamlit as st

import ui
from api_client import ApiError, explicar_error


def _resumen(api, fecha: str) -> dict:
    return ui.cargar("viajes:resumen:%s" % fecha, 45,
                     lambda: api.resumen_viajes(fecha))


def _diarios(api, dias: int, hasta: str) -> dict:
    return ui.cargar("viajes:diarios:%s:%s" % (dias, hasta), 60,
                     lambda: api.viajes_diarios(dias, hasta))


def _detalle(api, fecha: str) -> dict:
    return ui.cargar("viajes:dia:%s" % fecha, 45,
                     lambda: api.viajes_del_dia(fecha))


def _fila_detalle(v: dict) -> dict:
    return {
        "Estado": ui.estado_viaje(v.get("status")),
        "Origen": v.get("request_address") or "—",
        "Destino": v.get("dropoff_address") or "—",
        "Tipo": ui.tipo_vehiculo(v.get("vehicle_type")),
        "Km": ui.numero(v.get("distance_km")),
        "Base": ui.dinero(v.get("base_fare"), ""),
        "Distancia": ui.dinero(v.get("distance_fare"), ""),
        "Total": ui.dinero(v.get("total_fare"), ""),
        "Propina": ui.dinero(v.get("tip"), ""),
        "Solicitado": ui.fecha_hora(v.get("requested_at")),
        "Iniciado": ui.fecha_hora(v.get("started_at")),
        "Completado": ui.fecha_hora(v.get("completed_at")),
    }


def render(api) -> None:
    st.subheader("📊 Viajes por día")
    st.caption(
        "Totales del día y evolución de los últimos días. Las fechas son las "
        "del servidor, no las del navegador."
    )

    c1, c2 = st.columns([1, 1])
    with c1:
        hasta = st.date_input("Día a consultar", value=date.today(),
                              key="viajes_fecha")
    with c2:
        dias = st.selectbox("Días del gráfico", [7, 14, 30], index=0,
                            key="viajes_dias")

    fecha = hasta.isoformat()

    try:
        resumen = _resumen(api, fecha)
        diarios = _diarios(api, dias, fecha)
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    m1, m2, m3, m4, m5 = st.columns(5)
    m1.metric("Viajes", resumen.get("viajes", 0))
    m2.metric("Completados", resumen.get("completados", 0))
    m3.metric("Activos", resumen.get("activos", 0))
    m4.metric("Facturado", ui.dinero(resumen.get("facturado")))
    m5.metric("Chóferes", resumen.get("choferes", 0))

    m6, m7, m8, m9, m10 = st.columns(5)
    m6.metric("Solicitados", resumen.get("solicitados", 0))
    m7.metric("Cancelados", resumen.get("cancelados", 0))
    m8.metric("Expirados", resumen.get("expirados", 0))
    m9.metric("Km completados", ui.numero(resumen.get("km"), 1))
    m10.metric("Ingreso chóferes",
               ui.dinero(resumen.get("ingreso_choferes")))

    filas_dias = diarios.get("dias") or []
    if filas_dias:
        marco = pd.DataFrame([{
            "Día": ui.fecha(f.get("dia")),
            "Total": f.get("total", 0),
            "Completados": f.get("completados", 0),
            "Cancelados": f.get("cancelados", 0),
            "Expirados": f.get("expirados", 0),
            "Facturado": f.get("facturado", 0),
            "Km": f.get("km_recorridos", 0),
        } for f in filas_dias])

        st.markdown("#### Evolución")
        st.bar_chart(marco.set_index("Día")[["Total", "Completados"]])

        st.dataframe(marco, hide_index=True)
    else:
        st.info("No hay datos para ese rango de días.")

    st.markdown("#### Detalle del %s" % ui.fecha(fecha))
    try:
        detalle = _detalle(api, fecha)
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    viajes = detalle.get("viajes") or []
    if not viajes:
        st.info("Ese día no tiene viajes registrados.")
        return

    st.caption("Viajes del día: %d" % detalle.get("total", len(viajes)))
    st.dataframe(pd.DataFrame([_fila_detalle(v) for v in viajes]),
                 hide_index=True)
