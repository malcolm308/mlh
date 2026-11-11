"""Promociones, comisiones, referidos y tarifas por distancia.

Todo se guarda con un solo `PUT /admin/configuracion`. El backend reutiliza la
validacion de siempre: comision entre 0 y 1, descuento nunca mayor que la
comision ni mayor que el 10 %, coeficientes mayores que cero y limite corto
menor que el medio.
"""

from __future__ import annotations

from datetime import datetime

import streamlit as st

import ui
from api_client import ApiError, explicar_error


def _porcentaje(valor, decimales: int = 2) -> float:
    try:
        return round(float(valor) * 100, decimales)
    except (TypeError, ValueError):
        return 0.0


def _flotante(valor, defecto: float = 0.0) -> float:
    try:
        return float(valor)
    except (TypeError, ValueError):
        return defecto


def _resumen(config: dict) -> None:
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Comisión", "%.2f %%" % _porcentaje(config.get("comision_porcentaje")))
    if config.get("descuento_cliente_activo"):
        descuento = "%.2f %%" % _porcentaje(
            config.get("descuento_cliente_porcentaje"))
    else:
        descuento = "Apagado"
    c2.metric("Descuento al cliente", descuento)
    if config.get("bono_chofer_activo"):
        bono = ui.dinero(config.get("bono_chofer_monto"))
        bono += " / %s viajes" % config.get("bono_chofer_viajes_requeridos", 0)
    else:
        bono = "Apagado"
    c3.metric("Bono del chófer", bono)
    c4.metric("Referidos", "Activos" if config.get("referidos_activos")
              else "Apagados")

    p1, p2 = st.columns(2)
    p1.metric("Comisión de la billetera",
              "%.2f %%" % _porcentaje(config.get("comision_billetera")))
    p2.metric("Recargo por transferencia",
              "%.2f %%" % _porcentaje(config.get("recargo_transferencia")))

    if config.get("expirada"):
        st.warning(
            "La promoción está vencida%s. Los descuentos y bonos ya no se "
            "aplican." % (
                " desde el %s" % ui.fecha(config.get("fecha_expiracion"))
                if config.get("fecha_expiracion") else "")
        )
    elif config.get("fecha_expiracion"):
        st.caption("La promoción caduca el %s."
                   % ui.fecha(config.get("fecha_expiracion")))

    if config.get("actualizado_por"):
        st.caption("Última actualización: %s, por %s."
                   % (ui.fecha_hora(config.get("actualizado_at")),
                      config.get("actualizado_por")))


