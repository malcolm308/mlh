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

Nada de esto se conecta a Mongo/Postgres desde el navegador: el panel web es
solo un cliente HTTP y toda la escritura sigue pasando por la API.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional

import psycopg2.extras
from bson import ObjectId
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from db.Chofer.connection import chofer_db
from db.Cliente.connection import cliente_db
from routers.Solicitud_de_viajes_v4 import (
    _driver_vehicle_type,
    _normalize_vehicle_type,
    get_connection,
    publish_trip_event,
    set_driver_status,
)
from routers.admin_panel import _json_trip, _nombre_de, require_admin
from routers.promociones import (
    PromoIn,
    _a_json,
    guardar_promocion,
    leer_promocion,
    obtener_tarifas_espera,
)
from services.telefono import buscar_por_telefono, normalizar_telefono

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/admin", tags=["Panel web"])

chofer_coleccion = chofer_db.users
cliente_coleccion = cliente_db.users

ESTADO_APROBADO = "aprobado"
ESTADOS_ACTIVOS = ("requested", "accepted", "driver_arrived")


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
               ST_Y(request_location::geometry) AS request_lat,
               ST_X(request_location::geometry) AS request_lng
          FROM trips
         WHERE status IN ('requested', 'accepted', 'driver_arrived')
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
        item.update({
            "client_name": nombre or _nombre_de(cliente_coleccion, r.get("client_id")),
            "client_phone": telefono,
            "driver_name": None,
            "espera_segundos": _espera_segundos(r.get("requested_at")),
            "distance_km": (round(float(r["distance_km"]), 2)
                            if r.get("distance_km") is not None else None),
            "precio_estimado": (float(r["precio_estimado"])
                                if r.get("precio_estimado") is not None else None),
        })
        viajes.append(item)

    return {"total": len(viajes), "viajes": viajes}


# ===================== ASIGNACION FORZADA =====================

class ForzarAsignacionIn(BaseModel):
    """El panel web asigna por telefono; `driver_id` queda como alternativa."""

    telefono: Optional[str] = Field(
        None, description="Numero del chofer, con o sin +53. Es lo que usa el panel.")
    driver_id: Optional[str] = Field(None, description="Alternativa al telefono.")


def _buscar_chofer_para_asignar(datos: ForzarAsignacionIn) -> dict:
    if datos.driver_id:
        if not ObjectId.is_valid(datos.driver_id):
            raise HTTPException(status_code=400, detail="Id de chofer inválido")
        doc = chofer_coleccion.find_one({"_id": ObjectId(datos.driver_id)})
        if not doc:
            raise HTTPException(status_code=404, detail="Chofer no encontrado")
        return doc

    telefono = (datos.telefono or "").strip()
    if not telefono:
        raise HTTPException(
            status_code=400,
            detail="Escribe el número de teléfono del chofer o su id.")

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
           AND status IN ('accepted', 'driver_arrived', 'in_progress')
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
    admin: dict = Depends(require_admin),
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
                       status = 'accepted'
                 WHERE trip_id = %s
                   AND driver_id IS NULL
                   AND status IN ('requested', 'accepted', 'driver_arrived')
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
async def obtener_configuracion(admin: dict = Depends(require_admin)):
    """Todo lo que edita la pestaña Promociones y Tarifas, en una respuesta."""
    return await _configuracion_actual()


@router.put("/configuracion")
async def guardar_configuracion(
    datos: ConfiguracionIn,
    admin: dict = Depends(require_admin),
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
