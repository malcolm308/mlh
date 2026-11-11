"""
Carga inicial agrupada de las apps (`GET /app-init/{rol}/{user_id}`).

Sin este endpoint, al abrir cada app se disparaban 4-6 llamadas encadenadas
(perfil, tarifas, tipos de vehiculo, promociones/cortesia...) y en Render
dormido eran 5-30 s en cascada. Una sola respuesta reduce el arranque al
RTT de una peticion.

Solo devuelve los campos que las apps pintan: sin passwords, sin historico,
sin campos internos.
"""
import sys

sys.path.insert(0, "E:\\Taxi_Rapid")

from typing import Any, Dict, Optional

from fastapi import APIRouter, Header, HTTPException
from bson import ObjectId

from db.Cliente.auth import verify_token as verify_token_cliente
from db.Cliente.connection import cliente_db
from db.Chofer.auth import verify_token as verify_token_chofer
from db.Chofer.connection import chofer_db
from routers.promociones import leer_promocion
from routers.tariffs import listar_tarifas
from routers.vehiculos import listar_tipos
from routers.Solicitud_de_viajes_v4 import get_connection
from services.codigos_referido import asegurar_codigo

router = APIRouter(tags=["App init"])

_clientes = cliente_db["users"]


def _perfil_cliente(doc: dict) -> dict:
    codigo = doc.get("codigo_referido")
    if not codigo:
        codigo = asegurar_codigo(_clientes, doc)
    return {
        "id": str(doc["_id"]),
        "nombre": " ".join(
            filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip(),
        "email": doc.get("email"),
        "telefono": doc.get("numero_de_telefono"),
        "fondo": float(doc.get("Fondo") or 0),
        "codigo_referido": codigo,
        "descuentos_disponibles": int(doc.get("descuentos_disponibles") or 0),
    }


def _perfil_chofer(doc: dict) -> dict:
    vehiculo = doc.get("vehicle") or {}
    return {
        "id": str(doc["_id"]),
        "nombre": " ".join(
            filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip(),
        "email": doc.get("email"),
        "telefono": doc.get("numero_de_telefono"),
        "fondo": float(doc.get("Fondo") or 0),
        "raiting": float(doc.get("raiting") or 5),
        "tipo_vehiculo": doc.get("type_vehicle") or vehiculo.get("servicio"),
        "vehicle": {
            "marca": vehiculo.get("Marca"),
            "modelo": vehiculo.get("model"),
            "chapa": vehiculo.get("chapa"),
        },
        "enable": bool(doc.get("Enable", True)),
        "estado_habilitacion": doc.get("estado_habilitacion") or "aprobado",
    }


def _promocion_publica() -> dict:
    p = leer_promocion()
    return {
        "comision_porcentaje": float(p["comision_porcentaje"]),
        "comision_billetera": float(p["comision_billetera"]),
        "recargo_transferencia": float(p["recargo_transferencia"]),
        "referidos_activos": bool(p.get("referidos_activos", True)),
        "descuento_cliente_activo": bool(p.get("descuento_cliente_activo")),
        "descuento_cliente_porcentaje": float(p.get("descuento_cliente_porcentaje") or 0),
        "precio_por_minuto": float(p["precio_por_minuto"]),
        "tiempo_espera_cortesia_minutos": float(p["tiempo_espera_cortesia_minutos"]),
        # La zona especial con sus precios: el pasajero la usa para pintar
        # "zona aeropuerto" y el chofer para conocer sus precios kilometricos.
        "zona_especial_activa": bool(p.get("zona_especial_activa", True)),
        "precio_km_zona_basico": float(p["precio_km_zona_basico"]),
        "precio_km_zona_confort": float(p["precio_km_zona_confort"]),
        "precio_km_zona_triciclo": float(p["precio_km_zona_triciclo"]),
        "precio_km_zona_moto": float(p["precio_km_zona_moto"]),
        "zona_especial_coords": p.get("zona_especial_coords"),
    }


def _auth(rol: str, user_id: str, token: Optional[str]) -> dict:
    token = (token or "").strip()
    if token.lower().startswith("bearer "):
        token = token.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Token requerido")

    if rol == "cliente":
        payload = verify_token_cliente(token)
        coleccion = _clientes
    elif rol == "chofer":
        payload = verify_token_chofer(token)
        coleccion = chofer_db.users
    else:
        raise HTTPException(status_code=400, detail="Rol invalido: use cliente|chofer")
    if not payload:
        raise HTTPException(status_code=401, detail="Token invalido o expirado")

    user = coleccion.find_one({"_id": ObjectId(user_id)})
    if not user:
        raise HTTPException(status_code=403, detail="Usuario no encontrado")
    # El token debe pertenecer a esa cuenta (sub = email).
    if (payload.get("sub") or "").lower() != (user.get("email") or "").lower():
        raise HTTPException(status_code=403, detail="El token no corresponde a esta cuenta")
    return user


@router.get("/app-init/{rol}/{user_id}")
async def app_init(rol: str, user_id: str, authorization: Optional[str] = Header(None)):
    """Todo lo que la app necesita al arrancar, en una sola respuesta."""
    user = _auth(rol, user_id, authorization)
    base = {
        "rol": rol,
        "server_time": None,
    }

    # Tarifas: se leen de la tabla (posible excepcion si PG cae; que no tumbe
    # el arranque del chofer: se responde sin ese bloque y la app usa fallback).
    tarifas: Any = []
    try:
        tarifas = listar_tarifas()
    except Exception:
        tarifas = []

    base["promocion"] = _promocion_publica()
    base["tarifas"] = tarifas
    try:
        base["tipos_vehiculo"] = listar_tipos()
    except Exception:
        base["tipos_vehiculo"] = []

    if rol == "cliente":
        base["perfil"] = _perfil_cliente(user)
    else:
        base["perfil"] = _perfil_chofer(user)
        # Garaje activo: el tipo con el que sondea ofertas.
        try:
            activo = chofer_db["vehiculos"].find_one(
                {"driver_id": user_id, "es_activo": True, "estado": "aprobado"},
                {"tipo_vehiculo": 1},
            )
            base["vehiculo_activo"] = {
                "tipo_vehiculo": activo.get("tipo_vehiculo") if activo else None,
            }
        except Exception:
            base["vehiculo_activo"] = None
        # Viaje en curso, para recuperar la pantalla sin segunda consulta.
        try:
            with get_connection() as conn:
                cur = conn.cursor()
                cur.execute(
                    "SELECT trip_id, status FROM trips WHERE driver_id = %s "
                    "AND status IN ('accepted','driver_on_the_way',"
                    "'driver_arrived','in_progress') "
                    "ORDER BY requested_at DESC LIMIT 1",
                    (user_id,),
                )
                fila = cur.fetchone()
                cur.close()
            base["viaje_activo"] = (
                {"trip_id": fila[0], "status": fila[1]} if fila else None)
        except Exception:
            base["viaje_activo"] = None
    return base
