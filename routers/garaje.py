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
import os
import time
from datetime import datetime
from typing import Optional, Tuple, Dict

from bson import ObjectId
from bson.errors import InvalidId
from fastapi import (APIRouter, Body, File, Header, HTTPException, UploadFile)
from fastapi.responses import FileResponse
from pydantic import BaseModel

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db
from db.Chofer.connection import chofer_db
from db.Chofer.auth import verify_token as verify_chofer_token
from services.tipo_vehiculo import (campos_exigidos_por_tipo,
                                    normalizar_tipo_vehiculo,
                                    tipos_iguales)

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

def _foto_exterior_registro(doc: dict) -> Optional[dict]:
    """Foto exterior del registro clasico (`/documentos/registro`).

    Los choferes que se registraron con las 10 fotos tienen la del vehiculo en
    el documento del chofer, no en la coleccion del garaje. Se usa como
    respaldo cuando el vehiculo del garaje no tiene fotos propias y su
    matricula coincide con la del vehiculo embebido en el chofer.
    """
    driver_id = doc.get("driver_id")
    matricula = _matricula_norm(doc.get("matricula") or "")
    if not driver_id or not matricula or not ObjectId.is_valid(str(driver_id)):
        return None
    chofer = chofer_coleccion.find_one({"_id": ObjectId(str(driver_id))})
    if not chofer:
        return None
    embebido = chofer.get("vehicle") or {}
    if _matricula_norm(embebido.get("chapa") or "") != matricula:
        return None
    for campo in ("vehiculo_exterior_frente", "vehiculo_exterior_atras"):
        for ref in chofer.get("documentos") or []:
            if (isinstance(ref, dict) and ref.get("campo") == campo
                    and ref.get("archivo")):
                return {
                    "campo": campo,
                    "archivo": os.path.basename(str(ref["archivo"])),
                }
    return None


def _foto_exterior_url(doc: dict) -> Optional[str]:
    """Ruta de la foto exterior del vehiculo para pintarla en la app.

    Se prefiere la delantera y, si no hay, la trasera. Si el vehiculo del
    garaje aun no tiene fotos (chofer registrado por la via clasica) se cae a
    la foto exterior de su registro. La imagen se sirve con token: el chofer
    dueno o un administrador, nunca anonimo.
    """
    fotos = doc.get("fotos") or {}
    if isinstance(fotos, dict):
        for campo in ("vehiculo_exterior_frente", "vehiculo_exterior_atras"):
            ref = fotos.get(campo) or {}
            archivo = ref.get("archivo") if isinstance(ref, dict) else None
            if archivo:
                return "/garaje/imagen/%s" % archivo
    registro = _foto_exterior_registro(doc)
    if registro:
        return "/documentos/chofer/%s/foto/%s" % (
            doc.get("driver_id"), registro["campo"])
    return None


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
        "fotos": _fotos_salida(doc),
        "fotos_faltantes": _faltantes_de(doc),
        "foto_exterior_url": _foto_exterior_url(doc),
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


class FotoRevision(BaseModel):
    decision: str          # 'aprobado' o 'rechazado'
    motivo: str = ""


# ============================ FOTOS DEL VEHICULO ============================
#
# Mismo contrato que los documentos del registro: se guardan en disco bajo
# `uploads/garaje/` y en Mongo solo la referencia. El administrador las ve
# desde el panel y aprueba o rechaza CADA una; el vehiculo no se aprobará sin
# las obligatorias.
#
#   * vehiculo_exterior_frente / vehiculo_exterior_atras : por fuera
#   * vehiculo_interior_frente / vehiculo_interior_atras : por dentro
#   * circulacion : registro de circulacion del vehiculo

FOTOS_VEHICULO = [
    ("vehiculo_exterior_frente", "Vehiculo por fuera (por delante)"),
    ("vehiculo_exterior_atras", "Vehiculo por fuera (por atras)"),
    ("vehiculo_interior_frente", "Vehiculo por dentro (por delante)"),
    ("vehiculo_interior_atras", "Vehiculo por dentro (por atras)"),
    ("circulacion", "Registro de circulacion"),
]

