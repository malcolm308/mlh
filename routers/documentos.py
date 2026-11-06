"""Documentacion del chofer: 10 fotos obligatorias para el registro.

El chofer debe subir antes de poder ser habilitado por el administrador:
    1. rostro              - foto frontal de la cara
    2. carnet_frente       - carnet de identidad por delante
    3. carnet_atras        - carnet de identidad por detras
    4. licencia_frente      - licencia de conducir por delante
    5. licencia_atras       - licencia de conducir por detras
    6. circulacion          - registro de circulacion del vehiculo
    7. vehiculo_interior_frente - interior del vehiculo, parte de alante
    8. vehiculo_interior_atras  - interior del vehiculo, parte de atras
    9. vehiculo_exterior_frente  - vehiculo por fuera, por delante
    10. vehiculo_exterior_atras  - vehiculo por fuera, por detras

Las imagenes viven en Cloudinary (si hay credenciales en el entorno) y en el
documento del chofer se guarda la referencia: el nombre interno (`archivo`) y
la `url` segura de la nube. Si no hay credenciales se cae al respaldo de disco
`uploads/documentos/`, util en desarrollo.
El administrador las revisa desde el panel y aprueba o rechaza el chofer.
"""
import logging
import os
import uuid
from datetime import datetime
from typing import Optional

from bson import ObjectId
from fastapi import (APIRouter, Depends, File, Form, Header, HTTPException,
                     Response, UploadFile)
from fastapi.responses import FileResponse, RedirectResponse

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db
from db.Chofer.connection import chofer_db
from services.codigos_referido import generar_codigo
from services.fotos_nube import borrar as borrar_nube
from services.fotos_nube import subir as subir_nube
from services.telefono import buscar_por_telefono, es_telefono_valido, normalizar_telefono
from services.tipo_vehiculo import campos_exigidos_por_tipo, resolver_tipo_vehiculo

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/documentos", tags=["Documentos del chofer"])

chofer_coleccion = chofer_db.users
admin_coleccion = admin_db.users


def _generar_codigo_referido_chofer() -> str:
    """Codigo unico que el chofer comparte para invitar a otros choferes."""
    return generar_codigo(chofer_coleccion)

# Raiz de las imagenes: E:\Taxi_Rapid\uploads\documentos
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads", "documentos")

MAX_SIZE_MB = 8
CONTENT_TYPES = {
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/heic": ".heic",
}

# Firmas binarias reales: evita que alguien suba un .exe renombrado a .jpg
FIRMAS = {
    b"\xff\xd8\xff": ".jpg",                       # JPEG
    b"\x89PNG\r\n\x1a\n": ".png",                  # PNG
    b"RIFF": ".webp",                               # WebP (RIFF....WEBP)
}
MAGIC_HEIC = (b"ftypheic", b"ftypheix", b"ftypmif1", b"ftyphevc", b"ftypmif2")


def _detectar_extension(data: bytes, content_type: Optional[str]) -> Optional[str]:
    """Devuelve la extension si los bytes son realmente una imagen."""
    if data.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    if data[4:8] == b"ftyp" and data[8:12] in MAGIC_HEIC:
        return ".heic"
    return None

# Definicion de los 10 documentos exigidos
CAMPOS = [
    ("rostro", "Foto frontal de la cara", True),
    ("carnet_frente", "Carnet de identidad (por delante)", True),
    ("carnet_atras", "Carnet de identidad (por detras)", True),
    ("licencia_frente", "Licencia de conducir (por delante)", True),
    ("licencia_atras", "Licencia de conducir (por detras)", True),
    ("circulacion", "Circulacion del vehiculo", True),
    ("vehiculo_interior_frente", "Vehiculo por dentro (parte de alante)", True),
    ("vehiculo_interior_atras", "Vehiculo por dentro (parte de atras)", True),
    ("vehiculo_exterior_frente", "Vehiculo por fuera (por delante)", True),
    ("vehiculo_exterior_atras", "Vehiculo por fuera (por detras)", True),
]

