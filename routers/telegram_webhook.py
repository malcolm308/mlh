"""
Bot de Telegram para choferes y administradores de RapiTaxi.

La vinculacion entre el chat y el chofer se hace UNICAMENTE por numero de
celular, con el boton nativo de Telegram que comparte el numero ya verificado.
El chofer no escribe nada a mano y el bot no registra choferes nuevos: si el
numero no existe en la base, se le manda a hablar con el soporte.

Decisiones que importan al leer el codigo:

  * El campo del telefono se llama `numero_de_telefono` (base `Chofer`,
    coleccion `users`). No existe un campo `phone`.
  * Ese campo esta SIN NORMALIZAR: conviven `+5359295207`, `59295207` y valores
    de relleno como `00000000`. Por eso la busqueda compara numero normalizado y
    reescribe el campo cuando encuentra al chofer.
  * Si un numero corresponde a mas de un chofer no se vincula a ninguno: se
    avisa al administrador. Con el numero como unica clave, elegir uno al azar
    meteria a un chofer en la cuenta de otro.
  * El precio NUNCA se calcula aqui. Lo calcula `PUT /trips/{id}/complete`.
  * El limite de cancelaciones vive en `POST /trips/{id}/cancel`, que ya
    descuenta una unidad cuando el chofer cancela un viaje suyo. El bot no vuelve
    a sumar en `/chofer/{id}/cancelaciones/usadas`.
  * Las respuestas van por la API de Telegram con `httpx`, que ya es
    dependencia del backend.

Todos los textos van en español de Cuba y con la ortografia correcta.
"""
from __future__ import annotations

import html
import json
import logging
import os
import re
import secrets
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import httpx
from fastapi import APIRouter, BackgroundTasks, Header, HTTPException, Request
from fastapi.responses import JSONResponse

from routers.cache import garnet_client
from routers.documentos import CAMPOS, MAX_SIZE_MB, _detectar_extension

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Bot de Telegram"])

API_TELEGRAM = "https://api.telegram.org"
TIMEOUT_API = httpx.Timeout(10.0, connect=5.0, read=8.0, write=8.0)

TTL_CHOFER = 365 * 24 * 3600  # Un chat puede volver al mes siguiente.
TTL_TOKEN_ADMIN = 25 * 60     # El JWT dura 30 min; se renueva antes de caducar.
TTL_AUTO = 6 * 3600           # Cuanto se recuerda la ultima pasada automatica.

LIMITE_AUTO = int(os.getenv("TELEGRAM_AUTO_MAX", "20"))
EVENTOS_AUDITORIA = 500

# Tope del barrido de la coleccion cuando el telefono esta escrito con separadores
# raros. Acota el peor caso; con miles de choferes cabe de sobra y, como el
# telefono se normaliza al vincular, este paso cada vez se usa menos.
MAX_BARRIDO = int(os.getenv("TELEGRAM_MAX_BARRIDO", "5000"))

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGING_DIR = os.path.join(BASE_DIR, "uploads", "telegram_staging")

INDICE_TELEGRAM = "telegram_chat_id_unico"

# Estados de viaje en los que el chofer todavia tiene algo que hacer.
ESTADOS_VIAJES_ACTIVOS = ("requested", "accepted", "driver_arrived", "in_progress")

# Numeros de relleno que se han visto en la base. Si uno llega al bot es un
# dato de prueba, no una persona: se trata como numero no valido.
TELEFONOS_DE_RELLENO = {"00000000", "11111111", "12345678", "99999999"}

# Respaldo en memoria: si Garnet no responde, el bot sigue contestando en la
# misma instancia.
_MEMORIA: Dict[str, Any] = {}


# ===================== CONFIGURACION =====================

def _token_bot() -> Optional[str]:
    return (os.getenv("TELEGRAM_BOT_TOKEN") or "").strip() or None


def _secreto_webhook() -> Optional[str]:
    return (os.getenv("TELEGRAM_WEBHOOK_SECRET") or "").strip() or None


def _chats_admin() -> List[int]:
    salida = []
    for parte in (os.getenv("TELEGRAM_ADMIN_CHAT_ID") or "").split(","):
        parte = parte.strip()
        if parte.lstrip("-").isdigit():
            salida.append(int(parte))
    return salida


def _url_api_interna() -> str:
    """Base del propio backend. El bot llama a los endpoints por HTTP para no
    duplicar su logica de negocio."""
    base = os.getenv("TELEGRAM_API_BASE_URL")
    if base:
        return base.rstrip("/")
    return "http://127.0.0.1:%s" % (os.getenv("PORT") or "18000")


def _soporte() -> str:
    return (os.getenv("TELEGRAM_SOPORTE")
            or "Escribe al administrador de RapiTaxi desde el panel de soporte.")


# ===================== MONGODB =====================

def _coleccion():
    """Coleccion de choferes. Se resuelve aqui y no al importar el modulo para
    que este se pueda cargar sin tener Mongo a mano (los tests lo importan)."""
    from db.Chofer.connection import chofer_db
    return chofer_db.users


def asegurar_indice_telegram() -> None:
    """Crea el indice unico y disperso de `telegram_chat_id`.

    `sparse` deja vincular los choferes que no usan el bot: los documentos sin
    ese campo no entran al indice. Si el indice no se puede crear (porque ya
    habia dos choferes con el mismo chat, por ejemplo) se avisa por log y el bot
    sigue funcionando: el indice es una red de seguridad, no un requisito para
    usar el bot.
    """
    try:
        _coleccion().create_index("telegram_chat_id", unique=True, sparse=True,
                                  name=INDICE_TELEGRAM)
    except Exception:
        logger.warning("No se pudo crear el indice %s de telegram_chat_id; se "
                       "sigue sin el. Revisa si hay dos choferes con el mismo "
                       "chat_id.", INDICE_TELEGRAM, exc_info=True)


def _nombre_de(chofer: Dict[str, Any]) -> str:
    return " ".join(filter(None, [chofer.get("Nombre"), chofer.get("Apellidos")])).strip()


# ===================== ESTADO (Redis con respaldo en memoria) =====================

def _leer_json(clave: str, por_defecto: Any = None) -> Any:
    try:
        crudo = garnet_client.get(clave)
        if crudo:
            return json.loads(crudo)
        return por_defecto
    except Exception:
        logger.warning("Redis no disponible para %s; se usa memoria local", clave)
        return _MEMORIA.get(clave, por_defecto)


def _escribir_json(clave: str, valor: Any, ttl: int) -> None:
    _MEMORIA[clave] = valor
    try:
        garnet_client.setex(clave, ttl, json.dumps(valor, ensure_ascii=False))
    except Exception:
        logger.warning("No se pudo guardar %s en Redis; queda solo en memoria", clave)


def _borrar(clave: str) -> None:
    _MEMORIA.pop(clave, None)
    try:
        garnet_client.delete(clave)
    except Exception:
        logger.warning("No se pudo borrar %s de Redis", clave)


def _clave_chat(chat_id: int) -> str:
    return "telegram:chat:%s" % chat_id


def _clave_flujo(chat_id: int) -> str:
    return "telegram:flujo:%s" % chat_id


def _auditar(chat_id: int, accion: str, detalle: str = "", ok: bool = True) -> None:
    """Rastro de cada accion: al log del servidor y a una lista de Redis que
    `/audit` consulta."""
    evento = {
        "at": datetime.utcnow().isoformat(timespec="seconds"),
        "chat_id": chat_id,
        "accion": accion,
        "detalle": str(detalle)[:300],
        "ok": ok,
    }
    logger.info("telegram accion=%s chat=%s ok=%s detalle=%s",
                accion, chat_id, ok, str(detalle)[:200])
    try:
        garnet_client.lpush("telegram:audit", json.dumps(evento, ensure_ascii=False))
        garnet_client.ltrim("telegram:audit", 0, EVENTOS_AUDITORIA - 1)
    except Exception:
        pass


# ===================== CLIENTE DE TELEGRAM =====================

