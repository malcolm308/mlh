"""
Bloqueos de choferes e incidencias de viajes.
"""
import logging
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, HTTPException, Depends, Header
from pydantic import BaseModel
from bson import ObjectId

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db
from db.Chofer.connection import chofer_db
from db.Cliente.connection import cliente_db

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/incidencias", tags=["Incidencias y Bloqueos"])

bloqueos_coleccion = admin_db["bloqueos"]
incidencias_coleccion = admin_db["incidencias"]

def get_current_user(authorization: Optional[str] = Header(default=None,
                                                            alias="Authorization")) -> dict:
    """Lee `Authorization: Bearer <token>` de la cabecera.

    Antes el parametro se declaraba sin `Header`, y FastAPI lo tomaba como
    PARAMETRO DE QUERY (`?authorization=...`). Las apps mandan el token en la
    cabecera, asi que `/incidencias/bloqueos` y `/incidencias/bloquear-chofer`
    respondian 401 "Token requerido" SIEMPRE, aunque la sesion fuera valida.
    """
    if not authorization:
        raise HTTPException(status_code=401, detail="Token requerido")
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Formato de token inválido")
    payload = verify_admin_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token inválido")
    email = payload.get("sub")
    # Los bloqueos los crea el PASAJERO: su token no vive en la coleccion de
    # administradores. Si el email no es de un admin se busca en la de clientes
    # y si tampoco esta, en la de choferes; con cualquiera vale, porque el
    # bloqueo queda atado al `user_id` de quien lo firmo.
    user = admin_db.users.find_one({"email": email})
    if not user:
        user = cliente_db.users.find_one({"email": email})
    if not user:
        user = chofer_db.users.find_one({"email": email})
    if not user:
        raise HTTPException(status_code=403, detail="Usuario no encontrado")
    return {"id": str(user["_id"]), "email": email, "rol": user.get("rol")}

class BloqueoCreate(BaseModel):
    driver_id: str
    trip_id: str
    motivo: str


class PasajeroBloqueoCreate(BaseModel):
    """El chofer bloquea a un PASAJERO: simetrico a [BloqueoCreate]."""
    passenger_id: str
    trip_id: str
    motivo: str

@router.post("/bloquear-chofer", status_code=201)
async def bloquear_chofer(body: BloqueoCreate, user: dict = Depends(get_current_user)):
    """Bloquea a un chofer para el usuario actual.

    Es idempotente por (usuario, chofer): si ya estaba bloqueado se actualiza
    el motivo y el viaje en vez de crear un duplicado. La incidencia solo se
    abre la primera vez, para no llenar la cola del admin con repetidos.
    """
    ahora = datetime.utcnow()
    resultado = bloqueos_coleccion.update_one(
        {"user_id": user["id"], "driver_id": body.driver_id},
        {"$set": {"trip_id": body.trip_id, "motivo": body.motivo, "fecha": ahora}},
        upsert=True,
    )
    if resultado.upserted_id is None:
        # Ya existia: se actualizo el motivo, no se duplica la incidencia.
        return {"message": "Chofer ya estaba bloqueado; se actualizo el motivo",
                "incidencia_id": None}
    incidencia = {"trip_id": body.trip_id, "user_id": user["id"], "driver_id": body.driver_id, "tipo": "bloqueo_chofer", "motivo": body.motivo, "estado": "pendiente", "fecha": ahora}
    result = incidencias_coleccion.insert_one(incidencia)
    return {"message": "Chofer bloqueado e incidencia creada", "incidencia_id": str(result.inserted_id)}