FOTOS_OBLIGATORIAS = [c[0] for c in FOTOS_VEHICULO]

FOTO_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "uploads", "garaje")

MAX_FOTO_MB = 8

_EXTENSIONES = {
    b"\xff\xd8\xff": ".jpg",          # JPEG
    b"\x89PNG\r\n\x1a\n": ".png",     # PNG
    b"RIFF": ".webp",                 # WebP (RIFF....WEBP)
}


def _extension_foto(data: bytes, content_type: Optional[str],
                    nombre: Optional[str]) -> str:
    """Extension REAL (por bytes), no la que declara el cliente."""
    for firma, ext in _EXTENSIONES.items():
        if data.startswith(firma):
            if ext == ".webp" and data[8:12] != b"WEBP":
                continue
            return ext
    # HEIC iPhones
    if len(data) > 12 and data[4:8] == b"ftyp" and data[8:12].startswith(b"hei"):
        return ".heic"
    _ = content_type, nombre
    return ""


def _guardar_foto_vehiculo(vehiculo_id: str, campo: str,
                           upload: UploadFile) -> dict:
    """Escribe la imagen en disco y devuelve la referencia para Mongo."""
    os.makedirs(FOTO_DIR, exist_ok=True)
    data = upload.file.read()
    if len(data) > MAX_FOTO_MB * 1024 * 1024:
        raise HTTPException(
            status_code=400,
            detail="La imagen %s supera los %d MB" % (campo, MAX_FOTO_MB))
    ext = _extension_foto(data, upload.content_type, upload.filename)
    if not ext:
        raise HTTPException(
            status_code=400,
            detail="%s: no es una imagen valida (JPEG, PNG, WebP o HEIC)" % campo)
    # El nombre lleva el id del vehiculo: al servirlo se puede comprobar el
    # dueno sin abrir Mongo con el nombre pelado.
    nombre_archivo = "%s_%s%s" % (vehiculo_id, campo, ext)
    ruta = os.path.join(FOTO_DIR, nombre_archivo)
    with open(ruta, "wb") as destino:
        destino.write(data)
    return {
        "archivo": nombre_archivo,
        "subido_at": datetime.utcnow().isoformat(),
        "estado": ESTADO_PENDIENTE,
        "motivo": None,
    }


def _fotos_salida(doc: dict) -> Optional[dict]:
    fotos = doc.get("fotos")
    if not isinstance(fotos, dict):
        return None
    return fotos


def _obligatorias_de(tipo_vehiculo: Optional[str]) -> list:
    """Fotos obligatorias segun el tipo de vehiculo.

    Moto y triciclo: exterior delante/atras + circulacion (sin interior).
    Basico/confort: las 5. Mismo criterio que el registro inicial.
    """
    triples = [(c, e, True) for c, e in FOTOS_VEHICULO]
    return [c for c, _, _ in campos_exigidos_por_tipo(tipo_vehiculo, triples)]


def _faltantes_de(doc: dict) -> list:
    obligatorias = _obligatorias_de(doc.get("tipo_vehiculo"))
    fotos = doc.get("fotos") or {}
    if not isinstance(fotos, dict):
        return obligatorias
    return [c for c in obligatorias
            if not (fotos.get(c) or {}).get("archivo")]


