"""API del panel de administracion.

Consumida por la app de escritorio `desktop_admin/`:
    POST /admin/choferes/{id}/estado      habilitar / rechazar un chofer
    GET  /admin/choferes                 listado con filtro por estado
    GET  /admin/choferes/pendientes      solo los que aun no han sido habilitados
    GET  /admin/trips/diarios            viajes por dia (tabla de la app)
    GET  /admin/trips/dia                detalle de los viajes de un dia
    GET  /admin/trips/resumen            totales del dia
    GET  /admin/choferes/top             choferes con mas viajes del dia
    POST /admin/administradores          crea una cuenta de administrador
    GET  /admin/administradores          lista las cuentas de administrador

Todos los endpoints exigen token de administrador.
"""
import logging
import json
import random
import secrets
from datetime import date, datetime, timedelta
from decimal import Decimal
from typing import List, Optional

import bcrypt
import re
import psycopg2
import psycopg2.extras
from bson import ObjectId

from routers.admin_roles import (ROLES_VALIDOS, REQUIERE_OPERADOR_REGISTROS,
                                 REQUIERE_OPERADOR_VIAJES, ROL_SUPER,
                                 REQUIERE_SUPER, SUPER_EMAIL)
from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException
from pydantic import BaseModel

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db
from db.tokens import create_access_token, create_refresh_token, ACCESS_TOKEN_EXPIRE_MINUTES
from datetime import datetime
from db.Chofer.connection import chofer_db
from services.tipo_vehiculo import (
    campos_exigidos_por_tipo, resolver_tipo_vehiculo)