@router.post("/bloquear-pasajero", status_code=201)
async def bloquear_pasajero(body: PasajeroBloqueoCreate,
                            user: dict = Depends(get_current_user)):
    """Bloquea a un PASAJERO para el chofer actual.

    Mismo contrato y misma coleccion que `/bloquear-chofer`: identico por
    (usuario, pasajero), guarda `passenger_id` en vez de `driver_id` y opne la
    incidencia `bloqueo_pasajero`.
    """
    ahora = datetime.utcnow()
    resultado = bloqueos_coleccion.update_one(
        {"user_id": user["id"], "passenger_id": body.passenger_id},
        {"$set": {"trip_id": body.trip_id, "motivo": body.motivo, "fecha": ahora}},
        upsert=True,
    )
    if resultado.upserted_id is None:
        return {"message": "Pasajero ya estaba bloqueado; se actualizo el motivo",
                "incidencia_id": None}
    incidencia = {"trip_id": body.trip_id, "user_id": user["id"],
                  "passenger_id": body.passenger_id,
                  "tipo": "bloqueo_pasajero", "motivo": body.motivo,
                  "estado": "pendiente", "fecha": ahora}
    result = incidencias_coleccion.insert_one(incidencia)
    return {"message": "Pasajero bloqueado e incidencia creada",
            "incidencia_id": str(result.inserted_id)}

@router.get("/bloqueos")
async def listar_bloqueos(user: dict = Depends(get_current_user)):
    """Bloqueos del usuario actual, con el nombre del chofer si existe."""
    bloqueos = list(bloqueos_coleccion.find({"user_id": user["id"]}).sort("fecha", -1))
    for b in bloqueos:
        b["id"] = str(b["_id"])
        del b["_id"]
        # Resuelve el nombre de la persona bloqueada segun el lado: el
        # pasajero bloquea CHOFERES (driver_id) y el chofer bloquea
        # PASAJEROS (passenger_id). Pueden convivir en la misma lista.
        driver_id = b.get("driver_id")
        if driver_id and ObjectId.is_valid(str(driver_id)):
            chofer = chofer_db.users.find_one(
                {"_id": ObjectId(str(driver_id))},
                {"Nombre": 1, "Apellidos": 1})
            if chofer:
                b["driver_name"] = " ".join(filter(None, [
                    chofer.get("Nombre"), chofer.get("Apellidos")])).strip() or None
        passenger_id = b.get("passenger_id")
        if passenger_id and ObjectId.is_valid(str(passenger_id)):
            pasajero = cliente_db.users.find_one(
                {"_id": ObjectId(str(passenger_id))},
                {"Nombre": 1, "Apellidos": 1})
            if pasajero:
                b["passenger_name"] = " ".join(filter(None, [
                    pasajero.get("Nombre"), pasajero.get("Apellidos")])).strip() or None
    return bloqueos


@router.delete("/bloqueos/{bloqueado_id}")
async def desbloquear(bloqueado_id: str, user: dict = Depends(get_current_user)):
    """Desbloquea un chofer o un pasajero para el usuario actual.

    El id puede ser el `driver_id` o el `passenger_id` del bloqueo. Borra el
    documento y deja `resuelta` la incidencia que lo origen. 404 si no estaba
    bloqueado por este usuario.
    """
    criterios = [bloqueado_id]
    if ObjectId.is_valid(bloqueado_id):
        criterios.append(str(ObjectId(bloqueado_id)))
    resultado = bloqueos_coleccion.delete_one(
        {"user_id": user["id"],
         "$or": [{"driver_id": {"$in": criterios}},
                 {"passenger_id": {"$in": criterios}}]})
    if resultado.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Esa persona no está bloqueada")
    # La incidencia ya no representa un bloqueo vivo: se cierra para que no
    # quede "pendiente" en la cola del administrador para siempre. Matchea el
    # lado que corresponda: chofer bloqueado (driver_id) o pasajero.
    incidencias_coleccion.update_many(
        {"user_id": user["id"],
         "$or": [{"driver_id": {"$in": criterios}},
                 {"passenger_id": {"$in": criterios}}],
         "estado": "pendiente"},
        {"$set": {"estado": "resuelta", "fecha_resolucion": datetime.utcnow()}})
    return {"message": "Desbloqueado"}