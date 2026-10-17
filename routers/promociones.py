"""
Promociones y comisiones temporales.

La plataforma es un ecosistema cerrado: el saldo del chofer es un unico campo
(`Fondo` en Mongo) y no hay retiros en efectivo. Todo lo que se guarda son
promociones y comisiones, y quien las cambia es el administrador desde el panel.

Un detalle que condiciona todo el calculo: el descuento al cliente NUNCA sale del
dinero del chofer. Sale de la comision de la plataforma. Por eso el descuento se
aplica a la comision nominal y no al precio del viaje:

    precio del viaje          10.00
    comision nominal (15%)     1.50   <- lo que la plataforma cobra
    descuento al cliente       1.00   <- se descuenta de esa comision
    paga el cliente            9.00
    comision que sale del Fondo 0.50  <- 1.50 - 1.00
    conserva el chofer         8.50   <- 10.00 - 1.50, intacto
    se queda la plataforma     0.50

Si en vez de eso se calculara `0.15 x 9.00`, el chofer se quedaria con `7.65`:
perderia 0.85 CUP por un descuento que no le corresponde. Ese error es el que
impide usar `total_fare` como base de la comision cuando hay descuento.

Todos los porcentajes se guardan como FRACCION (0.15, no 15), que es lo que ya
usa `COMMISSION_RATE`. Guardarlos como 15 obligaria a convertir en cada punto y a
cambiar lo que la app del chofer ya recibe en `commission_rate`.
"""
import logging
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Dict, Optional

from fastapi import APIRouter, Depends, Header, HTTPException
from psycopg2.extras import RealDictCursor
from pydantic import BaseModel, Field

from db.Administración.auth import verify_token as verify_admin_token
from db.Administración.connection import admin_db

admin_coleccion = admin_db.users

logger = logging.getLogger(__name__)

# Prefijo con "/admin" dentro. Se registra ANTES que `CRUD_MONGODB` porque ese
# router tiene un `GET /admin/{id}` que se tragaria estas rutas.
router = APIRouter(prefix="/admin/promociones", tags=["Promociones y Comisiones"])

CENT = Decimal("0.01")
UNO = Decimal("1")
# Tope del descuento al cliente. Es el limite de negocio, no el tecnico: la
# plataforma se queda con `comision - descuento`, asi que un descuento sin tope
# permitiria regalar viajes.
DESCUENTO_MAXIMO = Decimal("0.10")

DEFAULT_COMISION = Decimal("0.15")
DEFAULT_BONO_MONTO = Decimal("1100")
DEFAULT_BONO_VIAJES = 10

# Fila unica: el CHECK sobre `id` impide que alguien inserte una segunda.
DDL = """
    CREATE TABLE IF NOT EXISTS promociones (
        id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
        comision_porcentaje NUMERIC(5,4) NOT NULL DEFAULT 0.1500,
        bono_chofer_activo BOOLEAN NOT NULL DEFAULT TRUE,
        bono_chofer_monto NUMERIC(12,2) NOT NULL DEFAULT 1100.00,
        bono_chofer_viajes_requeridos INTEGER NOT NULL DEFAULT 10,
        descuento_cliente_activo BOOLEAN NOT NULL DEFAULT FALSE,
        descuento_cliente_porcentaje NUMERIC(5,4) NOT NULL DEFAULT 0.0000,
        fecha_expiracion TIMESTAMP,
        actualizado_at TIMESTAMP DEFAULT NOW(),
        actualizado_por VARCHAR(200)
    );
"""


# ===================== AUTENTICACION ADMIN =====================

