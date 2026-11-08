"""Piezas visuales que no son una pestana: alerta roja y pitido.

El pitido se genera en Python (un WAV de dos tonos) y se reproduce con
`st.audio(..., autoplay=True)`. Se probo antes con Web Audio dentro de un
componente HTML, pero cada rerun crea un iframe nuevo y el navegador vuelve a
bloquear el audio: el contexto de audio pierde la activacion del usuario. El
elemento <audio> de Streamlit vive en la pagina principal y respeta mejor ese
gesto.
"""

from __future__ import annotations

import functools
import hashlib
import io
import math
import struct
import wave

import streamlit as st

import ui


@functools.lru_cache(maxsize=1)
def _wav_pitido() -> bytes:
    """Dos tonos cortos de 880 Hz, con una pausa en medio."""
    frecuencia = 22050
    muestras = bytearray()

    for tono in (880, 0, 880):
        duracion = 0.18 if tono else 0.09
        total = int(frecuencia * duracion)
        for i in range(total):
            if not tono:
                valor = 0
            else:
                # Envolvente lineal para que no chasquee al cortar.
                volumen = 1.0 - (i / max(1, total))
                valor = int(15000 * math.sin(2 * math.pi * tono * i / frecuencia)
                            * volumen)
            muestras += struct.pack("<h", valor)

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as archivo:
        archivo.setnchannels(1)
        archivo.setsampwidth(2)
        archivo.setframerate(frecuencia)
        archivo.writeframes(bytes(muestras))
    return buffer.getvalue()


def pitido() -> None:
    st.audio(_wav_pitido(), format="audio/wav", autoplay=True)


def boton_sonido() -> bool:
    """Boton de activar/silenciar. Devuelve el estado ya guardado."""
    activo = bool(st.session_state.get("sonido_activo"))
    texto = "🔕 Silenciar alertas" if activo else "🔔 Activar sonido"
    if st.button(texto, key="btn_sonido"):
        st.session_state["sonido_activo"] = not activo
        if not activo:
            ui.flash("success", "Sonido activado: sonará cuando aparezca un viaje sin chofer.")
        st.rerun()
    return bool(st.session_state.get("sonido_activo"))


def alerta_critica(texto: str, detalle: str = "") -> None:
    extra = "<br><small>%s</small>" % detalle if detalle else ""
    st.markdown(
        '<div class="alerta-critica">⚠️ %s%s</div>' % (texto, extra),
        unsafe_allow_html=True,
    )


def pitido_si_cambia(ids: list[str]) -> None:
    """Suena solo cuando el conjunto de viajes huerfanos cambia.

    Sin esta firma el panel pitaria cada 10 s por el mismo viaje y el
    administrador acabaria silenciandolo, que es justo lo contrario de lo que
    se busca.
    """
    if not st.session_state.get("sonido_activo"):
        return
    firma = hashlib.sha1("|".join(sorted(ids)).encode("utf-8")).hexdigest()
    if st.session_state.get("_ultima_alerta") == firma:
        return
    st.session_state["_ultima_alerta"] = firma
    pitido()


def limpiar_alerta() -> None:
    st.session_state.pop("_ultima_alerta", None)