CAMPOS_EXIGIDOS = [c[0] for c in CAMPOS if c[2]]


def asegurar_dir():
    os.makedirs(UPLOAD_DIR, exist_ok=True)


def _extension(content_type: Optional[str], nombre: Optional[str]) -> str:
    ext = CONTENT_TYPES.get((content_type or "").lower())
    if ext:
        return ext
    if nombre and "." in nombre:
        cand = os.path.splitext(nombre)[1].lower()
        if cand in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
            return ".jpg" if cand == ".jpeg" else cand
    return ".jpg"


def _guardar_archivo(driver_id: str, campo: str, upload: UploadFile) -> dict:
    """Guarda la imagen (Cloudinary o disco) y devuelve la referencia.

    Con credenciales la foto va a la nube y guardar la `secure_url` en la
    referencia; si la subida falla se escribe igualmente en disco para que el
    registro no se pierda. El nombre interno (`archivo`) mantiene el patron
    `<driver_id>_<campo>_<uuid>.<ext>` porque la autorizacion y varias busquedas
    de Mongo lo usan.
    """
    asegurar_dir()

    data = upload.file.read()
    max_bytes = MAX_SIZE_MB * 1024 * 1024
    if len(data) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail="La imagen %s supera los %d MB" % (campo, MAX_SIZE_MB))
    if not data:
        raise HTTPException(status_code=400, detail="El archivo %s está vacío" % campo)

    # El content_type lo manda el cliente, asi que se comprueban los bytes reales
    real = _detectar_extension(data, upload.content_type)
    if real is None:
        raise HTTPException(
            status_code=400,
            detail="El archivo de %s no es una imagen valida (JPEG, PNG, WebP o HEIC)"
                   % campo)

    nombre = "%s_%s_%s%s" % (driver_id, campo, uuid.uuid4().hex[:8], real)
    base_publico = os.path.splitext(nombre)[0]
    subida = subir_nube(
        data, (upload.content_type or "application/octet-stream").lower(),
        "rapitaxi/chofer/%s" % driver_id, base_publico)

    if subida:
        return {
            "campo": campo,
            "archivo": nombre,
            "url": subida.get("url"),
            "nube_public_id": subida.get("public_id"),
            "bytes": len(data),
            "content_type": (upload.content_type or "application/octet-stream").lower(),
            "subido_at": datetime.utcnow().isoformat(),
            "almacen": "cloudinary",
        }

    ruta = os.path.join(UPLOAD_DIR, nombre)
    with open(ruta, "wb") as f:
        f.write(data)

    return {
        "campo": campo,
        "archivo": nombre,
        "bytes": len(data),
        "content_type": (upload.content_type or "application/octet-stream").lower(),
        "subido_at": datetime.utcnow().isoformat(),
        "almacen": "disco",
    }


def _borrar_archivos(referencias):
    for ref in referencias or []:
        if not isinstance(ref, dict):
            continue
        borrar_nube(ref.get("nube_public_id"))
        nombre = ref.get("archivo")
        if not nombre:
            continue
        try:
            os.remove(os.path.join(UPLOAD_DIR, nombre))
        except OSError:
            pass


def _referencia_por_archivo(nombre: str) -> Optional[dict]:
    """Busca en Mongo la referencia con ese `archivo` (el panel la pidea)."""
    doc = chofer_coleccion.find_one(
        {"documentos.archivo": nombre},
        {"documentos": {"$elemMatch": {"archivo": nombre}}})
    refs = (doc or {}).get("documentos") or []
    for ref in refs:
        if isinstance(ref, dict):
            return ref
    return None


def _responder_desde_nube(url: str) -> Response:
    # Redirect directo a la nube: rapidisimo y no consume la instancia.
    return RedirectResponse(url, status_code=302)


