"""Campana "Sabado de RapiTaxi": saldo promocional por cliente.

La campana NO es el descuento comercial de siempre (`routers/promociones.py`).
Aqui cada cliente recibe una bolsa virtual (`saldo_promocional`) con fecha de
vencimiento. Al cerrar un viaje se cobra primero esa bolsa y lo que falte se
paga en efectivo al chofer. El `Fondo` del cliente no se toca nunca.

El chofer recibe en su billetera el saldo promocional usado mas el bono de la
campana; el efectivo lo cobra en mano. El bono solo se paga si la campana esta
vigente y el cliente uso saldo promocional.

La expiracion es perezosa: si `ahora > fecha_expiracion_promocional`, el saldo
se trata como 0 y, al consultar el perfil, se deja guardado en 0. No hace falta
un cron.

Endpoints:
    POST /admin/promos/lanzar     lanza la campana a TODOS los clientes
    GET  /admin/promos/estado     estado vigente para el panel

Las funciones de calculo (`saldo_promocional_vigente`, `bono_promocional`) las
usa `routers/Solicitud_de_viajes_v4.py` al crear y cerrar viajes.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from db.Cliente.connection import cliente_db
from routers.promociones import require_admin

logger = logging.getLogger(__name__)

CENT = Decimal("0.01")

# Nombre interno de la campana. El panel puede lanzarla otra vez: el documento
# se actualiza (upsert) y todos los clientes reciben el saldo nuevo.
CAMPANA_ID = "sabado_rapitaxi"

# Titulo/mensaje que la app del cliente muestra en el dialogo de la campana.
# Es editable desde el panel y se guarda junto al saldo de cada cliente, para
# que la app no tenga que recompilarse para cambiar el texto de la campana.
TITULO_PROMO_POR_DEFECTO = "¡Hoy es sábado y el cuerpo lo sabe!"

router = APIRouter(prefix="/admin/promos", tags=["Campana promocional"])

_clientes = cliente_db["users"]
_campanas = cliente_db["campanas"]


# --------------------------------------------------------------------------
# Utilidades de fecha y dinero
# --------------------------------------------------------------------------

def _ahora_utc() -> datetime:
    """Ahora en UTC **naive**, que es como Mongo guarda las fechas."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def a_utc_naive(valor: Any) -> Optional[datetime]:
    """Normaliza una fecha de Mongo a UTC naive.

    Acepta datetime (aware o naive), ISO 8601 en texto y valores raros. Un
    datetime naive se asume UTC, igual que el resto de los timestamps del
    sistema.
    """
    if valor is None:
        return None
    if isinstance(valor, datetime):
        if valor.tzinfo is not None:
            return valor.astimezone(timezone.utc).replace(tzinfo=None)
        return valor
    if isinstance(valor, str):
        texto = valor.strip().replace("Z", "+00:00")
        try:
            return a_utc_naive(datetime.fromisoformat(texto))
        except ValueError:
            return None
    return None


def _dinero(valor: Any) -> Decimal:
    try:
        return Decimal(str(valor)).quantize(CENT, rounding=ROUND_HALF_UP)
    except (TypeError, ValueError, ArithmeticError):
        return Decimal("0.00")


# --------------------------------------------------------------------------
# Reglas de la campana
# --------------------------------------------------------------------------

def campana_vigente(doc: Optional[dict],
                    ahora: Optional[datetime] = None) -> bool:
    """True si el cliente tiene campana y aun no ha vencido."""
    if not doc:
        return False
    expira = a_utc_naive(doc.get("fecha_expiracion_promocional"))
    if expira is None:
        return False
    return (ahora or _ahora_utc()) <= expira


def saldo_promocional_vigente(doc: Optional[dict],
                              ahora: Optional[datetime] = None) -> Decimal:
    """Saldo promocional disponible, con expiracion perezosa.

    Si `fecha_expiracion_promocional` ya paso, devuelve 0 sin importar lo que
    diga `saldo_promocional`.
    """
    if not doc:
        return Decimal("0.00")
    if not campana_vigente(doc, ahora):
        return Decimal("0.00")
    try:
        saldo = Decimal(str(doc.get("saldo_promocional") or 0))
    except (TypeError, ValueError, ArithmeticError):
        saldo = Decimal("0")
    return _dinero(max(Decimal("0"), saldo))