def _formulario(api, config: dict) -> None:
    comision_actual = _porcentaje(config.get("comision_porcentaje"))
    descuento_actual = _porcentaje(
        config.get("descuento_cliente_porcentaje"))
    max_descuento = _porcentaje(config.get("descuento_maximo", 0.10))
    comision_billetera_actual = _porcentaje(config.get("comision_billetera"))
    recargo_transferencia_actual = _porcentaje(
        config.get("recargo_transferencia"), 2)
    max_comision_billetera = _porcentaje(
        config.get("comision_billetera_maxima", 0.10))
    if max_comision_billetera <= 0:
        max_comision_billetera = 10.0
    max_recargo = 100.0

    with st.form("form_configuracion"):
        st.markdown("#### Comisión y descuento")
        st.caption(
            "La comisión es la parte que se queda la plataforma. El descuento "
            "al pasajero sale de esa comisión: nunca puede ser mayor, y el "
            "máximo permitido es %.0f %%." % max_descuento
        )
        c1, c2, c3 = st.columns(3)
        comision = c1.number_input(
            "Comisión de la plataforma (%)",
            min_value=0.0, max_value=100.0, step=0.5,
            value=float(comision_actual), format="%.2f",
            key="cfg_comision",
        )
        descuento_activo = c2.checkbox(
            "Aplicar descuento al cliente",
            value=bool(config.get("descuento_cliente_activo")),
            key="cfg_desc_activo",
        )
        descuento = c3.number_input(
            "Descuento al cliente (%)",
            min_value=0.0, max_value=float(max_descuento), step=0.5,
            value=float(min(descuento_actual, max_descuento)),
            format="%.2f", key="cfg_descuento",
        )

        st.markdown("#### Pagos con billetera y transferencia")
        st.caption(
            "La comisión de la billetera se retiene cuando el pasajero paga "
            "con saldo; el resto entra al Fondo del chófer. El recargo por "
            "transferencia se suma al precio en los pagos externos (Zelle, "
            "banco, etc.). El cálculo lo hace siempre el backend."
        )
        p1, p2 = st.columns(2)
        comision_billetera = p1.number_input(
            "Comisión de la billetera (%)",
            min_value=0.0, max_value=float(max_comision_billetera),
            step=0.5,
            value=float(min(comision_billetera_actual,
                            max_comision_billetera)),
            format="%.2f", key="cfg_comision_billetera",
            help="En lanzamiento es 0 %. El máximo permitido es %.0f %%."
                 % max_comision_billetera,
        )
        recargo_transferencia = p2.number_input(
            "Recargo por transferencia (%)",
            min_value=0.0, max_value=float(max_recargo), step=0.5,
            value=float(min(recargo_transferencia_actual, max_recargo)),
            format="%.2f", key="cfg_recargo_transferencia",
            help="Se añade al costo del viaje cuando el pasajero paga por "
                 "transferencia. Por defecto 10 %.",
        )

        st.markdown("#### Bono del chófer")
        b1, b2, b3 = st.columns(3)
        bono_activo = b1.checkbox(
            "Pagar bono diario",
            value=bool(config.get("bono_chofer_activo")),
            key="cfg_bono_activo",
        )
        bono_monto = b2.number_input(
            "Monto del bono (CUP)",
            min_value=0.0, step=50.0,
            value=_flotante(config.get("bono_chofer_monto")),
            format="%.2f", key="cfg_bono_monto",
        )
        bono_viajes = b3.number_input(
            "Viajes requeridos para el bono",
            min_value=0, max_value=1000, step=1,
            value=int(config.get("bono_chofer_viajes_requeridos") or 0),
            key="cfg_bono_viajes",
        )

        st.markdown("#### Referidos y vigencia")
        r1, r2 = st.columns(2)
        referidos = r1.checkbox(
            "Programa de referidos activo",
            value=bool(config.get("referidos_activos", True)),
            key="cfg_referidos",
        )
        expiracion_actual = config.get("fecha_expiracion") or ""
        expiracion = r2.text_input(
            "Fecha de expiración (AAAA-MM-DD, vacío = no caduca)",
            value=str(expiracion_actual)[:10],
            placeholder="2026-12-31",
            key="cfg_expiracion",
        )

        st.markdown("#### Tarifas por distancia y espera")
        st.caption(
            "El coeficiente multiplica SOLO el kilometraje; la tarifa base y "
            "el tiempo van enteros. La espera de cortesía son los minutos "
            "gratis antes de empezar a cobrar la espera."
        )
        t1, t2, t3 = st.columns(3)
        corto_km = t1.number_input(
            "Límite de carreras cortas (km)",
            min_value=0.01, step=1.0,
            value=_flotante(config.get("coef_corto_km"), 3.0),
            format="%.2f", key="cfg_corto_km",
        )
        medio_km = t2.number_input(
            "Límite de carreras medias (km)",
            min_value=0.01, step=1.0,
            value=_flotante(config.get("coef_medio_km"), 10.0),
            format="%.2f", key="cfg_medio_km",
        )
        espera = t3.number_input(
            "Espera de cortesía (minutos)",
            min_value=0.0, step=1.0,
            value=_flotante(config.get("tiempo_espera_cortesia_minutos"), 4.0),
            format="%.2f", key="cfg_espera",
        )

        t4, t5, t6 = st.columns(3)
        coef_corto = t4.number_input(
            "Coeficiente cortas",
            min_value=0.01, step=0.05,
            value=_flotante(config.get("coef_corto_valor"), 0.5),
            format="%.2f", key="cfg_coef_corto",
        )
        coef_medio = t5.number_input(
            "Coeficiente medias",
            min_value=0.01, step=0.05,
            value=_flotante(config.get("coef_medio_valor"), 0.6),
            format="%.2f", key="cfg_coef_medio",
        )
        coef_largo = t6.number_input(
            "Coeficiente largas",
            min_value=0.01, step=0.05,
            value=_flotante(config.get("coef_largo_valor"), 1.0),
            format="%.2f", key="cfg_coef_largo",
        )

        guardar = st.form_submit_button("💾 Guardar configuración",
                                        type="primary")

    if not guardar:
        return

    # ---- Validaciones que evitan un viaje de ida y vuelta al backend ----
    if corto_km >= medio_km:
        st.error("El límite de las carreras cortas tiene que ser menor que el "
                 "de las medias.")
        return

    if expiracion.strip():
        try:
            datetime.strptime(expiracion.strip(), "%Y-%m-%d")
        except ValueError:
            st.error("La fecha de expiración debe tener el formato AAAA-MM-DD.")
            return

    comision_fraccion = round(comision / 100.0, 4)
    descuento_fraccion = round(descuento / 100.0, 4)
    comision_billetera_fraccion = round(comision_billetera / 100.0, 4)
    recargo_transferencia_fraccion = round(
        recargo_transferencia / 100.0, 4)

    if comision_billetera_fraccion > (max_comision_billetera / 100.0) + 1e-9:
        st.error("La comisión de la billetera no puede pasar de %.0f %%."
                 % max_comision_billetera)
        return
    if recargo_transferencia_fraccion > 1.0 + 1e-9:
        st.error("El recargo por transferencia no puede pasar de 100 %.")
        return

    if comision_fraccion <= 0:
        if descuento_activo or descuento > 0:
            st.info(
                "Con comisión 0 % el descuento al cliente se apaga solo: la "
                "plataforma no tendría de dónde pagarlo."
            )
        descuento_activo = False
        descuento_fraccion = 0.0
    else:
        if descuento_activo and descuento_fraccion > comision_fraccion:
            st.error(
                "El descuento (%.2f %%) no puede ser mayor que la comisión "
                "(%.2f %%)." % (descuento, comision)
            )
            return
        if descuento_fraccion > (max_descuento / 100.0) + 1e-9:
            st.error("El descuento no puede pasar de %.0f %%." % max_descuento)
            return

    payload = {
        "comision_porcentaje": comision_fraccion,
        "comision_billetera": comision_billetera_fraccion,
        "recargo_transferencia": recargo_transferencia_fraccion,
        "bono_chofer_activo": bool(bono_activo),
        "bono_chofer_monto": round(float(bono_monto), 2),
        "bono_chofer_viajes_requeridos": int(bono_viajes),
        "descuento_cliente_activo": bool(descuento_activo),
        "descuento_cliente_porcentaje": descuento_fraccion,
        "referidos_activos": bool(referidos),
        "fecha_expiracion": expiracion.strip() or None,
        "coef_corto_km": float(corto_km),
        "coef_corto_valor": float(coef_corto),
        "coef_medio_km": float(medio_km),
        "coef_medio_valor": float(coef_medio),
        "coef_largo_valor": float(coef_largo),
        "tiempo_espera_cortesia_minutos": float(espera),
    }

    try:
        resultado = api.guardar_configuracion(payload)
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    ui.flash("success", resultado.get("message") or "Configuración guardada.")
    ui.invalidar("configuracion")
    st.rerun()


def render(api) -> None:
    st.subheader("🎁 Promociones, comisiones y tarifas")
    st.caption(
        "Estos valores se aplican a todos los chóferes y a todos los viajes: "
        "comisión de la plataforma, bono diario, descuento al pasajero, "
        "referidos, coeficientes por distancia y espera de cortesía."
    )

    try:
        config = ui.cargar("configuracion", 300, api.configuracion)
    except ApiError as exc:
        st.error(explicar_error(exc))
        return

    _resumen(config)
    st.divider()
    _formulario(api, config)
