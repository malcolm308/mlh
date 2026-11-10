"""Endpoints exclusivos del panel web (Streamlit).

El panel de escritorio hablaba con `/admin/trips/active`, `/admin/vehicles` y
`/admin/promociones`. El panel web necesita ademas:

    GET  /admin/alerts/pending
        Viajes huerfanos: siguen en la cola pero no tienen chofer.

    POST /admin/trips/{trip_id}/force-assign
        Asigna un viaje huerfano a un chofer concreto, buscandolo por telefono.
        Es la operacion de emergencia que antes no existia: el monitor solo
        podia forzar inicio/fin de un viaje YA asignado.

    GET/PUT /admin/configuracion
        Vista agregada de promociones + tarifas para el formulario unico del
        panel web. El PUT reutiliza la validacion de `promociones.guardar_promocion`
        (incluye comision, bono, descuento, referidos, coeficientes y espera).

    POST /admin/trips/check-orphaned
        Lo llama un cron job (Render) cada minuto: publica en el grupo de
        Telegram los viajes que siguen en `requested` pasado el 50 % del tiempo
        de espera. Se autentica con API Key, no con JWT de administrador.

Nada de esto se conecta a Mongo/Postgres desde el navegador: el panel web es
solo un cliente HTTP y toda la escritura sigue pasando por la API.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
from datetime import datetime
from typing import Optional

import psycopg2.extras
from bson import ObjectId
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field

from db.Chofer.connection import chofer_db
from db.Cliente.connection import cliente_db
from routers.Solicitud_de_viajes_v4 import (
    OFFER_TTL_SECS,
    _driver_vehicle_type,
    _normalize_vehicle_type,
    garnet,
    get_connection,
    get_trip,
    publish_trip_event,
    set_driver_status,
)
from routers.admin_panel import _json_trip, _nombre_de, require_admin
from routers.admin_roles import REQUIERE_OPERADOR_VIAJES, REQUIERE_SUPER
from routers.promociones import (
    PromoIn,
    _a_json,
    guardar_promocion,
    leer_promocion,
    obtener_tarifas_espera,
)
from services.telefono import buscar_por_telefono, normalizar_telefono
from services.telegram_huerfanos import (
    TelegramError,
    configuracion as telegram_config,
    enviar_mensaje,
    faltantes as telegram_faltantes,
    llamar_api,
    mensaje_huerfano,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/admin", tags=["Panel web"])

chofer_coleccion = chofer_db.users
cliente_coleccion = cliente_db.users

ESTADO_APROBADO = "aprobado"
ESTADOS_ACTIVOS = ("requested", "accepted", "driver_on_the_way",
                   "driver_arrived")

# Un viaje es huerfano cuando ha consumido mas de la mitad del tiempo que la
# oferta permanece viva (OFFER_TTL_SECS, 60 s por defecto). El 100 % es el
# momento en que el viaje expira; el 50 % deja margen para que un chofer que lo
# vio en Telegram llegue a tiempo.
UMBRAL_HUERFANO_SECS = max(1, int(OFFER_TTL_SECS * 0.5))


def require_api_key(
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
    x_cron_key: Optional[str] = Header(None, alias="X-Cron-Key"),
) -> dict:
    """Autenticacion del cron job por API Key estatica.

    Acepta `X-API-Key` y, por compatibilidad con los cron jobs que ya usan
    `X-Cron-Key`, la misma cabecera alternativa. La clave se toma de
    `ORPHANED_API_KEY` o, si no existe, de `CRON_API_KEY`.

    Si no hay clave configurada en el servidor se responde 503: es preferible
    que el cron falle de forma visible a dejar el endpoint abierto.
    """
    esperada = (os.getenv("ORPHANED_API_KEY")
                or os.getenv("CRON_API_KEY") or "").strip()
    if not esperada:
        raise HTTPException(
            status_code=503,
            detail="Falta configurar ORPHANED_API_KEY (o CRON_API_KEY) en "
                   "el servidor.")
    recibida = (x_api_key or x_cron_key or "").strip()
    if not recibida or not hmac.compare_digest(recibida, esperada):
        raise HTTPException(
            status_code=401,
            detail="API Key inválida o ausente. Usa la cabecera X-API-Key.")
    return {"source": "api-key"}


# El endpoint de prueba del grupo se puede llamar con la API Key normal o con
# un token derivado del TELEGRAM_BOT_TOKEN. Asi se puede comprobar el grupo
# desde una maquina que tiene el token del bot pero no la API Key del cron.
_SAL_TEST_GRUPO = b"rapitaxi:telegram:test-group:v1"


def _token_prueba_grupo() -> str:
    token = (os.getenv("TELEGRAM_BOT_TOKEN") or "").strip()
    if not token:
        return ""
    return hmac.new(token.encode("utf-8"), _SAL_TEST_GRUPO, hashlib.sha256).hexdigest()


def require_api_key_or_test_token(
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
    x_cron_key: Optional[str] = Header(None, alias="X-Cron-Key"),
    x_test_token: Optional[str] = Header(None, alias="X-Test-Token"),
) -> dict:
    """API Key del cron o token derivado del bot para la prueba del grupo."""
    esperado = _token_prueba_grupo()
    recibido = (x_test_token or "").strip()
    if esperado and recibido and hmac.compare_digest(recibido, esperado):
        return {"source": "test-token"}
    return require_api_key(x_api_key=x_api_key, x_cron_key=x_cron_key)


# ===================== HELPERS =====================

def _contacto_cliente(cliente_id: Optional[str]):
    """Nombre y telefono del pasajero, tolerando ids viejos o invalidos."""
    if not cliente_id or not ObjectId.is_valid(cliente_id):
        return None, None
    try:
        doc = cliente_coleccion.find_one(
            {"_id": ObjectId(cliente_id)},
            {"Nombre": 1, "Apellidos": 1, "numero_de_telefono": 1},
        )
    except Exception:
        logger.exception("alerts/pending: no se pudo leer al cliente %s", cliente_id)
        return None, None
    if not doc:
        return None, None
    nombre = " ".join(filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip()
    return nombre or None, doc.get("numero_de_telefono")


def _espera_segundos(requested_at) -> Optional[int]:
    if not isinstance(requested_at, datetime):
        return None
    try:
        return max(0, int((datetime.utcnow() - requested_at).total_seconds()))
    except Exception:
        return None


def _chofer_resumen(doc: dict) -> dict:
    return {
        "driver_id": str(doc["_id"]),
        "nombre": " ".join(filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip(),
        "telefono": doc.get("numero_de_telefono"),
        "email": doc.get("email"),
        "tipo_vehiculo": _driver_vehicle_type(doc),
        "estado": doc.get("estado_habilitacion") or ESTADO_APROBADO,
        "enable": bool(doc.get("Enable", True)),
    }


# ===================== VIAJES HUERFANOS =====================

@router.get("/alerts/pending")
async def alertas_pendientes(admin: dict = Depends(require_admin)):
    """Viajes en cola que no tienen chofer asignado.

    Se ordenan por antiguedad: el primero de la lista es el pasajero que mas
    lleva esperando. `espera_segundos` lo calcula el backend para que el panel
    no dependa del reloj del navegador.
    """
    sql = """
        SELECT trip_id, client_id, status, request_address, dropoff_address,
               vehicle_type, distance_km, precio_estimado, requested_at,
               alerta_enviada,
               ST_Y(request_location::geometry) AS request_lat,
               ST_X(request_location::geometry) AS request_lng
          FROM trips
         WHERE status IN ('requested', 'accepted', 'driver_on_the_way',
                          'driver_arrived')
           AND driver_id IS NULL
         ORDER BY requested_at ASC
         LIMIT 200
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql)
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()

    viajes = []
    for r in rows:
        item = _json_trip(r)
        nombre, telefono = _contacto_cliente(r.get("client_id"))
        espera = _espera_segundos(r.get("requested_at"))
        item.update({
            "client_name": nombre or _nombre_de(cliente_coleccion, r.get("client_id")),
            "client_phone": telefono,
            "driver_name": None,
            "espera_segundos": espera,
            "es_huerfano": bool(espera is not None
                                and espera > UMBRAL_HUERFANO_SECS),
            "alerta_enviada": bool(r.get("alerta_enviada")),
            "distance_km": (round(float(r["distance_km"]), 2)
                            if r.get("distance_km") is not None else None),
            "precio_estimado": (float(r["precio_estimado"])
                                if r.get("precio_estimado") is not None else None),
        })
        viajes.append(item)

    return {
        "total": len(viajes),
        "umbral_huerfano_segundos": UMBRAL_HUERFANO_SECS,
        "viajes": viajes,
    }


