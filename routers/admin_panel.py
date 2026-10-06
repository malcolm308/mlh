"""API del panel de administracion.

Consumida por la app de escritorio `desktop_admin/`:
    POST /admin/choferes/{id}/estado      habilitar / rechazar un chofer
    GET  /admin/choferes                 listado con filtro por estado
    GET  /admin/choferes/pendientes      solo los que aun no han sido habilitados
    GET  /admin/trips/diarios            viajes por dia (tabla de la app)
    GET  /admin/trips/dia                detalle de los viajes de un dia
    GET  /admin/trips/resumen            totales del dia
    GET  /admin/choferes/top             choferes con mas viajes del dia

Todos los endpoints exigen token de administrador.
"""
import logging
from datetime import date, datetime, timedelta
from typing import Optional

import psycopg2
import psycopg2.extras
from bson import ObjectId
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db
from db.Chofer.connection import chofer_db
from routers.Solicitud_de_viajes_v4 import get_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/admin", tags=["Administracion"])

chofer_coleccion = chofer_db.users
admin_coleccion = admin_db.users

# Los 10 documentos que el chofer debe subir en el registro
CAMPOS_DOCUMENTOS = [
    ("rostro", "Foto frontal de la cara"),
    ("carnet_frente", "Carnet de identidad (por delante)"),
    ("carnet_atras", "Carnet de identidad (por detras)"),
    ("licencia_frente", "Licencia de conducir (por delante)"),
    ("licencia_atras", "Licencia de conducir (por detras)"),
    ("circulacion", "Circulacion del vehiculo"),
    ("vehiculo_interior_frente", "Vehiculo por dentro (alante)"),
    ("vehiculo_interior_atras", "Vehiculo por dentro (atras)"),
    ("vehiculo_exterior_frente", "Vehiculo por fuera (delante)"),
    ("vehiculo_exterior_atras", "Vehiculo por fuera (atras)"),
]

# Estados de habilitacion de un chofer
ESTADO_PENDIENTE = "pendiente"
ESTADO_APROBADO = "aprobado"
ESTADO_RECHAZADO = "rechazado"
ESTADOS_VALIDOS = (ESTADO_PENDIENTE, ESTADO_APROBADO, ESTADO_RECHAZADO)


# ===================== AUTENTICACION =====================

def require_admin(authorization: Optional[str] = Header(None)) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Falta el token de administrador")
    payload = verify_admin_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token invalido o expirado")

    email = payload.get("sub")
    admin = admin_coleccion.find_one({"email": email}) if email else None
    if not admin:
        raise HTTPException(status_code=403, detail="La cuenta no es de administrador")
    return {"id": str(admin["_id"]), "email": email, "rol": admin.get("rol")}


# ===================== HELPERS =====================

def estado_de(doc: dict) -> str:
    """Estado de habilitacion del chofer.

    Los choferes dados de alta antes de existir este control no tienen el campo,
    asi que se consideran aprobados (no se bloquea a nadie que ya workings).
    """
    return doc.get("estado_habilitacion") or ESTADO_APROBADO


def _documentos_de(doc: dict) -> dict:
    """Resumen de los 10 documentos exigidos para el panel."""
    docs = doc.get("documentos") or []
    por_campo = {d.get("campo"): d for d in docs if isinstance(d, dict)}
    estado = {}
    faltan = []
    for campo, etiqueta in CAMPOS_DOCUMENTOS:
        ref = por_campo.get(campo)
        estado[campo] = {
            "etiqueta": etiqueta,
            "subido": bool(ref),
            "archivo": ref.get("archivo") if ref else None,
            "subido_at": ref.get("subido_at") if ref else None,
        }
        if not ref:
            faltan.append(etiqueta)
    return {
        "total": len(CAMPOS_DOCUMENTOS),
        "subidos": len(CAMPOS_DOCUMENTOS) - len(faltan),
        "faltan": faltan,
        "completo": not faltan,
        "detalle": estado,
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
async def cambiar_estado(driver_id: str, body: EstadoChoferIn, admin: dict = Depends(require_admin)):
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
        raise HTTPException(status_code=400, detail="Id de chofer invalido")

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
        # Rechazar o volver a pendiente deja la cuenta bloqueada para el login
        update["Enable"] = False
        update["status"] = "rejected" if body.estado == ESTADO_RECHAZADO \
            else "pending_review"
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
            ESTADO_PENDIENTE: "Chofer devuelto a pendiente",
        }[body.estado],
    }


# ===================== VIAJES POR DIA =====================

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
            COUNT(*) FILTER (WHERE status IN ('accepted', 'driver_arrived')) AS asignados,
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
            COUNT(*) FILTER (WHERE status IN ('accepted','driver_arrived','in_progress')) AS activos,
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