def _exigidos_de(chofer: dict) -> list:
    """Campos obligatorios para ESTE chofer segun el tipo de su vehiculo."""
    return [c for c, _, _ in campos_exigidos_por_tipo(
        resolver_tipo_vehiculo(chofer), CAMPOS)]


def _estado_documentos(chofer: dict) -> dict:
    """Devuelve el estado de cada documento exigido."""
    docs = chofer.get("documentos") or []
    por_campo = {d.get("campo"): d for d in docs if isinstance(d, dict)}
    estado = {}
    faltan = []
    for campo, etiqueta, exigido in CAMPOS:
        ref = por_campo.get(campo)
        # El tipo del chofer decide si el interior "cuenta": moto y triciclo
        # no lo exigen (ver `campos_exigidos_por_tipo`).
        exigidos = _exigidos_de(chofer)
        estado[campo] = {
            "etiqueta": etiqueta,
            "subido": bool(ref),
            "exigido": campo in exigidos,
            "archivo": ref.get("archivo") if ref else None,
            "subido_at": ref.get("subido_at") if ref else None,
        }
        if campo in exigidos and not ref:
            faltan.append(etiqueta)
    return {
        "documentos": estado,
        "total": len(CAMPOS),
        "subidos": sum(1 for c in CAMPOS if por_campo.get(c[0])),
        "faltantes": faltan,
        "completo": not faltan,
    }


def _borrar_por_campo(documentos, campo: str):
    """Quita la referencia anterior (y su archivo en nube/disco) de un doc."""
    docs = list(documentos or [])
    for d in list(docs):
        if isinstance(d, dict) and d.get("campo") == campo:
            borrar_nube(d.get("nube_public_id"))
            nombre = d.get("archivo")
            if nombre:
                try:
                    os.remove(os.path.join(UPLOAD_DIR, nombre))
                except OSError:
                    pass
            docs.remove(d)
    return docs


# ===================== AUTENTICACION =====================

def _token(authorization: Optional[str]) -> Optional[str]:
    if not authorization or not authorization.lower().startswith("bearer "):
        return None
    return authorization.split(" ", 1)[1].strip()


def _es_admin(token: Optional[str]) -> bool:
    if not token:
        return False
    payload = verify_admin_token(token)
    if not payload:
        return False
    admin = admin_coleccion.find_one({"email": payload.get("sub")})
    return bool(admin)


def require_chofer_o_admin(driver_id: str, authorization: Optional[str]) -> dict:
    """Deja pasar al administrador o al propio chofer del `driver_id`."""
    token = _token(authorization)
    if _es_admin(token):
        return {"rol": "admin"}

    payload = verify_admin_token(token) if token else None
    # El chofer se autentica con el mismo JWT, asi que se valida el `sub` del
    # token contra la cuenta del chofer dueno de los documentos.
    if payload:
        chofer = chofer_coleccion.find_one({"email": (payload.get("sub") or "").lower()})
        if chofer and str(chofer["_id"]) == str(driver_id):
            return {"rol": "chofer", "chofer": chofer}

    raise HTTPException(
        status_code=401,
        detail="Necesitas iniciar sesion para ver o subir estos documentos")


# ===================== SUBIDA =====================