# ===================== CRON: AVISO DE HUERFANOS A TELEGRAM =====================

@router.post("/trips/check-orphaned")
async def revisar_viajes_huerfanos(_: dict = Depends(require_api_key)):
    """Publica en el grupo de Telegram los viajes que ya son huerfanos.

    Lo llama un cron job externo cada minuto (Render Cron Job, cron-job.org,
    etc.). No espera JWT: usa `X-API-Key` contra `ORPHANED_API_KEY` (o
    `CRON_API_KEY`).

    La marca `alerta_enviada` se pone ANTES de hablar con Telegram y se revierte
    si el envio falla. Con dos instancias del cron solapadas, solo una consigue
    el UPDATE ... RETURNING y no se duplica el mensaje; si Telegram falla, el
    viaje queda otra vez pendiente para la siguiente pasada.
    """
    cfg = telegram_config()
    faltan = telegram_faltantes(cfg)
    if faltan:
        raise HTTPException(
            status_code=503,
            detail="Faltan variables de entorno para Telegram: %s"
                   % ", ".join(faltan))

    sql = """
        SELECT trip_id, request_address, dropoff_address, precio_estimado,
               vehicle_type, requested_at
          FROM trips
         WHERE status = 'requested'
           AND driver_id IS NULL
           AND alerta_enviada = FALSE
           AND requested_at < NOW() - make_interval(secs => %s)
         ORDER BY requested_at ASC
         LIMIT 50
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        try:
            cur.execute(sql, (UMBRAL_HUERFANO_SECS,))
            candidatos = [dict(r) for r in cur.fetchall()]
        finally:
            cur.close()

    enviados = 0
    fallidos = 0
    reclamados = 0
    errores = []
    detalle = []

    for viaje in candidatos:
        trip_id = str(viaje["trip_id"])

        # Reclamo atomico: si otra pasada del cron ya lo tomo, este UPDATE no
        # devuelve fila y se salta el envio.
        with get_connection() as conn:
            cur = conn.cursor()
            try:
                cur.execute(
                    """
                    UPDATE trips
                       SET alerta_enviada = TRUE
                     WHERE trip_id = %s
                       AND alerta_enviada = FALSE
                       AND status = 'requested'
                       AND driver_id IS NULL
                    RETURNING trip_id
                    """,
                    (trip_id,),
                )
                reclamado = cur.fetchone()
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                cur.close()

        if not reclamado:
            continue
        reclamados += 1

        texto = mensaje_huerfano(
            trip_id=trip_id,
            origen=viaje.get("request_address"),
            destino=viaje.get("dropoff_address"),
            precio=viaje.get("precio_estimado"),
            numero_whatsapp=cfg["whatsapp"],
            tipo_vehiculo=viaje.get("vehicle_type"),
        )
        try:
            await enviar_mensaje(cfg["token"], cfg["grupo"], texto)
        except TelegramError as exc:
            fallidos += 1
            errores.append({"trip_id": trip_id, "error": str(exc)})
            logger.warning("check-orphaned: Telegram fallo para %s: %s",
                           trip_id, exc)
            with get_connection() as conn:
                cur = conn.cursor()
                try:
                    cur.execute(
                        "UPDATE trips SET alerta_enviada = FALSE "
                        "WHERE trip_id = %s",
                        (trip_id,),
                    )
                    conn.commit()
                except Exception:
                    conn.rollback()
                    logger.exception(
                        "check-orphaned: no se pudo revertir alerta_enviada "
                        "del viaje %s", trip_id)
                finally:
                    cur.close()
            continue

        enviados += 1
        detalle.append({"trip_id": trip_id, "enviado": True})

    return {
        "ok": True,
        "umbral_huerfano_segundos": UMBRAL_HUERFANO_SECS,
        "candidatos": len(candidatos),
        "reclamados": reclamados,
        "enviados": enviados,
        "fallidos": fallidos,
        "errores": errores[:10],
        "viajes": detalle,
    }


@router.post("/telegram/test-group")
async def probar_grupo_telegram(
    vehicle_type: str = "basico",
    _: dict = Depends(require_api_key_or_test_token),
):
    """Envia un viaje huerfano de prueba al grupo de Telegram configurado.

    `?vehicle_type=moto` (o triciclo/confort/premium) permite comprobar que el
    tipo se pinta bien. Devuelve el status code y el cuerpo JSON EXACTO de
    Telegram para `getChat` y `sendMessage`, de modo que se distinga un chat_id
    equivocado (400), un bot sin permisos (403), etc. No toca la base de datos.
    """
    cfg = telegram_config()
    faltan = telegram_faltantes(cfg)
    if faltan:
        raise HTTPException(
            status_code=503,
            detail="Faltan variables de entorno para Telegram: %s"
                   % ", ".join(faltan))

    chat_status, chat_cuerpo = await llamar_api(
        "getChat", cfg["token"], chat_id=cfg["grupo"])
    chat = chat_cuerpo.get("result") or {}

    texto = "🧪 <b>PRUEBA DE SISTEMA</b>\n\n" + mensaje_huerfano(
        trip_id="TEST-123",
        origen="Calle Falsa 123",
        destino="Avenida Siempre Viva 742",
        precio=1500,
        numero_whatsapp=cfg["whatsapp"],
        tipo_vehiculo=vehicle_type,
    )
    envio_status, envio_cuerpo = await llamar_api(
        "sendMessage", cfg["token"],
        chat_id=cfg["grupo"],
        text=texto,
        disable_web_page_preview=True,
    )

    return {
        "ok": bool(envio_status == 200 and envio_cuerpo.get("ok")),
        "chat_id_configurado": cfg["grupo"],
        "whatsapp": cfg["whatsapp"],
        "vehicle_type": vehicle_type,
        "get_chat": {
            "status": chat_status,
            "ok": bool(chat_cuerpo.get("ok")),
            "descripcion": chat_cuerpo.get("description"),
            "titulo": chat.get("title"),
            "tipo": chat.get("type"),
            "username": chat.get("username"),
        },
        "send_message": {
            "status": envio_status,
            "body": envio_cuerpo,
        },
    }


# ===================== ASIGNACION FORZADA =====================

class ForzarAsignacionIn(BaseModel):
    """El panel web asigna por telefono; `driver_id` queda como alternativa.

    `driver_phone` es el nombre que usa el flujo de Telegram/WhatsApp: el
    administrador ve el numero en WhatsApp y lo pega tal cual. `telefono` se
    mantiene para no romper llamadas antiguas del panel.
    """

    driver_phone: Optional[str] = Field(
        None, description="Numero que escribio el chofer por WhatsApp.")
    telefono: Optional[str] = Field(
        None, description="Alias de driver_phone (compatibilidad).")
    driver_id: Optional[str] = Field(None, description="Alternativa al telefono.")


def _telefono_cliente(client_id) -> Optional[str]:
    """Telefono del pasajero para el evento de asignacion manual.

    La app del chofer ya lo recibe en `GET /trips/{id}`, pero el evento se
    publica tambien con el objeto completo para que el aviso en segundo plano
    pueda mostrar la recogida incluso si el HTTP falla.
    """
    try:
        if not client_id or not ObjectId.is_valid(str(client_id)):
            return None
        doc = cliente_coleccion.find_one({"_id": ObjectId(str(client_id))}) or {}
        profile = doc.get("profile") or {}
        return (doc.get("numero_de_telefono") or doc.get("phone")
                or profile.get("phone"))
    except Exception:
        return None


def _buscar_chofer_para_asignar(datos: ForzarAsignacionIn) -> dict:
    if datos.driver_id:
        if not ObjectId.is_valid(datos.driver_id):
            raise HTTPException(status_code=400, detail="Id de chofer inválido")
        doc = chofer_coleccion.find_one({"_id": ObjectId(datos.driver_id)})
        if not doc:
            raise HTTPException(status_code=404, detail="Chofer no encontrado")
        return doc

    telefono = (datos.driver_phone or datos.telefono or "").strip()
    if not telefono:
        raise HTTPException(
            status_code=400,
            detail="Escribe el número de teléfono del chofer (driver_phone) "
                   "o su id.")

    coincidencias = buscar_por_telefono(chofer_coleccion, telefono)
    if not coincidencias:
        raise HTTPException(
            status_code=404,
            detail="No hay ningún chofer registrado con el teléfono %s."
                   % normalizar_telefono(telefono))
    if len(coincidencias) > 1:
        raise HTTPException(
            status_code=409,
            detail="Ese teléfono aparece en %d cuentas de chofer. "
                   "Corrige el dato antes de asignar." % len(coincidencias))
    return coincidencias[0]


def _chofer_tiene_viaje_activo(driver_id: str) -> Optional[str]:
    sql = """
        SELECT trip_id
          FROM trips
         WHERE driver_id = %s
           AND status IN ('accepted', 'driver_on_the_way', 'driver_arrived',
                          'in_progress')
         LIMIT 1
    """
    with get_connection() as conn:
        cur = conn.cursor()
        try:
            cur.execute(sql, (driver_id,))
            row = cur.fetchone()
        finally:
            cur.close()
    return str(row[0]) if row and row[0] else None


@router.post("/trips/{trip_id}/force-assign")
async def forzar_asignacion(
    trip_id: str,
    datos: ForzarAsignacionIn,
    admin: dict = Depends(REQUIERE_OPERADOR_VIAJES),
):
    """Asigna un viaje sin chofer a un chofer concreto (emergencia).

    A diferencia de `POST /trips/{id}/accept`, no exige que el chofer este en
    estado `available` ni que la oferta siga dentro de los 60 s: el
    administrador esta rescatando un viaje que se quedo sin despacho. Si se
    exige que la cuenta este aprobada, que no tenga otro viaje activo y que el
    tipo de vehiculo coincida con el que pidio el pasajero.
    """
    doc = _buscar_chofer_para_asignar(datos)
    driver_id = str(doc["_id"])

    if (doc.get("estado_habilitacion") or ESTADO_APROBADO) != ESTADO_APROBADO:
        raise HTTPException(
            status_code=403,
            detail="Ese chofer no está habilitado. Apruébalo en la pestaña "
                   "Choferes antes de asignarle viajes.")
    if not doc.get("Enable", True):
        raise HTTPException(
            status_code=403,
            detail="La cuenta de ese chofer está deshabilitada.")

    otro_viaje = _chofer_tiene_viaje_activo(driver_id)
    if otro_viaje:
        raise HTTPException(
            status_code=409,
            detail="Ese chofer ya tiene el viaje %s en curso. "
                   "Termínalo o cancélalo antes de asignarle otro." % otro_viaje)

    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        try:
            cur.execute(
                "SELECT trip_id, client_id, status, driver_id, vehicle_type "
                "FROM trips WHERE trip_id = %s FOR UPDATE",
                (trip_id,),
            )
            trip = cur.fetchone()
            if not trip:
                raise HTTPException(status_code=404, detail="Viaje no encontrado")

            if trip.get("driver_id"):
                if str(trip["driver_id"]) == driver_id:
                    return {
                        "ok": True,
                        "trip_id": trip_id,
                        "driver_id": driver_id,
                        **_chofer_resumen(doc),
                        "status": trip.get("status"),
                        "message": "El viaje ya estaba asignado a ese chofer",
                    }
                raise HTTPException(
                    status_code=409,
                    detail="El viaje ya tiene un chofer asignado. "
                           "No se reasigna desde el panel.")

            if trip.get("status") not in ESTADOS_ACTIVOS:
                raise HTTPException(
                    status_code=400,
                    detail="No se puede asignar un viaje en estado '%s'"
                           % trip.get("status"))

            tipo_chofer = _driver_vehicle_type(doc)
            tipo_viaje = _normalize_vehicle_type(trip.get("vehicle_type"))
            if tipo_chofer and tipo_viaje and tipo_chofer != tipo_viaje:
                raise HTTPException(
                    status_code=400,
                    detail="El viaje pide vehículo tipo %s y ese chofer tiene %s. "
                           "Elige un chofer del tipo correcto."
                           % (tipo_viaje, tipo_chofer))

            cur.execute(
                """
                UPDATE trips
                   SET driver_id = %s,
                       status = 'accepted',
                       alerta_enviada = TRUE
                 WHERE trip_id = %s
                   AND driver_id IS NULL
                   AND status IN ('requested', 'accepted', 'driver_on_the_way',
                                  'driver_arrived')
                RETURNING trip_id, status
                """,
                (driver_id, trip_id),
            )
            actualizado = cur.fetchone()
            if not actualizado:
                raise HTTPException(
                    status_code=409,
                    detail="Otro proceso asignó o cerró el viaje mientras "
                           "se guardaba. Actualiza la tabla e inténtalo de nuevo.")
            conn.commit()
        except HTTPException:
            conn.rollback()
            raise
        except Exception as exc:
            conn.rollback()
            logger.exception("force-assign fallo para el viaje %s", trip_id)
            raise HTTPException(
                status_code=500,
                detail="No se pudo asignar el viaje: %s" % exc)
        finally:
            cur.close()

    try:
        await set_driver_status(driver_id, "busy")
    except Exception as exc:
        logger.warning("force-assign: no se pudo marcar chofer %s: %s", driver_id, exc)

    # Aviso DIRECTO al chofer por su canal de WebSocket.
    #
    # Hasta ahora force-assign solo publicaba `trip_accepted` en el canal del
    # VIAJE: el pasajero se enteraba y el chofer no. La app del chofer no
    # sondea viajes ya asignados (solo `requested-nearby`), asi que el admin
    # cambiaba la fila en Postgres y el chofer seguia en "Aceptando viajes"
    # hasta reiniciar la app.
    #
    # El evento lleva el objeto completo del viaje (origen, destino, cliente y
    # precio): el isolate de segundo plano lo usa para la notificacion local y
    # la app en primer plano lo usa para montar el panel del viaje sin esperar
    # a otra peticion.
    try:
        viaje = get_trip(trip_id) or {}
        evento = _json_trip(viaje)
        evento.update({
            "event": "trip_force_assigned",
            "trip_id": trip_id,
            "driver_id": driver_id,
            "status": "accepted",
            "asignado_por": admin.get("email"),
            "client_name": _nombre_de(
                cliente_coleccion, viaje.get("client_id")),
            "client_phone": _telefono_cliente(viaje.get("client_id")),
        })
        await garnet.publish(
            f"driver:{driver_id}:offers",
            json.dumps(evento, ensure_ascii=False, default=str),
        )
    except Exception as exc:
        logger.warning(
            "force-assign: no se pudo avisar al chofer %s por WS: %s",
            driver_id, exc)

    try:
        await publish_trip_event(trip_id, "trip_accepted", {
            "driver_id": driver_id,
            "client_id": trip.get("client_id"),
            "forzado_por": admin.get("email"),
        })
    except Exception as exc:
        logger.warning("force-assign: no se pudo publicar evento: %s", exc)

    resumen = _chofer_resumen(doc)
    return {
        "ok": True,
        "trip_id": trip_id,
        "driver_id": driver_id,
        "driver_name": resumen["nombre"],
        "driver_phone": resumen["telefono"],
        "status": actualizado.get("status"),
        "message": "Viaje asignado manualmente a %s" % (resumen["nombre"] or driver_id),
    }


# ===================== CONFIGURACION AGREGADA =====================

class ConfiguracionIn(PromoIn):
    """Promociones + tarifas en un solo cuerpo.

    `PromoIn` ya incluye los coeficientes y la espera de cortesía, y
    `guardar_promocion` los escribe en la misma fila. El panel web solo agrega
    una ruta con el nombre que usa su formulario.
    """


async def _configuracion_actual() -> dict:
    promo = _a_json(leer_promocion())
    tarifas = await obtener_tarifas_espera()
    # Las claves comunes (coef_*, espera) las trae `tarifas` con los mismos
    # valores ya resueltos; se mezclan para que el formulario tenga todo junto.
    return {**promo, **tarifas}


@router.get("/configuracion")
async def obtener_configuracion(admin: dict = Depends(REQUIERE_SUPER)):
    """Todo lo que edita la pestaña Promociones y Tarifas, en una respuesta."""
    return await _configuracion_actual()


@router.put("/configuracion")
async def guardar_configuracion(
    datos: ConfiguracionIn,
    admin: dict = Depends(REQUIERE_SUPER),
):
    """Guarda comisión, bono, descuento, referidos, caducidad y coeficientes.

    Reutiliza `guardar_promocion`: la validación (comisión 0 apaga el
    descuento, descuento <= comisión, coeficientes > 0, etc.) vive en un solo
    sitio y no se duplica aqui.
    """
    await guardar_promocion(datos, admin)
    respuesta = await _configuracion_actual()
    respuesta["message"] = "Configuración guardada"
    return respuesta
