"""Billetera (fondo) de los choferes.

Servicio de recargas y movimientos del fondo. El saldo vive en el documento del
chofer en MongoDB (campo `Fondo`), que es de donde ya descontan la comision del
15% y de donde salen las transferencias entre choferes. Aqui queda el libro de
movimientos (PostgreSQL) y los endpoints que consume la app de administracion.

Endpoints (todos requieren token de administrador salvo el saldo):
    GET  /billetera/saldo/{driver_id}          saldo de un chofer
    GET  /billetera/choferes                  lista corta para el buscador
    POST /billetera/recarga                   recarga de saldo (admin)
    POST /billetera/descargo                  debito manual (admin)
    GET  /billetera/movimientos               historial de movimientos
    GET  /billetera/resumen                   totales de recargas del dia
"""
import logging
from datetime import datetime
from typing import Optional

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field

from db.Administración.connection import admin_db
from db.Chofer.connection import chofer_db
from db.Administración.auth import verify_token as verify_admin_token
from routers.Solicitud_de_viajes_v4 import get_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/billetera", tags=["Billetera"])

chofer_coleccion = chofer_db.users          # los choferes viven en la BD Chofer
admin_coleccion = admin_db.users            # administradores

# Metodos de recarga que puede registrar el administrador
METODOS_RECARGA = ("efectivo", "transferencia", "pasarela", "promocion", "ajuste")


# ===================== MODELOS =====================

class RecargaIn(BaseModel):
    driver_id: Optional[str] = None
    email: Optional[str] = None
    monto: float = Field(..., gt=0)
    metodo: str = "efectivo"
    referencia: Optional[str] = None
    nota: Optional[str] = None


class DescargoIn(BaseModel):
    driver_id: str
    monto: float = Field(..., gt=0)
    metodo: str = "ajuste"
    nota: Optional[str] = None


# ===================== BASE DE DATOS =====================

def init_wallet_db():
    """Crea la tabla de movimientos de la billetera (idempotente)."""
    ddl = """
        CREATE TABLE IF NOT EXISTS wallet_movements (
            movement_id SERIAL PRIMARY KEY,
            driver_id VARCHAR(50) NOT NULL,
            admin_id VARCHAR(50),
            admin_email VARCHAR(200),
            tipo VARCHAR(20) NOT NULL,
            monto NUMERIC(12, 2) NOT NULL,
            saldo_anterior NUMERIC(12, 2) NOT NULL DEFAULT 0,
            saldo_nuevo NUMERIC(12, 2) NOT NULL DEFAULT 0,
            metodo VARCHAR(30) DEFAULT 'efectivo',
            referencia VARCHAR(200),
            nota TEXT,
            created_at TIMESTAMP DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS idx_wallet_mov_driver
            ON wallet_movements (driver_id, created_at DESC);
    """
    try:
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute(ddl)
            conn.commit()
            cur.close()
        logger.info("billetera: tabla wallet_movements lista")
    except Exception:
        logger.exception("billetera.init_wallet_db: no se pudo crear la tabla")


# ===================== AUTENTICACION ADMIN =====================

def require_admin(authorization: Optional[str] = Header(None)) -> dict:
    """Valida el token del administrador y devuelve {id, email}."""
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

def _driver_doc(identifier: str):
    """Busca un chofer por id o por email."""
    from bson import ObjectId
    from bson.errors import InvalidId

    ident = (identifier or "").strip()
    if not ident:
        return None

    if ObjectId.is_valid(ident):
        doc = chofer_coleccion.find_one({"_id": ObjectId(ident)})
        if doc:
            return doc
    return chofer_coleccion.find_one({"email": ident.lower()})


def _saldo(doc) -> float:
    return float(doc.get("Fondo") or doc.get("fondo") or 0)