@router.post("/registro")
async def registro_con_fotos(
    # --- datos de la cuenta ---
    Nombre: str = Form(...),
    Apellidos: str = Form(...),
    email: str = Form(...),
    numero_de_telefono: str = Form(...),
    password: str = Form(...),
    marca: str = Form(...),
    model: str = Form(...),
    year: int = Form(...),
    chapa: str = Form(...),
    circulation: str = Form(""),
    color: str = Form(...),
    servicio: str = Form(...),
    license_number: str = Form(""),
    max_passengers: int = Form(4),
    codigo_referido: str = Form(""),
    # --- los 10 documentos (prefijo doc_ para no chocar con `circulacion` del vehiculo) ---
    doc_rostro: Optional[UploadFile] = File(None),
    doc_carnet_frente: Optional[UploadFile] = File(None),
    doc_carnet_atras: Optional[UploadFile] = File(None),
    doc_licencia_frente: Optional[UploadFile] = File(None),
    doc_licencia_atras: Optional[UploadFile] = File(None),
    doc_circulacion: Optional[UploadFile] = File(None),
    doc_vehiculo_interior_frente: Optional[UploadFile] = File(None),
    doc_vehiculo_interior_atras: Optional[UploadFile] = File(None),
    doc_vehiculo_exterior_frente: Optional[UploadFile] = File(None),
    doc_vehiculo_exterior_atras: Optional[UploadFile] = File(None),
):
    """Registra al chofer junto con sus 10 fotos en una sola llamada.

    multipart/form-data. Si falta algun documento obligatorio devuelve 400 y no
    crea la cuenta. El chofer queda `pendiente` hasta que el administrador
    revise las fotos y lo apruebe.
    """
    import bcrypt

    archivos = {
        "rostro": doc_rostro,
        "carnet_frente": doc_carnet_frente,
        "carnet_atras": doc_carnet_atras,
        "licencia_frente": doc_licencia_frente,
        "licencia_atras": doc_licencia_atras,
        "circulacion": doc_circulacion,
        "vehiculo_interior_frente": doc_vehiculo_interior_frente,
        "vehiculo_interior_atras": doc_vehiculo_interior_atras,
        "vehiculo_exterior_frente": doc_vehiculo_exterior_frente,
        "vehiculo_exterior_atras": doc_vehiculo_exterior_atras,
    }
    recibidos = {k: v for k, v in archivos.items() if v is not None and v.filename}

    # Las fotos exigidas dependen del tipo de vehiculo: moto/triciclo no tienen
    # interior en el registro (exterior + circulacion bastan, ver
    # `campos_exigidos_por_tipo`). El tipo viene del formulario del registro.
    exigidos = {c for c, _, _ in campos_exigidos_por_tipo(servicio, CAMPOS)}
    faltan = [etiqueta for campo, etiqueta, _ in CAMPOS
              if campo in exigidos and campo not in recibidos]
    if faltan:
        raise HTTPException(
            status_code=400,
            detail="Faltan fotos obligatorias: %s" % ", ".join(faltan))

    email = email.strip().lower()
    if chofer_coleccion.find_one({"email": email}):
        raise HTTPException(status_code=400, detail="Correo ya registrado")

    # El teléfono identifica a la persona. Se compara normalizado, porque en la
    # base puede estar escrito con o sin el prefijo del país y sin normalizar
    # "+5359295207" y "59295207" pasarían los dos como si fueran distintos.
    if not es_telefono_valido(numero_de_telefono):
        raise HTTPException(
            status_code=400,
            detail="El número de teléfono no es válido. Escribe los 8 dígitos.")
    if buscar_por_telefono(chofer_coleccion, numero_de_telefono):
        raise HTTPException(
            status_code=409,
            detail="El número de teléfono ya está asociado a otra cuenta.")

    # Referido de chofer: el código pertenece a otro chofer y se traduce al
    # `_id` del referidor. El bono de 500 CUP se paga cuando este chofer
    # complete su primer viaje (ver complete_trip).
    codigo_invitacion = (codigo_referido or "").strip().upper()
    referidor_doc = None
    if codigo_invitacion:
        referidor_doc = chofer_coleccion.find_one(
            {"codigo_referido": codigo_invitacion})
        if not referidor_doc:
            raise HTTPException(
                status_code=400, detail="Código de referido no válido")

    ahora = datetime.utcnow()
    doc = {
        "Nombre": Nombre.strip(),
        "Apellidos": Apellidos.strip(),
        "email": email,
        "numero_de_telefono": normalizar_telefono(numero_de_telefono),
        "password": bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8"),
        "Fondo": 0.0,
        "raiting": 5.0,
        "Enable": False,
        "status": "pending_review",
        "estado_habilitacion": "pendiente",
        "documents_verified": False,
        "type_vehicle": servicio.strip() or "basico",
        "license_number": license_number.strip(),  # vacio si no se envio
        "max_passengers": max_passengers,
        "codigo_referido": _generar_codigo_referido_chofer(),
        "referido_por": str(referidor_doc["_id"]) if referidor_doc else None,
        "referido_recompensado": False,
        "viajes_completados": 0,
        "vehicle": {
            "Marca": marca.strip(),
            "model": model.strip(),
            "year": year,
            "chapa": chapa.strip(),
            "circulation": circulation.strip(),  # vacio si no se envio
            "color": color.strip(),
            "servicio": servicio.strip(),
        },
        "created_at": ahora.isoformat(),
        "updated_at": ahora.isoformat(),
    }

    resultado = chofer_coleccion.insert_one(doc)
    driver_id = str(resultado.inserted_id)

    guardados = []
    try:
        for campo, upload in recibidos.items():
            guardados.append(_guardar_archivo(driver_id, campo, upload))
    except Exception as e:
        # Si falla una foto se deshace la cuenta: no quedan registros a medias
        _borrar_archivos(guardados)
        chofer_coleccion.delete_one({"_id": resultado.inserted_id})
        logger.exception("Fallo al guardar las fotos de %s", driver_id)
        raise HTTPException(status_code=500, detail="No se pudieron guardar las fotos: %s" % e)

    chofer_coleccion.update_one(
        {"_id": resultado.inserted_id},
        {"$set": {"documentos": guardados, "documentos_subidos_at": ahora.isoformat()}},
    )

    return {
        "ok": True,
        "_id": driver_id,
        "email": email,
        "documentos_subidos": len(guardados),
        "estado_habilitacion": "pendiente",
        "message": "Registro recibido. El administrador revisara tus documentos "
                   "antes de habilitarte.",
    }


