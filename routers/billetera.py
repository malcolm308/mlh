"""Billetera (fondo) de choferes y clientes.

Servicio de recargas y movimientos del fondo. El saldo vive en el documento del
usuario en MongoDB (campo `Fondo`): en la coleccion de choferes es de donde se
descuenta la comision vigente, y en la de clientes es el saldo con el que
pagan los viajes por Billetera y las transferencias entre pasajeros. Aqui queda
el libro de movimientos (PostgreSQL) y los endpoints que consume la app de
administracion.

El libro `wallet_movements` distingue `user_type` ('driver' | 'client') para
que los movimientos de un chofer y de un cliente con el mismo id no se mezclen.

Endpoints (todos requieren token de administrador salvo el saldo):
    GET  /billetera/saldo/{driver_id}          saldo de un chofer
    GET  /billetera/choferes                  lista corta para el buscador
    POST /billetera/recarga                   recarga de saldo (admin)
    POST /billetera/descargo                  debito manual (admin)
    GET  /billetera/movimientos               historial de movimientos
    GET  /billetera/resumen                   totales de recargas del dia
    GET  /billetera/clientes                  lista corta de pasajeros
    GET  /billetera/clientes/{client_id}      saldo de un pasajero
    POST /billetera/clientes/recarga          abono al Fondo del pasajero
    POST /billetera/clientes/descargo         debito del Fondo del pasajero
    GET  /billetera/clientes/{id}/movimientos historial del pasajero
"""
import logging
import re
from datetime import datetime
from typing import Optional

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field

from db.Administración.connection import admin_db
from db.Chofer.connection import chofer_db
from db.Cliente.connection import cliente_db
from db.Administración.auth import verify_token as verify_admin_token
from routers.Solicitud_de_viajes_v4 import (
    _buscar_por_telefono,
    _telefono_visible,
    get_connection,
)
from routers.admin_roles import REQUIERE_OPERADOR_CARTERA

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/billetera", tags=["Billetera"])

chofer_coleccion = chofer_db.users          # los choferes viven en la BD Chofer
cliente_coleccion = cliente_db.users        # los pasajeros viven en la BD Cliente
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


class RecargaClienteIn(BaseModel):
    """Abono al Fondo de un pasajero desde el panel de administracion.

    Se puede identificar al pasajero por id, correo o telefono: el panel manda
    el `client_id` que ya tiene de la busqueda, pero aceptar los otros dos
    permite usar la API a mano sin depender del ObjectId de Mongo.
    """

    client_id: Optional[str] = None
    email: Optional[str] = None
    telefono: Optional[str] = None
    monto: float = Field(..., gt=0)
    metodo: str = "efectivo"
    referencia: Optional[str] = None
    nota: Optional[str] = None


class DescargoClienteIn(BaseModel):
    client_id: Optional[str] = None
    email: Optional[str] = None
    telefono: Optional[str] = None
    monto: float = Field(..., gt=0)
    metodo: str = "ajuste"
    nota: Optional[str] = None


# ===================== BASE DE DATOS =====================