def _registrar_movimiento(conn, driver_id, admin, tipo, monto, saldo_anterior,
                          saldo_nuevo, metodo, referencia, nota) -> int:
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO wallet_movements (
            driver_id, admin_id, admin_email, tipo, monto,
            saldo_anterior, saldo_nuevo, metodo, referencia, nota
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        RETURNING movement_id
        """,
        (driver_id, admin["id"], admin["email"], tipo, monto,
         round(saldo_anterior, 2), round(saldo_nuevo, 2), metodo,
         referencia, nota),
    )
    movement_id = cur.fetchone()[0]
    return movement_id


# ===================== ENDPOINTS =====================

@router.get("/saldo/{driver_id}")
async def get_saldo(driver_id: str, admin: dict = Depends(require_admin)):
    """Saldo actual del fondo de un chofer."""
    doc = _driver_doc(driver_id)
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    return {
        "driver_id": str(doc["_id"]),
        "nombre": " ".join(filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip(),
        "email": doc.get("email"),
        "saldo": round(_saldo(doc), 2),
        "currency": "CUP",
    }


@router.get("/choferes")
async def listar_choferes(q: Optional[str] = None, limit: int = 50,
                          admin: dict = Depends(require_admin)):
    """Lista corta de choferes para el buscador de la app de administracion."""
    query = {}
    if q:
        texto = q.strip()
        query["$or"] = [
            {"email": {"$regex": texto, "$options": "i"}},
            {"Nombre": {"$regex": texto, "$options": "i"}},
            {"Apellidos": {"$regex": texto, "$options": "i"}},
        ]
    docs = list(chofer_coleccion.find(query, {"password": 0}).limit(min(limit, 200)))
    return [
        {
            "driver_id": str(d["_id"]),
            "nombre": " ".join(filter(None, [d.get("Nombre"), d.get("Apellidos")])).strip(),
            "email": d.get("email"),
            "saldo": round(_saldo(d), 2),
        }
        for d in docs
    ]


@router.post("/recarga")
async def recargar(body: RecargaIn, admin: dict = Depends(require_admin)):
    """Recarga saldo al fondo de un chofer. Solo administradores."""
    identificador = body.driver_id or body.email
    if not identificador:
        raise HTTPException(status_code=400, detail="Indique driver_id o email del chofer")

    doc = _driver_doc(identificador)
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")

    metodo = (body.metodo or "efectivo").strip().lower()
    if metodo not in METODOS_RECARGA:
        raise HTTPException(
            status_code=400,
            detail=f"Metodo invalido. Opciones: {', '.join(METODOS_RECARGA)}",
        )

    driver_id = str(doc["_id"])
    monto = round(float(body.monto), 2)
    anterior = _saldo(doc)
    nuevo = round(anterior + monto, 2)

    try:
        chofer_coleccion.update_one({"_id": doc["_id"]}, {"$inc": {"Fondo": monto}})
        with get_connection() as conn:
            movement_id = _registrar_movimiento(
                conn, driver_id, admin, "recarga", monto, anterior, nuevo,
                metodo, body.referencia, body.nota,
            )
            conn.commit()
    except Exception as e:
        # Si fallo el registro del movimiento se revierte el saldo
        try:
            chofer_coleccion.update_one({"_id": doc["_id"]}, {"$inc": {"Fondo": -monto}})
        except Exception:
            logger.exception("No se pudo revertir la recarga de %s", driver_id)
        logger.exception("Fallo la recarga de %s", driver_id)
        raise HTTPException(status_code=500, detail=f"No se pudo registrar la recarga: {e}")

    return {
        "ok": True,
        "movement_id": movement_id,
        "driver_id": driver_id,
        "nombre": " ".join(filter(None, [doc.get("Nombre"), doc.get("Apellidos")])).strip(),
        "monto": monto,
        "saldo_anterior": round(anterior, 2),
        "saldo_nuevo": nuevo,
        "metodo": metodo,
        "message": f"Recarga de {monto} CUP aplicada",
    }


@router.post("/descargo")
async def descontar(body: DescargoIn, admin: dict = Depends(require_admin)):
    """Descuenta saldo del fondo de un chofer (ajuste o penalizacion)."""
    doc = _driver_doc(body.driver_id)
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")

    driver_id = str(doc["_id"])
    monto = round(float(body.monto), 2)
    anterior = _saldo(doc)
    if anterior < monto:
        raise HTTPException(status_code=400, detail="Saldo insuficiente para el debito")

    nuevo = round(anterior - monto, 2)
    try:
        chofer_coleccion.update_one({"_id": doc["_id"]}, {"$inc": {"Fondo": -monto}})
        with get_connection() as conn:
            movement_id = _registrar_movimiento(
                conn, driver_id, admin, "debito", -monto, anterior, nuevo,
                (body.metodo or "ajuste").lower(), None, body.nota,
            )
            conn.commit()
    except Exception as e:
        try:
            chofer_coleccion.update_one({"_id": doc["_id"]}, {"$inc": {"Fondo": monto}})
        except Exception:
            logger.exception("No se pudo revertir el debito de %s", driver_id)
        raise HTTPException(status_code=500, detail=f"No se pudo registrar el debito: {e}")

    return {
        "ok": True,
        "movement_id": movement_id,
        "driver_id": driver_id,
        "monto": -monto,
        "saldo_anterior": round(anterior, 2),
        "saldo_nuevo": nuevo,
        "message": f"Debito de {monto} CUP aplicado",
    }


@router.get("/movimientos")
async def movimientos(driver_id: Optional[str] = None, limit: int = 100,
                      admin: dict = Depends(require_admin)):
    """Historial de movimientos de la billetera."""
    sql = """
        SELECT movement_id, driver_id, admin_email, tipo, monto,
               saldo_anterior, saldo_nuevo, metodo, referencia, nota, created_at
          FROM wallet_movements
    """
    params = []
    if driver_id:
        doc = _driver_doc(driver_id)
        sql += " WHERE driver_id = %s"
        params.append(str(doc["_id"]) if doc else driver_id)
    sql += " ORDER BY created_at DESC, movement_id DESC LIMIT %s"
    params.append(min(limit, 500))

    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, params)
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()

    for r in rows:
        r["monto"] = float(r["monto"])
        r["saldo_anterior"] = float(r["saldo_anterior"])
        r["saldo_nuevo"] = float(r["saldo_nuevo"])
        if isinstance(r.get("created_at"), datetime):
            r["created_at"] = r["created_at"].isoformat()
    return rows


@router.get("/resumen")
async def resumen(admin: dict = Depends(require_admin)):
    """Totales de recargas del dia actual."""
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT
                COALESCE(SUM(monto) FILTER (WHERE tipo = 'recarga'), 0) AS recargado,
                COALESCE(SUM(-monto) FILTER (WHERE tipo = 'debito'), 0)  AS descontado,
                COUNT(*) FILTER (WHERE tipo = 'recarga')                AS num_recargas,
                COUNT(*) FILTER (WHERE tipo = 'debito')                  AS num_debitos
              FROM wallet_movements
             WHERE created_at::date = CURRENT_DATE
            """
        )
        row = dict(cur.fetchone() or {})
        cur.close()
    for k in ("recargado", "descontado"):
        row[k] = float(row.get(k) or 0)
    return row
