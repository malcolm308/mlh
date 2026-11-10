"""Habilitacion de choferes: aprobar o rechazar cuentas."""

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


def _fila(c: dict) -> dict:
    docs = c.get("documentos") or {}
    return {
        "Chófer": c.get("nombre") or "—",
        "Teléfono": c.get("telefono") or "—",
        "Correo": c.get("email") or "—",
        "Estado": ui.estado_cuenta(c.get("estado")),
        "Vehículo": c.get("vehiculo") or "—",
        "Matrícula": c.get("matricula") or "—",
        "Fondo": ui.dinero(c.get("fondo")),
        "Documentos": "%s/%s" % (docs.get("subidos", 0),
                                 docs.get("total", 0)),
        "Creado": ui.fecha_hora(c.get("creado")),
    }


def _etiqueta(c: dict) -> str:
    nombre = c.get("nombre") or "Chófer sin nombre"
    telefono = c.get("telefono") or c.get("email") or "sin contacto"
    return "%s · %s · %s" % (nombre, telefono,
                             ui.estado_cuenta(c.get("estado")))


def _detalle(api, chofer: dict) -> None:
    docs = chofer.get("documentos") or {}
    with st.container(border=True):
        st.markdown("#### %s" % (chofer.get("nombre") or "Chófer"))
        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Estado", ui.estado_cuenta(chofer.get("estado")))
        c2.metric("Fondo", ui.dinero(chofer.get("fondo")))
        c3.metric("Documentos", "%s/%s" % (docs.get("subidos", 0),
                                           docs.get("total", 0)))
        c4.metric("Calificación", ui.numero(chofer.get("rating"), 1))

        st.write(
            "**Teléfono:** %s  ·  **Correo:** %s  ·  **Vehículo:** %s  ·  "
            "**Matrícula:** %s  ·  **Servicio:** %s"
            % (
                chofer.get("telefono") or "—",
                chofer.get("email") or "—",
                chofer.get("vehiculo") or "—",
                chofer.get("matricula") or "—",
                ui.tipo_vehiculo(chofer.get("servicio")),
            )
        )

        if docs.get("completo"):
            st.success("Documentos completos (%s de %s)."
                       % (docs.get("subidos", 0), docs.get("total", 0)))
        else:
            st.warning("Faltan documentos: %s"
                       % (", ".join(docs.get("faltan") or []) or "—"))

        if chofer.get("motivo"):
            st.info("Motivo del último rechazo: %s" % chofer["motivo"])
        if chofer.get("revisado_por"):
            st.caption("Revisado por %s el %s"
                       % (chofer.get("revisado_por"),
                          ui.fecha_hora(chofer.get("revisado_at"))))

        # Galeria de documentos subidos (Cloudinary). Se agrupan en desplegables
        # para no saturar la pantalla.
        docs = chofer.get("documentos") or {}
        detalle = docs.get("detalle") or {}
        if detalle:
            st.markdown("##### 📄 Documentos subidos")
            # Licencia y carnet en un desplegable, fotos del vehiculo en otro.
            licencia_campos = ["rostro", "carnet_frente", "carnet_atras",
                               "licencia_frente", "licencia_atras", "circulacion"]
            vehiculo_campos = ["vehiculo_interior_frente", "vehiculo_interior_atras",
                               "vehiculo_exterior_frente", "vehiculo_exterior_atras"]
            with st.expander("📄 Ver identidad y licencia", expanded=False):
                cols = st.columns(3)
                i = 0
                for campo in licencia_campos:
                    info = detalle.get(campo) or {}
                    if not info.get("aplica", True):
                        continue
                    with cols[i % 3]:
                        url = info.get("url")
                        if url:
                            st.image(url, caption=info.get("etiqueta") or campo,
                                     use_container_width=True)
                        else:
                            st.warning("Documento no subido: %s"
                                       % (info.get("etiqueta") or campo))
                    i += 1
            with st.expander("🚗 Ver fotos del vehículo", expanded=False):
                cols = st.columns(2)
                i = 0
                for campo in vehiculo_campos:
                    info = detalle.get(campo) or {}
                    if not info.get("aplica", True):
                        continue
                    with cols[i % 2]:
                        url = info.get("url")
                        if url:
                            st.image(url, caption=info.get("etiqueta") or campo,
                                     use_container_width=True)
                        else:
                            st.warning("Documento no subido: %s"
                                       % (info.get("etiqueta") or campo))
                    i += 1

        with st.form("decision_chofer"):
            st.caption(
                "Aprobar habilita la cuenta para entrar a la app. Rechazar "
                "la bloquea; el motivo lo ve el chófer."
            )
            confirmo = st.checkbox(
                "Revisé los documentos y confirmo la decisión",
                key="chofer_confirmo",
            )
            motivo = st.text_input(
                "Motivo del rechazo (obligatorio para rechazar)",
                key="chofer_motivo",
            )
            # Campos que el administrador marca como faltantes/incorrectos.
            campos_opciones = [
                "rostro", "carnet_frente", "carnet_atras",
                "licencia_frente", "licencia_atras", "circulacion",
                "vehiculo_interior_frente", "vehiculo_interior_atras",
                "vehiculo_exterior_frente", "vehiculo_exterior_atras",
            ]
            faltantes_sel = st.multiselect(
                "Campos a corregir (opcional)",
                campos_opciones,
                key="chofer_faltantes",
            )
            b1, b2 = st.columns(2)
            aprobar = b1.form_submit_button(
                "✅ Aprobar chófer", type="primary",
                disabled=not docs.get("completo"),
            )
            rechazar = b2.form_submit_button("❌ Rechazar y pedir corrección")

        if not aprobar and not rechazar:
            return
        if not confirmo:
            st.warning("Marca la casilla de confirmación antes de decidir.")
            return
        if rechazar and not motivo.strip():
            st.warning("Escribe el motivo del rechazo.")
            return

        if aprobar:
            estado = "aprobado"
            missing = None
        else:
            estado = "needs_correction"
            missing = faltantes_sel or None
        try:
            resultado = api.cambiar_estado_chofer(
                chofer["driver_id"], estado, motivo,
                missing_fields=missing)
        except ApiError as exc:
            st.error(explicar_error(exc))
            return
        ui.flash("success", resultado.get("message")
                 or "Estado del chófer actualizado.")
        ui.invalidar("choferes", "vehiculos", "billetera")
        st.rerun()

    # ---- Zona de peligro: eliminacion definitiva ----
    with st.expander("🗑️ Zona de peligro", expanded=False):
        st.warning("⚠️ ¿Estás seguro? Esta acción borrará al chófer de la "
                   "plataforma de forma permanente y no se puede deshacer.")
        confirmar_elim = st.checkbox(
            "Confirmo que quiero eliminar este chófer definitivamente",
            key="chofer_confirmar_elim",
        )
        if st.button("🗑️ Eliminar Chófer Definitivamente", type="secondary"):
            if not confirmar_elim:
                st.warning("Marca la casilla de confirmación.")
            else:
                try:
                    resultado = api.eliminar_chofer(chofer["driver_id"])
                except ApiError as exc:
                    st.error(explicar_error(exc))
                    return
                ui.flash("success", resultado.get("message")
                         or "Chófer eliminado.")
                ui.invalidar("choferes", "vehiculos", "billetera")
                st.rerun()