class Telegram:
    """Envuelve lo justo de la API de Telegram que usa el bot."""

    def __init__(self, token: str):
        self.token = token

    @property
    def _url(self) -> str:
        return "%s/bot%s" % (API_TELEGRAM, self.token)

    async def _llamar(self, metodo: str, **params) -> Any:
        limpio = {k: v for k, v in params.items() if v is not None}
        async with httpx.AsyncClient(timeout=TIMEOUT_API) as cliente:
            respuesta = await cliente.post(self._url + "/" + metodo, data=limpio)
        cuerpo = respuesta.json()
        if not cuerpo.get("ok"):
            raise RuntimeError("Telegram %s fallo: %s" % (metodo, cuerpo.get("description")))
        return cuerpo.get("result")

    async def enviar(self, chat_id: int, texto: str,
                     teclado: Optional[dict] = None,
                     con_html: bool = False,
                     quitar_teclado: bool = False) -> bool:
        """Manda un mensaje. `quitar_teclado` retira el teclado de compartir: se
        hace en el mismo mensaje porque Telegram no tiene forma de quitar un
        teclado sin enviar texto, y mandarlo con el texto siempre sale mas
        barato que un mensaje aparte."""
        if teclado is None and quitar_teclado:
            teclado = {"remove_keyboard": True}
        try:
            await self._llamar(
                "sendMessage",
                chat_id=chat_id,
                text=texto,
                parse_mode="HTML" if con_html else None,
                reply_markup=json.dumps(teclado, ensure_ascii=False) if teclado else None,
                disable_web_page_preview="true",
            )
            return True
        except Exception as exc:
            logger.warning("No se pudo avisar al chat %s: %s", chat_id, exc)
            return False

    async def teclado_boton_compartir(self, chat_id: int) -> bool:
        """Boton nativo `request_contact`. Telegram garantiza que el numero viene
        verificado y que pertenece al usuario que pulsa, asi que el chofer no
        puede escribir el numero de otro."""
        return await self.enviar(
            chat_id,
            "👋 Hola. Para usar el bot, comparte tu numero de celular.\n\n"
            "📱 Pulsa el boton de abajo.",
            teclado={
                "keyboard": [[{"text": "📱 Compartir mi numero de celular",
                               "request_contact": True}]],
                "resize_keyboard": True,
                "one_time_keyboard": True,
            })

    async def responder_boton(self, callback_id: str, texto: str = "") -> None:
        try:
            await self._llamar("answerCallbackQuery",
                               callback_query_id=callback_id, text=texto or None)
        except Exception:
            logger.debug("answerCallbackQuery sin respuesta para %s", callback_id)

    async def leer_archivo(self, file_id: str) -> bytes:
        info = await self._llamar("getFile", file_id=file_id)
        ruta = (info or {}).get("file_path")
        if not ruta:
            raise ValueError("Telegram no devolvio la ruta del archivo")
        url = "%s/file/bot%s/%s" % (API_TELEGRAM, self.token, ruta)
        async with httpx.AsyncClient(timeout=TIMEOUT_API) as cliente:
            respuesta = await cliente.get(url)
            respuesta.raise_for_status()
            return respuesta.content


def _cliente() -> Telegram:
    token = _token_bot()
    if not token:
        raise HTTPException(status_code=503, detail="TELEGRAM_BOT_TOKEN no esta definido")
    return Telegram(token)


async def _avisar_admin(bot: Telegram, texto: str) -> None:
    for chat_id in _chats_admin():
        await bot.enviar(chat_id, texto)


# ===================== CLIENTE DEL BACKEND =====================

async def _api(metodo: str, ruta: str, *, token: Optional[str] = None,
               cuerpo: Optional[dict] = None, params: Optional[dict] = None,
               archivos: Optional[dict] = None,
               datos: Optional[dict] = None) -> Tuple[int, Any]:
    """Llama a un endpoint del propio backend. Devuelve (status, cuerpo) y nunca
    lanza excepcion: el handler decide que mensaje le manda al chofer."""
    cabeceras = {"Authorization": "Bearer %s" % token} if token else {}
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT_API) as cliente:
            respuesta = await cliente.request(
                metodo, _url_api_interna() + ruta,
                headers=cabeceras, json=cuerpo, params=params,
                files=archivos, data=datos,
            )
    except Exception as exc:
        logger.exception("Fallo al llamar %s %s", metodo, ruta)
        return 0, {"detail": "No se pudo contactar el servidor: %s" % exc}

    if not respuesta.content:
        return respuesta.status_code, {}
    try:
        return respuesta.status_code, respuesta.json()
    except ValueError:
        return respuesta.status_code, {"detail": respuesta.text[:200]}


def _detalle_error(cuerpo: Any) -> str:
    if isinstance(cuerpo, dict):
        detalle = cuerpo.get("detail")
        if isinstance(detalle, str):
            return detalle
        if detalle is not None:
            return json.dumps(detalle, ensure_ascii=False)
    return "La operacion no se pudo completar."


async def _token_admin() -> Optional[str]:
    """JWT de administrador, cacheado. Sin estas dos variables no hay modo
    administrador."""
    guardado = _leer_json("telegram:admin_token")
    if isinstance(guardado, dict) and guardado.get("token"):
        return guardado["token"]

    email = os.getenv("TELEGRAM_ADMIN_EMAIL")
    contrasena = os.getenv("TELEGRAM_ADMIN_PASSWORD")
    if not email or not contrasena:
        return None

    codigo, cuerpo = await _api("POST", "/login",
                                cuerpo={"email": email, "password": contrasena})
    if codigo != 200 or not isinstance(cuerpo, dict) or not cuerpo.get("access_token"):
        logger.error("No se pudo iniciar sesion del administrador del bot (status %s)", codigo)
        return None

    _escribir_json("telegram:admin_token", {"token": cuerpo["access_token"]}, TTL_TOKEN_ADMIN)
    return cuerpo["access_token"]


# ===================== TELEFONO =====================

def normalizar_telefono(raw: str) -> str:
    """Deja solo los digitos y quita el prefijo de Cuba.

        "+53 5 9295207"  -> "59295207"
        "5359295207"     -> "59295207"
        "59295207"       -> "59295207"

    El 53 solo se quita cuando el numero tiene 10 digitos, que es el largo real
    de un movil cubano con el pais delante. Asi un fijo de 8 digitos que empiece
    por 53 no se mutila.
    """
    digitos = "".join(ch for ch in str(raw or "") if ch.isdigit())
    if digitos.startswith("053") and len(digitos) == 11:
        digitos = digitos[1:]
    if digitos.startswith("53") and len(digitos) == 10:
        digitos = digitos[2:]
    return digitos


def _variantes(digitos: str) -> List[str]:
    """Como puede estar escrito ese mismo numero en la base."""
    if not digitos:
        return []
    return [digitos, "53" + digitos, "+53" + digitos, "0" + "53" + digitos,
            "53 " + digitos, "+53 " + digitos]


def _buscar_choferes_por_telefono(digitos: str) -> List[Dict[str, Any]]:
    """Todos los choferes cuyo numero, ya normalizado, coincide con `digitos`.

    No se usa `find_one`: si el numero esta en dos choferes hay que saberlo para
    no meter a nadie en la cuenta de otro. Devuelve la lista de documentos.

    La busqueda va en tres pasos porque el campo esta sin normalizar:

      1. Literal sobre las formas habituales (`59295207`, `+5359295207`, ...).
      2. Expresion regular sobre los ultimos 8 digitos, para lo que tenga
         espacios o guiones.
      3. Barrido acotado de la coleccion, normalizando en Python.

    El paso 3 existe porque un regex no puede encontrar `59295207` dentro de
    `+53 5 9295207`: los digitos estan partidos por los separadores y ningun
    patron los junta. Se compara siempre el valor normalizado, asi que un
    coincidente de mas se descarta. Y no es un problema de rendimiento: cada
    vinculacion deja el telefono ya normalizado, con lo cual el paso 1 acierta
    cada vez mas y el barrido se usa menos.
    """
    if len(digitos) < 7 or digitos in TELEFONOS_DE_RELLENO:
        return []

    coleccion = _coleccion()
    encontrados: Dict[str, Dict[str, Any]] = {}

    # 1) Literal: camino rapido, y el que va a acertar casi siempre.
    for documento in coleccion.find({"numero_de_telefono": {"$in": _variantes(digitos)}},
                                    {"password": 0}):
        encontrados[str(documento["_id"])] = documento

    # 2) Regex sobre los ultimos 8 digitos.
    if not encontrados and len(digitos) >= 8:
        patron = re.compile(r"(^|\D)(%s)(\D|$)" % re.escape(digitos[-8:]))
        for documento in coleccion.find({"numero_de_telefono": patron}, {"password": 0}):
            if normalizar_telefono(documento.get("numero_de_telefono")) == digitos:
                encontrados[str(documento["_id"])] = documento

    # 3) Barrido acotado, normalizando en Python.
    if not encontrados:
        for documento in coleccion.find({}, {"password": 0}).limit(MAX_BARRIDO):
            if normalizar_telefono(documento.get("numero_de_telefono")) == digitos:
                encontrados[str(documento["_id"])] = documento

    return list(encontrados.values())


def _normalizar_en_la_base(documento: Dict[str, Any], digitos: str) -> None:
    """Deja el telefono del chofer en la forma normalizada. Se hace al vincular,
    no en una migracion aparte: asi el campo queda limpio para el siguiente que
    se vinculo y para cualquier busqueda futura."""
    actual = documento.get("numero_de_telefono")
    if normalizar_telefono(actual) == digitos and str(actual).strip() == digitos:
        return
    try:
        _coleccion().update_one({"_id": documento["_id"]},
                                {"$set": {"numero_de_telefono": digitos}})
        logger.info("Telefono normalizado del chofer %s: %r -> %r",
                    documento["_id"], actual, digitos)
    except Exception:
        logger.exception("No se pudo normalizar el telefono del chofer %s", documento["_id"])


