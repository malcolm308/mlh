"""
Mi Garaje: varios vehiculos por chofer con aprobacion individual.

Antes el chofer tenia UN vehiculo embebido en su documento (`vehicle`) y su
tipo se mantenia en `type_vehicle`. Para poder trabajar con dos coches (y que
el administrador apruebe cada uno por separado) se pasa a una coleccion
`Vehiculos` de la misma base "Chofer" con relacion 1:N:

    Vehiculos { driver_id, tipo_vehiculo, marca, modelo, matricula,
                estado: pendiente|aprobado|rechazado, es_activo }

Reglas:
  * Un vehiculo nuevo entra `pendiente`.
  * Solo `aprobado` puede ser `es_activo: True`, y solo hay uno activo por
    chofer (los demas se desactivan al seleccionar).
  * Al aprobarse/selccionarse, el documento del chofer se sincroniza
    (`type_vehicle` + `vehicle` embebido): todo lo que ya leia el vehiculo
    embebido (panel, factificacion, ofertas) sigue funcionando igual.
  * El sondeo de ofertas resuelve el tipo del chofe ACTIVO en el servidor:
    la app puede mentir en el query param, la base no.

Los vehiculos embebidos existentes se importan automaticamente como
`aprobado` + `es_activo: True` (backfill), para que nadie se quede sin
trabajar tras el despliegue.
"""
import logging
from datetime import datetime
from typing import Optional

from bson import ObjectId
from bson.errors import InvalidId
from fastapi import APIRouter, Body, Header, HTTPException
from pydantic import BaseModel

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db
from db.Chofer.connection import chofer_db
from db.Chofer.auth import verify_token as verify_chofer_token
from services.tipo_vehiculo import normalizar_tipo_vehiculo, tipos_iguales

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Mi Garaje"])

coleccion = chofer_db["vehiculos"]
chofer_coleccion = chofer_db.users
admin_coleccion = admin_db.users

ESTADO_PENDIENTE = "pendiente"
ESTADO_APROBADO = "aprobado"
ESTADO_RECHAZADO = "rechazado"
ESTADOS_VALIDOS = (ESTADO_PENDIENTE, ESTADO_APROBADO, ESTADO_RECHAZADO)


# ============================ AUTENTICACION ============================