def bono_promocional(doc: Optional[dict],
                     ahora: Optional[datetime] = None) -> Decimal:
    """Bono que paga la campana al chofer, si sigue vigente.

    El llamador decide si se paga o no: solo cuando el cliente uso saldo
    promocional en el viaje (ver `complete_trip`).
    """
    if not campana_vigente(doc, ahora):
        return Decimal("0.00")
    try:
        return _dinero(max(Decimal("0"), Decimal(
            str(doc.get("monto_bono_chofer_campana") or 0))))
    except (TypeError, ValueError, ArithmeticError):
        return Decimal("0.00")


def expirar_saldo_si_vencido(doc: Optional[dict]) -> Decimal:
    """Aplica la expiracion perezosa y deja el saldo guardado en 0.

    Se llama al consultar el perfil. Si ya vencio y todavia habia saldo, se
    actualiza el documento para que el panel y las apps no sigan mostrando una
    bolsa muerta. Devuelve el saldo vigente ya resuelto.
    """
    if not doc:
        return Decimal("0.00")
    saldo = saldo_promocional_vigente(doc)
    if saldo > 0:
        return saldo
    # Vencio (o ya estaba en 0). Si habia saldo guardado, limpiarlo.
    try:
        guardado = Decimal(str(doc.get("saldo_promocional") or 0))
    except (TypeError, ValueError, ArithmeticError):
        guardado = Decimal("0")
    if guardado > 0 and doc.get("_id") is not None:
        try:
            _clientes.update_one(
                {"_id": doc["_id"]}, {"$set": {"saldo_promocional": 0.0}})
            doc["saldo_promocional"] = 0.0
            logger.info("Campana: saldo promocional vencido del cliente %s "
                        "pasado a 0", doc["_id"])
        except Exception:
            logger.exception("Campana: no se pudo expirar el saldo de %s",
                             doc.get("_id"))
    return Decimal("0.00")


def info_promocional(doc: Optional[dict]) -> dict:
    """Campos de campana listos para una respuesta JSON.

    Aplica la expiracion perezosa antes de devolver nada.
    """
    if not doc:
        return {
            "saldo_promocional": 0.0,
            "fecha_expiracion_promocional": None,
            "campana_promocional_activa": False,
            "monto_bono_chofer_campana": 0.0,
            "titulo_promo": None,
        }
    expirar_saldo_si_vencido(doc)
    expira = a_utc_naive(doc.get("fecha_expiracion_promocional"))
    vigente = campana_vigente(doc)
    saldo = saldo_promocional_vigente(doc) if vigente else Decimal("0.00")
    bono = bono_promocional(doc) if vigente else Decimal("0.00")
    titulo = ((doc.get("titulo_promo") or "").strip()
              or TITULO_PROMO_POR_DEFECTO)
    return {
        "saldo_promocional": float(saldo),
        "fecha_expiracion_promocional": (
            expira.isoformat() + "Z" if expira else None),
        "campana_promocional_activa": vigente,
        "monto_bono_chofer_campana": float(bono),
        # Solo se expone con la campana vigente: sin saldo activo no hay
        # mensaje que mostrar en la app.
        "titulo_promo": titulo if vigente else None,
    }


# --------------------------------------------------------------------------
# Endpoints del panel
# --------------------------------------------------------------------------

class LanzarPromoIn(BaseModel):
    """Datos del formulario "Lanzar Promocion Masiva"."""

    monto_cliente: float = Field(
        gt=0, description="Saldo promocional que recibe cada cliente, en CUP")
    monto_bono_chofer: float = Field(
        ge=0, description="Bono extra que recibe el chofer por viaje, en CUP")
    horas_expiracion: float = Field(
        gt=0, description="Horas que dura la campana desde que se lanza")
    titulo_promo: str = Field(
        default=TITULO_PROMO_POR_DEFECTO, max_length=200,
        description="Titulo/mensaje que muestra la app del cliente")


