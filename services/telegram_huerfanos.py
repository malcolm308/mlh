"""Mensajes de Telegram para viajes huerfanos.

Este modulo no toca Mongo ni Postgres: solo compone el texto y habla con la
API de Telegram. Se separo de `routers/admin_web.py` para poder probar el
formato del mensaje y el enlace de WhatsApp sin levantar el backend.

Variables de entorno:

    TELEGRAM_BOT_TOKEN       token del bot (ya lo usa routers/telegram_webhook.py)
    TELEGRAM_GROUP_ID        chat_id del grupo donde se publican los huerfanos.
                             Los grupos empiezan por "-": p. ej. -1001234567890
    ADMIN_WHATSAPP_NUMBER    numero del administrador, solo digitos y prefijo
                             de pais. Por defecto 5359295207.
    TELEGRAM_API_BASE_URL    opcional; permite apuntar a un servidor de pruebas.

`httpx` se importa dentro de `enviar_mensaje` para que este modulo se pueda
importar tambien en el panel Streamlit, que no necesita esa dependencia.
"""

from __future__ import annotations

import html
import os
from typing import Any, Optional
from urllib.parse import quote

API_TELEGRAM = (os.getenv("TELEGRAM_API_BASE_URL")
                or "https://api.telegram.org").rstrip("/")

WHATSAPP_POR_DEFECTO = "5359295207"


class TelegramError(RuntimeError):
    """Telegram no acepto el mensaje (token, chat_id o red)."""


def configuracion() -> dict:
    """Lee la configuracion en cada llamada, no al importar el modulo.

    Asi un cambio de variable en Render se aplica al reiniciar el servicio sin
    depender del orden de importacion.
    """
    return {
        "token": (os.getenv("TELEGRAM_BOT_TOKEN") or "").strip(),
        "grupo": (os.getenv("TELEGRAM_GROUP_ID") or "").strip(),
        "whatsapp": (os.getenv("ADMIN_WHATSAPP_NUMBER")
                     or WHATSAPP_POR_DEFECTO).strip(),
    }


def faltantes(cfg: Optional[dict] = None) -> list[str]:
    """Nombres de las variables obligatorias que no estan definidas."""
    cfg = cfg or configuracion()
    obligatorias = (
        ("token", "TELEGRAM_BOT_TOKEN"),
        ("grupo", "TELEGRAM_GROUP_ID"),
    )
    return [nombre for clave, nombre in obligatorias if not cfg.get(clave)]


def enlace_whatsapp(numero: str, trip_id: str) -> str:
    """Enlace wa.me con el texto ya codificado.

    El chofer lo toca desde Telegram, escribe al administrador y le dice que
    quiere ese viaje. El administrador ve su numero en WhatsApp y lo escribe
    en el panel para asignarselo.
    """
    numero = "".join(ch for ch in str(numero or "") if ch.isdigit())
    texto = quote("Hola, quiero el viaje %s" % trip_id, safe=",")
    return "https://wa.me/%s?text=%s" % (numero, texto)


def _texto(valor: Any, vacio: str = "por confirmar") -> str:
    texto = str(valor or "").strip()
    return html.escape(texto) if texto else vacio


def _precio(valor: Any) -> str:
    try:
        return "{:,.2f} CUP".format(float(valor))
    except (TypeError, ValueError):
        return "por confirmar"


def mensaje_huerfano(trip_id: str, origen: Any, destino: Any, precio: Any,
                     numero_whatsapp: str) -> str:
    """Texto HTML del mensaje que se publica en el grupo."""
    return (
        "🚨 <b>VIAJE HUÉRFANO</b>\n"
        "🆔 <b>ID:</b> <code>%s</code>\n"
        "📍 <b>Origen:</b> %s\n"
        "🏁 <b>Destino:</b> %s\n"
        "💵 <b>Precio:</b> %s\n"
        "\n"
        "El chófer debe escribir al administrador por WhatsApp y decir este ID:\n"
        "%s"
        % (
            _texto(trip_id, "—"),
            _texto(origen, "—"),
            _texto(destino, "—"),
            _precio(precio),
            html.escape(enlace_whatsapp(numero_whatsapp, trip_id)),
        )
    )


async def enviar_mensaje(token: str, chat_id: str, texto: str) -> None:
    """POST a `sendMessage`. Lanza TelegramError con el motivo exacto."""
    import httpx

    url = "%s/bot%s/sendMessage" % (API_TELEGRAM, token)
    cuerpo = {
        "chat_id": chat_id,
        "text": texto,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    try:
        async with httpx.AsyncClient(timeout=15.0) as cliente:
            respuesta = await cliente.post(url, json=cuerpo)
    except Exception as exc:  # red, DNS, timeout
        raise TelegramError("No se pudo conectar con Telegram: %s" % exc)

    if respuesta.status_code == 200:
        return

    detalle = (respuesta.text or "")[:300]
    try:
        detalle = respuesta.json().get("description") or detalle
    except Exception:
        pass
    raise TelegramError(
        "Telegram respondió %s: %s" % (respuesta.status_code, detalle))