def _dueno_o_admin(archivo: str, authorization: Optional[str]) -> None:
    """Sirve una foto: admin SIEMPRE; un chofer solo las de SU vehiculo."""
    email_admin = None
    if authorization and authorization.lower().startswith("bearer "):
        payload = verify_admin_token(authorization.split(" ", 1)[1].strip())
        email_admin = (payload or {}).get("sub")
    if email_admin:
        _ = admin_coleccion.find_one({"email": email_admin})
        return
    # no admin: tiene que ser el token del chofer dueno del vehiculo
    chofer = _chofer_actual(authorization)
    # El archivo es `<vehiculo_id>_<campo>.<ext>`: el prefijo identifica el
    # vehiculo sin escanear la coleccion.
    prefijo = archivo.split("_", 1)[0]
    if not ObjectId.is_valid(prefijo):
        raise HTTPException(status_code=403, detail="No puedes ver esta foto")
    vehiculo = coleccion.find_one(
        {"_id": ObjectId(prefijo), "driver_id": chofer["id"]})
    if not vehiculo:
        raise HTTPException(status_code=403, detail="No puedes ver esta foto")


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


@router.delete("/driver/vehicles/{vehiculo_id}")
async def eliminar_vehiculo(vehiculo_id: str,
                            authorization: Optional[str] = Header(None)):
    """Borra un vehiculo del garaje del chofer autenticado.

    Solo el dueno puede borrarlo: el `driver_id` sale del token, nunca del
    body. Se eliminan tambien sus fotos del disco. Si era el vehiculo activo,
    el chofer queda sin vehiculo activo (el sondeo deja de darle ofertas)
    hasta que elija otro aprobado, igual que cuando el admin lo rechaza.
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

    # Limpieza de las fotos en disco (solo el nombre base: nunca una ruta).
    fotos = doc.get("fotos") or {}
    if isinstance(fotos, dict):
        for ref in fotos.values():
            archivo = ref.get("archivo") if isinstance(ref, dict) else None
            if not archivo:
                continue
            try:
                os.remove(os.path.join(FOTO_DIR, os.path.basename(archivo)))
            except OSError:
                pass

    coleccion.delete_one({"_id": doc["_id"]})
    if doc.get("es_activo"):
        chofer_coleccion.update_one(
            {"_id": ObjectId(chofer["id"])},
            {"$set": {
                "type_vehicle": "",
                "vehicle": {},
                "updated_at": datetime.utcnow().isoformat(),
            }},
        )
    _invalidar_cache(chofer["id"])
    return {"ok": True, "message": "Vehiculo eliminado"}


# ============================ FOTOS DEL VEHICULO (CHOFER) ============================

@router.post("/driver/vehicles/{vehiculo_id}/fotos", status_code=201)
async def subir_fotos_vehiculo(vehiculo_id: str,
                               authorization: Optional[str] = Header(None),
                               vehiculo_exterior_frente:
                               Optional[UploadFile] = File(None),
                               vehiculo_exterior_atras:
                               Optional[UploadFile] = File(None),
                               vehiculo_interior_frente:
                               Optional[UploadFile] = File(None),
                               vehiculo_interior_atras:
                               Optional[UploadFile] = File(None),
                               circulacion:
                               Optional[UploadFile] = File(None)):
    """Sube (o reemplaza) las fotos del vehiculo.

    Acepta UNA o VARIAS fotos por llamada, con el nombre del campo como clave
    del multipart. Cada foto queda `pendiente` de revision; si el vehiculo ya
    estaba aprobado VUELVE a `pendiente` y se desactiva: el administrador debe
    volver a verlo antes de que el chofer pueda ponerlo en linea.
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

    recibidos = {
        "vehiculo_exterior_frente": vehiculo_exterior_frente,
        "vehiculo_exterior_atras": vehiculo_exterior_atras,
        "vehiculo_interior_frente": vehiculo_interior_frente,
        "vehiculo_interior_atras": vehiculo_interior_atras,
        "circulacion": circulacion,
    }
    recibidos = {k: v for k, v in recibidos.items() if v is not None and v.filename}
    if not recibidos:
        raise HTTPException(status_code=400, detail="No se recibio ninguna imagen")

    guardados: Dict[str, dict] = {}
    for campo, upload in recibidos.items():
        if campo not in [c for c, _ in FOTOS_VEHICULO]:
            raise HTTPException(status_code=400, detail="Campo invalido: %s" % campo)
        guardados[campo] = _guardar_foto_vehiculo(str(doc["_id"]), campo, upload)

    fotos_previas = doc.get("fotos") or {}
    if not isinstance(fotos_previas, dict):
        fotos_previas = {}
    fotos_previas.update(guardados)

    cambios = {"fotos": fotos_previas}
    mensaje = "Fotos guardadas"
    # Reemplazar fotos de un vehiculo aprobado reabre la revision: el admin
    # vuelve a revisarlo y mientras tanto el chofer no puede trabajar con el
    # (misma consecuencia que un rechazo del vehiculo).
    estaba_aprobado = doc.get("estado") == ESTADO_APROBADO
    if estaba_aprobado:
        cambios["estado"] = ESTADO_PENDIENTE
        cambios["es_activo"] = False
        mensaje = ("Fotos guardadas: el vehiculo vuelve a revision y se "
                   "desactiva hasta que el administrador lo apruebe")
    coleccion.update_one({"_id": doc["_id"]}, {"$set": cambios})
    _invalidar_cache(chofer["id"])
    respuesta = dict(doc)
    respuesta.update({"id": str(doc["_id"]), **cambios})
    salida = _vehiculo_out(respuesta)
    return {
        "ok": True,
        "message": mensaje,
        "fotos": fotos_previas,
        "fotos_faltantes": salida.get("fotos_faltantes") or [],
    }