def require_admin(authorization: Optional[str] = Header(None)) -> dict:
    """Valida el token del administrador y devuelve {id, email}.

    Se define aqui en vez de importar el de `routers.billetera` porque ese modulo
    importa `get_connection` de `Solicitud_de_viajes_v4`, que a su vez importa
    este: importarlo crearia un ciclo. Es el mismo criterio que ya usan
    `admin_panel.py` y `documentos.py`.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Falta el token de administrador")
    payload = verify_admin_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token inválido o expirado")

    email = payload.get("sub")
    admin = admin_coleccion.find_one({"email": email}) if email else None
    if not admin:
        raise HTTPException(status_code=403, detail="La cuenta no es de administrador")
    return {"id": str(admin["_id"]), "email": email, "rol": admin.get("rol")}


def _conexion():
    """Se importa aqui y no arriba para que este modulo se pueda cargar sin
    PostgreSQL (los tests del bot lo importan)."""
    from routers.Solicitud_de_viajes_v4 import get_connection
    return get_connection()


# ===================== TABLA =====================

def asegurar_tabla_promociones() -> None:
    """Crea la tabla y deja la fila de configuracion lista (idempotente)."""
    try:
        with _conexion() as conn:
            cur = conn.cursor()
            cur.execute(DDL)
            cur.execute(
                "INSERT INTO promociones (id) VALUES (1) ON CONFLICT (id) DO NOTHING")
            conn.commit()
            cur.close()
        logger.info("promociones: tabla y configuracion inicial listas")
    except Exception:
        logger.exception("promociones: no se pudo crear la tabla")


# ===================== LECTURA =====================

def _a_decimal(valor: Any, por_defecto: Decimal) -> Decimal:
    try:
        if valor is None:
            return por_defecto
        return Decimal(str(valor))
    except (TypeError, ValueError, ArithmeticError):
        return por_defecto


def leer_promocion() -> Dict[str, Any]:
    """Configuracion vigente, ya resuelta.

    Se lee en cada cierre de viaje a proposito: si el administrador cambia la
    comision, el siguiente viaje cerrado ya usa la nueva sin esperar reinicios ni
    cachés que puedan quedar viejos.

    Si la tabla todavia no existe, devuelve los valores por defecto. Que la app
    deChofer pueda cerrar viajes mientras la base se arregla es mas importante que
    la promocion este a punto.
    """
    valores = {
        "comision_porcentaje": DEFAULT_COMISION,
        "bono_chofer_activo": True,
        "bono_chofer_monto": DEFAULT_BONO_MONTO,
        "bono_chofer_viajes_requeridos": DEFAULT_BONO_VIAJES,
        "descuento_cliente_activo": False,
        "descuento_cliente_porcentaje": Decimal("0"),
        "fecha_expiracion": None,
        "actualizado_at": None,
        "actualizado_por": None,
    }
    try:
        with _conexion() as conn:
            cur = conn.cursor(cursor_factory=RealDictCursor)
            cur.execute("SELECT * FROM promociones WHERE id = 1")
            fila = cur.fetchone()
            cur.close()
    except Exception:
        logger.exception("promociones: no se pudo leer la configuracion")
        fila = None

    if fila:
        comision = _a_decimal(fila.get("comision_porcentaje"), DEFAULT_COMISION)
        valores.update({
            "comision_porcentaje": comision,
            "bono_chofer_activo": bool(fila.get("bono_chofer_activo", True)),
            "bono_chofer_monto": _a_decimal(fila.get("bono_chofer_monto"),
                                             DEFAULT_BONO_MONTO),
            "bono_chofer_viajes_requeridos": int(
                fila.get("bono_chofer_viajes_requeridos") or DEFAULT_BONO_VIAJES),
            "descuento_cliente_activo": bool(fila.get("descuento_cliente_activo")),
            "descuento_cliente_porcentaje": _a_decimal(
                fila.get("descuento_cliente_porcentaje"), Decimal("0")),
            "fecha_expiracion": fila.get("fecha_expiracion"),
            "actualizado_at": fila.get("actualizado_at"),
            "actualizado_por": fila.get("actualizado_por"),
        })

    # Con comision 0 no hay de donde sacar el descuento: el chofer ya se lleva el
    # 100% y la plataforma no tiene nada que ceder. Se apaga aqui, no solo en el
    # panel, para que ni una llamada directa a la API se lo saltee.
    if valores["comision_porcentaje"] <= 0:
        valores["descuento_cliente_activo"] = False
        valores["descuento_cliente_porcentaje"] = Decimal("0")

    valores["expirada"] = _esta_expirada(valores["fecha_expiracion"])
    valores["descuento_aplicando"] = (
        valores["descuento_cliente_activo"]
        and not valores["expirada"]
        and valores["comision_porcentaje"] > 0
    )
    return valores


# psycopg2 con `RealDictCursor` devuelve dicts; con el cursor normal devuelve
# tuplas. Se lee con RealDictCursor para no tener que jugglingar `cursor.description`
# en cada lectura.

def _esta_expirada(fecha: Optional[datetime]) -> bool:
    if fecha is None:
        return False
    # `fecha_expiracion` se guarda sin zona horaria (TIMESTAMP). Se compara
    # contra la hora de Cuba, que es la del reloj del chofer y del pasajero, no
    # contra Greenwich: una promocion que vence "hoy a las 18:00" tiene que
    # seguir viva hasta las 18:00 de La Habana.
    referencia = datetime.now(timezone.utc).astimezone(_CUBA())
    if getattr(fecha, "tzinfo", None) is not None:
        fecha = fecha.astimezone(_CUBA())
    return fecha < referencia.replace(tzinfo=None)


def _CUBA():
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo("America/Havana")
    except Exception:
        return timezone.utc


def calcular_descuento_cliente(precio_bruto: Decimal,
                              promo: Dict[str, Any]) -> Decimal:
    """Cuanto se le resta al precio del viaje, en dinero, ya redondeado.

    Devuelve 0 si no toca descuento, por las cuatro razones que lo anulan: la
    promocion esta expirada, el descuento esta apagado, la comision es 0, o el
    descuento supera a la comision (la plataforma no puede perder dinero).
    """
    if not promo.get("descuento_aplicando"):
        return Decimal("0")
    porcentaje = promo["descuento_cliente_porcentaje"]
    if porcentaje <= 0:
        return Decimal("0")

    comision_nominal = _a_dinero(precio_bruto * promo["comision_porcentaje"])
    descuento = _a_dinero(precio_bruto * porcentaje)

    # Cinturon: el descuento nunca puede ser mayor que lo que gana la plataforma.
    if descuento > comision_nominal:
        logger.warning("promociones: descuento %s mayor que la comision %s; se recorta",
                       descuento, comision_nominal)
        descuento = comision_nominal
    return max(Decimal("0"), descuento)


def _a_dinero(valor: Decimal) -> Decimal:
    """Redondeo a centimos con ROUND_HALF_UP, que es como se redondea un precio
    para un humano. El `round()` de Python usa banker's rounding y daria centavos
    distintos en los casos .5, que es justo donde se nota un descuadre."""
    return Decimal(valor).quantize(CENT, rounding=ROUND_HALF_UP)


# ===================== API =====================

class PromoIn(BaseModel):
    comision_porcentaje: float = Field(..., description="Fraccion: 0.0 a 1.0")
    bono_chofer_activo: bool = True
    bono_chofer_monto: float = 0
    bono_chofer_viajes_requeridos: int = 0
    descuento_cliente_activo: bool = False
    descuento_cliente_porcentaje: float = 0
    fecha_expiracion: Optional[str] = Field(
        None, description="YYYY-MM-DD. Vacio = no caduca")


def _validar(datos: PromoIn) -> Dict[str, Any]:
    comision = Decimal(str(datos.comision_porcentaje)).quantize(Decimal("0.0001"))
    if comision < 0 or comision > UNO:
        raise HTTPException(
            status_code=400,
            detail="La comisión debe ser una fracción entre 0 y 1. "
                   "Por ejemplo, 0.15 es el quince por ciento.")

    descuento = Decimal(str(datos.descuento_cliente_porcentaje)).quantize(
        Decimal("0.0001"))
    descuento_activo = bool(datos.descuento_cliente_activo)

    # Con comisión 0 el descuento se apaga ANTES de validarlo. Va primero a
    # proposito: si se comprobara antes `descuento <= comision`, poner la comision
    # a cero con un descuento puesto daria error de validacion, que es justo lo
    # contrario de lo que quiere el administrador en mitad de una campana de
    # captacion. Se corrige solo y se le avisa por log.
    if comision <= 0:
        if descuento_activo or descuento > 0:
            logger.info("promociones: comisión 0%%, se ignora el descuento al cliente")
        descuento_activo = False
        descuento = Decimal("0")

    if descuento < 0 or descuento > DESCUENTO_MAXIMO:
        raise HTTPException(
            status_code=400,
            detail="El descuento al cliente no puede pasar de %s (0.10)."
                   % _porcentaje(DESCUENTO_MAXIMO))

    if descuento > comision:
        raise HTTPException(
            status_code=400,
            detail="El descuento (%s) no puede ser mayor que la comisión (%s): "
                   "la plataforma no puede perder dinero."
                   % (_porcentaje(descuento), _porcentaje(comision)))

    monto_bono = Decimal(str(datos.bono_chofer_monto)).quantize(CENT)
    if monto_bono < 0:
        raise HTTPException(status_code=400, detail="El monto del bono no puede ser negativo.")

    viajes = int(datos.bono_chofer_viajes_requeridos)
    if viajes < 0:
        raise HTTPException(
            status_code=400, detail="Los viajes requeridos no pueden ser negativos.")

    expiracion = None
    if datos.fecha_expiracion:
        try:
            expiracion = datetime.strptime(datos.fecha_expiracion.strip(), "%Y-%m-%d")
        except ValueError:
            raise HTTPException(
                status_code=400,
                detail="La fecha no es válida. Use el formato AAAA-MM-DD.")

    return {
        "comision_porcentaje": comision,
        "bono_chofer_activo": bool(datos.bono_chofer_activo),
        "bono_chofer_monto": monto_bono,
        "bono_chofer_viajes_requeridos": viajes,
        "descuento_cliente_activo": descuento_activo,
        "descuento_cliente_porcentaje": descuento,
        "fecha_expiracion": expiracion,
    }


def _porcentaje(fraccion: Decimal) -> str:
    """0.15 -> '15%', 0.075 -> '7,5%'. Para leerlo bien en el panel."""
    valor = Decimal(fraccion) * 100
    if abs(valor - round(valor)) < Decimal("0.005"):
        return "%d%%" % round(valor)
    return ("%s%%" % round(valor, 2)).replace(".", ",")


@router.get("")
async def obtener_promocion(admin: dict = Depends(require_admin)):
    """Configuracion vigente, con los valores ya resueltos y las reglas de
    negocio ya aplicadas, para que el panel no tenga que reimplementarlas."""
    promo = leer_promocion()
    return _a_json(promo)


@router.post("")
async def guardar_promocion(datos: PromoIn, admin: dict = Depends(require_admin)):
    limpio = _validar(datos)
    with _conexion() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE promociones SET
                comision_porcentaje = %s,
                bono_chofer_activo = %s,
                bono_chofer_monto = %s,
                bono_chofer_viajes_requeridos = %s,
                descuento_cliente_activo = %s,
                descuento_cliente_porcentaje = %s,
                fecha_expiracion = %s,
                actualizado_at = NOW(),
                actualizado_por = %s
            WHERE id = 1
            """,
            (limpio["comision_porcentaje"], limpio["bono_chofer_activo"],
             limpio["bono_chofer_monto"], limpio["bono_chofer_viajes_requeridos"],
             limpio["descuento_cliente_activo"], limpio["descuento_cliente_porcentaje"],
             limpio["fecha_expiracion"], admin.get("email")),
        )
        if cur.rowcount == 0:
            cur.execute("INSERT INTO promociones (id) VALUES (1) ON CONFLICT (id) DO NOTHING")
            cur.execute(
                """
                UPDATE promociones SET
                    comision_porcentaje = %s, bono_chofer_activo = %s,
                    bono_chofer_monto = %s, bono_chofer_viajes_requeridos = %s,
                    descuento_cliente_activo = %s, descuento_cliente_porcentaje = %s,
                    fecha_expiracion = %s, actualizado_at = NOW(), actualizado_por = %s
                WHERE id = 1
                """,
                (limpio["comision_porcentaje"], limpio["bono_chofer_activo"],
                 limpio["bono_chofer_monto"], limpio["bono_chofer_viajes_requeridos"],
                 limpio["descuento_cliente_activo"], limpio["descuento_cliente_porcentaje"],
                 limpio["fecha_expiracion"], admin.get("email")),
            )
        conn.commit()
        cur.close()

    logger.info("promociones: guardada por %s -> comision=%s descuento=%s%%",
                admin.get("email"), limpio["comision_porcentaje"],
                limpio["descuento_cliente_porcentaje"] * 100)

    promo = leer_promocion()
    respuesta = _a_json(promo)
    respuesta["message"] = "Configuración guardada"
    return respuesta


