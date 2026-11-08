"""Viajes criticos: huerfanos (sin chofer) y control manual de los activos.

Es la pestana que justifica el panel web. El auto-refresco de 10 s lo dispara
`app.py`; aqui solo se leen los datos frescos, sin cache, porque un viaje sin
chofer es exactamente lo que no puede esperar.
"""

from __future__ import annotations

import pandas as pd
import streamlit as st

import ui
from api_client import ApiError, explicar_error
from components import (
    alerta_critica,
    boton_sonido,
    limpiar_alerta,
    pitido_si_cambia,
)


def _fila_huerfano(v: dict) -> dict:
    return {
        "Esperando": ui.espera(v.get("espera_segundos")),
        "Pasajero": v.get("client_name") or "—",
        "Teléfono": v.get("client_phone") or "—",
        "Origen": v.get("request_address") or "—",
        "Destino": v.get("dropoff_address") or "—",
        "Tipo": ui.tipo_vehiculo(v.get("vehicle_type")),
        "Km": ui.numero(v.get("distance_km")),
        "Estimado": ui.dinero(v.get("precio_estimado")),
        "Solicitado": ui.fecha_hora(v.get("requested_at")),
    }


def _opciones(viajes: list[dict]) -> dict[str, dict]:
    """Etiqueta legible -> viaje. El indice evita colisiones de texto."""
    salida = {}
    for i, v in enumerate(viajes, start=1):
        salida["%d. %s" % (i, ui.etiqueta_viaje(v))] = v
    return salida


def _asignar(api, viaje: dict) -> None:
    with st.container(border=True):
        st.markdown("#### Asignar este viaje a un chófer")
        st.caption(
            "Escribe el teléfono del chófer. El backend comprueba que esté "
            "aprobado, sin otro viaje activo y con el tipo de vehículo que "
            "pidió el pasajero."
        )
        with st.form("form_asignar_viaje"):
            telefono = st.text_input(
                "Teléfono del chófer",
                placeholder="+53 5 123 4567",
                key="asignar_telefono",
            )
            enviado = st.form_submit_button("Asignar viaje", type="primary")
        if not enviado:
            return
        if not telefono.strip():
            st.warning("Escribe el teléfono del chófer antes de asignar.")
            return
        try:
            resultado = api.asignar_viaje(viaje["trip_id"], telefono)
        except ApiError as exc:
            st.error(explicar_error(exc))
            return
        ui.flash("success", resultado.get("message") or "Viaje asignado.")
        ui.invalidar("criticos")
        st.rerun()


def _control_manual(api) -> None:
    with st.expander("🛠️ Control manual de viajes en curso", expanded=False):
        st.caption(
            "Para cuando el chófer se queda sin conexión a mitad de viaje. "
            "El precio no se escribe: al forzar el fin se calcula igual que "
            "cuando el chófer pulsa «Completar»."
        )
        try:
            datos = ui.cargar("criticos_activos", 8, api.viajes_activos)
        except ApiError as exc:
            st.error(explicar_error(exc))
            return

        viajes = datos.get("viajes") or []
        if not viajes:
            st.info("No hay viajes activos en este momento.")
            return

        filas = [{
            "Estado": ui.estado_viaje(v.get("status")),
            "Pasajero": v.get("client_name") or "—",
            "Chófer": v.get("driver_name") or "sin asignar",
            "Origen": v.get("request_address") or "—",
            "Destino": v.get("dropoff_address") or "—",
            "Solicitado": ui.fecha_hora(v.get("requested_at")),
        } for v in viajes]
        st.dataframe(pd.DataFrame(filas), hide_index=True)

        opciones = _opciones(viajes)
        elegido = st.selectbox("Viaje a controlar", list(opciones),
                               key="control_viaje")
        viaje = opciones[elegido]
        tiene_chofer = bool(viaje.get("driver_id"))

        columnas = st.columns([1, 1, 1.2])
        with columnas[0]:
            if st.button("▶️ Forzar inicio", key="forzar_inicio",
                         disabled=not tiene_chofer):
                try:
                    resultado = api.forzar_inicio(viaje["trip_id"])
                except ApiError as exc:
                    st.error(explicar_error(exc))
                else:
                    ui.flash("success", resultado.get("message")
                             or "Viaje iniciado.")
                    ui.invalidar("criticos")
                    st.rerun()
        with columnas[1]:
            propina = st.number_input("Propina (CUP)", min_value=0.0,
                                      step=10.0, format="%.2f",
                                      key="forzar_propina")
            if st.button("⏹️ Forzar fin", key="forzar_fin",
                         disabled=not tiene_chofer):
                try:
                    resultado = api.forzar_fin(viaje["trip_id"], propina)
                except ApiError as exc:
                    st.error(explicar_error(exc))
                else:
                    mensaje = resultado.get("message") or "Viaje completado."
                    precio = resultado.get("precio_final") or resultado.get("total_fare")
                    if precio is not None:
                        mensaje += " Precio final: %s." % ui.dinero(precio)
                    ui.flash("success", mensaje)
                    ui.invalidar("criticos")
                    st.rerun()
        with columnas[2]:
            if not tiene_chofer:
                st.caption("Sin chófer asignado no se puede iniciar ni cerrar.")
            else:
                st.caption("Chófer: %s" % (viaje.get("driver_name") or "—"))


def render(api) -> None:
    st.subheader("🚨 Viajes críticos")
    st.caption(
        "Viajes que siguen en cola y no tienen chófer. El primero es el "
        "pasajero que más lleva esperando."
    )

    columna_sonido, columna_refresco, columna_nota = st.columns([1.1, 1, 2.4])
    with columna_sonido:
        sonido = boton_sonido()
    with columna_refresco:
        if st.button("🔄 Actualizar ahora", key="refrescar_criticos"):
            ui.invalidar("criticos")
            st.rerun()
    with columna_nota:
        estado = "activado" if sonido else "silenciado"
        st.caption(
            "Refresco automático cada 10 s. Sonido %s. Solo suena cuando "
            "aparece o cambia un viaje sin chófer." % estado
        )

    datos = api.viajes_criticos()
    viajes = datos.get("viajes") or []

    if viajes:
        alerta_critica(
            "%d viaje%s sin chófer asignado." % (
                len(viajes), "" if len(viajes) == 1 else "s"),
            "El más antiguo lleva esperando %s. Asigna uno o revisa el control manual."
            % ui.espera(viajes[0].get("espera_segundos")),
        )
        pitido_si_cambia([v.get("trip_id") for v in viajes])
    else:
        limpiar_alerta()
        st.success("No hay viajes huérfanos ahora mismo.")

    if viajes:
        st.dataframe(
            pd.DataFrame([_fila_huerfano(v) for v in viajes]),
            hide_index=True,
            height=min(430, 40 + 35 * max(1, len(viajes))),
        )
        opciones = _opciones(viajes)
        elegido = st.selectbox("Viaje huérfano", list(opciones),
                               key="huerfano_elegido")
        _asignar(api, opciones[elegido])

    _control_manual(api)