from routers.documentos import CAMPOS as CAMPOS_DOCUMENTOS_BASE
from db.Cliente.connection import cliente_db
from routers.Solicitud_de_viajes_v4 import (
    _asegurar_columnas_cancelacion,
    apply_daily_bonus,
    complete_trip,
    daily_trip_metrics,
    garnet,
    get_connection,
    get_trip,
    publish_trip_event,
    set_driver_status,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/admin", tags=["Administracion"])

chofer_coleccion = chofer_db.users
admin_coleccion = admin_db.users
cliente_coleccion = cliente_db.users

# Estados de habilitacion de un chofer
ESTADO_PENDIENTE = "pendiente"
ESTADO_APROBADO = "aprobado"
ESTADO_RECHAZADO = "rechazado"
ESTADO_CORRECCION = "needs_correction"
ESTADOS_VALIDOS = (ESTADO_PENDIENTE, ESTADO_APROBADO, ESTADO_RECHAZADO, ESTADO_CORRECCION)


# ===================== AUTENTICACION =====================

def require_admin(authorization: Optional[str] = Header(None)) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Falta el token de administrador")
    payload = verify_admin_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token invalido o expirado")

    email = payload.get("sub")
    admin = (admin_coleccion.find_one({"email": email}) if email else None)
    if not admin and email:
        # Casi sin caso (mayusculas en el registro): comparacion sin case,
        # para que un token valido no quede "huerfano" por el formato.
        seguro = email.strip().lower()
        admin = admin_coleccion.find_one(
            {"email": {"$regex": "^%s$" % re.escape(seguro), "$options": "i"}})
    if not admin:
        raise HTTPException(
            status_code=403,
            detail="No existe un administrador con el correo del token "
                   "(%s). Cierra sesion y entra de nuevo." % (email or "?"))
    return {"id": str(admin["_id"]), "email": admin.get("email"), "rol": admin.get("rol")}


# ===================== HELPERS =====================

def estado_de(doc: dict) -> str:
    """Estado de habilitacion del chofer.

    Los choferes dados de alta antes de existir este control no tienen el campo,
    asi que se consideran aprobados (no se bloquea a nadie que ya workings).
    """
    return doc.get("estado_habilitacion") or ESTADO_APROBADO


def _documentos_de(doc: dict) -> dict:
    """Resumen de los documentos exigidos para el panel, segun el tipo de vehiculo."""
    docs = doc.get("documentos") or []
    por_campo = {d.get("campo"): d for d in docs if isinstance(d, dict)}
    tipo = resolver_tipo_vehiculo(doc)
    # Lista de campos exigidos para este tipo (usa el mismo criterio que el
    # registro). Si no se puede resolver el tipo, se exigen todos.
    if tipo:
        exigidos = {c[0] for c in campos_exigidos_por_tipo(tipo, CAMPOS_DOCUMENTOS_BASE)}
    else:
        exigidos = {c[0] for c in CAMPOS_DOCUMENTOS_BASE}
    etiquetas = {c[0]: c[1] for c in CAMPOS_DOCUMENTOS_BASE}
    estado = {}
    faltan = []
    for campo, etiqueta, _ in CAMPOS_DOCUMENTOS_BASE:
        if campo not in exigidos:
            # No aplica a este tipo de vehiculo.
            estado[campo] = {
                "etiqueta": etiqueta,
                "subido": None,
                "archivo": None,
                "url": None,
                "aplica": False,
            }
            continue
        ref = por_campo.get(campo)
        url = None
        if ref:
            url = ref.get("url") or ref.get("secure_url")
        estado[campo] = {
            "etiqueta": etiqueta,
            "subido": bool(ref),
            "archivo": ref.get("archivo") if ref else None,
            "url": url,
            "aplica": True,
        }
        if not ref:
            faltan.append(etiqueta)
    aplicables = [c for c in CAMPOS_DOCUMENTOS_BASE if c[0] in exigidos]
    return {
        "total": len(aplicables),
        "subidos": len(aplicables) - len(faltan),
        "faltan": faltan,
        "completo": not faltan,
        "detalle": estado,
        "tipo_vehiculo": tipo,
    }


def _chofer_out(doc: dict) -> dict:
    vehicle = doc.get("vehicle") or {}
    return {
        "driver_id": str(doc["_id"]),
        "nombre": " ".join(filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip(),
        "email": doc.get("email"),
        "telefono": doc.get("numero_de_telefono"),
        "estado": estado_de(doc),
        "motivo": doc.get("motivo_habilitacion"),
        "revisado_por": doc.get("revisado_por"),
        "revisado_at": (doc.get("revisado_at").isoformat()
                        if isinstance(doc.get("revisado_at"), datetime) else None),
        "vehiculo": ("%s %s" % (vehicle.get("Marca", ""), vehicle.get("model", ""))).strip() or None,
        "matricula": vehicle.get("chapa"),
        "color": vehicle.get("color"),
        "servicio": vehicle.get("servicio"),
        "licencia": doc.get("license_number"),
        "pasajeros": doc.get("max_passengers"),
        "fondo": round(float(doc.get("Fondo") or doc.get("fondo") or 0), 2),
        "rating": doc.get("raiting"),
        "status": doc.get("status"),
        # El login ademas del estado mira Enable, asi que se expone para saber
        # de un vistazo si la cuenta puede entrar a la app.
        "enable": bool(doc.get("Enable", True)),
        "documentos": _documentos_de(doc),
        "missing_fields": doc.get("missing_fields") or [],
        "creado": (doc.get("created_at").isoformat()
                   if isinstance(doc.get("created_at"), datetime) else None),
    }


def _validar_fecha(valor: Optional[str]) -> date:
    if not valor:
        return date.today()
    try:
        return datetime.strptime(valor, "%Y-%m-%d").date()
    except ValueError:
        raise HTTPException(status_code=400, detail="Fecha invalida, use YYYY-MM-DD")


# ===================== HABILITACION DE CHOFERES =====================

class EstadoChoferIn(BaseModel):
    estado: str
    motivo: Optional[str] = None
    missing_fields: Optional[List[str]] = None


class AdminNuevoIn(BaseModel):
    """Datos minimos para dar de alta a otra cuenta de administrador.

    Se piden solo los campos que hacen falta para entrar al panel y para saber
    quien es: nombre, email, telefono, rol y contrasena. El hash lo pone el
    backend; la contrasena en claro nunca se guarda ni se devuelve.
    """

    # El super_admin es quien crea contrasenas: nombre y telefono son
    # opcionales (si no hay nombre, se deriva del correo). La contrasena
    # TAMBIEN: si no viene, el backend genera una aleatoria y la devuelve
    # UNA VEZ en la respuesta.
    nombre: str = ""
    email: str
    telefono: str = ""
    password: Optional[str] = None
    rol: str = "admin"


# Contrasena minima: por debajo de esto no protege nada, y un panel sin
# proteccion real es peor que no tener panel.
ADMIN_PASSWORD_MINIMA = 8


def _validar_admin_nuevo(datos: AdminNuevoIn, creado_por_email: str = "",
                         creado_por_rol: str = "") -> dict:
    """Normaliza y valida. Devuelve el documento listo para insertar.

    Se separa del endpoint para que las mismas reglas sirvan al alta y a
    cualquier edicion posterior.
    """
    nombre = (datos.nombre or "").strip()
    email = (datos.email or "").strip().lower()
    telefono = (datos.telefono or "").strip()
    rol = (datos.rol or "").strip().lower() or "admin"

    # Solo se crean OPERADORES. El super_admin es una cuenta semanticamente
    # diferente (gatekeeper): si se pudiera fabricar con este endpoint, el
    # "solo existe un super_admin" seria una promesa de papel. EXCEPCION
    # controlada: el propio super (SUPER_EMAIL) puede crear OTRO super_admin,
    # p. ej. para cambiar su propio correo de acceso.
    ROLES_CREATIVOS = ("trip_operator", "user_operator", "wallet_operator")
    creado_por_super = (creado_por_email or "").strip().lower() == SUPER_EMAIL \
        or (creado_por_rol or "").strip().lower() == ROL_SUPER
    rol_super_solicitado = rol == ROL_SUPER
    if rol_super_solicitado and not creado_por_super:
        raise HTTPException(
            status_code=403,
            detail="Solo el super_admin vigente (%s) puede crear otra cuenta "
                   "super_admin." % SUPER_EMAIL)
    if (rol not in ROLES_CREATIVOS) and not rol_super_solicitado:
        raise HTTPException(
            status_code=400,
            detail="El rol debe ser uno de: %s. No se puede crear un "
                   "super_admin desde el correo %s." % (
                       ", ".join(ROLES_CREATIVOS), creado_por_email or "?"))

    if not nombre:
        # Solo un correo: el nombre sale de la parte local del email.
        nombre = email.split("@")[0].replace(".", " ").replace("_", " ").title()
    if "@" not in email or "." not in email.split("@")[-1]:
        raise HTTPException(
            status_code=400, detail="El email no tiene un formato valido.")

    # El mismo correo que usa /login. Aqui se compara en minusculas porque el
    # login tambien normaliza, y si se guardara con mayusculas la cuenta
    # quedaria inaccesible.
    if admin_coleccion.find_one({"email": email}):
        raise HTTPException(
            status_code=409, detail="Ya existe un administrador con ese email.")

    # La contraseña la CREA EL BACKEND (o la trae el super con >= minima).
    # Si no viene, se genera y se devuelve UNA VEZ en la respuesta.
    contraseña = datos.password or _generar_contraseña()
    if len(contraseña) < ADMIN_PASSWORD_MINIMA:
        raise HTTPException(
            status_code=400,
            detail="La contrasena debe tener al menos %d caracteres."
                   % ADMIN_PASSWORD_MINIMA)

    ahora = datetime.utcnow()
    return {
        "nombre": nombre,
        "email": email,
        "telefono": telefono,
        # bcrypt con sal propia. El login usa `checkpw`, que compara contra
        # esto; guardar el texto plano seria inutil y peligroso.
        "password": bcrypt.hashpw(
            contraseña.encode("utf-8"), bcrypt.gensalt()).decode("utf-8"),
        "rol": rol,
        "created_at": ahora,
        "updated_at": ahora,
        # Para la respuesta de creacion unica vez; el documento en Mongo
        # lo llevara (hay que hacer pop antes de insertar).
        "_contraseña_plana": contraseña,
    }


@router.post("/administradores", status_code=201)
async def crear_administrador(
    body: AdminNuevoIn,
    admin: dict = Depends(REQUIERE_SUPER),
):
    """Crea una cuenta de administrador.

    Exige sesion de administrador: es el endpoint que permite abrir la puerta,
    asi que dejarlo sin proteger convertiria cualquier error de autenticacion en
    un acceso total al panel.
    """
    documento = _validar_admin_nuevo(
        body,
        creado_por_email=admin.get("email"),
        creado_por_rol=admin.get("rol"))
    contraseña_plana = documento.pop("_contraseña_plana", None)
    resultado = admin_coleccion.insert_one(documento)

    logger.info("Administrador creado: %s por %s",
                documento["email"], admin.get("email"))

    # El documento de vuelta lleva el hash fuera a proposito: que no salga por
    # la red ni siquiera una vez evita que acabe en un log del panel. Pero la
    # CONTRASEÑA GENERADA si se devuelve UNA VEZ: el pass nunca es recuperable
    # despues, solo re-asignable con otro reset.
    return {
        "id": str(resultado.inserted_id),
        "nombre": documento["nombre"],
        "email": documento["email"],
        "telefono": documento["telefono"],
        "rol": documento["rol"],
        "password_generada": contraseña_plana,
        "message": "Administrador creado. Guarda la contraseña ahora: no se "
                   "volverá a mostrar.",
    }


@router.get("/administradores")
async def listar_administradores(admin: dict = Depends(REQUIERE_SUPER)):
    """Lista las cuentas de administrador, sin passwords."""
    admins = admin_coleccion.find({}).sort("created_at", 1)
    return {
        "administradores": [
            {
                "id": str(a["_id"]),
                "nombre": a.get("nombre", ""),
                "email": a.get("email", ""),
                "telefono": a.get("telefono", ""),
                "rol": a.get("rol", "admin"),
                "created_at": a["created_at"].isoformat()
                if isinstance(a.get("created_at"), datetime) else None,
            }
            for a in admins
        ]
    }


@router.delete("/users/{user_id}")
async def despedir_administrador(
    user_id: str,
    admin: dict = Depends(REQUIERE_SUPER),
):
    """Despide (elimina) a otro administrador. SOLO super_admin.

    Reglas de seguridad:
      * Un operador que intente despidar recibe 403 (dependencia del router).
      * El super_admin NO puede despedirse a si mismo: quedaria sin nadie
        capaz de gestionar a los operadores.
      * No se elimina por email en el body: el target va en la URL y la
        identidad del que pide sale del token.
    """
    if not ObjectId.is_valid(user_id):
        raise HTTPException(status_code=400, detail="Id invalido")
    objetivo = admin_coleccion.find_one({"_id": ObjectId(user_id)})
    if not objetivo:
        raise HTTPException(status_code=404, detail="Administrador no encontrado")
    if str(objetivo["_id"]) == str(admin["id"]):
        raise HTTPException(
            status_code=400,
            detail="No puedes eliminar tu propia cuenta desde el panel.")
    if (objetivo.get("rol") or "").strip().lower() == ROL_SUPER and \
            (objetivo.get("email") or "").strip().lower() == SUPER_EMAIL:
        # El super VIGENTE no se elimina: quedaria el panel sin guardian. Los
        # supers ANTERIORES (cuentas reemplazadas) si se pueden borrar, que es
        # el exacto caso de cambio de correo.
        raise HTTPException(
            status_code=403,
            detail="No se puede eliminar: %s es el super vigente."
            % objetivo.get("email"))
    admin_coleccion.delete_one({"_id": objetivo["_id"]})
    logger.info("Administrador eliminado: %s (%s) por %s",
                objetivo.get("email"), user_id, admin.get("email"))
    return {"ok": True,
            "message": "Administrador eliminado: %s" % objetivo.get("email")}


class CambioPasswordIn(BaseModel):
    """Cambio de la PROPIA contrasena: exige la actual, evita un token robado."""

    actual: str
    nueva: str


class PasswordAsignadaIn(BaseModel):
    """Reset de contraseña por el super_admin. Si `nueva` viene vacia o None,
    el backend GENERA una y la devuelve UNA VEZ en la respuesta."""

    nueva: Optional[str] = None


def _hash_contrasena_nueva(nueva: str) -> str:
    if len(nueva or "") < ADMIN_PASSWORD_MINIMA:
        raise HTTPException(status_code=400, detail="La contraseña debe tener "
                            "al menos %d caracteres." % ADMIN_PASSWORD_MINIMA)
    return bcrypt.hashpw(nueva.encode("utf-8"),
                         bcrypt.gensalt()).decode("utf-8")


def _generar_contraseña(largo: int = 12) -> str:
    """Contraseña aleatoria legible: sin 0/O/1/l para que no se confundan
    al leerse por telefono."""
    alfabeto = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"
    # Garantiza letra mayuscula + minuscula + digito.
    partes = [
        secrets.choice("ABCDEFGHJKMNPQRSTUVWXYZ"),
        secrets.choice("abcdefghjkmnpqrstuvwxyz"),
        secrets.choice("23456789"),
    ]
    partes.extend(secrets.choice(alfabeto) for _ in range(max(largo - len(partes), 0)))
    random.shuffle(partes)
    return "".join(partes)


@router.put("/mi-password")
async def cambiar_mi_password(body: CambioPasswordIn,
                              admin: dict = Depends(require_admin)):
    """Cada administrador cambiaSU contrasena: valido la actual primero.

    Exige sesion de admin (cualquier rol) pero SOLO toca la cuenta del
    token: cambiar la de otro por esta via seria un agujero.
    """
    documento = admin_coleccion.find_one(
        {"email": admin["email"]}, {"password": 1})
    if not documento:
        raise HTTPException(status_code=404, detail="Administrador no encontrado")
    guardada = (documento.get("password") or "")
    if not bcrypt.checkpw(body.actual.encode("utf-8"), guardada.encode("utf-8")):
        raise HTTPException(status_code=403, detail="La contraseña actual no es correcta")
    hash_nuevo = _hash_contrasena_nueva(body.nueva)
    admin_coleccion.update_one({"_id": documento["_id"]},
                               {"$set": {"password": hash_nuevo,
                                         "updated_at": datetime.utcnow()}})
    logger.info("Contrasena cambiada (propia) de %s", admin["email"])
    return {"ok": True, "message": "Contraseña actualizada"}


@router.put("/users/{user_id}/password")
async def asignar_password(user_id: str,
                           body: Optional[PasswordAsignadaIn] = None,
                           admin: dict = Depends(REQUIERE_SUPER)):
    """El super_admin pide una contrasena nueva PARA OTRO administrador.

    Si no envia `nueva`, el backend la genera y la devuelve UNA VEZ (despues
    no es recuperable: solo se puede pedir otro reset). Es el flujo "yo solo
    la solicito": el operador la recibe por un canal seguro del super.
    """
    body = body or PasswordAsignadaIn()
    if not ObjectId.is_valid(user_id):
        raise HTTPException(status_code=400, detail="Id invalido")
    objetivo = admin_coleccion.find_one(
        {"_id": ObjectId(user_id)}, {"email": 1, "rol": 1})
    if not objetivo:
        raise HTTPException(status_code=404, detail="Administrador no encontrado")
    contraseña = (body.nueva or "").strip() or _generar_contraseña()
    hash_nuevo = _hash_contrasena_nueva(contraseña)
    admin_coleccion.update_one({"_id": objetivo["_id"]},
                               {"$set": {"password": hash_nuevo,
                                         "updated_at": datetime.utcnow()}})
    logger.info("Contrasena asignada a %s por %s",
                objetivo.get("email"), admin["email"])
    return {"ok": True,
            "password_generada": contraseña,
            "message": "Contraseña asignada a %s. Guardala: no se volverá a "
                       "mostrar." % objetivo.get("email")}


# ===================== PERFIL DEL ADMIN =====================

def require_admin_super():  # mantenido aqui por el import legacy del panel
    return REQUIERE_SUPER


@router.get("/perfil")
async def perfil_admin(admin: dict = Depends(require_admin)):
    """Perfil del administrador que entra: email y rol para el panel.

    Backfill del super: si la cuenta es la del super vigente sabado oleh
    campo rol, se asigna en el momento, sin script de migracion.
    """
    if admin["email"].strip().lower() == SUPER_EMAIL and \
            (admin.get("rol") or "").strip().lower() != ROL_SUPER:
        admin_coleccion.update_one(
            {"email": admin["email"]},
            {"$set": {"rol": ROL_SUPER, "updated_at": datetime.utcnow()}})
        admin["rol"] = ROL_SUPER
    return {"email": admin["email"], "rol": admin.get("rol") or "",
            "nombre": (admin_coleccion.find_one({"email": admin["email"]},
                                                {"nombre": 1}) or {}).get("nombre")}


@router.get("/choferes")
async def listar_choferes(estado: Optional[str] = None, q: Optional[str] = None,
                          admin: dict = Depends(require_admin)):
    """Choferes con su estado de habilitacion. Filtros opcionales por estado y texto."""
    # Acepta singular y plural (pendiente/pendientes, aprobado/aprobados, ...)
    if estado:
        estado = estado.strip().lower()
        if estado.endswith("s") and estado[:-1] in ESTADOS_VALIDOS:
            estado = estado[:-1]
    if estado and estado not in ESTADOS_VALIDOS:
        raise HTTPException(status_code=400,
                            detail=f"Estado invalido. Opciones: {', '.join(ESTADOS_VALIDOS)}")

    query = {}
    if q:
        texto = q.strip()
        query["$or"] = [
            {"email": {"$regex": texto, "$options": "i"}},
            {"Nombre": {"$regex": texto, "$options": "i"}},
            {"Apellidos": {"$regex": texto, "$options": "i"}},
        ]

    docs = list(chofer_coleccion.find(query, {"password": 0}).sort("created_at", -1))
    choferes = [_chofer_out(d) for d in docs]

    if estado:
        choferes = [c for c in choferes if c["estado"] == estado]
    return {
        "total": len(choferes),
        "pendientes": sum(1 for c in choferes if c["estado"] == ESTADO_PENDIENTE),
        "aprobados": sum(1 for c in choferes if c["estado"] == ESTADO_APROBADO),
        "rechazados": sum(1 for c in choferes if c["estado"] == ESTADO_RECHAZADO),
        "choferes": choferes,
    }


@router.get("/choferes/pendientes")
async def choferes_pendientes(admin: dict = Depends(require_admin)):
    """Solo los choferes que el administrador aun tiene por habilitar."""
    docs = list(chofer_coleccion.find({"estado_habilitacion": ESTADO_PENDIENTE},
                                      {"password": 0}).sort("created_at", 1))
    return {"total": len(docs), "choferes": [_chofer_out(d) for d in docs]}


@router.post("/choferes/{driver_id}/estado")
async def cambiar_estado(driver_id: str, body: EstadoChoferIn, admin: dict = Depends(REQUIERE_OPERADOR_REGISTROS)):
    """Habilita o rechaza a un chofer (control de acceso a la app)."""
    if body.estado not in ESTADOS_VALIDOS:
        if isinstance(body.estado, str):
            candidato = body.estado.strip().lower()
            if candidato.endswith("s") and candidato[:-1] in ESTADOS_VALIDOS:
                body.estado = candidato[:-1]
    if body.estado not in ESTADOS_VALIDOS:
        raise HTTPException(status_code=400,
                            detail=f"Estado invalido. Opciones: {', '.join(ESTADOS_VALIDOS)}")
    if not ObjectId.is_valid(driver_id):
        raise HTTPException(status_code=400, detail="Id de chofer inválido")

    doc = chofer_coleccion.find_one({"_id": ObjectId(driver_id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")

    ahora = datetime.utcnow()
    update = {
        "estado_habilitacion": body.estado,
        "revisado_por": admin["email"],
        "revisado_at": ahora,
        "updated_at": ahora,
    }
    if body.motivo:
        update["motivo_habilitacion"] = body.motivo
    elif body.estado == ESTADO_APROBADO:
        update["motivo_habilitacion"] = None

    if body.estado == ESTADO_APROBADO:
        resumen_docs = _documentos_de(doc)
        if not resumen_docs["completo"]:
            raise HTTPException(
                status_code=400,
                detail=("El chofer no tiene todas las fotos obligatorias: %s"
                        % ", ".join(resumen_docs["faltan"])))
        update["Enable"] = True
        update["status"] = "active"
        update["documents_verified"] = True
    else:
        # Rechazar o volver a pendiente deja la cuenta bloqueada para el login.
        # NO se borra ni se anonimiza: se conservan nombre, correo y telefono
        # para auditoria y soporte.
        update["Enable"] = False
        if body.estado == ESTADO_CORRECCION:
            update["status"] = "needs_correction"
            update["missing_fields"] = body.missing_fields or []
        elif body.estado == ESTADO_RECHAZADO:
            update["status"] = "rejected"
        else:
            update["status"] = "pending_review"
        update["documents_verified"] = False

    chofer_coleccion.update_one({"_id": doc["_id"]}, {"$set": update})
    return {
        "ok": True,
        "driver_id": driver_id,
        "nombre": " ".join(filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip(),
        "estado": body.estado,
        "message": {
            ESTADO_APROBADO: "Chofer habilitado: ya puede entrar a la app",
            ESTADO_RECHAZADO: "Chofer rechazado: no puede entrar a la app",
            ESTADO_CORRECCION: "Chofer marcado para corrección: debe reenviar los datos",
            ESTADO_PENDIENTE: "Chofer devuelto a pendiente",
        }[body.estado],
    }


@router.delete("/drivers/{driver_id}")
async def eliminar_chofer(driver_id: str, admin: dict = Depends(REQUIERE_SUPER)):
    """Borrado definitivo (hard delete) de un chofer de la plataforma."""
    if not ObjectId.is_valid(driver_id):
        raise HTTPException(status_code=400, detail="Id de chofer inválido")
    doc = chofer_coleccion.find_one({"_id": ObjectId(driver_id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")

    from services.fotos_nube import borrar as _borrar_foto
    # Fotos de documentos del registro.
    for ref in (doc.get("documentos") or []):
        if isinstance(ref, dict):
            _borrar_foto(ref.get("nube_public_id"))
    # Vehiculos de Mi Garaje y sus fotos.
    for v in chofer_db["vehiculos"].find({"driver_id": str(doc["_id"])}):
        for foto in (v.get("fotos") or {}).values():
            if isinstance(foto, dict):
                _borrar_foto(foto.get("public_id"))
    chofer_db["vehiculos"].delete_many({"driver_id": str(doc["_id"])})
    # El documento del chofer.
    chofer_coleccion.delete_one({"_id": doc["_id"]})
    return {
        "ok": True,
        "driver_id": driver_id,
        "nombre": " ".join(filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip(),
        "message": "Chófer eliminado definitivamente",
    }

@router.get("/trips/diarios")
async def viajes_diarios(dias: int = 7, hasta: Optional[str] = None,
                        admin: dict = Depends(require_admin)):
    """Una fila por dia: cuantos viajes se dieron y cuanto facturaron."""
    try:
        dias = max(1, min(int(dias), 90))
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="El parametro 'dias' debe ser un numero")

    fin = _validar_fecha(hasta)
    inicio = fin - timedelta(days=dias - 1)

    sql = """
        SELECT
            requested_at::date                       AS dia,
            COUNT(*)                                 AS total,
            COUNT(*) FILTER (WHERE status = 'completed')   AS completados,
            COUNT(*) FILTER (WHERE status = 'cancelled')   AS cancelados,
            COUNT(*) FILTER (WHERE status = 'expired')     AS expirados,
            COUNT(*) FILTER (WHERE status = 'requested')   AS solicitados,
            COUNT(*) FILTER (WHERE status IN ('accepted', 'driver_on_the_way', 'driver_arrived')) AS asignados,
            COUNT(*) FILTER (WHERE status = 'in_progress')  AS en_curso,
            COALESCE(SUM(total_fare) FILTER (WHERE status = 'completed'), 0) AS facturado,
            COALESCE(AVG(total_fare) FILTER (WHERE status = 'completed'), 0) AS ticket_promedio,
            COALESCE(SUM(distance_km) FILTER (WHERE status = 'completed'), 0) AS km_recorridos,
            COUNT(DISTINCT driver_id) FILTER (WHERE status = 'completed')      AS choferes
          FROM trips
         WHERE requested_at::date BETWEEN %s AND %s
         GROUP BY dia
         ORDER BY dia
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, (inicio, fin))
        filas = [dict(r) for r in cur.fetchall()]
        cur.close()

    por_dia = {str(f["dia"]): f for f in filas}
    filas = []
    for i in range(dias):
        d = inicio + timedelta(days=i)
        f = por_dia.get(str(d), {})
        filas.append({
            "dia": str(d),
            "total": int(f.get("total") or 0),
            "completados": int(f.get("completados") or 0),
            "cancelados": int(f.get("cancelados") or 0),
            "expirados": int(f.get("expirados") or 0),
            "solicitados": int(f.get("solicitados") or 0),
            "asignados": int(f.get("asignados") or 0),
            "en_curso": int(f.get("en_curso") or 0),
            "facturado": round(float(f.get("facturado") or 0), 2),
            "ticket_promedio": round(float(f.get("ticket_promedio") or 0), 2),
            "km_recorridos": round(float(f.get("km_recorridos") or 0), 2),
            "choferes": int(f.get("choferes") or 0),
        })

    return {
        "desde": str(inicio),
        "hasta": str(fin),
        "dias": filas,
        "totales": {
            "viajes": sum(f["total"] for f in filas),
            "completados": sum(f["completados"] for f in filas),
            "cancelados": sum(f["cancelados"] for f in filas),
            "expirados": sum(f["expirados"] for f in filas),
            "facturado": round(sum(f["facturado"] for f in filas), 2),
            "km_recorridos": round(sum(f["km_recorridos"] for f in filas), 2),
        },
    }


@router.delete("/trips/{trip_id}")
async def eliminar_viaje(trip_id: str, admin: dict = Depends(REQUIERE_SUPER)):
    """Elimina un viaje (pensado para viajes de PRUEBA).

    Un viaje de prueba completado contamina las ganancias del chofer y los
    totales del panel, y no hay forma de deshacerlo desde las apps. Solo se
    permite borrar viajes ya cerrados: si estuviera activo, el chofer quedaria
    atascado en `on_trip`.
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT trip_id, driver_id, client_id, status, total_fare
              FROM trips WHERE trip_id = %s FOR UPDATE
            """,
            (trip_id,),
        )
        fila = cur.fetchone()
        if not fila:
            cur.close()
            raise HTTPException(status_code=404, detail="Viaje no encontrado")
        if fila["status"] not in ("completed", "cancelled", "expired"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="Solo se pueden borrar viajes cerrados",
            )
        # `transactions.trip_id` tiene FK sin ON DELETE: se limpia primero.
        cur.execute("DELETE FROM transactions WHERE trip_id = %s", (trip_id,))
        cur.execute("DELETE FROM trips WHERE trip_id = %s", (trip_id,))
        conn.commit()
        cur.close()

    logger.info(
        "Viaje %s eliminado por %s (estado=%s, chofer=%s)",
        trip_id, admin.get("email"), fila["status"], fila["driver_id"],
    )
    return {
        "deleted": trip_id,
        "status": fila["status"],
        "driver_id": fila["driver_id"],
        "total_fare": float(fila["total_fare"] or 0),
    }


@router.get("/trips/dia")
async def viajes_del_dia(fecha: Optional[str] = None, admin: dict = Depends(require_admin)):
    """Detalle de los viajes solicitados en un dia."""
    dia = _validar_fecha(fecha)
    sql = """
        SELECT trip_id, client_id, driver_id, status,
               request_address, dropoff_address,
               vehicle_type, num_pasajes, payment_method, equipaje, mascota,
               distance_km, duration_secs,
               base_fare, distance_fare, precio_estimado, total_fare, tip, currency,
               requested_at, started_at, completed_at
          FROM trips
         WHERE requested_at::date = %s
         ORDER BY requested_at DESC
         LIMIT 500
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, (dia,))
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()

    for r in rows:
        for k in ("requested_at", "started_at", "completed_at"):
            if isinstance(r.get(k), datetime):
                r[k] = r[k].isoformat()
        for k in ("distance_km", "base_fare", "distance_fare",
                  "precio_estimado", "total_fare", "tip"):
            if r.get(k) is not None:
                r[k] = float(r[k])
    return {"fecha": str(dia), "total": len(rows), "viajes": rows}


@router.get("/trips/resumen")
async def resumen_del_dia(fecha: Optional[str] = None, admin: dict = Depends(require_admin)):
    """Totales rapidos del dia, para el encabezado de la app."""
    dia = _validar_fecha(fecha)
    sql = """
        SELECT
            COUNT(*)                                              AS viajes,
            COUNT(*) FILTER (WHERE status = 'completed')          AS completados,
            COUNT(*) FILTER (WHERE status = 'cancelled')          AS cancelados,
            COUNT(*) FILTER (WHERE status = 'expired')            AS expirados,
            COUNT(*) FILTER (WHERE status = 'requested')          AS solicitados,
            COUNT(*) FILTER (WHERE status IN ('accepted','driver_on_the_way','driver_arrived','in_progress')) AS activos,
            COALESCE(SUM(total_fare) FILTER (WHERE status = 'completed'), 0) AS facturado,
            COALESCE(SUM(distance_km) FILTER (WHERE status = 'completed'), 0) AS km,
            COUNT(DISTINCT driver_id)                             AS choferes,
            COALESCE(SUM(distance_fare) FILTER (WHERE status = 'completed'), 0)
                                                                 AS ingreso_choferes
          FROM trips
         WHERE requested_at::date = %s
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, (dia,))
        row = dict(cur.fetchone() or {})
        cur.close()

    out = {"fecha": str(dia)}
    for k, v in row.items():
        out[k] = int(v) if isinstance(v, int) else round(float(v or 0), 2)
    return out


@router.get("/choferes/top")
async def choferes_top(fecha: Optional[str] = None, limite: int = 10,
                       admin: dict = Depends(require_admin)):
    """Choferes con mas viajes completados en un dia."""
    dia = _validar_fecha(fecha)
    sql = """
        SELECT driver_id,
               COUNT(*)                                    AS viajes,
               COALESCE(SUM(total_fare), 0)               AS facturado,
               COALESCE(SUM(distance_km), 0)              AS km
          FROM trips
         WHERE requested_at::date = %s
           AND status = 'completed'
           AND driver_id IS NOT NULL
         GROUP BY driver_id
         ORDER BY viajes DESC, facturado DESC
         LIMIT %s
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, (dia, min(limite, 50)))
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()

    for r in rows:
        doc = chofer_coleccion.find_one({"_id": ObjectId(r["driver_id"])}) if ObjectId.is_valid(r["driver_id"]) else None
        r["nombre"] = " ".join(filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip() if doc else None
        r["facturado"] = round(float(r["facturado"]), 2)
        r["km"] = round(float(r["km"]), 2)
    return {"fecha": str(dia), "choferes": rows}


# ===================== MONITOR / CONTROL MANUAL DE VIAJES =====================

ESTADOS_ACTIVOS = ("requested", "accepted", "driver_on_the_way",
                   "driver_arrived", "in_progress")


def _nombre_persona(doc: Optional[dict]) -> Optional[str]:
    if not doc:
        return None
    nombre = " ".join(filter(None, [
        doc.get("Nombre") or doc.get("nombre"),
        doc.get("Apellidos") or doc.get("apellidos"),
    ])).strip()
    if nombre:
        return nombre
    profile = doc.get("profile") or {}
    return profile.get("name") or doc.get("full_name") or doc.get("email")


def _nombre_de(coleccion, id_str) -> Optional[str]:
    try:
        if not id_str or not ObjectId.is_valid(id_str):
            return None
        return _nombre_persona(coleccion.find_one({"_id": ObjectId(id_str)}))
    except Exception:
        return None


def _json_trip(row: dict) -> dict:
    """Convierte Decimal/fecha de Postgres a tipos que entiende el panel."""
    salida = {}
    for k, v in row.items():
        if isinstance(v, datetime):
            salida[k] = v.isoformat()
        elif isinstance(v, Decimal):
            salida[k] = float(v)
        else:
            salida[k] = v
    return salida


class ForzarFinIn(BaseModel):
    """El precio NO se manda: lo calcula el backend con las tarifas vigentes."""
    dropoff_lat: Optional[float] = None
    dropoff_lng: Optional[float] = None
    tip: float = 0.0


class ForzarCancelacionIn(BaseModel):
    """Motivo visible para el pasajero en el aviso de cancelación."""
    motivo: Optional[str] = None


async def _avisar_estado_admin(
    trip_id: str,
    trip: Optional[dict],
    status: str,
    previous_status: Optional[str],
    admin_email: Optional[str],
    extra: Optional[dict] = None,
) -> None:
    """Avisa un cambio forzado por el administrador a Cliente y Chófer.

    Se publica en los TRES canales que existen de verdad en el backend:

      * `trip:{trip_id}:events`  -> canal del viaje, lo escucha el cliente
        suscrito (y es el que ya usaba `publish_trip_event`).
      * `ws:cliente:{client_id}` -> canal personal del pasajero, por si el
        cliente aún no se había suscrito al viaje.
      * `ws:chofer:{driver_id}`  -> canal personal del chófer; su app escucha
        aquí y así se entera de un cambio hecho desde el panel sin esperar al
        sondeo de 4 s.

    El evento es el mismo `trip_status_updated` que publica la app del chófer
    al deslizar, de modo que el stepper y el panel inferior del cliente
    reaccionan igual venga el cambio de donde venga.
    """
    viaje = trip or {}
    client_id = viaje.get("client_id")
    driver_id = viaje.get("driver_id")

    cuerpo: dict = {
        "trip_id": trip_id,
        "event": "trip_status_updated",
        "status": status,
        "previous_status": previous_status,
        "driver_id": driver_id,
        "client_id": client_id,
        "forzado_por": admin_email,
    }
    if extra:
        cuerpo.update(extra)

    # 1) Canal del VIAJE (cliente ya suscrito). `publish_trip_event` envuelve
    #    el mensaje con `event`, pero el cuerpo ya trae el suyo: se publica
    #    aquí directo para no duplicar claves.
    try:
        await publish_trip_event(trip_id, "trip_status_updated", cuerpo)
    except Exception as exc:
        logger.warning(
            "admin: no se pudo publicar el estado %s del viaje %s: %s",
            status, trip_id, exc)

    # 2) Canal PERSONAL del cliente.
    if client_id:
        try:
            await garnet.publish(
                f"ws:cliente:{client_id}", json.dumps(cuerpo, default=str))
        except Exception as exc:
            logger.warning(
                "admin: no se pudo avisar al cliente %s del viaje %s: %s",
                client_id, trip_id, exc)

    # 3) Canal PERSONAL del chófer.
    if driver_id:
        try:
            await garnet.publish(
                f"ws:chofer:{driver_id}", json.dumps(cuerpo, default=str))
        except Exception as exc:
            logger.warning(
                "admin: no se pudo avisar al chofer %s del viaje %s: %s",
                driver_id, trip_id, exc)


@router.post("/trips/{trip_id}/force-cancel")
async def forzar_cancelacion(
    trip_id: str,
    body: Optional[ForzarCancelacionIn] = None,
    admin: dict = Depends(REQUIERE_OPERADOR_VIAJES),
):
    """Cancela un viaje activo desde el control de viajes del panel.

    Es la salida cuando el chofer ya agotó sus 3 cancelaciones del día (o no
    puede hacerlo desde la app). NO descuenta ninguna de las 3: la decisión es
    del operador. Libera al chofer y avisa al pasajero por WebSocket.
    """
    motivo = ((body.motivo if body else None) or "").strip() or \
        "Cancelado por el operador de viajes"
    _asegurar_columnas_cancelacion()

    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM trips WHERE trip_id = %s FOR UPDATE",
                    (trip_id,))
        trip = cur.fetchone()
        if not trip:
            cur.close()
            raise HTTPException(status_code=404, detail="Viaje no encontrado")
        if trip["status"] in ("completed", "cancelled", "expired"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="No se puede cancelar un viaje en estado '%s'"
                       % trip["status"])

        cur.execute(
            """
            UPDATE trips
               SET status = 'cancelled',
                   cancelled_by = 'admin',
                   cancellation_reason = %s,
                   completed_at = NOW()
             WHERE trip_id = %s
            """,
            (motivo, trip_id),
        )
        conn.commit()
        cur.close()

    driver_id = trip.get("driver_id")
    if driver_id:
        try:
            await set_driver_status(driver_id, "available")
        except Exception as e:
            logger.warning("force-cancel: no se pudo liberar chofer %s: %s",
                           driver_id, e)
    try:
        await publish_trip_event(trip_id, "trip_cancelled", {
            "reason": motivo,
            "cancelled_by": "admin",
            "forced_by": admin.get("email"),
        })
    except Exception as e:
        logger.warning("force-cancel: no se pudo publicar evento: %s", e)

    # El chófer también tiene que soltar el viaje: su app escucha su canal
    # personal y el evento genérico le dice que el viaje ya no está vivo.
    await _avisar_estado_admin(
        trip_id, trip, "cancelled", trip.get("status"), admin.get("email"),
        {"cancelled_by": "admin", "reason": motivo})

    return {
        "ok": True,
        "trip_id": trip_id,
        "status": "cancelled",
        "message": "Viaje cancelado por el operador",
        "motivo": motivo,
    }


@router.get("/trips/active")
async def viajes_activos(admin: dict = Depends(require_admin)):
    """Viajes pendientes o en curso, para el monitor de emergencias."""
    sql = """
        SELECT trip_id, client_id, driver_id, status,
               request_address, dropoff_address, vehicle_type,
               distance_km, precio_estimado, requested_at, started_at,
               hora_llegada,
               ST_Y(dropoff_location::geometry) AS dropoff_lat,
               ST_X(dropoff_location::geometry) AS dropoff_lng
          FROM trips
         WHERE status IN ('requested', 'accepted', 'driver_on_the_way',
                          'driver_arrived', 'in_progress')
         ORDER BY requested_at DESC
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
        item["client_name"] = _nombre_de(cliente_coleccion, r.get("client_id"))
        item["driver_name"] = _nombre_de(chofer_coleccion, r.get("driver_id"))
        item["distance_km"] = (round(float(r["distance_km"]), 2)
                               if r.get("distance_km") is not None else None)
        item["precio_estimado"] = (float(r["precio_estimado"])
                                   if r.get("precio_estimado") is not None else None)
        viajes.append(item)

    return {"total": len(viajes), "viajes": viajes}


@router.post("/trips/{trip_id}/force-confirm")
async def forzar_confirmacion(
    trip_id: str,
    admin: dict = Depends(REQUIERE_OPERADOR_VIAJES),
):
    """Marca el viaje como `driver_on_the_way` (el chófer confirmó y va).

    Es el paso que la app del chófer hace al deslizar «Confirmar viaje». Se
    usa cuando el chófer se quedó sin conexión o no puede tocar el teléfono.
    """
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM trips WHERE trip_id = %s FOR UPDATE",
                    (trip_id,))
        trip = cur.fetchone()
        if not trip:
            cur.close()
            raise HTTPException(status_code=404, detail="Viaje no encontrado")

        anterior = trip["status"]
        if anterior == "driver_on_the_way":
            cur.close()
            return {"trip_id": trip_id, "status": anterior,
                    "message": "El viaje ya estaba en camino"}
        if anterior in ("completed", "cancelled", "expired"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="No se puede confirmar un viaje en estado '%s'" % anterior)
        if anterior not in ("requested", "accepted"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="Solo se confirma un viaje solicitado o aceptado "
                       "(estado actual: '%s')" % anterior)
        if not trip.get("driver_id"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="El viaje no tiene chófer asignado; asígnalo primero")

        cur.execute(
            """
            UPDATE trips
               SET status = 'driver_on_the_way'
             WHERE trip_id = %s
             RETURNING *
            """,
            (trip_id,),
        )
        actualizado = dict(cur.fetchone())
        conn.commit()
        cur.close()

    driver_id = trip.get("driver_id")
    if driver_id:
        try:
            await set_driver_status(driver_id, "busy")
        except Exception as e:
            logger.warning("force-confirm: no se pudo marcar chófer %s: %s",
                           driver_id, e)
    try:
        await publish_trip_event(trip_id, "driver_on_the_way",
                                 {"forced_by": admin.get("email")})
    except Exception as e:
        logger.warning("force-confirm: no se pudo publicar evento: %s", e)

    await _avisar_estado_admin(
        trip_id, trip, "driver_on_the_way", anterior, admin.get("email"))

    return {**_json_trip(actualizado),
            "message": "Viaje confirmado manualmente por el administrador",
            "forzado_por": admin.get("email")}


@router.post("/trips/{trip_id}/force-arrive")
async def forzar_llegada(
    trip_id: str,
    admin: dict = Depends(REQUIERE_OPERADOR_VIAJES),
):
    """Marca el viaje como `driver_arrived` (el chófer llegó a recogida)."""
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM trips WHERE trip_id = %s FOR UPDATE",
                    (trip_id,))
        trip = cur.fetchone()
        if not trip:
            cur.close()
            raise HTTPException(status_code=404, detail="Viaje no encontrado")

        anterior = trip["status"]
        if anterior == "driver_arrived":
            cur.close()
            return {"trip_id": trip_id, "status": anterior,
                    "message": "El viaje ya estaba marcado como llegado"}
        if anterior in ("completed", "cancelled", "expired"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="No se puede marcar llegada en un viaje '%s'" % anterior)
        if anterior not in ("accepted", "driver_on_the_way"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="Solo se marca llegada desde un viaje aceptado o en "
                       "camino (estado actual: '%s')" % anterior)
        if not trip.get("driver_id"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="El viaje no tiene chófer asignado")

        cur.execute(
            """
            UPDATE trips
               SET status = 'driver_arrived',
                   hora_llegada = COALESCE(hora_llegada, NOW())
             WHERE trip_id = %s
             RETURNING *
            """,
            (trip_id,),
        )
        actualizado = dict(cur.fetchone())
        conn.commit()
        cur.close()

    try:
        await publish_trip_event(trip_id, "driver_arrived",
                                 {"forced_by": admin.get("email")})
    except Exception as e:
        logger.warning("force-arrive: no se pudo publicar evento: %s", e)

    await _avisar_estado_admin(
        trip_id, trip, "driver_arrived", anterior, admin.get("email"))

    return {**_json_trip(actualizado),
            "message": "Llegada marcada manualmente por el administrador",
            "forzado_por": admin.get("email")}


@router.post("/trips/{trip_id}/force-start")
async def forzar_inicio(trip_id: str, admin: dict = Depends(REQUIERE_OPERADOR_VIAJES)):
    """Pone el viaje 'en curso' aunque el chofer no tenga conexion."""
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM trips WHERE trip_id = %s FOR UPDATE", (trip_id,))
        trip = cur.fetchone()
        if not trip:
            cur.close()
            raise HTTPException(status_code=404, detail="Viaje no encontrado")

        if trip["status"] == "in_progress":
            cur.close()
            return {"trip_id": trip_id, "status": "in_progress",
                    "message": "El viaje ya estaba en curso"}

        if trip["status"] not in ("requested", "accepted", "driver_on_the_way",
                                  "driver_arrived"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="No se puede iniciar un viaje en estado '%s'" % trip["status"])

        if not trip.get("driver_id"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="El viaje no tiene chofer asignado; no se puede iniciar")

        cur.execute(
            """
            UPDATE trips
               SET status = 'in_progress',
                   started_at = COALESCE(started_at, NOW())
             WHERE trip_id = %s
             RETURNING trip_id, status, started_at
            """,
            (trip_id,),
        )
        actualizado = dict(cur.fetchone())
        conn.commit()
        cur.close()

    driver_id = trip.get("driver_id")
    if driver_id:
        try:
            await set_driver_status(driver_id, "on_trip")
        except Exception as e:
            logger.warning("force-start: no se pudo marcar chofer %s: %s", driver_id, e)
    try:
        await publish_trip_event(trip_id, "trip_started", {"forced_by": admin.get("email")})
    except Exception as e:
        logger.warning("force-start: no se pudo publicar evento: %s", e)

    # El chófer tiene que ver el deslizable en «Completar viaje» y el cliente
    # avanzar al paso 3 aunque el cambio lo haya hecho el panel.
    await _avisar_estado_admin(
        trip_id, trip, "in_progress", trip.get("status"), admin.get("email"))

    return {**_json_trip(actualizado),
            "message": "Viaje iniciado manualmente por el administrador",
            "forzado_por": admin.get("email")}


@router.post("/trips/{trip_id}/force-complete")
@router.post("/trips/{trip_id}/force-finish")
async def forzar_fin(
    trip_id: str,
    background: BackgroundTasks,
    body: Optional[ForzarFinIn] = None,
    admin: dict = Depends(REQUIERE_OPERADOR_VIAJES),
):
    """Cierra el viaje con el MISMO calculo de precio que el cierre normal.

    El administrador no escribe el precio: se calcula distancia, tiempo,
    comisiones y descuentos igual que cuando el chofer pulsa "Completar".
    """
    body = body or ForzarFinIn()

    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT trip_id, client_id, driver_id, status,
                   ST_Y(COALESCE(dropoff_location, request_location)::geometry) AS lat,
                   ST_X(COALESCE(dropoff_location, request_location)::geometry) AS lng
              FROM trips WHERE trip_id = %s
            """,
            (trip_id,),
        )
        trip = cur.fetchone()
        if not trip:
            cur.close()
            raise HTTPException(status_code=404, detail="Viaje no encontrado")

        estado_previo = trip["status"]
        if trip["status"] == "completed":
            cur.close()
            raise HTTPException(status_code=400, detail="El viaje ya esta completado")
        if trip["status"] in ("cancelled", "expired"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="No se puede completar un viaje '%s'" % trip["status"])
        if not trip.get("driver_id"):
            cur.close()
            raise HTTPException(
                status_code=400,
                detail="El viaje no tiene chofer asignado; no se puede completar")

        # Si aun no estaba en curso (el chofer perdio la conexion antes de
        # pulsar "Iniciar"), se pasa a in_progress para que complete_trip pueda
        # ejecutar el mismo calculo. La distancia ya esta guardada desde la
        # creacion del viaje, asi que el precio por km no se pierde.
        if trip["status"] != "in_progress":
            cur.execute(
                """
                UPDATE trips
                   SET status = 'in_progress',
                       started_at = COALESCE(started_at, NOW())
                 WHERE trip_id = %s
                """,
                (trip_id,),
            )
            conn.commit()
        cur.close()

    lat = body.dropoff_lat if body.dropoff_lat is not None else trip.get("lat")
    lng = body.dropoff_lng if body.dropoff_lng is not None else trip.get("lng")
    if lat is None or lng is None:
        raise HTTPException(
            status_code=400,
            detail="El viaje no tiene destino guardado; envía dropoff_lat y dropoff_lng")

    try:
        result = complete_trip(
            trip_id=trip_id,
            dropoff_lat=float(lat),
            dropoff_lng=float(lng),
            tip=float(body.tip or 0),
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception:
        logger.exception("force-complete fallo para el viaje %s", trip_id)
        raise HTTPException(
            status_code=500,
            detail="No se pudo completar el viaje en el servidor. Revisa los logs.")

    driver_id = result.get("driver_id")
    if driver_id:
        try:
            await set_driver_status(driver_id, "available")
        except Exception as e:
            logger.warning("force-complete: no se pudo liberar chofer %s: %s",
                           driver_id, e)
        try:
            await publish_trip_event(trip_id, "trip_completed", {
                "total_fare": result.get("total_fare"),
                "currency": result.get("currency"),
                "forced_by": admin.get("email"),
            })
        except Exception as e:
            logger.warning("force-complete: no se pudo publicar evento: %s", e)
        try:
            bonus = apply_daily_bonus(driver_id)
            if bonus.get("bonus_applied"):
                result["bonus"] = bonus
        except Exception as e:
            logger.exception("force-complete: error aplicando bono: %s", e)

    # El recibo viaja en el evento: la app del chófer lo abre tal cual, sin
    # una segunda petición ni esperar al sondeo. `result` trae el desglose
    # completo que devuelve `complete_trip` (base, distancia, tiempo, comisión).
    await _avisar_estado_admin(
        trip_id, trip, "completed", estado_previo, admin.get("email"),
        {
            "recibo": result,
            "total_fare": result.get("total_fare"),
            "currency": result.get("currency"),
        })

    background.add_task(daily_trip_metrics)

    return {
        "trip_id": trip_id,
        "status": result.get("status"),
        "precio_final": result.get("total_fare"),
        "moneda": result.get("currency", "CUP"),
        "distancia_km": result.get("distance_km"),
        "duracion_segundos": result.get("duration_secs"),
        "descuento_cliente": result.get("descuento_cliente"),
        "forzado_por": admin.get("email"),
        "message": "Viaje completado manualmente. Precio calculado por el backend.",
        "viaje": _json_trip(result),
    }


# ===================== LOGIN DEDICADO DEL PANEL =====================
# Se usa exclusivamente por el panel web. A diferencia de `/login` (compartido
# por pasajeros, choferes y administradores), este endpoint MIRA SOLO la base
# de administradores: el mismo correo usado en las apps no puede desviarse a la
# cuenta de chofer/cliente y devolver un token del tipo equivocado.


class AdminLoginIn(BaseModel):
    email: str
    password: str


@router.post("/login", response_model=None)
async def login_admin_panel(body: AdminLoginIn):
    email = (body.email or "").strip().lower()
    if not email or not body.password:
        raise HTTPException(status_code=400, detail="Escribe tu correo y tu contraseña")

    admin = admin_coleccion.find_one({"email": {"$regex": "^%s$" % re.escape(email),
                                                "$options": "i"}})
    if not admin:
        raise HTTPException(status_code=401, detail="Correo o contraseña incorrectos")

    guardada = (admin.get("password") or "")
    try:
        valida = bcrypt.checkpw(body.password.encode("utf-8"), guardada.encode("utf-8"))
    except Exception:
        valida = False
    if not valida:
        raise HTTPException(status_code=401, detail="Correo o contraseña incorrectos")

    if admin.get("Enable") is False:
        raise HTTPException(status_code=403, detail="Tu cuenta está deshabilitada")

    # Backfill del super (sin script de migracion).
    rol = (admin.get("rol") or "").strip().lower()
    if email == SUPER_EMAIL and rol != ROL_SUPER:
        admin_coleccion.update_one(
            {"_id": admin["_id"]},
            {"$set": {"rol": ROL_SUPER, "updated_at": datetime.utcnow()}})
        rol = ROL_SUPER

    token_data = {"sub": admin.get("email") or email, "id": str(admin["_id"])}
    access = create_access_token(token_data, app="admin")
    refresh = create_refresh_token(token_data, app="admin")
    return {
        "access_token": access,
        "refresh_token": refresh,
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        "rol": rol or "admin",
    }