def render(api) -> None:
    st.subheader("🧑‍✈️ Habilitación de chóferes")
    st.caption(
        "El administrador decide quién puede entrar a la app del chófer. "
        "Para aprobar, la cuenta debe tener los documentos completos."
    )

    filtro = st.radio("Filtro", list(FILTROS), horizontal=True,
                      key="filtro_choferes")

    with st.form("buscar_chofer"):
        busqueda = st.text_input("Buscar por nombre, correo o teléfono",
                                 placeholder="Ej.: Carlos o 59295207")
        buscar = st.form_submit_button("Buscar")
    estado = FILTROS[filtro]
    clave = "choferes:%s:%s" % (estado, busqueda.strip().lower())

    try:
        datos = ui.cargar(
            clave, 60,
            lambda: api.choferes(estado or None, busqueda.strip() or None),
        )
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    choferes = datos.get("choferes") or []
    st.caption(
        "Total: %d · Pendientes: %d · Aprobados: %d · Rechazados: %d"
        % (datos.get("total", len(choferes)),
           datos.get("pendientes", 0),
           datos.get("aprobados", 0),
           datos.get("rechazados", 0))
    )

    if not choferes:
        st.info("No hay chóferes con ese filtro.")
        return

    st.dataframe(pd.DataFrame([_fila(c) for c in choferes]),
                 hide_index=True)

    # El desplegable de revision solo muestra pendientes: los rechazados/aprobados
    # no se re-revisan desde esta pantalla (siguen visibles en la tabla superior).
    pendientes = [c for c in choferes
                  if (c.get("estado") or "").strip().lower() == "pendiente"]
    if not pendientes:
        st.info("No hay chóferes pendientes de revisión en este filtro.")
        return
    opciones = {"%d. %s" % (i, _etiqueta(c)): c
                for i, c in enumerate(pendientes, start=1)}
    elegido = st.selectbox("Chófer a revisar", list(opciones),
                           key="chofer_elegido")
    _detalle(api, opciones[elegido])