@router.get("/garaje/imagen/{archivo}")
async def ver_foto_vehiculo(archivo: str,
                            authorization: Optional[str] = Header(None)):
    """Sirve una foto del garaje (admin o el chofer dueno del vehiculo)."""
    if "/" in archivo or "\\" in archivo or ".." in archivo:
        raise HTTPException(status_code=400, detail="Nombre de archivo invalido")
    _dueno_o_admin(archivo, authorization)
    ruta = os.path.abspath(os.path.join(FOTO_DIR, archivo))
    if not os.path.isfile(ruta):
        raise HTTPException(status_code=404, detail="Imagen no encontrada")
    return FileResponse(ruta)


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
    _invalidar_cache(chofer["id"])
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
    _invalidar_cache(doc.get("driver_id"))

    decision_txt = "aprobado" if decision == ESTADO_APROBADO else "rechazado"
    salida = _vehiculo_out(coleccion.find_one({"_id": doc["_id"]}) or doc)
    return {"ok": True, "message": "Vehiculo %s" % decision_txt, **salida}


@router.put("/admin/vehicles/{vehiculo_id}/fotos/{campo}/revisar")
async def revisar_foto_vehiculo(vehiculo_id: str, campo: str,
                                body: FotoRevision = Body(...),
                                authorization: Optional[str] = Header(None)):
    """Aprueba o rechaza UNA foto del vehiculo (solo administrador).

    El chofer ve la decision y el motivo en su app. Cuando TODAS las
    obligatorias quedan aprobadas, el vehiculo pasa a `aprobado`
    automaticamente (con esas fotos ya revisadas no queda nada por ver).
    Un rechazo deja el vehiculo en `pendiente` para que el chofer vuelva a
    subirla.
    """
    email_admin = _admin_actual(authorization)
    if not ObjectId.is_valid(vehiculo_id):
        raise HTTPException(status_code=400, detail="Id invalido")
    if campo not in FOTOS_OBLIGATORIAS:
        raise HTTPException(status_code=400, detail="Campo invalido: %s" % campo)
    decision = (body.decision or "").strip().lower()
    if decision not in (ESTADO_APROBADO, ESTADO_RECHAZADO):
        raise HTTPException(
            status_code=400,
            detail="La decision debe ser 'aprobado' o 'rechazado'")

    doc = coleccion.find_one({"_id": ObjectId(vehiculo_id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Vehiculo no encontrado")
    fotos = doc.get("fotos") or {}
    if campo not in fotos or not fotos[campo].get("archivo"):
        raise HTTPException(
            status_code=400, detail="El vehiculo no tiene la foto %s" % campo)

    fotos[campo]["estado"] = decision
    fotos[campo]["motivo"] = (body.motivo or "").strip() or None
    fotos[campo]["revisado_por"] = email_admin
    fotos[campo]["revisado_at"] = datetime.utcnow().isoformat()

    cambios = {"fotos": fotos}
    # Las obligatorias dependen del tipo: moto/triciclo sin interiores.
    obligatorias = _obligatorias_de(doc.get("tipo_vehiculo"))
    completas = all(
        (fotos.get(c) or {}).get("archivo")
        and (fotos.get(c) or {}).get("estado") == ESTADO_APROBADO
        for c in obligatorias
    )
    # Todas las fotos aprobadas => el vehiculo esta a la vista: se aprueba
    # solo. Con alguna rechazada sigue `pendiente` (el chofer corregira).
    auto_aprobado = False
    if completas and doc.get("estado") != ESTADO_APROBADO:
        cambios["estado"] = ESTADO_APROBADO
        cambios["revisado_por"] = email_admin
        cambios["revisado_at"] = datetime.utcnow()
        cambios["motivo"] = None
        auto_aprobado = True
    coleccion.update_one({"_id": doc["_id"]}, {"$set": cambios})
    _invalidar_cache(doc.get("driver_id"))

    salida = _vehiculo_out(coleccion.find_one({"_id": doc["_id"]}) or doc)
    return {
        "ok": True,
        "message": ("Foto %s" % decision
                    + (" (vehiculo aprobado con todas sus fotos)"
                       if auto_aprobado else "")),
        **salida,
    }


# ============================ CONSULTA PARA EL SONDEO ============================

def vehiculo_activo_de(driver_id: Optional[str]) -> Optional[dict]:
    """Documento del vehiculo activo y aprobado del chofer, o None."""
    if not driver_id or not ObjectId.is_valid(driver_id):
        return None
    return coleccion.find_one(
        {"driver_id": driver_id, "es_activo": True,
         "estado": ESTADO_APROBADO})


def tipo_vehiculo_activo_de(driver_id: Optional[str],
                            usar_cache: bool = True) -> Optional[str]:
    """Tipo normalizado del vehiculo activo del chofer, o None si no tiene.

    Es la fuente de verdad del sondeo: el filtro de ofertas usa esto y no el
    query param de la app. Si el chofer no tiene vehiculo aprobado y activo,
    no recibe ofertas de ningun tipo.

    Se cachea 15 s: el sondeo de la app pregunta cada 4 s y cada chofe con
    una lectura Mongo extra por sondeo es gasto gratis; los cambios de
    vehiculo activo (select/aprobacion) invalidan la cache en el acto.
    """
    if not driver_id or not ObjectId.is_valid(driver_id):
        return None
    ahora = time.time()
    tallo = _cache_tipos.get(driver_id)
    if usar_cache and tallo and (ahora - tallo[0]) < _CACHE_TTL:
        return tallo[1]

    doc = coleccion.find_one(
        {"driver_id": driver_id, "es_activo": True,
         "estado": ESTADO_APROBADO},
        {"tipo_vehiculo": 1},
    )
    tipo = normalizar_tipo_vehiculo(doc.get("tipo_vehiculo")) if doc else None
    _cache_tipos[driver_id] = (ahora, tipo)
    return tipo


def _invalidar_cache(driver_id: Optional[str]) -> None:
    if driver_id:
        _cache_tipos.pop(str(driver_id), None)


# driver_id -> (timestamp, tipo). Prefiere torta: se recalcula tras _CACHE_TTL.
_cache_tipos: Dict[str, Tuple[float, Optional[str]]] = {}
_CACHE_TTL = 15.0


try:
    async_backfill_vehiculos()
except Exception:  # pragma: no cover - el arranque no puede morir por esto
    logger.exception("No se pudo hacer el backfill de vehiculos")