# ===================== VINCULACION =====================

async def _mi_chofer(chat_id: int) -> Optional[Dict[str, Any]]:
    """Chat -> chofer. La fuente de verdad es `telegram_chat_id` en Mongo; Redis
    es cache para no consultar la base en cada mensaje."""
    info = _leer_json(_clave_chat(chat_id))
    if isinstance(info, dict) and info.get("driver_id"):
        return info
    try:
        documento = _coleccion().find_one({"telegram_chat_id": int(chat_id)}, {"password": 0})
    except Exception:
        logger.exception("No se pudo buscar el chofer del chat %s", chat_id)
        return None
    if not documento:
        return None
    info = {"driver_id": str(documento["_id"]),
            "email": documento.get("email") or "",
            "nombre": _nombre_de(documento)}
    _escribir_json(_clave_chat(chat_id), info, TTL_CHOFER)
    return info


async def _procesar_contacto(bot: Telegram, chat_id: int, contacto: Dict[str, Any],
                             usuario_id: Optional[int],
                             username: Optional[str]) -> None:
    """Caso E -> caso D: decide que hacer con el numero que acaba de compartir."""
    if contacto.get("user_id") != usuario_id:
        _auditar(chat_id, "contacto_rechazado",
                 "contact.user_id=%s from.id=%s" % (contacto.get("user_id"), usuario_id),
                 ok=False)
        await bot.enviar(chat_id, "❌ Debes compartir TU PROPIO numero.")
        await bot.teclado_boton_compartir(chat_id)
        return

    digitos = normalizar_telefono(contacto.get("phone_number"))
    if len(digitos) < 7:
        _auditar(chat_id, "contacto_invalido", "telefono=%r" % contacto.get("phone_number"),
                 ok=False)
        await bot.enviar(chat_id, "❌ Ese numero no parece valido. Pulsa el boton otra vez.")
        await bot.teclado_boton_compartir(chat_id)
        return

    if digitos in TELEFONOS_DE_RELLENO:
        _auditar(chat_id, "contacto_relleno", "telefono=%s" % digitos, ok=False)
        await bot.enviar(chat_id, "❌ Ese numero no es valido. Comparte el tuyo.")
        await bot.teclado_boton_compartir(chat_id)
        return

    try:
        candidatos = _buscar_choferes_por_telefono(digitos)
    except Exception:
        logger.exception("Fallo la busqueda del telefono %s", digitos)
        await bot.enviar(chat_id, "❌ No pude consultar la base. Intentalo en un momento.")
        return

    if not candidatos:
        _auditar(chat_id, "contacto_sin_chofer", "telefono=%s" % digitos, ok=False)
        await bot.enviar(
            chat_id,
            "❌ No encontramos tu numero.\n\nContacta al soporte para registrarte: %s"
            % _escapar(_soporte()), quitar_teclado=True)
        await _avisar_admin(
            bot,
            "⚠️ Alguien intento vincular un numero que no esta en la base.\n"
            "Telefono: %s\nChat: %s" % (digitos, chat_id))
        return

    # Un numero en mas de un chofer no se resuelve solo: el mas antiguo podria
    # ser una prueba y el mas nuevo el chofer de verdad.
    if len(candidatos) > 1:
        ids = ", ".join(str(c["_id"]) for c in candidatos)
        nombres = "; ".join(_nombre_de(c) or c.get("email", "") for c in candidatos)
        _auditar(chat_id, "contacto_duplicado", "telefono=%s choferes=%s" % (digitos, ids),
                 ok=False)
        await bot.enviar(
            chat_id,
            "❌ Tu numero aparece en mas de una cuenta. Contacta al soporte para "
            "resolverlo: %s" % _escapar(_soporte()), quitar_teclado=True)
        await _avisar_admin(
            bot,
            "⚠️ Numero repetido en la base; el bot no lo vino.\n"
            "Telefono: %s\nChoferes: %s\nChat que intento: %s" % (digitos, nombres, chat_id))
        return

    chofer = candidatos[0]
    driver_id = str(chofer["_id"])
    nombre = _nombre_de(chofer) or chofer.get("email") or "chofer"
    estado = chofer.get("estado_habilitacion") or "aprobado"

    if estado == "rechazado":
        _auditar(chat_id, "contacto_rechazado_admin", "driver=%s" % driver_id, ok=False)
        await bot.enviar(chat_id, "❌ Tu cuenta esta rechazada. Contacta al soporte.",
                         quitar_teclado=True)
        return

    # --- Caso B: ya esta en este mismo chat ---
    if chofer.get("telegram_chat_id") is not None and int(chofer["telegram_chat_id"]) == int(chat_id):
        _auditar(chat_id, "vinculo_ya_existente", "driver=%s" % driver_id)
        _escribir_json(_clave_chat(chat_id),
                       {"driver_id": driver_id, "email": chofer.get("email") or "",
                        "nombre": nombre}, TTL_CHOFER)
        await bot.enviar(chat_id, "✅ Ya estas vinculado.\n\n%s" % _escapar(_texto_comandos()),
                         teclado=_teclado_menu())
        return

    # --- Caso C: esta en otro chat ---
    if chofer.get("telegram_chat_id") is not None:
        otro = int(chofer["telegram_chat_id"])
        _auditar(chat_id, "vinculo_duplicado",
                 "driver=%s chat_existente=%s" % (driver_id, otro), ok=False)
        await bot.enviar(chat_id, "❌ Este numero ya esta vinculado a otra cuenta.",
                         quitar_teclado=True)
        await _avisar_admin(
            bot,
            "⚠️ Intento de vinculo duplicado.\nTelefono: %s\nChofer: %s (%s)\n"
            "Chat ya vinculado: %s\nChat nuevo: %s"
            % (digitos, nombre, driver_id, otro, chat_id))
        return

    # --- Caso A: se vincula ---
    try:
        resultado = _coleccion().update_one(
            {"_id": chofer["_id"], "telegram_chat_id": None},
            {"$set": {"telegram_chat_id": int(chat_id),
                      "telegram_username": username,
                      "telegram_registered_at": datetime.utcnow()}},
        )
    except Exception:
        logger.exception("No se pudo vincular el chofer %s", driver_id)
        await bot.enviar(chat_id, "❌ No pude guardar tu vinculo. Intentalo otra vez.")
        return

    if resultado.modified_count != 1:
        # Otra peticion gano la carrera entre la lectura y la escritura.
        _auditar(chat_id, "vinculo_perdido", "driver=%s" % driver_id, ok=False)
        await bot.enviar(chat_id, "❌ Ese numero se vinculo justo ahora con otra cuenta. "
                                  "Contacta al soporte.")
        return

    _normalizar_en_la_base(chofer, digitos)
    _escribir_json(_clave_chat(chat_id),
                   {"driver_id": driver_id, "email": chofer.get("email") or "",
                    "nombre": nombre}, TTL_CHOFER)
    _auditar(chat_id, "vinculo_ok", "driver=%s telefono=%s" % (driver_id, digitos))

    aviso_extra = ""
    if estado != "aprobado":
        aviso_extra = ("\n\nTu cuenta aun esta pendiente de que el administrador la "
                       "revise. En cuanto lo haga podras entrar a la app.")

    await bot.enviar(
        chat_id,
        "✅ ¡Bienvenido, %s!%s\n\n%s"
        % (_escapar(nombre), aviso_extra, _escapar(_texto_comandos())),
        teclado=_teclado_menu())


# ===================== UTILIDADES =====================

def _escapar(texto: Any) -> str:
    return html.escape(str(texto or ""))


def _dinero(valor: Any) -> str:
    try:
        return "{:,.2f} CUP".format(float(valor))
    except (TypeError, ValueError):
        return str(valor)