def _chofer_actual(authorization: Optional[str]) -> dict:
    """Chofer identificado por su token; el driver_id sale de ahi.

    No se acepta un driver_id en el body: un token robado a un chofer no
    deberia poder crear vehiculos en la cuenta de otro.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Token requerido")
    payload = verify_chofer_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token invalido o expirado")
    driver_id = payload.get("id")
    if not driver_id or not ObjectId.is_valid(driver_id):
        raise HTTPException(status_code=401, detail="Token sin chofer valido")
    chofer = chofer_coleccion.find_one({"_id": ObjectId(driver_id)})
    if not chofer:
        raise HTTPException(status_code=403, detail="Chofer no encontrado")
    return {"id": driver_id, "doc": chofer}


def _admin_actual(authorization: Optional[str]) -> str:
    email_admin = None
    if authorization and authorization.lower().startswith("bearer "):
        payload = verify_admin_token(authorization.split(" ", 1)[1].strip())
        email_admin = (payload or {}).get("sub")
    if not email_admin:
        raise HTTPException(status_code=401, detail="Token de administrador requerido")
    if not admin_coleccion.find_one({"email": email_admin}):
        raise HTTPException(status_code=403, detail="La cuenta no es de administrador")
    return email_admin


# ============================ HELPERS ============================

def _vehiculo_out(doc: dict) -> dict:
    return {
        "id": str(doc["_id"]),
        "driver_id": str(doc.get("driver_id", "")),
        "tipo_vehiculo": doc.get("tipo_vehiculo"),
        "marca": doc.get("marca"),
        "modelo": doc.get("modelo"),
        "matricula": doc.get("matricula"),
        "estado": doc.get("estado"),
        "es_activo": bool(doc.get("es_activo")),
        "creado": (doc.get("created_at").isoformat()
                   if isinstance(doc.get("created_at"), datetime) else None),
        "revisado_por": doc.get("revisado_por"),
        "revisado_at": (doc.get("revisado_at").isoformat()
                        if isinstance(doc.get("revisado_at"), datetime) else None),
        "motivo": doc.get("motivo"),
    }


def _matricula_norm(valor: str) -> str:
    return (valor or "").strip().upper()


def _matricula_repetida(matricula: str, driver_id: str, otro_id=None) -> bool:
    """Dos vehiculos con la misma placa no pueden existir, ni entre choferes.

    Se comprueba contra la coleccion nueva y contra los documentos embebidos
    antiguos, porque el backfill deja los datos en los dos sitios.
    """
    query = {"matricula": matricula}
    if otro_id is not None:
        query["_id"] = {"$ne": otro_id}
    if coleccion.find_one(query):
        return True
    repetida_embebida = chofer_coleccion.find_one(
        {"vehicle.chapa": matricula})
    if repetida_embebida and str(repetida_embebida["_id"]) != driver_id:
        return True
    return False


class VehiculoCreate(BaseModel):
    tipo_vehiculo: str
    marca: str
    modelo: str
    matricula: str


class VehiculoAprobacion(BaseModel):
    decision: str          # 'aprobado' o 'rechazado'
    motivo: str = ""


def async_backfill_vehiculos() -> None:
    """Importa los vehiculos embebidos que todavia no esten en la coleccion.

    Se llama al importar el router (una vez por arranque). El vehiculo
    embebido entra como `aprobado` + `es_activo: True`: era el vehiculo con
    el que el chofer ya trabajaba y no hay motivo para bloquearlo.
    """
    importados = 0
    for chofer in chofer_coleccion.find({}, {"_id": 1, "vehicle": 1,
                                             "type_vehicle": 1}):
        driver_id = str(chofer["_id"])
        if coleccion.find_one({"driver_id": driver_id}):
            continue
        vehicle = chofer.get("vehicle") or {}
        tipo = normalizar_tipo_vehiculo(
            chofer.get("type_vehicle") or vehicle.get("servicio"))
        matricula = _matricula_norm(vehicle.get("chapa") or "")
        if not tipo or not (vehicle.get("Marca") or "").strip():
            # Sin datos minimos no se puede aprobar a ciegas; se deja
            # pendiente para que el panel lo revise.
            estado = ESTADO_PENDIENTE
            es_activo = False
        else:
            estado = ESTADO_APROBADO
            es_activo = True
        coleccion.insert_one({
            "driver_id": driver_id,
            "tipo_vehiculo": tipo,
            "marca": (vehicle.get("Marca") or "").strip() or None,
            "modelo": (vehicle.get("model") or "").strip() or None,
            "year": vehicle.get("year"),
            "matricula": matricula or None,
            "color": vehicle.get("color"),
            "estado": estado,
            "es_activo": es_activo,
            "creado_por_backfill": True,
            "created_at": datetime.utcnow(),
        })
        importados += 1
    if importados:
        logger.info("Backfill de vehiculos: %d importados", importados)


# ============================ ENDPOINTS CHOFER ============================

@router.post("/driver/vehicles", status_code=201)
async def crear_vehiculo(body: VehiculoCreate,
                         authorization: Optional[str] = Header(None)):
    """Registra un vehiculo nuevo para el chofer autenticado. Entra pendiente."""
    chofer = _chofer_actual(authorization)
    tipo = normalizar_tipo_vehiculo(body.tipo_vehiculo)
    if not tipo:
        raise HTTPException(status_code=400, detail="Indica el tipo de vehiculo")
    marca = (body.marca or "").strip()
    modelo = (body.modelo or "").strip()
    matricula = _matricula_norm(body.matricula)
    if not marca:
        raise HTTPException(status_code=400, detail="Indica la marca")
    if not modelo:
        raise HTTPException(status_code=400, detail="Indica el modelo")
    if not matricula:
        raise HTTPException(status_code=400, detail="Indica la matricula")
    if _matricula_repetida(matricula, chofer["id"]):
        raise HTTPException(
            status_code=409,
            detail="Esa matricula ya esta registrada por otro vehiculo")

    doc = {
        "driver_id": chofer["id"],
        "tipo_vehiculo": tipo,
        "marca": marca,
        "modelo": modelo,
        "matricula": matricula,
        "estado": ESTADO_PENDIENTE,
        "es_activo": False,
        "created_at": datetime.utcnow(),
    }
    result = coleccion.insert_one(doc)
    # `insert_one` deja `_id` (ObjectId) inservible en el dict: se saca para
    # que la respuesta sea jsonable.
    doc.pop("_id", None)
    return {"id": str(result.inserted_id), **doc}


@router.get("/driver/vehicles")
async def listar_vehiculos(authorization: Optional[str] = Header(None)):
    """Vehiculos del chofer autenticado, del mas nuevo al mas viejo."""
    chofer = _chofer_actual(authorization)
    docs = list(coleccion.find(
        {"driver_id": chofer["id"]}).sort("created_at", -1))
    return [_vehiculo_out(d) for d in docs]


@router.put("/driver/vehicles/{vehiculo_id}/select")
async def seleccionar_vehiculo(vehiculo_id: str,
                               authorization: Optional[str] = Header(None)):
    """Marca el vehiculo como el ACTIVO del chofer.

    Solo un `aprobado` puede activarse y solo puede haber uno activo: los
    demas quedan desactivados. Tipo y datos del vehiculo elegido se escriben
    tambien en el documento del chofer (`type_vehicle` + `vehicle` embebido),
    porque el sondeo de ofertas, el panel y la facturacion leen de ahi.
    """
    chofer = _chofer_actual(authorization)
    if not ObjectId.is_valid(vehiculo_id):
        raise HTTPException(status_code=400, detail="Id invalido")
    doc = coleccion.find_one({
        "_id": ObjectId(vehiculo_id),
        "driver_id": chofer["id"],
    })
    if not doc:
        raise HTTPException(status_code=404, detail="Vehiculo no encontrado")
    if doc.get("estado") != ESTADO_APROBADO:
        raise HTTPException(
            status_code=400,
            detail="Solo puedes usar un vehiculo aprobado por el administrador")

    coleccion.update_many(
        {"driver_id": chofer["id"]},
        {"$set": {"es_activo": False}},
    )
    coleccion.update_one(
        {"_id": doc["_id"]},
        {"$set": {"es_activo": True}},
    )
    chofer_coleccion.update_one(
        {"_id": ObjectId(chofer["id"])},
        {"$set": {
            "type_vehicle": doc.get("tipo_vehiculo") or "basico",
            "vehicle": {
                "Marca": doc.get("marca") or "",
                "model": doc.get("modelo") or "",
                "year": doc.get("year") or 0,
                "chapa": doc.get("matricula") or "",
                "circulation": (chofer["doc"].get("vehicle") or {}).get("circulation", ""),
                "color": doc.get("color") or (chofer["doc"].get("vehicle") or {}).get("color", ""),
                "servicio": doc.get("tipo_vehiculo") or "basico",
            },
            "updated_at": datetime.utcnow().isoformat(),
        }},
    )
    return {"ok": True,
            "message": "Vehiculo activo",
            "tipo_vehiculo": doc.get("tipo_vehiculo")}


# ============================ ENDPOINTS ADMIN ============================

@router.get("/admin/vehicles")
async def listar_vehiculos_admin(estado: Optional[str] = None,
                                 authorization: Optional[str] = Header(None)):
    """Lista de vehiculos para el panel. Por defecto, solo pendientes."""
    email_admin = _admin_actual(authorization)
    filtro = {}
    if estado is not None and estado != "":
        if estado not in ESTADOS_VALIDOS:
            raise HTTPException(status_code=400, detail="Estado invalido")
        filtro["estado"] = estado

    salida = []
    for doc in coleccion.find(filtro).sort("created_at", -1):
        chofer = chofer_coleccion.find_one(
            {"_id": ObjectId(doc.get("driver_id"))},
            {"Nombre": 1, "Apellidos": 1, "email": 1, "numero_de_telefono": 1,
             "estado_habilitacion": 1},
        ) or {}
        item = _vehiculo_out(doc)
        item.update({
            "chofer": " ".join(filter(None, [
                chofer.get("Nombre"), chofer.get("Apellidos")])).strip() or None,
            "email": chofer.get("email"),
            "telefono": chofer.get("numero_de_telefono"),
            "chofer_estado": chofer.get("estado_habilitacion") or ESTADO_APROBADO,
        })
        salida.append(item)
    _ = email_admin   # el token ya valido el acceso
    return {
        "vehiculos": salida,
        "total": len(salida),
    }


@router.put("/admin/vehicles/{vehiculo_id}/approve")
async def aprobar_vehiculo(vehiculo_id: str, body: VehiculoAprobacion = Body(...),
                           authorization: Optional[str] = Header(None)):
    """Aprueba o rechaza un vehiculo (solo administrador).

    El rechazo desactiva el vehiculo; si era el activo del chofer, este queda
    sin vehiculo activo y no podra ponerse en linea hasta elegir otro
    aprobado.
    """
    email_admin = _admin_actual(authorization)
    if not ObjectId.is_valid(vehiculo_id):
        raise HTTPException(status_code=400, detail="Id invalido")
    decision = (body.decision or "").strip().lower()
    if decision not in (ESTADO_APROBADO, ESTADO_RECHAZADO):
        raise HTTPException(
            status_code=400,
            detail="La decision debe ser 'aprobado' o 'rechazado'")

    doc = coleccion.find_one({"_id": ObjectId(vehiculo_id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Vehiculo no encontrado")

    cambios = {
        "estado": decision,
        "revisado_por": email_admin,
        "revisado_at": datetime.utcnow(),
        "motivo": (body.motivo or "").strip() or None,
    }
    if decision == ESTADO_RECHAZADO:
        cambios["es_activo"] = False
        coleccion.update_one({"_id": doc["_id"]}, {"$set": cambios})
        # Si el rechazado era el activo, el chofer queda sin vehiculo activo:
        # no podra ponerse en linea hasta elegir otro aprobado, y mientras
        # tanto el sondeo no le entrega ofertas (tipo activo = None).
        if doc.get("es_activo"):
            chofer_coleccion.update_one(
                {"_id": ObjectId(doc["driver_id"])},
                {"$set": {
                    "type_vehicle": "",
                    "vehicle": (chofer_coleccion.find_one(
                        {"_id": ObjectId(doc["driver_id"])},
                        {"vehicle": 1}) or {}).get("vehicle", {}),
                    "updated_at": datetime.utcnow().isoformat(),
                }},
            )
    else:
        coleccion.update_one({"_id": doc["_id"]}, {"$set": cambios})

    decision_txt = "aprobado" if decision == ESTADO_APROBADO else "rechazado"
    salida = _vehiculo_out(coleccion.find_one({"_id": doc["_id"]}) or doc)
    return {"ok": True, "message": "Vehiculo %s" % decision_txt, **salida}


# ============================ CONSULTA PARA EL SONDEO ============================

def tipo_vehiculo_activo_de(driver_id: Optional[str]) -> Optional[str]:
    """Tipo normalizado del vehiculo activo del chofer, o None si no tiene.

    Es la fuente de verdad del sondeo: el filtro de ofertas usa esto y no el
    query param de la app. Si el chofer no tiene vehiculo aprobado y activo,
    no recibe ofertas de ningun tipo.
    """
    if not driver_id or not ObjectId.is_valid(driver_id):
        return None
    doc = coleccion.find_one(
        {"driver_id": driver_id, "es_activo": True,
         "estado": ESTADO_APROBADO},
        {"tipo_vehiculo": 1},
    )
    return normalizar_tipo_vehiculo(doc.get("tipo_vehiculo")) if doc else None


try:
    async_backfill_vehiculos()
except Exception:  # pragma: no cover - el arranque no puede morir por esto
    logger.exception("No se pudo hacer el backfill de vehiculos")