def init_wallet_db():
    """Crea la tabla de movimientos de la billetera (idempotente)."""
    ddl = """
        CREATE TABLE IF NOT EXISTS wallet_movements (
            movement_id SERIAL PRIMARY KEY,
            -- Id del usuario dueno del Fondo. Se conserva el nombre historico
            -- `driver_id` para no romper el libro ya existente; `user_type`
            -- dice si ese id pertenece a un chofer o a un cliente.
            driver_id VARCHAR(50) NOT NULL,
            user_type VARCHAR(10) NOT NULL DEFAULT 'driver',
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
        -- Bases creadas antes de que existieran las billeteras de clientes:
        -- la columna se agrega sin tocar las filas viejas (quedan 'driver').
        ALTER TABLE wallet_movements
            ADD COLUMN IF NOT EXISTS user_type VARCHAR(10) NOT NULL DEFAULT 'driver';
        CREATE INDEX IF NOT EXISTS idx_wallet_mov_driver
            ON wallet_movements (user_type, driver_id, created_at DESC);
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


def _cliente_doc(identifier: str):
    """Busca un pasajero por id, correo o telefono."""
    from bson import ObjectId

    ident = (identifier or "").strip()
    if not ident:
        return None

    if ObjectId.is_valid(ident):
        doc = cliente_coleccion.find_one({"_id": ObjectId(ident)})
        if doc:
            return doc
    if "@" in ident:
        doc = cliente_coleccion.find_one({"email": ident.lower()})
        if doc:
            return doc
    return _buscar_por_telefono(cliente_coleccion, ident)


def _saldo(doc) -> float:
    return float(doc.get("Fondo") or doc.get("fondo") or 0)


def _nombre_cliente(doc) -> Optional[str]:
    """Nombre legible del pasajero (soporta el perfil nuevo y el viejo)."""
    if not doc:
        return None
    nombre = " ".join(filter(None, [
        doc.get("Nombre"), doc.get("Apellidos")])).strip()
    if nombre:
        return nombre
    profile = doc.get("profile") or {}
    return ((profile.get("name") or "").strip()
            or (doc.get("nombre") or "").strip() or None)


def _telefono_cliente(doc) -> Optional[str]:
    if not doc:
        return None
    profile = doc.get("profile") or {}
    return _telefono_visible(
        doc.get("numero_de_telefono") or doc.get("phone")
        or profile.get("phone"))


def _identificador_cliente(body) -> Optional[str]:
    """Primer identificador no vacio del cuerpo (id, correo o telefono)."""
    for valor in (body.client_id, body.email, body.telefono):
        if valor and str(valor).strip():
            return str(valor).strip()
    return None


def _registrar_movimiento(conn, driver_id, admin, tipo, monto, saldo_anterior,
                          saldo_nuevo, metodo, referencia, nota,
                          user_type: str = "driver") -> int:
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO wallet_movements (
            driver_id, user_type, admin_id, admin_email, tipo, monto,
            saldo_anterior, saldo_nuevo, metodo, referencia, nota
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        RETURNING movement_id
        """,
        (driver_id, user_type, admin["id"], admin["email"], tipo, monto,
         round(saldo_anterior, 2), round(saldo_nuevo, 2), metodo,
         referencia, nota),
    )
    movement_id = cur.fetchone()[0]
    return movement_id


def acreditar_bono_referido(driver_identifier: str, monto: float, nota: str) -> bool:
    """Acredita un bono al fondo de un chofer sin pasar por el panel de admin.

    Se usa para el premio de 500 CUP del sistema de referidos de choferes.
    Devuelve True solo si el saldo y el movimiento quedaron guardados.
    """
    doc = _driver_doc(driver_identifier)
    if not doc:
        logger.warning("Bono de referido: chofer %s no encontrado", driver_identifier)
        return False

    monto = round(float(monto), 2)
    if monto <= 0:
        return False

    driver_id = str(doc["_id"])
    anterior = _saldo(doc)
    nuevo = round(anterior + monto, 2)
    sistema = {"id": "sistema", "email": "sistema@rapitaxi"}

    try:
        chofer_coleccion.update_one({"_id": doc["_id"]}, {"$inc": {"Fondo": monto}})
        with get_connection() as conn:
            _registrar_movimiento(
                conn, driver_id, sistema, "recarga", monto, anterior, nuevo,
                "promocion", "BONO-REFERIDO", nota,
            )
            conn.commit()
        logger.info("Bono de referido de %.2f CUP acreditado a %s", monto, driver_id)
        return True
    except Exception:
        # Si falla el libro de movimientos se revierte el saldo.
        try:
            chofer_coleccion.update_one(
                {"_id": doc["_id"]}, {"$inc": {"Fondo": -monto}})
        except Exception:
            logger.exception("No se pudo revertir el bono de referido de %s", driver_id)
        logger.exception("No se pudo acreditar el bono de referido a %s", driver_id)
        return False


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
async def recargar(body: RecargaIn, admin: dict = Depends(REQUIERE_OPERADOR_CARTERA)):
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
async def descontar(body: DescargoIn, admin: dict = Depends(REQUIERE_OPERADOR_CARTERA)):
    """Descuenta saldo del fondo de un chofer (ajuste o penalizacion)."""
    doc = _driver_doc(body.driver_id)
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")

    driver_id = str(doc["_id"])
    monto = round(float(body.monto), 2)
    anterior = _saldo(doc)
    if anterior < monto:
        raise HTTPException(status_code=400, detail="Saldo insuficiente para el débito")

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
         WHERE user_type = 'driver'
    """
    params = []
    if driver_id:
        doc = _driver_doc(driver_id)
        sql += " AND driver_id = %s"
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
             WHERE user_type = 'driver'
               AND created_at::date = CURRENT_DATE
            """
        )
        row = dict(cur.fetchone() or {})
        cur.close()
    for k in ("recargado", "descontado"):
        row[k] = float(row.get(k) or 0)
    return row


