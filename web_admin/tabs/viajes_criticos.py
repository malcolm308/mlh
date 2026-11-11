"""Viajes criticos: huerfanos (sin chofer) y control manual de los activos.

El auto-refresco lo hace un `st.fragment(run_every=...)`: cada 10 s se vuelve a
pedir SOLO esta pestana, no el panel entero. Antes se usaba `st_autorefresh`,
que provocaba un rerun completo y seis peticiones al backend cada 10 s.

Flujo del viaje huerfano:

1. El cron llama a `POST /admin/trips/check-orphaned` y publica el viaje en el
   grupo de Telegram con el enlace wa.me del administrador.
2. El chofer escribe al administrador por WhatsApp; el administrador ve su
   numero.
3. El administrador escribe ese numero en la tarjeta del viaje y pulsa
   «Asignar». El backend busca al chofer por telefono, lo valida y notifica al
   cliente.
"""

from __future__ import annotations

import pandas as pd
import streamlit as st

import ui
from api_client import ApiError, ErrorDeRed, explicar_error
from components import (
    alerta_critica,
    boton_sonido,
    limpiar_alerta,
    pitido_si_cambia,
)
from config import AUTO_REFRESH_SECS


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
        "Aviso Telegram": "Enviado" if v.get("alerta_enviada") else "—",
        "Solicitado": ui.fecha_hora(v.get("requested_at")),
    }


def _es_huerfano(v: dict, umbral: int) -> bool:
    """El backend manda `es_huerfano`; si es un backend viejo, se calcula.

    El umbral (50 % de OFFER_TTL_SECS) lo decide el servidor para que el panel
    y el cron usen exactamente el mismo criterio.
    """
    if "es_huerfano" in v:
        return bool(v.get("es_huerfano"))
    espera = v.get("espera_segundos")
    try:
        return espera is not None and int(espera) > umbral
    except (TypeError, ValueError):
        return False


def _tarjeta_asignacion(api, viaje: dict) -> None:
    """Un campo de telefono y un boton «Asignar» por cada viaje pendiente."""
    trip_id = str(viaje.get("trip_id") or "")
    if not trip_id:
        return

    with st.container(border=True):
        datos, accion = st.columns([2.4, 1.3])

        with datos:
            st.markdown(
                "**%s → %s**" % (
                    viaje.get("request_address") or "Origen sin dirección",
                    viaje.get("dropoff_address") or "Destino sin dirección",
                )
            )
            st.caption(
                "Pasajero: %s · Tel: %s · Espera: %s · Estimado: %s · Tipo: %s"
                % (
                    viaje.get("client_name") or "—",
                    viaje.get("client_phone") or "—",
                    ui.espera(viaje.get("espera_segundos")),
                    ui.dinero(viaje.get("precio_estimado")),
                    ui.tipo_vehiculo(viaje.get("vehicle_type")),
                )
            )
            if viaje.get("alerta_enviada"):
                st.caption("📨 Aviso publicado en el grupo de Telegram.")

        with accion:
            telefono = st.text_input(
                "Teléfono del chófer",
                placeholder="+53 5 123 4567",
                key="tel_%s" % trip_id,
            )
            if st.button("Asignar", key="asignar_%s" % trip_id,
                         type="primary"):
                if not telefono.strip():
                    st.warning("Escribe el teléfono que te llegó por WhatsApp.")
                else:
                    try:
                        resultado = api.asignar_viaje(trip_id, telefono)
                    except ApiError as exc:
                        st.error(explicar_error(exc))
                    else:
                        ui.flash(
                            "success",
                            resultado.get("message")
                            or "Viaje asignado al chófer.",
                        )
                        ui.invalidar("criticos")
                        st.rerun()


@st.fragment(run_every=AUTO_REFRESH_SECS)
def _viajes_en_cola(api) -> None:
    """Tabla + asignacion. Es lo unico que se refresca cada 10 s."""
    columna_sonido, columna_refresco, columna_nota = st.columns([1.1, 1, 2.4])
    with columna_sonido:
        sonido = boton_sonido()
    with columna_refresco:
        if st.button("🔄 Actualizar ahora", key="refrescar_criticos"):
            ui.invalidar("criticos")
            st.rerun()
    with columna_nota:
        st.caption(
            "Refresco automático cada %d s. Sonido %s. Solo suena cuando "
            "aparece o cambia un viaje sin chófer."
            % (AUTO_REFRESH_SECS, "activado" if sonido else "silenciado")
        )

    # Sin cache: un viaje sin chofer es justo lo que no puede esperar 30 s.
    datos = api.viajes_criticos()
    viajes = datos.get("viajes") or []
    # 90 s = 50 % de la ventana de solicitud de 180 s. Solo se usa si el backend
    # es anterior a este cambio y no manda el umbral.
    umbral = int(datos.get("umbral_huerfano_segundos") or 90)
    huerfanos = [v for v in viajes if _es_huerfano(v, umbral)]

    if huerfanos:
        st.error("¡ATENCIÓN: Hay viajes esperando asignación!")
        alerta_critica(
            "%d viaje%s pasó el 50 %% del tiempo de espera."
            % (len(huerfanos), "" if len(huerfanos) == 1 else "s"),
            "El más antiguo lleva esperando %s. Asígnalo con el teléfono que "
            "te llegó por WhatsApp."
            % ui.espera(huerfanos[0].get("espera_segundos")),
        )
        pitido_si_cambia([v.get("trip_id") for v in huerfanos])
    elif viajes:
        limpiar_alerta()
        st.warning(
            "Hay %d viaje%s en cola, pero todavía no pasó el 50 %% del tiempo "
            "de espera." % (len(viajes), "" if len(viajes) == 1 else "s")
        )
    else:
        limpiar_alerta()
        st.success("No hay viajes esperando chófer ahora mismo.")

    if not viajes:
        return

    st.dataframe(
        pd.DataFrame([_fila_huerfano(v) for v in viajes]),
        hide_index=True,
        height=min(430, 40 + 35 * max(1, len(viajes))),
    )

    st.markdown("#### Asignar por teléfono")
    st.caption(
        "Pega el número del chófer que te escribió por WhatsApp. El backend "
        "comprueba que esté aprobado, sin otro viaje activo y con el tipo de "
        "vehículo que pidió el pasajero."
    )
    for viaje in viajes:
        _tarjeta_asignacion(api, viaje)