@router.post("/lanzar")
async def lanzar_promocion(datos: LanzarPromoIn,
                           admin: dict = Depends(require_admin)):
    """Asigna el saldo promocional a TODOS los clientes.

    No filtra por estado: la campana es masiva, tal como se aprobo. Si ya
    habia una campana anterior, el saldo y la fecha se reemplazan.
    """
    monto = _dinero(datos.monto_cliente)
    bono = _dinero(datos.monto_bono_chofer)
    titulo = (datos.titulo_promo or "").strip() or TITULO_PROMO_POR_DEFECTO
    ahora = _ahora_utc()
    expira = ahora + timedelta(hours=float(datos.horas_expiracion))

    try:
        resultado = _clientes.update_many(
            {},
            {"$set": {
                "saldo_promocional": float(monto),
                "fecha_expiracion_promocional": expira,
                "monto_bono_chofer_campana": float(bono),
                "titulo_promo": titulo,
            }},
        )
    except Exception as exc:
        logger.exception("Campana: no se pudo lanzar la promocion masiva")
        raise HTTPException(
            status_code=500,
            detail="No se pudo lanzar la campana: %s" % exc)

    documento = {
        "_id": CAMPANA_ID,
        "nombre": "Sabado de RapiTaxi",
        "monto_cliente": float(monto),
        "monto_bono_chofer": float(bono),
        "horas_expiracion": float(datos.horas_expiracion),
        "titulo_promo": titulo,
        "lanzada_at": ahora,
        "fecha_expiracion": expira,
        "lanzada_por": admin.get("email"),
        "clientes_afectados": int(resultado.matched_count or 0),
    }
    try:
        _campanas.update_one(
            {"_id": CAMPANA_ID}, {"$set": documento}, upsert=True)
    except Exception:
        # El saldo de los clientes ya quedo aplicado: no se rompe la campana
        # por no poder guardar el resumen del panel.
        logger.exception("Campana: no se pudo guardar el resumen de la campana")

    logger.info(
        "Campana lanzada por %s: %.2f CUP por cliente, bono %.2f CUP, "
        "vence %s, %s clientes",
        admin.get("email"), float(monto), float(bono), expira,
        resultado.matched_count)

    return {
        "ok": True,
        "mensaje": "Promocion masiva lanzada",
        "clientes_afectados": int(resultado.matched_count or 0),
        "monto_cliente": float(monto),
        "monto_bono_chofer": float(bono),
        "titulo_promo": titulo,
        "fecha_expiracion": expira.isoformat() + "Z",
        "campana_promocional_activa": True,
    }


@router.get("/estado")
async def estado_promocion(admin: dict = Depends(require_admin)):
    """Estado de la campana para la pestana "Gestion de Promociones"."""
    ahora = _ahora_utc()
    documento = None
    try:
        documento = _campanas.find_one({"_id": CAMPANA_ID})
    except Exception:
        logger.exception("Campana: no se pudo leer el resumen de la campana")

    expira = a_utc_naive((documento or {}).get("fecha_expiracion"))
    activa = bool(expira and ahora <= expira)

    afectados = 0
    con_saldo = 0
    saldo_total = Decimal("0.00")
    try:
        for doc in _clientes.find({}, {
            "saldo_promocional": 1,
            "fecha_expiracion_promocional": 1,
            "monto_bono_chofer_campana": 1,
        }):
            if campana_vigente(doc, ahora):
                afectados += 1
                saldo = saldo_promocional_vigente(doc, ahora)
                if saldo > 0:
                    con_saldo += 1
                    saldo_total += saldo
    except Exception:
        logger.exception("Campana: no se pudo contar el saldo de los clientes")

    if activa and not documento:
        # Sin resumen guardado (base antigua): reconstruir lo esencial.
        documento = {
            "monto_cliente": float(saldo_total / afectados) if afectados else 0,
            "fecha_expiracion": expira,
        }

    if activa:
        mensaje = "Promocion masiva vigente"
    elif expira:
        mensaje = "La promocion masiva ya expiro"
    else:
        mensaje = "No hay promocion masiva lanzada"

    return {
        "campana_promocional_activa": activa,
        "mensaje": mensaje,
        "clientes_afectados": afectados,
        "clientes_con_saldo": con_saldo,
        "saldo_promocional_total": float(_dinero(saldo_total)),
        "monto_cliente": float((documento or {}).get("monto_cliente") or 0),
        "monto_bono_chofer": float(
            (documento or {}).get("monto_bono_chofer") or 0),
        "horas_expiracion": float(
            (documento or {}).get("horas_expiracion") or 0),
        "titulo_promo": (
            ((documento or {}).get("titulo_promo") or "").strip()
            or TITULO_PROMO_POR_DEFECTO),
        "lanzada_at": (
            a_utc_naive((documento or {}).get("lanzada_at")).isoformat()
            if (documento or {}).get("lanzada_at") else None),
        "fecha_expiracion": (expira.isoformat() + "Z") if expira else None,
        "lanzada_por": (documento or {}).get("lanzada_por"),
    }