@router.post("/chofer/{driver_id}")
async def subir_documentos(
    driver_id: str,
    authorization: Optional[str] = Header(None),
    doc_rostro: Optional[UploadFile] = File(None),
    doc_carnet_frente: Optional[UploadFile] = File(None),
    doc_carnet_atras: Optional[UploadFile] = File(None),
    doc_licencia_frente: Optional[UploadFile] = File(None),
    doc_licencia_atras: Optional[UploadFile] = File(None),
    doc_circulacion: Optional[UploadFile] = File(None),
    doc_vehiculo_interior_frente: Optional[UploadFile] = File(None),
    doc_vehiculo_interior_atras: Optional[UploadFile] = File(None),
    doc_vehiculo_exterior_frente: Optional[UploadFile] = File(None),
    doc_vehiculo_exterior_atras: Optional[UploadFile] = File(None),
):
    """Sube o reemplaza fotos de un chofer ya registrado."""
    require_chofer_o_admin(driver_id, authorization)
    if not ObjectId.is_valid(driver_id):
        raise HTTPException(status_code=400, detail="Id de chofer inválido")
    chofer = chofer_coleccion.find_one({"_id": ObjectId(driver_id)})
    if not chofer:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")

    archivos = {
        "rostro": doc_rostro,
        "carnet_frente": doc_carnet_frente,
        "carnet_atras": doc_carnet_atras,
        "licencia_frente": doc_licencia_frente,
        "licencia_atras": doc_licencia_atras,
        "circulacion": doc_circulacion,
        "vehiculo_interior_frente": doc_vehiculo_interior_frente,
        "vehiculo_interior_atras": doc_vehiculo_interior_atras,
        "vehiculo_exterior_frente": doc_vehiculo_exterior_frente,
        "vehiculo_exterior_atras": doc_vehiculo_exterior_atras,
    }
    recibidos = {k: v for k, v in archivos.items() if v is not None and v.filename}
    if not recibidos:
        raise HTTPException(status_code=400, detail="No se recibió ninguna imagen")

    docs = chofer.get("documentos") or []
    nuevos = []
    try:
        for campo, upload in recibidos.items():
            ref = _guardar_archivo(driver_id, campo, upload)
            nuevos.append(ref)
    except Exception:
        _borrar_archivos(nuevos)
        raise

    # Quita las referencias anteriores de los campos reemplazados
    for campo in recibidos:
        docs = _borrar_por_campo(docs, campo)
    docs = docs + nuevos

    chofer_coleccion.update_one(
        {"_id": chofer["_id"]},
        {"$set": {"documentos": docs,
                  "documentos_subidos_at": datetime.utcnow().isoformat()}},
    )
    return {
        "ok": True,
        "driver_id": driver_id,
        "subidas": len(nuevos),
        "total_documentos": len(docs),
        # El tipo del chofer decide qué interiores "cuentan" (moto/triciclo
        # quedan exentos).
        "faltantes": [et for c, et, _ in CAMPOS
                      if c in _exigidos_de(chofer)
                      and c not in {d.get("campo") for d in docs}],
    }