# ===================== BILLETERA DE CLIENTES =====================

@router.get("/clientes")
async def listar_clientes(q: Optional[str] = None, limit: int = 50,
                          admin: dict = Depends(require_admin)):
    """Lista corta de pasajeros para el buscador del panel.

    Devuelve el saldo del Fondo para que el operador vea de un golpe a quien
    va a abonar, sin una peticion extra por cada fila.
    """
    query = {"eliminado": {"$ne": True}}
    if q and q.strip():
        texto = re.escape(q.strip())
        query["$or"] = [
            {"email": {"$regex": texto, "$options": "i"}},
            {"Nombre": {"$regex": texto, "$options": "i"}},
            {"Apellidos": {"$regex": texto, "$options": "i"}},
            {"numero_de_telefono": {"$regex": texto, "$options": "i"}},
        ]
    docs = list(cliente_coleccion.find(query, {"password": 0})
                .sort([("Nombre", 1), ("Apellidos", 1)])
                .limit(min(limit, 200)))
    return [
        {
            "client_id": str(d["_id"]),
            "nombre": _nombre_cliente(d),
            "telefono": _telefono_cliente(d),
            "email": d.get("email"),
            "saldo": round(_saldo(d), 2),
        }
        for d in docs
    ]


@router.get("/clientes/{client_id}")
async def saldo_cliente(client_id: str, admin: dict = Depends(require_admin)):
    """Saldo actual del Fondo de un pasajero."""
    doc = _cliente_doc(client_id)
    if not doc:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    return {
        "client_id": str(doc["_id"]),
        "nombre": _nombre_cliente(doc),
        "telefono": _telefono_cliente(doc),
        "email": doc.get("email"),
        "saldo": round(_saldo(doc), 2),
        "currency": "CUP",
    }


@router.post("/clientes/recarga")
async def recargar_cliente(body: RecargaClienteIn,
                           admin: dict = Depends(REQUIERE_OPERADOR_CARTERA)):
    """Abona saldo al Fondo de un pasajero (transferencia desde el panel).

    El dinero entra al mismo campo `Fondo` que usa la app del cliente para
    pagar viajes con Billetera. Cada abono queda en el libro de movimientos
    con el administrador que lo aplico.
    """
    identificador = _identificador_cliente(body)
    if not identificador:
        raise HTTPException(
            status_code=400,
            detail="Indique client_id, email o telefono del cliente")

    doc = _cliente_doc(identificador)
    if not doc:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")

    metodo = (body.metodo or "efectivo").strip().lower()
    if metodo not in METODOS_RECARGA:
        raise HTTPException(
            status_code=400,
            detail=f"Metodo invalido. Opciones: {', '.join(METODOS_RECARGA)}",
        )

    client_id = str(doc["_id"])
    monto = round(float(body.monto), 2)
    anterior = _saldo(doc)
    nuevo = round(anterior + monto, 2)

    try:
        resultado = cliente_coleccion.update_one(
            {"_id": doc["_id"]}, {"$inc": {"Fondo": monto}})
        if resultado.matched_count == 0:
            raise HTTPException(status_code=404, detail="Cliente no encontrado")
        with get_connection() as conn:
            movement_id = _registrar_movimiento(
                conn, client_id, admin, "recarga", monto, anterior, nuevo,
                metodo, body.referencia, body.nota, user_type="client",
            )
            conn.commit()
    except HTTPException:
        raise
    except Exception as e:
        # Si falla el libro, se revierte el saldo para no dejar dinero sin
        # respaldo contable.
        try:
            cliente_coleccion.update_one(
                {"_id": doc["_id"]}, {"$inc": {"Fondo": -monto}})
        except Exception:
            logger.exception("No se pudo revertir la recarga del cliente %s",
                             client_id)
        logger.exception("Fallo la recarga del cliente %s", client_id)
        raise HTTPException(
            status_code=500,
            detail=f"No se pudo registrar la recarga: {e}")

    return {
        "ok": True,
        "movement_id": movement_id,
        "client_id": client_id,
        "nombre": _nombre_cliente(doc),
        "telefono": _telefono_cliente(doc),
        "monto": monto,
        "saldo_anterior": round(anterior, 2),
        "saldo_nuevo": nuevo,
        "metodo": metodo,
        "message": f"Recarga de {monto} CUP aplicada al cliente",
    }