def _a_timestamp(valor: Any) -> Optional[float]:
    if valor is None:
        return None
    if isinstance(valor, (int, float)):
        return float(valor)
    try:
        return datetime.fromisoformat(str(valor).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _servicio_de(chofer: Dict[str, Any]) -> str:
    vehiculo = chofer.get("vehicle") or {}
    return (chofer.get("type_vehicle") or chofer.get("vehicle_type")
            or vehiculo.get("servicio") or "basico")


def _teclado_menu() -> dict:
    return {"inline_keyboard": [
        [{"text": "Mi estado", "callback_data": "menu:estado"},
         {"text": "Mi fondo", "callback_data": "menu:fondo"}],
        [{"text": "Completar viaje", "callback_data": "menu:completar"},
         {"text": "Cancelar viaje", "callback_data": "menu:cancelar"}],
        [{"text": "Tarifas", "callback_data": "menu:precio"},
         {"text": "Ayuda", "callback_data": "menu:ayuda"}],
    ]}


def _texto_comandos() -> str:
    return ("Comandos disponibles:\n"
            "/completar - Cerrar el viaje en curso\n"
            "/cancelar - Cancelar el viaje actual\n"
            "/estado - Ver el viaje activo\n"
            "/precio - Tarifas de referencia\n"
            "/fondo - Saldo disponible\n"
            "/mi_id - Tu identificador de chofer\n"
            "/documentos - Poner fotos que falten\n"
            "/ayuda - Ver esta ayuda")


# ===================== FOTOS (para /documentos) =====================

def _carpeta_staging(chat_id: int) -> str:
    carpeta = os.path.join(STAGING_DIR, str(chat_id))
    os.makedirs(carpeta, exist_ok=True)
    return carpeta


def _buscar_staging(chat_id: int, campo: str) -> Optional[str]:
    carpeta = os.path.join(STAGING_DIR, str(chat_id))
    if not os.path.isdir(carpeta):
        return None
    for nombre in os.listdir(carpeta):
        if os.path.splitext(nombre)[0] == campo:
            return os.path.join(carpeta, nombre)
    return None


def _limpiar_staging(chat_id: int) -> None:
    carpeta = os.path.join(STAGING_DIR, str(chat_id))
    if not os.path.isdir(carpeta):
        return
    for nombre in os.listdir(carpeta):
        try:
            os.remove(os.path.join(carpeta, nombre))
        except OSError:
            logger.debug("No se pudo borrar el archivo temporal %s", nombre)


def _leer_foto(chat_id: int, campo: str) -> Optional[Tuple[str, bytes]]:
    ruta = _buscar_staging(chat_id, campo)
    if not ruta:
        return None
    try:
        with open(ruta, "rb") as archivo:
            return os.path.basename(ruta), archivo.read()
    except OSError:
        logger.exception("No se pudo leer la foto temporal %s del chat %s", campo, chat_id)
        return None


def _iniciar_flujo(chat_id: int, tipo: str, extra: Optional[dict] = None) -> Dict[str, Any]:
    estado = {"tipo": tipo, "indice": 0, "datos": {},
              "inicio": datetime.utcnow().isoformat()}
    if extra:
        estado.update(extra)
    _escribir_json(_clave_flujo(chat_id), estado, TTL_FLUJO)
    _limpiar_staging(chat_id)
    return estado


def _flujo(chat_id: int) -> Optional[Dict[str, Any]]:
    estado = _leer_json(_clave_flujo(chat_id))
    return estado if isinstance(estado, dict) else None


def _terminar_flujo(chat_id: int) -> None:
    _borrar(_clave_flujo(chat_id))
    _limpiar_staging(chat_id)


async def _guardar_foto(bot: Telegram, chat_id: int, campo: str, foto: dict) -> None:
    """Descarga la foto, comprueba por los bytes que sea una imagen de verdad y la
    deja en el directorio temporal del chat. Reutiliza el validador del modulo de
    documentos: el mismo criterio para la app y para el bot."""
    try:
        contenido = await bot.leer_archivo(foto["file_id"])
    except Exception as exc:
        logger.warning("No se pudo descargar una foto del chat %s: %s", chat_id, exc)
        await bot.enviar(chat_id, "No pude descargar esa foto. Mandamela otra vez.")
        return

    if len(contenido) > MAX_SIZE_MB * 1024 * 1024:
        await bot.enviar(chat_id, "Esa imagen pesa mas de %d MB. Mandala mas pequena."
                         % MAX_SIZE_MB)
        return

    extension = _detectar_extension(contenido, None)
    if not extension:
        await bot.enviar(chat_id, "Eso no es una imagen valida: puede ser JPEG, PNG, "
                                  "WebP o HEIC.")
        return

    try:
        with open(os.path.join(_carpeta_staging(chat_id), campo + extension), "wb") as archivo:
            archivo.write(contenido)
    except OSError as exc:
        logger.exception("No se pudo escribir la foto temporal del chat %s", chat_id)
        await bot.enviar(chat_id, "No pude guardar la foto: %s" % exc)
        return

    await bot.enviar(chat_id, "Foto de %s recibida." % campo)


async def _subir_documentos(bot: Telegram, chat_id: int, estado: Dict[str, Any]) -> None:
    """Cierra la subida y llama a `POST /documentos/chofer/{id}`."""
    pasos = estado.get("pasos") or []
    archivos: Dict[str, Tuple[str, bytes, str]] = {}

    for paso in pasos:
        leida = _leer_foto(chat_id, paso["campo"])
        if leida is None:
            await bot.enviar(chat_id, "No tengo la foto de %s. Empieza otra vez con "
                                      "/documentos." % paso["campo"])
            _terminar_flujo(chat_id)
            return
        nombre, contenido = leida
        ext = os.path.splitext(nombre)[1].lstrip(".").lower() or "jpeg"
        archivos["doc_" + paso["campo"]] = (nombre, contenido, "image/" + ext)

    token = await _token_admin()
    if not token:
        await bot.enviar(chat_id, "No pude subir las fotos: falta la sesion del "
                                  "administrador. Avisale al soporte.")
        _terminar_flujo(chat_id)
        return

    driver_id = estado.get("driver_id")
    codigo, cuerpo = await _api("POST", "/documentos/chofer/%s" % driver_id,
                                token=token, archivos=archivos)
    _terminar_flujo(chat_id)

    if codigo != 200 or not isinstance(cuerpo, dict):
        _auditar(chat_id, "documentos", "fallo status=%s" % codigo, ok=False)
        await bot.enviar(chat_id, "No se pudieron guardar las fotos: %s"
                                  % _escapar(_detalle_error(cuerpo)))
        return

    _auditar(chat_id, "documentos", "driver=%s subidas=%s" % (driver_id, cuerpo.get("subidas")))
    restantes = cuerpo.get("faltantes") or []
    await bot.enviar(
        chat_id,
        "Listo, guarde %s foto(s).%s"
        % (cuerpo.get("subidas"),
           "\n\nTodavia falta: %s." % _escapar(", ".join(restantes))
           if restantes else "\n\nYa tienes los 10 documentos completos."))


# ===================== COMANDOS DEL CHOFER =====================

async def _exigir_vinculo(bot: Telegram, chat_id: int) -> bool:
    """True si el chat ya esta vinculado. Si no, reenvia el boton de compartir."""
    if await _mi_chofer(chat_id):
        return True
    await bot.teclado_boton_compartir(chat_id)
    return False


async def _cmd_ayuda(bot: Telegram, chat_id: int) -> None:
    await bot.enviar(chat_id, "<b>RapiTaxi</b>\n\n%s" % _escapar(_texto_comandos())
                     + "\n\nPara cerrar un viaje el bot te pide la ubicacion de destino: "
                       "compartela con el icono de ubicacion de Telegram. El precio lo "
                       "calcula el servidor, no el bot.", con_html=True)


async def _cmd_mi_id(bot: Telegram, chat_id: int) -> None:
    info = await _mi_chofer(chat_id)
    if not info:
        await bot.teclado_boton_compartir(chat_id)
        return
    await bot.enviar(chat_id, "Tu chat de Telegram: <code>%s</code>\n"
                              "Identificador de chofer: <code>%s</code>\nCorreo: %s"
                     % (chat_id, _escapar(info.get("driver_id")),
                        _escapar(info.get("email"))), con_html=True)


async def _viaje_activo(driver_id: str) -> Optional[Dict[str, Any]]:
    codigo, cuerpo = await _api("GET", "/trips/driver/%s" % driver_id, params={"limit": 50})
    if codigo != 200 or not isinstance(cuerpo, list):
        return None
    candidatos = [v for v in cuerpo
                  if isinstance(v, dict) and v.get("status") in ESTADOS_VIAJES_ACTIVOS]
    return candidatos[-1] if candidatos else None


async def _cargar_chofer(token: Optional[str], driver_id: str) -> Optional[Dict[str, Any]]:
    codigo, cuerpo = await _api("GET", "/chofer/%s" % driver_id, token=token)
    return cuerpo if codigo == 200 and isinstance(cuerpo, dict) else None


async def _cmd_estado(bot: Telegram, chat_id: int) -> None:
    info = await _mi_chofer(chat_id)
    if not info:
        await bot.teclado_boton_compartir(chat_id)
        return

    driver_id = info["driver_id"]
    token = await _token_admin()
    chofer = await _cargar_chofer(token, driver_id) if token else None

    habilitacion = "aprobado, ya puedes trabajar"
    if chofer:
        estado_crudo = chofer.get("estado_habilitacion") or "aprobado"
        habilitacion = {"aprobado": "aprobado, ya puedes trabajar",
                        "pendiente": "pendiente de revision del administrador",
                        "rechazado": "rechazado"}.get(estado_crudo, estado_crudo)

    linea_viaje = "No tienes ningun viaje activo."
    viaje = await _viaje_activo(driver_id)
    if viaje:
        linea_viaje = ("Viaje <code>%s</code>\nEstado: %s\nPasajero: %s"
                       % (_escapar(viaje.get("trip_id")), _escapar(viaje.get("status")),
                          _escapar(viaje.get("client_id"))))

    lineas_cuota = ""
    codigo, cuota = await _api("GET", "/chofer/%s/cancelaciones" % driver_id)
    if codigo == 200 and isinstance(cuota, dict):
        lineas_cuota = ("\nCancelaciones de hoy: %s de 3 usadas, te quedan %s."
                        % (cuota.get("usadas"), cuota.get("restantes")))

    faltan: List[str] = []
    if token:
        _codigo, docs = await _api("GET", "/documentos/chofer/%s/estado" % driver_id,
                                   token=token)
        if isinstance(docs, dict):
            faltan = docs.get("faltantes") or []

    extra = ("\n\nTe faltan fotos: %s. Mandalas con /documentos." % _escapar(", ".join(faltan))
             if faltan else "")

    await bot.enviar(chat_id, "<b>Tu estado</b>\n\nHabilitacion: %s\n%s%s%s"
                     % (habilitacion, linea_viaje, lineas_cuota, extra), con_html=True)
    _auditar(chat_id, "estado", "driver=%s" % driver_id)


async def _cmd_fondo(bot: Telegram, chat_id: int) -> None:
    info = await _mi_chofer(chat_id)
    if not info:
        await bot.teclado_boton_compartir(chat_id)
        return

    codigo, cuerpo = await _api("GET", "/drivers/%s/fondo" % info["driver_id"])
    if codigo != 200 or not isinstance(cuerpo, dict):
        await bot.enviar(chat_id, "No pude consultar tu fondo: %s"
                                  % _escapar(_detalle_error(cuerpo)))
        return
    await bot.enviar(chat_id, "<b>Tu fondo</b>\n\nDisponible: %s\nTitular: %s"
                     % (_dinero(cuerpo.get("fondo")),
                        _escapar(cuerpo.get("email") or "tu cuenta")), con_html=True)
    _auditar(chat_id, "fondo", "driver=%s" % info["driver_id"])


async def _cmd_precio(bot: Telegram, chat_id: int) -> None:
    """Tarifas de referencia. NO es una cotizacion: el precio final lo calcula el
    servidor al cerrar el viaje."""
    if not await _exigir_vinculo(bot, chat_id):
        return

    info = await _mi_chofer(chat_id) or {}
    servicio = "basico"
    token = await _token_admin()
    if token and info.get("driver_id"):
        chofer = await _cargar_chofer(token, info["driver_id"])
        if chofer:
            servicio = _servicio_de(chofer)

    codigo, cuerpo = await _api("GET", "/api/tariffs/%s" % servicio)
    if codigo != 200 or not isinstance(cuerpo, dict):
        texto = "No hay tarifa configurada para <b>%s</b>." % _escapar(servicio)
        _codigo_lista, lista = await _api("GET", "/api/tariffs")
        if isinstance(lista, dict) and lista.get("tariffs"):
            texto += "\n\nLas que hay ahora mismo:\n" + "\n".join(
                "- %s: base %s, por km %s, por minuto %s"
                % (_escapar(t["vehicle_type"]), _dinero(t["base_fare"]),
                   _dinero(t["price_per_km"]), _dinero(t["price_per_minute"]))
                for t in lista["tariffs"])
        await bot.enviar(chat_id, texto, con_html=True)
        return

    _codigo, reglas = await _api("GET", "/api/pricing-rules/%s" % servicio)
    lineas_reglas = ""
    if isinstance(reglas, dict) and reglas.get("rules"):
        lineas_reglas = "\n\n<b>Reglas por horario</b>\n" + "\n".join(
            "- %s a %s: base x%s, km x%s, minuto x%s"
            % (_escapar(r.get("start_time")), _escapar(r.get("end_time")),
               r.get("base_fare_multiplier"), r.get("price_per_km_multiplier"),
               r.get("price_per_minute_multiplier"))
            for r in reglas["rules"])

    await bot.enviar(
        chat_id,
        "<b>Tarifas de tu vehiculo (%s)</b>\n\nBase: %s\nPor kilómetro: %s\nPor minuto: %s\n"
        "Pasajeros: %s%s\n\nEl precio final lo calcula el servidor al cerrar el viaje, "
        "segun la hora y la distancia real. Estos son los valores de referencia."
        % (_escapar(cuerpo.get("vehicle_type", servicio)), _dinero(cuerpo.get("base_fare")),
           _dinero(cuerpo.get("price_per_km")), _dinero(cuerpo.get("price_per_minute")),
           cuerpo.get("max_passengers"), lineas_reglas), con_html=True)
    _auditar(chat_id, "precio", "servicio=%s" % servicio)


async def _cmd_soporte(bot: Telegram, chat_id: int) -> None:
    await bot.enviar(chat_id, "Soporte:\n%s" % _escapar(_soporte()))


async def _cmd_documentos(bot: Telegram, chat_id: int) -> None:
    info = await _mi_chofer(chat_id)
    if not info:
        await bot.teclado_boton_compartir(chat_id)
        return

    token = await _token_admin()
    if not token:
        await bot.enviar(chat_id, "La subida de documentos no esta disponible ahora. "
                                  "Avisale al administrador.")
        return

    codigo, docs = await _api("GET", "/documentos/chofer/%s/estado" % info["driver_id"],
                              token=token)
    if codigo != 200 or not isinstance(docs, dict):
        await bot.enviar(chat_id, "No pude revisar tus documentos: %s"
                                  % _escapar(_detalle_error(docs)))
        return

    faltan = docs.get("faltantes") or []
    if not faltan:
        await bot.enviar(chat_id, "Ya tienes las 10 fotos completas. No hay nada que "
                                  "reemplazar.")
        return

    pasos = [{"campo": campo, "tipo": "foto", "pregunta": "Envia la foto de %s." % etiqueta}
             for campo, etiqueta, _exigido in CAMPOS if etiqueta in faltan]
    _iniciar_flujo(chat_id, "documentos",
                   extra={"driver_id": info["driver_id"], "pasos": pasos})
    await bot.enviar(chat_id, "Te faltan %s foto(s). Mandamelas una por una."
                     % len(pasos))
    await bot.enviar(chat_id, pasos[0]["pregunta"] + "\n\nFoto 1 de %d." % len(pasos))
    _auditar(chat_id, "documentos_inicio", "faltan=%s" % len(pasos))


async def _cmd_completar(bot: Telegram, chat_id: int) -> None:
    info = await _mi_chofer(chat_id)
    if not info:
        await bot.teclado_boton_compartir(chat_id)
        return

    viaje = await _viaje_activo(info["driver_id"])
    if not viaje:
        await bot.enviar(chat_id, "No tienes ningun viaje en curso que cerrar.")
        return

    if viaje.get("status") != "in_progress":
        await bot.enviar(chat_id, "Tu viaje %s esta en estado <b>%s</b>. Solo se puede "
                                  "completar cuando esta en curso."
                         % (_escapar(viaje.get("trip_id")), _escapar(viaje.get("status"))),
                         con_html=True)
        return

    _iniciar_flujo(chat_id, "completar",
                   extra={"trip_id": viaje.get("trip_id"), "driver_id": info["driver_id"]})
    await bot.enviar(chat_id, "Comparte la ubicacion donde termino el viaje con el icono "
                              "de ubicacion de Telegram (abajo a la izquierda). Con eso "
                              "cierro el viaje y el servidor calcula el precio.")


async def _cmd_cancelar(bot: Telegram, chat_id: int) -> None:
    info = await _mi_chofer(chat_id)
    if not info:
        await bot.teclado_boton_compartir(chat_id)
        return

    viaje = await _viaje_activo(info["driver_id"])
    if not viaje:
        await bot.enviar(chat_id, "No tienes ningun viaje activo que cancelar.")
        return

    codigo, cuota = await _api("GET", "/chofer/%s/cancelaciones" % info["driver_id"])
    if codigo == 200 and isinstance(cuota, dict) and cuota.get("restantes") == 0:
        await bot.enviar(chat_id, "Hoy ya usaste tus 3 cancelaciones. No puedes cancelar "
                                  "otro viaje hasta manana.")
        _auditar(chat_id, "cancelar", "sin cuota", ok=False)
        return

    _iniciar_flujo(chat_id, "cancelar",
                   extra={"trip_id": viaje.get("trip_id"), "driver_id": info["driver_id"]})
    await bot.enviar(chat_id, "¿Por que cancelas el viaje %s? Escribe el motivo; queda en "
                              "el historial." % _escapar(viaje.get("trip_id")))


async def _confirmar_cancelacion(bot: Telegram, chat_id: int,
                                 estado: Dict[str, Any]) -> None:
    trip_id = estado.get("trip_id")
    driver_id = estado.get("driver_id")
    motivo = (estado.get("datos") or {}).get("motivo", "")
    _terminar_flujo(chat_id)

    # El endpoint descuenta la cuota cuando el chofer cancela un viaje suyo, asi
    # que el bot no vuelve a sumar en /chofer/{id}/cancelaciones/usadas.
    codigo, cuerpo = await _api("POST", "/trips/%s/cancel" % trip_id,
                                cuerpo={"driver_id": driver_id, "reason": motivo})

    if codigo == 0:
        _auditar(chat_id, "cancelar", "red caida trip=%s" % trip_id, ok=False)
        await bot.enviar(chat_id, "No pude cancelar el viaje: el servidor no responde. "
                                  "Intentalo en un momento.")
        return

    if isinstance(cuerpo, dict) and cuerpo.get("ok") is False:
        error = cuerpo.get("code")
        _auditar(chat_id, "cancelar", "rechazado %s" % error, ok=False)
        if error == "limite_alcanzado":
            texto = "Llegaste al limite de 3 cancelaciones de hoy. Manana vuelves a empezar."
        elif error == "no_cancelable":
            texto = "Ese viaje ya no se puede cancelar; quiza ya estaba cerrado."
        else:
            texto = _detalle_error(cuerpo)
        await bot.enviar(chat_id, texto)
        return

    if codigo != 200:
        _auditar(chat_id, "cancelar", "status=%s" % codigo, ok=False)
        await bot.enviar(chat_id, "No se pudo cancelar: %s" % _escapar(_detalle_error(cuerpo)))
        return

    restantes = cuerpo.get("restantes") if isinstance(cuerpo, dict) else None
    _auditar(chat_id, "cancelar", "trip=%s restantes=%s" % (trip_id, restantes))
    texto = "Viaje cancelado. Motivo: %s" % _escapar(motivo or "sin especificar")
    if restantes is not None:
        texto += "\n\nTe quedan %s de 3 cancelaciones hoy." % restantes
    await bot.enviar(chat_id, texto)


async def _confirmar_completar(bot: Telegram, chat_id: int, estado: Dict[str, Any],
                               lat: float, lng: float) -> None:
    trip_id = estado.get("trip_id")
    driver_id = estado.get("driver_id")
    _terminar_flujo(chat_id)

    codigo, cuerpo = await _api("PUT", "/trips/%s/complete" % trip_id,
                                cuerpo={"dropoff_lat": lat, "dropoff_lng": lng, "tip": 0})

    if codigo != 200 or not isinstance(cuerpo, dict) or cuerpo.get("status") != "completed":
        _auditar(chat_id, "completar", "fallo status=%s" % codigo, ok=False)
        await bot.enviar(chat_id, "No se pudo cerrar el viaje: %s"
                                  % _escapar(_detalle_error(cuerpo)))
        return

    _auditar(chat_id, "completar", "trip=%s total=%s" % (trip_id, cuerpo.get("total_fare")))

    lineas = ["<b>Viaje cerrado</b>", "",
              "Distancia: %s km" % cuerpo.get("distance_km"),
              "Duracion: %s min" % round(float(cuerpo.get("duration_secs") or 0) / 60),
              "Tarifa base: %s" % _dinero(cuerpo.get("base_fare")),
              "Por distancia: %s" % _dinero(cuerpo.get("distance_fare")),
              "Por tiempo: %s" % _dinero(cuerpo.get("time_fare"))]
    if cuerpo.get("tip"):
        lineas.append("Propina: %s" % _dinero(cuerpo.get("tip")))
    lineas += ["", "<b>Total que paga el pasajero: %s</b>" % _dinero(cuerpo.get("total_fare")),
               "", "Comision RapiTaxi: %s (%s%%)%s"
               % (_dinero(cuerpo.get("commission")), cuerpo.get("commission_rate"),
                  " - descuento aplicado" if cuerpo.get("commission_discount") else "")]
    if cuerpo.get("bonus"):
        lineas.append("Bono del dia aplicado.")

    await bot.enviar(chat_id, "\n".join(lineas), con_html=True)


# ===================== COMANDOS DEL ADMINISTRADOR =====================

def _es_admin(chat_id: int) -> bool:
    return chat_id in _chats_admin()


async def _cmd_pendientes(bot: Telegram, chat_id: int) -> None:
    token = await _token_admin()
    if not token:
        await bot.enviar(chat_id, "El modo administrador no esta configurado.")
        return

    codigo, cuerpo = await _api("GET", "/admin/choferes/pendientes", token=token)
    if codigo != 200 or not isinstance(cuerpo, dict):
        await bot.enviar(chat_id, "No pude listar los pendientes: %s"
                                  % _escapar(_detalle_error(cuerpo)))
        return

    pendientes = cuerpo.get("choferes") or []
    if not pendientes:
        await bot.enviar(chat_id, "No hay choferes esperando revision.")
        return

    botones = []
    for chofer in pendientes[:20]:
        etiqueta = _nombre_de(chofer) or chofer.get("email") or chofer.get("id") or ""
        driver_id = chofer.get("id") or ""
        botones.append([
            {"text": "Aprobar %s" % etiqueta[:24], "callback_data": "ap:%s" % driver_id},
            {"text": "Rechazar", "callback_data": "re:%s" % driver_id},
        ])

    await bot.enviar(chat_id, "Hay <b>%s</b> chofer(es) esperando revision."
                     % len(pendientes), teclado={"inline_keyboard": botones}, con_html=True)
    _auditar(chat_id, "pendientes", "total=%s" % len(pendientes))


async def _cambiar_estado(bot: Telegram, chat_id: int, driver_id: str, estado: str,
                          motivo: Optional[str] = None) -> None:
    token = await _token_admin()
    if not token:
        await bot.enviar(chat_id, "El modo administrador no esta configurado.")
        return

    cuerpo: Dict[str, Any] = {"estado": estado}
    if motivo:
        cuerpo["motivo"] = motivo

    codigo, respuesta = await _api("POST", "/admin/choferes/%s/estado" % driver_id,
                                   token=token, cuerpo=cuerpo)
    if codigo != 200 or not isinstance(respuesta, dict):
        _auditar(chat_id, estado, "driver=%s status=%s" % (driver_id, codigo), ok=False)
        await bot.enviar(chat_id, "No se pudo cambiar el estado: %s"
                                  % _escapar(_detalle_error(respuesta)))
        return

    _auditar(chat_id, estado, "driver=%s" % driver_id)
    await bot.enviar(chat_id, "%s\nChofer: %s"
                     % (respuesta.get("message", "Listo"),
                        _escapar(respuesta.get("nombre") or driver_id)))


async def _cmd_desvincular(bot: Telegram, chat_id: int, argumento: str) -> None:
    """Quita el vinculo de Telegram de un chofer, para que pueda volver a
    vincularlo desde otro telefono."""
    digitos = normalizar_telefono((argumento or "").strip())
    if len(digitos) < 7:
        await bot.enviar(chat_id, "Uso: /desvincular &lt;numero&gt;", con_html=True)
        return

    try:
        candidatos = _buscar_choferes_por_telefono(digitos)
    except Exception:
        logger.exception("Fallo al buscar el telefono %s", digitos)
        await bot.enviar(chat_id, "No pude consultar la base. Intentalo en un momento.")
        return

    if not candidatos:
        await bot.enviar(chat_id, "❌ No se encontro ningun chofer con el numero %s." % digitos)
        return

    desvinculados = []
    for chofer in candidatos:
        try:
            resultado = _coleccion().update_one(
                {"_id": chofer["_id"], "telegram_chat_id": {"$ne": None}},
                {"$unset": {"telegram_chat_id": "", "telegram_username": "",
                            "telegram_registered_at": ""}},
            )
        except Exception:
            logger.exception("No se pudo desvincular el chofer %s", chofer["_id"])
            await bot.enviar(chat_id, "❌ No pude guardar el cambio. Intentalo otra vez.")
            return
        if resultado.modified_count:
            desvinculados.append(chofer)
            chat_viejo = chofer.get("telegram_chat_id")
            if chat_viejo:
                _borrar(_clave_chat(int(chat_viejo)))
            _auditar(chat_id, "desvinculo", "driver=%s telefono=%s"
                     % (chofer["_id"], digitos))

    if not desvinculados:
        await bot.enviar(chat_id, "El chofer con el numero %s no estaba vinculado a ningun "
                                  "chat." % digitos)
        return

    nombres = "; ".join("%s (%s)" % (_nombre_de(c) or c.get("email", ""), c["_id"])
                        for c in desvinculados)
    await bot.enviar(chat_id, "✅ Desvinculado: %s" % _escapar(nombres))


async def _cmd_autoactivar(bot: Telegram, chat_id: int, argumento: str) -> None:
    if (argumento or "").strip().lower() in ("off", "apagado", "desactivar", "0"):
        _borrar("telegram:auto:aprobaciones")
        await bot.enviar(chat_id, "Auto-aprobacion desactivada.")
        _auditar(chat_id, "autoactivar_off")
        return

    token = await _token_admin()
    if not token:
        await bot.enviar(chat_id, "El modo administrador no esta configurado.")
        return

    codigo, cuerpo = await _api("GET", "/admin/choferes/pendientes", token=token)
    if codigo != 200 or not isinstance(cuerpo, dict):
        await bot.enviar(chat_id, "No pude leer la cola de pendientes: %s"
                                  % _escapar(_detalle_error(cuerpo)))
        return

    pendientes = cuerpo.get("choferes") or []
    hechos = 0
    fallidos: List[str] = []
    acciones = 0

    for chofer in pendientes[:LIMITE_AUTO]:
        driver_id = chofer.get("id")
        acciones += 1
        cod, _resp = await _api("POST", "/admin/choferes/%s/estado" % driver_id,
                                token=token, cuerpo={"estado": "aprobado"})
        if cod == 200:
            hechos += 1
        else:
            fallidos.append(str(driver_id))

    _escribir_json("telegram:auto:aprobaciones", {
        "activado": True, "acciones": acciones, "limite": LIMITE_AUTO,
        "aprobados": hechos, "fallidos": fallidos,
        "inicio": datetime.utcnow().isoformat()}, TTL_AUTO)

    texto = ("Auto-aprobacion ejecutada.\n\nPendientes en la cola: %s\nAprobados: %s\n"
             "Acciones usadas: %s de %s (tope por pasada)."
             % (len(pendientes), hechos, acciones, LIMITE_AUTO))
    if len(pendientes) > LIMITE_AUTO:
        texto += "\nQuedaron %s sin tocar: el tope por pasada es %s." % (
            len(pendientes) - LIMITE_AUTO, LIMITE_AUTO)
    if fallidos:
        texto += "\nFallaron: %s" % _escapar(", ".join(fallidos[:10]))
    texto += "\n\nEs una pasada de una vez, no un ciclo continuo: revisa y repites si hace falta."

    _auditar(chat_id, "autoactivar", "aprobados=%s acciones=%s" % (hechos, acciones))
    await bot.enviar(chat_id, texto)


async def _cmd_autocancelar(bot: Telegram, chat_id: int, argumento: str) -> None:
    partes = (argumento or "").split()
    if partes and partes[0].lower() in ("off", "apagado", "desactivar"):
        _borrar("telegram:auto:cancelaciones")
        await bot.enviar(chat_id, "Auto-cancelacion desactivada.")
        _auditar(chat_id, "autocancelar_off")
        return

    try:
        minutos = max(1, min(int(partes[0]), 240)) if partes else 30
    except ValueError:
        minutos = 30

    codigo, cuerpo = await _api("GET", "/trips/status/requested", params={"limit": 100})
    if codigo != 200 or not isinstance(cuerpo, list):
        await bot.enviar(chat_id, "No pude leer los viajes solicitados: %s"
                                  % _escapar(_detalle_error(cuerpo)))
        return

    umbral = datetime.utcnow().timestamp() - minutos * 60
    viejos = [v for v in cuerpo if isinstance(v, dict)
              and (_a_timestamp(v.get("requested_at") or v.get("created_at")) or 0) <= umbral]

    hechos = 0
    acciones = 0
    for viaje in viejos[:LIMITE_AUTO]:
        acciones += 1
        # Sin `driver_id`: cancelar una oferta que nadie ha tomado no le cuenta a
        # ningun chofer, que es justo el caso de un viaje `requested` viejo.
        cod, _resp = await _api("POST", "/trips/%s/cancel" % viaje.get("trip_id"), cuerpo={})
        if cod == 200:
            hechos += 1

    _escribir_json("telegram:auto:cancelaciones", {
        "activado": True, "acciones": acciones, "limite": LIMITE_AUTO,
        "minutos": minutos, "cancelados": hechos,
        "inicio": datetime.utcnow().isoformat()}, TTL_AUTO)

    texto = ("Auto-cancelacion ejecutada.\n\nViajes solicitados con mas de %s minutos: %s\n"
             "Cancelados: %s\nAcciones usadas: %s de %s (tope por pasada)."
             % (minutos, len(viejos), hechos, acciones, LIMITE_AUTO))
    if len(viejos) > LIMITE_AUTO:
        texto += "\nQuedaron %s sin tocar: el tope por pasada es %s." % (
            len(viejos) - LIMITE_AUTO, LIMITE_AUTO)
    texto += "\n\nEs una pasada de una vez, no un ciclo continuo."

    _auditar(chat_id, "autocancelar", "cancelados=%s acciones=%s" % (hechos, acciones))
    await bot.enviar(chat_id, texto)


async def _cmd_autoestado(bot: Telegram, chat_id: int) -> None:
    lineas = []
    for nombre, clave in (("Auto-aprobacion", "telegram:auto:aprobaciones"),
                          ("Auto-cancelacion", "telegram:auto:cancelaciones")):
        dato = _leer_json(clave)
        if isinstance(dato, dict):
            lineas.append("%s: %s de %s acciones usadas, %s aplicadas (ultima pasada %s)"
                          % (nombre, dato.get("acciones"), dato.get("limite"),
                             dato.get("aprobados") or dato.get("cancelados"),
                             str(dato.get("inicio") or "")[:19].replace("T", " ")))
    if not lineas:
        await bot.enviar(chat_id, "Todavia no se ha ejecutado ninguna pasada automatica.")
        return
    await bot.enviar(chat_id, "<b>Pasadas automaticas</b>\n\n" + "\n".join(lineas), con_html=True)


async def _cmd_audit(bot: Telegram, chat_id: int) -> None:
    try:
        crudos = garnet_client.lrange("telegram:audit", 0, 14)
    except Exception:
        await bot.enviar(chat_id, "El registro de auditoria no esta disponible ahora.")
        return
    if not crudos:
        await bot.enviar(chat_id, "Todavia no hay eventos registrados.")
        return

    lineas = []
    for crudo in crudos:
        try:
            evento = json.loads(crudo)
        except ValueError:
            continue
        lineas.append("%s  %s  %s  %s" % (evento.get("at"),
                                         "OK  " if evento.get("ok") else "ERR ",
                                         evento.get("accion"), _escapar(evento.get("detalle"))))
    await bot.enviar(chat_id, "<b>Ultimos eventos</b>\n\n<pre>" + "\n".join(lineas) + "</pre>",
                     con_html=True)


# ===================== DESPACHO =====================

async def _aprobar_desde_texto(bot: Telegram, chat_id: int, argumento: str) -> None:
    driver_id = (argumento or "").strip()
    if not driver_id:
        await bot.enviar(chat_id, "Uso: /aprobar &lt;id_de_chofer&gt;", con_html=True)
        return
    await _cambiar_estado(bot, chat_id, driver_id, "aprobado")


async def _rechazar_desde_texto(bot: Telegram, chat_id: int, argumento: str) -> None:
    partes = (argumento or "").strip().split(maxsplit=1)
    if not partes:
        await bot.enviar(chat_id, "Uso: /rechazar &lt;id_de_chofer&gt; [motivo]", con_html=True)
        return
    await _cambiar_estado(bot, chat_id, partes[0], "rechazado",
                          partes[1] if len(partes) > 1 else None)


COMANDOS = {
    "start": None,  # Se atiende antes, en _despachar.
    "ayuda": lambda b, c: _cmd_ayuda(b, c),
    "help": lambda b, c: _cmd_ayuda(b, c),
    "estado": lambda b, c: _cmd_estado(b, c),
    "completar": lambda b, c: _cmd_completar(b, c),
    "cancelar": lambda b, c: _cmd_cancelar(b, c),
    "precio": lambda b, c: _cmd_precio(b, c),
    "fondo": lambda b, c: _cmd_fondo(b, c),
    "mi_id": lambda b, c: _cmd_mi_id(b, c),
    "documentos": lambda b, c: _cmd_documentos(b, c),
    "soporte": lambda b, c: _cmd_soporte(b, c),
}

COMANDOS_ADMIN = {
    "pendientes": lambda b, c, a: _cmd_pendientes(b, c),
    "aprobar": lambda b, c, a: _aprobar_desde_texto(b, c, a),
    "rechazar": lambda b, c, a: _rechazar_desde_texto(b, c, a),
    "desvincular": lambda b, c, a: _cmd_desvincular(b, c, a),
    "autoactivar": lambda b, c, a: _cmd_autoactivar(b, c, a),
    "autocancelar": lambda b, c, a: _cmd_autocancelar(b, c, a),
    "autoestado": lambda b, c, a: _cmd_autoestado(b, c),
    "audit": lambda b, c, a: _cmd_audit(b, c),
}

TEXTO_AYUDA_ADMIN = (
    "<b>Comandos de administrador</b>\n"
    "/pendientes - Choferes por revisar, con botones\n"
    "/aprobar &lt;id&gt; - Habilitar un chofer\n"
    "/rechazar &lt;id&gt; [motivo] - Rechazar un chofer\n"
    "/desvincular &lt;numero&gt; - Quitar el vinculo de Telegram\n"
    "/autoactivar [off] - Aprobar la cola, tope de %s por pasada\n"
    "/autocancelar [min] [off] - Cancelar ofertas viejas, tope de %s\n"
    "/autoestado - Como va la ultima pasada\n"
    "/audit - Ultimos eventos" % (LIMITE_AUTO, LIMITE_AUTO)
)


async def _procesar_comando(bot: Telegram, chat_id: int, comando: str,
                            argumento: str) -> None:
    nombre = comando.split("@")[0].strip().lower()

    if nombre in COMANDOS_ADMIN:
        if not _es_admin(chat_id):
            _auditar(chat_id, "admin_denegado", nombre, ok=False)
            await bot.enviar(chat_id, "Ese comando es solo para el administrador.")
            return
        _auditar(chat_id, "comando_admin", nombre)
        await COMANDOS_ADMIN[nombre](bot, chat_id, argumento)
        return

    manejador = COMANDOS.get(nombre)
    if manejador is None:
        if _es_admin(chat_id):
            await bot.enviar(chat_id, "No conozco /%s.\n\n%s"
                             % (_escapar(nombre), TEXTO_AYUDA_ADMIN), con_html=True)
        else:
            await bot.enviar(chat_id, "No conozco el comando /%s.\n\n%s"
                             % (_escapar(nombre), _escapar(_texto_comandos())), con_html=True)
        return

    _auditar(chat_id, "comando", nombre)
    await manejador(bot, chat_id)


async def _procesar_boton(bot: Telegram, chat_id: int, datos: str) -> None:
    partes = datos.split(":")
    accion = partes[0]

    if accion == "menu":
        destino = partes[1] if len(partes) > 1 else ""
        manejadores = {"estado": _cmd_estado, "fondo": _cmd_fondo, "precio": _cmd_precio,
                       "ayuda": _cmd_ayuda, "completar": _cmd_completar,
                       "cancelar": _cmd_cancelar}
        if destino in manejadores:
            await manejadores[destino](bot, chat_id)
        return

    if accion == "can":
        estado = _flujo(chat_id)
        if not estado or estado.get("tipo") != "cancelar":
            await bot.enviar(chat_id, "Ese viaje ya no esta pendiente de confirmar.")
            return
        if (partes[1] if len(partes) > 1 else "no") == "si":
            await _confirmar_cancelacion(bot, chat_id, estado)
        else:
            _terminar_flujo(chat_id)
            await bot.enviar(chat_id, "Viaje intacto. No cancele nada.")
        return

    if accion in ("ap", "re") and _es_admin(chat_id):
        await _cambiar_estado(bot, chat_id, partes[1] if len(partes) > 1 else "",
                              "aprobado" if accion == "ap" else "rechazado")


async def _procesar_mensaje(bot: Telegram, chat_id: int, texto: str,
                            ubicacion: Optional[dict], foto: Optional[dict]) -> None:
    estado = _flujo(chat_id)
    tipo = (estado or {}).get("tipo")

    # --- Cerrar viaje: llega la ubicacion de destino ---
    if ubicacion and tipo == "completar":
        await _confirmar_completar(bot, chat_id, estado,
                                   float(ubicacion["latitude"]), float(ubicacion["longitude"]))
        return

    # --- Cancelar: el siguiente texto es el motivo ---
    if tipo == "cancelar" and texto and not foto:
        estado.setdefault("datos", {})["motivo"] = texto.strip()[:300]
        teclado = {"inline_keyboard": [[
            {"text": "Si, cancelar", "callback_data": "can:si"},
            {"text": "No, dejar el viaje", "callback_data": "can:no"},
        ]]}
        await bot.enviar(chat_id, "Motivo: %s\n\n¿Confirmas la cancelacion del viaje %s?"
                         % (_escapar(texto.strip()[:300]), _escapar(estado.get("trip_id"))),
                         teclado=teclado, con_html=True)
        return

    # --- Sin formulario abierto ---
    if estado is None:
        if texto.startswith("/"):
            comando, _, argumento = texto[1:].partition(" ")
            await _procesar_comando(bot, chat_id, comando, argumento)
        elif texto:
            if not await _exigir_vinculo(bot, chat_id):
                return
            await bot.enviar(chat_id, "No te entendi. Escribe /ayuda para ver los comandos.")
        return

    # --- Poner fotos que faltan ---
    if tipo == "documentos":
        pasos = estado.get("pasos") or []
        indice = estado.get("indice", 0)
        if indice >= len(pasos):
            await _subir_documentos(bot, chat_id, estado)
            return
        if not foto:
            await bot.enviar(chat_id, "Falta esa foto. Mandamela como imagen.")
            return
        await _guardar_foto(bot, chat_id, pasos[indice]["campo"], foto)
        estado["indice"] = indice + 1
        if estado["indice"] >= len(pasos):
            await _subir_documentos(bot, chat_id, estado)
            return
        _escribir_json(_clave_flujo(chat_id), estado, TTL_FLUJO)
        await bot.enviar(chat_id, pasos[estado["indice"]]["pregunta"]
                         + "\n\nFoto %d de %d." % (estado["indice"] + 1, len(pasos)))
        return

    if tipo == "completar":
        await bot.enviar(chat_id, "Para cerrar el viaje necesito la ubicacion. Compartela "
                                  "con el icono de ubicacion de Telegram, abajo a la "
                                  "izquierda.")
        return

    await bot.enviar(chat_id, "No te entendi. Escribe /ayuda.")


# ===================== WEBHOOK =====================

@router.post("/webhook/{token}")
async def webhook(
    token: str,
    request: Request,
    background: BackgroundTasks,
    x_telegram_bot_api_secret_token: Optional[str] = Header(
        None, alias="X-Telegram-Bot-Api-Secret-Token"),
) -> JSONResponse:
    """Entrada unica de Telegram.

    Se comprueban el token de la ruta y la cabecera secreta que Telegram manda
    cuando el webhook se registro con `secret_token`. Sin las dos, cualquiera que
    conozca la URL podria mandar mensajes en nombre del bot.
    """
    esperado_ruta = _token_bot()
    esperado_cabecera = _secreto_webhook()

    if not esperado_ruta or not esperado_cabecera:
        logger.error("Webhook recibido sin TELEGRAM_BOT_TOKEN o TELEGRAM_WEBHOOK_SECRET")
        raise HTTPException(status_code=503, detail="El bot no esta configurado")

    if not secrets.compare_digest(token, esperado_ruta):
        logger.warning("Webhook con token de ruta invalido")
        raise HTTPException(status_code=404, detail="No encontrado")

    if not secrets.compare_digest(x_telegram_bot_api_secret_token or "", esperado_cabecera):
        logger.warning("Webhook con cabecera secreta invalida")
        raise HTTPException(status_code=403, detail="Prohibido")

    try:
        actualizacion = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Cuerpo no valido")

    # Se responde 200 ya y el trabajo va en segundo plano: si el bot se demora,
    # Telegram reintenta el envio y el chofer recibe el mensaje duplicado.
    background.add_task(_despachar, actualizacion)
    return JSONResponse({"ok": True})


async def _despachar(actualizacion: dict) -> None:
    try:
        bot = _cliente()
    except HTTPException:
        logger.error("No se puede despachar: falta TELEGRAM_BOT_TOKEN")
        return

    try:
        if "callback_query" in actualizacion:
            consulta = actualizacion["callback_query"]
            chat_id = (consulta.get("message") or {}).get("chat", {}).get("id")
            await bot.responder_boton(consulta.get("id", ""))
            if chat_id:
                await _procesar_boton(bot, chat_id, consulta.get("data", ""))
            return

        mensaje = actualizacion.get("message")
        if not mensaje:
            return

        chat = mensaje.get("chat") or {}
        chat_id = chat.get("id")
        if not chat_id or chat.get("type") != "private":
            return

        emisor = mensaje.get("from") or {}
        texto = (mensaje.get("text") or "").strip()
        ubicacion = mensaje.get("location")
        fotos = mensaje.get("photo") or []
        contacto = mensaje.get("contact")

        # El contacto manda sobre cualquier otra cosa del mensaje.
        if contacto:
            await _procesar_contacto(bot, chat_id, contacto, emisor.get("id"),
                                     emisor.get("username"))
            return

        # /start se atiende aqui porque decide entre el boton de compartir y el menu.
        if texto.startswith("/start"):
            info = await _mi_chofer(chat_id)
            if info:
                await bot.enviar(chat_id, "Hola de nuevo. Esto es lo que puedes hacer:\n\n%s"
                                 % _escapar(_texto_comandos()), teclado=_teclado_menu())
            else:
                await bot.teclado_boton_compartir(chat_id)
            _auditar(chat_id, "start")
            return

        await _procesar_mensaje(bot, chat_id, texto, ubicacion,
                                fotos[-1] if fotos else None)

    except Exception:
        logger.exception("Fallo despachando una actualizacion de Telegram")


@router.get("/telegram/status")
async def estado_del_bot() -> dict:
    """Diagnostico para el script de verificacion. No devuelve ningun secreto."""
    return {
        "webhook_configurado": bool(_token_bot() and _secreto_webhook()),
        "api_base_url": _url_api_interna(),
        "administradores": len(_chats_admin()),
        "tope_por_pasada_automatica": LIMITE_AUTO,
    }