def _a_json(promo: Dict[str, Any]) -> Dict[str, Any]:
    """Decimal no es serializable por JSON. Se pasan a float para que la respuesta
    sea la misma que espera la app y que el panel pueda pintar con `money()`."""
    return {
        "comision_porcentaje": float(promo["comision_porcentaje"]),
        "comision_porcentaje_texto": _porcentaje(promo["comision_porcentaje"]),
        "bono_chofer_activo": promo["bono_chofer_activo"],
        "bono_chofer_monto": float(promo["bono_chofer_monto"]),
        "bono_chofer_viajes_requeridos": promo["bono_chofer_viajes_requeridos"],
        "descuento_cliente_activo": promo["descuento_cliente_activo"],
        "descuento_cliente_porcentaje": float(promo["descuento_cliente_porcentaje"]),
        "descuento_cliente_porcentaje_texto":
            _porcentaje(promo["descuento_cliente_porcentaje"]),
        "descuento_aplicando": promo["descuento_aplicando"],
        "descuento_bloqueado_por_comision_cero": promo["comision_porcentaje"] <= 0,
        "expirada": promo["expirada"],
        "fecha_expiracion": (promo["fecha_expiracion"].isoformat()
                             if promo["fecha_expiracion"] else None),
        "descuento_maximo": float(DESCUENTO_MAXIMO),
        "actualizado_at": (promo["actualizado_at"].isoformat()
                           if promo["actualizado_at"] else None),
        "actualizado_por": promo["actualizado_por"],
    }