def _opciones(viajes: list[dict]) -> dict[str, dict]:
    """Etiqueta legible -> viaje. El indice evita colisiones de texto."""
    salida = {}
    for i, v in enumerate(viajes, start=1):
        salida["%d. %s" % (i, ui.etiqueta_viaje(v))] = v
    return salida


def _control_manual(api) -> None:
    # Fuera del fragment: no tiene sentido repedir los viajes activos cada 10 s
    # solo porque la pestana de criticos este abierta.
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

        # Todos los botones están SIEMPRE habilitados: si falta el chófer o el
        # estado no permite el paso, el backend responde 400 y el panel muestra
        # el motivo. Un botón gris no explica nada y parece "roto".
        columnas = st.columns(3)
        acciones = (
            (columnas[0], "📞 Forzar confirmación", "forzar_confirmacion",
             "Viaje confirmado: el chófer va en camino."),
            (columnas[1], "📍 Forzar llegada", "forzar_llegada",
             "Llegada al punto de recogida marcada."),
            (columnas[2], "▶️ Forzar inicio", "forzar_inicio",
             "Viaje iniciado."),
        )
        for columna, etiqueta, metodo, ok in acciones:
            with columna:
                if st.button(etiqueta, key=metodo):
                    try:
                        resultado = getattr(api, metodo)(viaje["trip_id"])
                    except ErrorDeRed:
                        st.error("Error de conexión. Intenta de nuevo.")
                    except ApiError as exc:
                        st.error(explicar_error(exc))
                    except Exception:
                        st.error("No se pudo ejecutar la acción. "
                                 "Revisa los logs del servidor.")
                    else:
                        ui.flash("success",
                                 resultado.get("message") or ok)
                        ui.invalidar("criticos")
                        st.rerun()

        st.divider()
        col_propina, col_fin = st.columns([1.2, 1])
        with col_propina:
            propina = st.number_input("Propina (CUP)", min_value=0.0,
                                      step=10.0, format="%.2f",
                                      key="forzar_propina")
        with col_fin:
            st.write("")
            if st.button("⏹️ Forzar fin", key="forzar_fin"):
                try:
                    resultado = api.forzar_fin(viaje["trip_id"], propina)
                except ErrorDeRed:
                    st.error("Error de conexión. Intenta de nuevo.")
                except ApiError as exc:
                    st.error(explicar_error(exc))
                except Exception:
                    st.error("No se pudo cerrar el viaje. "
                             "Revisa los logs del servidor.")
                else:
                    mensaje = resultado.get("message") or "Viaje completado."
                    precio = (resultado.get("precio_final")
                              or resultado.get("total_fare"))
                    if precio is not None:
                        mensaje += " Precio final: %s." % ui.dinero(precio)
                    ui.flash("success", mensaje)
                    ui.invalidar("criticos")
                    st.rerun()

        if not tiene_chofer:
            st.caption("Este viaje no tiene chófer asignado. "
                       "Asígnalo arriba antes de forzar un paso.")
        else:
            st.caption("Chófer: %s" % (viaje.get("driver_name") or "—"))

        # Cancelacion desde el control de viajes: es la salida cuando el chofer
        # ya agoto sus 3 del dia (o no puede hacerlo desde la app). No descuenta
        # ninguna y deja al chofer disponible.
        st.divider()
        st.markdown("##### 🚫 Cancelar el viaje seleccionado")
        st.caption(
            "Solo el operador de viajes puede cerrar un viaje que el chófer ya "
            "no puede cancelar. No se descuenta de sus 3 del día."
        )
        col_motivo, col_boton = st.columns([2.2, 1])
        with col_motivo:
            motivo_cancel = st.text_input(
                "Motivo para el pasajero (opcional)",
                key="motivo_force_cancel_%s" % viaje["trip_id"],
                placeholder="El chófer reportó que no encontrabas el punto")
            confirmar_cancel = st.checkbox(
                "Confirmo cancelar este viaje (no se deshace)",
                key="confirmar_force_cancel_%s" % viaje["trip_id"])
        with col_boton:
            if st.button("Cancelar viaje", type="primary",
                         disabled=not confirmar_cancel,
                         key="forzar_cancel_%s" % viaje["trip_id"]):
                try:
                    resultado = api.cancelar_viaje_admin(
                        viaje["trip_id"], motivo_cancel)
                except ErrorDeRed:
                    st.error("Error de conexión. Intenta de nuevo.")
                except ApiError as exc:
                    st.error(explicar_error(exc))
                except Exception:
                    st.error("No se pudo cancelar el viaje. "
                             "Revisa los logs del servidor.")
                else:
                    ui.flash("success", resultado.get("message")
                             or "Viaje cancelado por el operador.")
                    ui.invalidar("criticos")
                    st.rerun()


def render(api) -> None:
    st.subheader("🚨 Viajes críticos")
    st.caption(
        "Viajes que siguen en cola y no tienen chófer. El primero es el "
        "pasajero que más lleva esperando. El aviso de Telegram sale cuando "
        "el viaje pasa el 50 % del tiempo de espera."
    )

    _viajes_en_cola(api)
    _control_manual(api)