@router.post("/clientes/descargo")
async def descontar_cliente(body: DescargoClienteIn,
                            admin: dict = Depends(REQUIERE_OPERADOR_CARTERA)):
    """Descuenta saldo del Fondo de un pasajero (ajuste o penalizacion)."""
    identificador = _identificador_cliente(body)
    if not identificador:
        raise HTTPException(
            status_code=400,
            detail="Indique client_id, email o telefono del cliente")

    doc = _cliente_doc(identificador)
    if not doc:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")

    client_id = str(doc["_id"])
    monto = round(float(body.monto), 2)
    anterior = _saldo(doc)

    try:
        # El filtro `Fondo >= monto` hace el debito atomico: dos operadores
        # simultaneos no pueden dejar el saldo en negativo.
        resultado = cliente_coleccion.update_one(
            {"_id": doc["_id"], "Fondo": {"$gte": monto}},
            {"$inc": {"Fondo": -monto}})
        if resultado.modified_count == 0:
            raise HTTPException(
                status_code=400,
                detail="Saldo insuficiente para el débito")
        nuevo = round(anterior - monto, 2)
        with get_connection() as conn:
            movement_id = _registrar_movimiento(
                conn, client_id, admin, "debito", -monto, anterior, nuevo,
                (body.metodo or "ajuste").lower(), None, body.nota,
                user_type="client",
            )
            conn.commit()
    except HTTPException:
        raise
    except Exception as e:
        try:
            cliente_coleccion.update_one(
                {"_id": doc["_id"]}, {"$inc": {"Fondo": monto}})
        except Exception:
            logger.exception("No se pudo revertir el debito del cliente %s",
                             client_id)
        raise HTTPException(
            status_code=500,
            detail=f"No se pudo registrar el debito: {e}")

    return {
        "ok": True,
        "movement_id": movement_id,
        "client_id": client_id,
        "nombre": _nombre_cliente(doc),
        "telefono": _telefono_cliente(doc),
        "monto": -monto,
        "saldo_anterior": round(anterior, 2),
        "saldo_nuevo": nuevo,
        "message": f"Debito de {monto} CUP aplicado al cliente",
    }


@router.get("/clientes/{client_id}/movimientos")
async def movimientos_cliente(client_id: str, limit: int = 100,
                              admin: dict = Depends(require_admin)):
    """Historial de recargas y descuentos del Fondo de un pasajero."""
    doc = _cliente_doc(client_id)
    if not doc:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")

    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT movement_id, driver_id, admin_email, tipo, monto,
                   saldo_anterior, saldo_nuevo, metodo, referencia, nota,
                   created_at
              FROM wallet_movements
             WHERE user_type = 'client' AND driver_id = %s
             ORDER BY created_at DESC, movement_id DESC
             LIMIT %s
            """,
            (str(doc["_id"]), min(limit, 500)),
        )
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()

    for r in rows:
        r["monto"] = float(r["monto"])
        r["saldo_anterior"] = float(r["saldo_anterior"])
        r["saldo_nuevo"] = float(r["saldo_nuevo"])
        if isinstance(r.get("created_at"), datetime):
            r["created_at"] = r["created_at"].isoformat()
    return rows