@router.get("/chofer/{driver_id}/estado")
async def estado_documentos(driver_id: str,
                            authorization: Optional[str] = Header(None)):
    """Que documentos faltan y cuales estan subidos."""
    require_chofer_o_admin(driver_id, authorization)
    if not ObjectId.is_valid(driver_id):
        raise HTTPException(status_code=400, detail="Id de chofer inválido")
    chofer = chofer_coleccion.find_one({"_id": ObjectId(driver_id)})
    if not chofer:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    return _estado_documentos(chofer)


@router.get("/chofer/{driver_id}/foto/{campo}")
async def ver_foto_chofer(driver_id: str, campo: str,
                          authorization: Optional[str] = Header(None)):
    """Sirve UNA foto del registro del chofer (dueno o administrador).

    La usa Mi Garaje para mostrar la foto exterior del vehiculo cuando este
    viene del registro clasico y no tiene fotos propias en el garaje.
    """
    require_chofer_o_admin(driver_id, authorization)
    if not ObjectId.is_valid(driver_id):
        raise HTTPException(status_code=400, detail="Id de chofer inválido")
    chofer = chofer_coleccion.find_one({"_id": ObjectId(driver_id)})
    if not chofer:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")

    ref = None
    for r in chofer.get("documentos") or []:
        if isinstance(r, dict) and r.get("campo") == campo and (
                r.get("archivo") or r.get("url")):
            ref = r
            break
    if not ref:
        raise HTTPException(status_code=404, detail="Foto no encontrada")

    url = ref.get("url")
    if url:
        return _responder_desde_nube(str(url))
    archivo = str(ref.get("archivo") or "")
    ruta = os.path.join(UPLOAD_DIR, os.path.basename(archivo))
    if not os.path.isfile(ruta):
        raise HTTPException(status_code=404, detail="Foto no encontrada")
    return FileResponse(ruta)


@router.get("/imagen/{archivo}")
async def ver_imagen(archivo: str, authorization: Optional[str] = Header(None)):
    """Sirve una imagen para que el panel pueda mostrarla.

    Exige token de administrador: las fotos son documentos de identidad y no
    deben quedar accesibles sin sesion.
    """
    if not _es_admin(_token(authorization)):
        raise HTTPException(status_code=401,
                            detail="Necesitas iniciar sesión como administrador")
    seguro = os.path.basename(archivo)
    # Las fotos que viven en Cloudinary no estan en el disco: se busca la
    # referencia en Mongo y se sirven los bytes desde la nube.
    ref = _referencia_por_archivo(seguro)
    if ref and ref.get("url"):
        return _responder_desde_nube(str(ref["url"]))
    ruta = os.path.join(UPLOAD_DIR, seguro)
    if not os.path.isfile(ruta):
        raise HTTPException(status_code=404, detail="Imagen no encontrada")
    return FileResponse(ruta)
