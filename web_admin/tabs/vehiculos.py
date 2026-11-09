"""Aprobacion de vehiculos del garaje de cada chofer."""

from __future__ import annotations

import pandas as pd
import streamlit as st

import ui
from api_client import ApiError, explicar_error

FILTROS = {
    "Solo pendientes": "pendiente",
    "Solo aprobados": "aprobado",
    "Solo rechazados": "rechazado",
    "Todos": "",
}


def _fila(v: dict) -> dict:
    return {
        "Chófer": v.get("chofer") or "—",
        "Teléfono": v.get("telefono") or "—",
        "Matrícula": v.get("matricula") or "—",
        "Tipo": ui.tipo_vehiculo(v.get("tipo_vehiculo")),
        "Marca / modelo": " ".join(filter(None, [
            v.get("marca"), v.get("modelo")])).strip() or "—",
        "Estado": ui.estado_cuenta(v.get("estado")),
        "Fotos faltantes": ", ".join(
            ui.FOTO_LABELS.get(c, c) for c in (v.get("fotos_faltantes") or [])
        ) or "—",
        "Registrado": ui.fecha_hora(v.get("creado")),
    }


def _etiqueta_vehiculo(v: dict) -> str:
    matricula = v.get("matricula") or "sin matrícula"
    chofer = v.get("chofer") or "chófer sin nombre"
    tipo = ui.tipo_vehiculo(v.get("tipo_vehiculo"))
    return "%s · %s · %s" % (matricula, chofer, tipo)


def _galeria(api, vehiculo: dict) -> None:
    fotos = vehiculo.get("fotos") or {}
    if not isinstance(fotos, dict) or not fotos:
        st.info("Ese vehículo no tiene fotos guardadas.")
        return

    columnas = st.columns(3)
    for i, (campo, ref) in enumerate(fotos.items()):
        ref = ref or {}
        archivo = ref.get("archivo")
        if not archivo:
            continue
        with columnas[i % 3]:
            try:
                datos = ui.cargar("imagen:%s" % archivo, 600,
                                  lambda a=archivo: api.descargar_imagen(a))
                st.image(ui.imagen_desde_bytes(datos),
                         caption=ui.FOTO_LABELS.get(campo, campo),
                         width=300)
            except ApiError as exc:
                st.caption("No se pudo cargar %s: %s"
                           % (ui.FOTO_LABELS.get(campo, campo),
                              explicar_error(exc)))
                continue
            estado = (ref.get("estado") or "pendiente").lower()
            st.caption("Estado: %s%s" % (
                ui.estado_cuenta(estado),
                (" · " + ref["motivo"]) if ref.get("motivo") else "",
            ))


def _imagen_revision(api, url, caption: str) -> None:
    """Pinta una imagen para la revision previa a aprobar el vehiculo."""
    if not url:
        st.info("Sin %s." % caption.lower())
        return
    try:
        datos = ui.cargar("imagen:%s" % url, 600,
                          lambda u=url: api.descargar_imagen(u))
        st.image(ui.imagen_desde_bytes(datos), caption=caption, width=280)
    except ApiError as exc:
        st.caption("No se pudo cargar %s: %s" % (caption, explicar_error(exc)))


def _detalle(api, vehiculo: dict) -> None:
    with st.container(border=True):
        st.markdown("#### %s · %s" % (
            vehiculo.get("matricula") or "Sin matrícula",
            ui.tipo_vehiculo(vehiculo.get("tipo_vehiculo")),
        ))
        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Estado", ui.estado_cuenta(vehiculo.get("estado")))
        c2.metric("Chófer", vehiculo.get("chofer") or "—")
        c3.metric("Teléfono", vehiculo.get("telefono") or "—")
        c4.metric("Fotos faltantes",
                  len(vehiculo.get("fotos_faltantes") or []))

        if vehiculo.get("motivo"):
            st.warning("Motivo del rechazo anterior: %s" % vehiculo["motivo"])
        if vehiculo.get("chofer_estado") and \
                vehiculo.get("chofer_estado") != "aprobado":
            st.warning(
                "La cuenta del chófer está %s. Aunque apruebes el vehículo, "
                "no podrá ponerse en línea hasta habilitar al chófer."
                % ui.estado_cuenta(vehiculo.get("chofer_estado")).lower()
            )

        with st.expander("📷 Exterior y licencia del chófer", expanded=True):
            c1, c2, c3 = st.columns(3)
            with c1:
                _imagen_revision(api, vehiculo.get("foto_exterior_url"),
                                 "Exterior del vehículo")
            with c2:
                _imagen_revision(api, vehiculo.get("license_front_url"),
                                 "Licencia (frente)")
            with c3:
                _imagen_revision(api, vehiculo.get("license_back_url"),
                                 "Licencia (dorso)")

        with st.expander("📷 Todas las fotos del vehículo", expanded=False):
            _galeria(api, vehiculo)

        with st.form("decision_vehiculo"):
            st.caption(
                "Aprueba solo si las fotos corresponden al vehículo y se leen "
                "la matrícula y la circulación. Al rechazar, el motivo lo ve "
                "el chófer en su app."
            )
            confirmo = st.checkbox(
                "Revisé las fotos y confirmo la decisión",
                key="vehiculo_confirmo",
            )
            motivo = st.text_input(
                "Motivo del rechazo (obligatorio para rechazar)",
                key="vehiculo_motivo",
            )
            b1, b2 = st.columns(2)
            aprobar = b1.form_submit_button("✅ Aprobar vehículo",
                                            type="primary")
            rechazar = b2.form_submit_button("❌ Rechazar vehículo")

        if not aprobar and not rechazar:
            return
        if not confirmo:
            st.warning("Marca la casilla de confirmación antes de decidir.")
            return
        if rechazar and not motivo.strip():
            st.warning("Escribe el motivo del rechazo.")
            return

        decision = "aprobado" if aprobar else "rechazado"
        try:
            resultado = api.decidir_vehiculo(vehiculo["id"], decision, motivo)
        except ApiError as exc:
            st.error(explicar_error(exc))
            return
        mensaje = resultado.get("message") or "Vehículo actualizado."
        # El aviso se guarda para que se vea DESPUÉS del rerun; el st.success
        # directo lo borraria la recarga inmediata.
        st.success(mensaje)
        st.cache_data.clear()
        ui.flash("success", mensaje)
        ui.invalidar("vehiculos")
        st.rerun()


def render(api) -> None:
    st.subheader("🚗 Aprobación de vehículos")
    st.caption(
        "Un vehículo nuevo entra como pendiente. Solo uno aprobado puede "
        "ponerse «En línea» y recibir viajes."
    )

    filtro = st.radio("Filtro", list(FILTROS), horizontal=True,
                      key="filtro_vehiculos")
    estado = FILTROS[filtro]

    try:
        datos = ui.cargar("vehiculos:%s" % estado, 60,
                          lambda: api.vehiculos(estado or None))
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    vehiculos = datos.get("vehiculos") or []
    st.caption("Vehículos en esta vista: %d" % len(vehiculos))

    if not vehiculos:
        st.info("No hay vehículos con ese filtro.")
        return

    st.dataframe(pd.DataFrame([_fila(v) for v in vehiculos]),
                 hide_index=True)

    opciones = {"%d. %s" % (i, _etiqueta_vehiculo(v)): v
                for i, v in enumerate(vehiculos, start=1)}
    elegido = st.selectbox("Vehículo a revisar", list(opciones),
                           key="vehiculo_elegido")
    _detalle(api, opciones[elegido])
