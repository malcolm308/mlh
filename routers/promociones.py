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
from typing import Any, Dict, Optional, Tuple

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
        -- Coeficientes por distancia. Se aplican SOLO al subtotal del
        -- kilometraje: la tarifa base siempre se suma entera.
        --   precio = base + (km * precio_por_km * coeficiente)
        coef_corto_km NUMERIC(6,2) NOT NULL DEFAULT 3.0,
        coef_corto_valor NUMERIC(6,4) NOT NULL DEFAULT 0.5000,
        coef_medio_km NUMERIC(6,2) NOT NULL DEFAULT 10.0,
        coef_medio_valor NUMERIC(6,4) NOT NULL DEFAULT 0.6000,
        coef_largo_valor NUMERIC(6,4) NOT NULL DEFAULT 1.0000,
        -- Minutos de cortesia que espera el pasajero sin que se cobren. Solo
        -- cuenta lo que pase de aqui, y se suma a la duracion facturable.
        tiempo_espera_cortesia_minutos NUMERIC(6,2) NOT NULL DEFAULT 4.0,
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


ALTER_PROMOCIONES = """
    ALTER TABLE promociones
            ADD COLUMN IF NOT EXISTS coef_corto_km NUMERIC(6,2) NOT NULL DEFAULT 3.0,
            ADD COLUMN IF NOT EXISTS coef_corto_valor NUMERIC(6,4) NOT NULL DEFAULT 0.5000,
            ADD COLUMN IF NOT EXISTS coef_medio_km NUMERIC(6,2) NOT NULL DEFAULT 10.0,
            ADD COLUMN IF NOT EXISTS coef_medio_valor NUMERIC(6,4) NOT NULL DEFAULT 0.6000,
            ADD COLUMN IF NOT EXISTS coef_largo_valor NUMERIC(6,4) NOT NULL DEFAULT 1.0000,
            ADD COLUMN IF NOT EXISTS tiempo_espera_cortesia_minutos NUMERIC(6,2) NOT NULL DEFAULT 4.0,
            ADD COLUMN IF NOT EXISTS precio_por_minuto NUMERIC(12,2) DEFAULT 5.00,
            ADD COLUMN IF NOT EXISTS precio_km_zona_basico NUMERIC(12,2) DEFAULT 1000.00,
            ADD COLUMN IF NOT EXISTS precio_km_zona_confort NUMERIC(12,2) DEFAULT 1200.00,
            ADD COLUMN IF NOT EXISTS precio_km_zona_triciclo NUMERIC(12,2) DEFAULT 700.00,
            ADD COLUMN IF NOT EXISTS precio_km_zona_moto NUMERIC(12,2) DEFAULT 600.00,
            ADD COLUMN IF NOT EXISTS zona_especial_coords JSONB;
    """


def _conexion():
    """Se importa aqui y no arriba para que este modulo se pueda cargar sin
    PostgreSQL (los tests del bot lo importan)."""
    from routers.Solicitud_de_viajes_v4 import get_connection
    return get_connection()


# ===================== TABLA =====================

def asegurar_tabla_promociones() -> None:
    """Crea la tabla y deja la fila de configuracion lista (idempotente).

    Las columnas nuevas van en un ALTER aparte y no en el CREATE: sobre una tabla
    que ya existe (produccion, o la local de hace meses) un CREATE TABLE IF NOT
    EXISTS no hace absolutamente nada, y las columnas faltarian. Un ADD COLUMN si es
    aditivo y se aplica sobre la tabla que haya.
    """
    try:
        with _conexion() as conn:
            cur = conn.cursor()
            cur.execute(DDL)
            cur.execute(ALTER_PROMOCIONES)
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
        "coef_corto_km": Decimal("3.0"),
        "coef_corto_valor": Decimal("0.5"),
        "coef_medio_km": Decimal("10.0"),
        "coef_medio_valor": Decimal("0.6"),
        "coef_largo_valor": Decimal("1.0"),
        "tiempo_espera_cortesia_minutos": Decimal("4.0"),
        "precio_por_minuto": Decimal("5.0"),
        "precio_km_zona_basico": Decimal("1000.0"),
        "precio_km_zona_confort": Decimal("1200.0"),
        "precio_km_zona_triciclo": Decimal("700.0"),
        "precio_km_zona_moto": Decimal("600.0"),
        "zona_especial_coords": [
            [23.001228, -82.416735],
            [23.007982, -82.394788],
            [22.989298, -82.413242],
            [23.001007, -82.389251],
        ],
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
            "coef_corto_km": _a_decimal(fila.get("coef_corto_km"), Decimal("3.0")),
            "coef_corto_valor": _a_decimal(fila.get("coef_corto_valor"), Decimal("0.5")),
            "coef_medio_km": _a_decimal(fila.get("coef_medio_km"), Decimal("10.0")),
            "coef_medio_valor": _a_decimal(fila.get("coef_medio_valor"), Decimal("0.6")),
            "coef_largo_valor": _a_decimal(fila.get("coef_largo_valor"), Decimal("1.0")),
            "tiempo_espera_cortesia_minutos": _a_decimal(
                fila.get("tiempo_espera_cortesia_minutos"), Decimal("4.0")),
            "precio_por_minuto": _a_decimal(fila.get("precio_por_minuto"), Decimal("5.0")),
            "precio_km_zona_basico": _a_decimal(fila.get("precio_km_zona_basico"), Decimal("1000.0")),
            "precio_km_zona_confort": _a_decimal(fila.get("precio_km_zona_confort"), Decimal("1200.0")),
            "precio_km_zona_triciclo": _a_decimal(fila.get("precio_km_zona_triciclo"), Decimal("700.0")),
            "precio_km_zona_moto": _a_decimal(fila.get("precio_km_zona_moto"), Decimal("600.0")),
            "zona_especial_coords": fila.get("zona_especial_coords") or [
                [23.001228, -82.416735],
                [23.007982, -82.394788],
                [22.989298, -82.413242],
                [23.001007, -82.389251],
            ],
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


def excedente_espera(espera_secs: Optional[float], trayecto_secs: Optional[float],
                     cortesia_minutos: float) -> Tuple[int, int]:
    """Reparte la espera entre lo que es cortesía y lo que se cobra.

        espera    = hora_inicio_viaje - hora_llegada
        excedente = max(0, espera - cortesia)
        total     = trayecto_real + excedente

    Devuelve `(excedente_segundos, total_facturable_segundos)`, los dos en
    segundos. Recibe el trayecto aparte porque desde la espera no se puede saber.

    Que la espera NUNCA sea negativa importa: con dos relojes desajustados
    `started_at` puede quedar antes que `hora_llegada`, y el `max(0, ...)` evita
    que al chofer le resten minutos de su propio trayecto.
    """
    def _segundos(valor) -> int:
        try:
            return max(0, int(valor or 0))
        except (TypeError, ValueError):
            return 0

    try:
        cortesia = float(cortesia_minutos or 0) * 60
    except (TypeError, ValueError):
        cortesia = 0.0

    espera = _segundos(espera_secs)
    trayecto = _segundos(trayecto_secs)
    excedente = max(0, int(espera - cortesia))
    return excedente, trayecto + excedente


def coeficiente_por_distancia(distancia_km: float, promo: Dict[str, Any]) -> Decimal:
    """Que coeficiente se aplica a un trayecto de `distancia_km` kilometros.

        <= corto_km              -> coef_corto_valor   (0.5 por defecto)
        >  corto_km y <= medio_km-> coef_medio_valor   (0.6 por defecto)
        >  medio_km              -> coef_largo_valor   (1.0 por defecto)

    Los limites son INCLUSIVOS por arriba, que es como se lee "de 3 a 10 km":
    un viaje de exactamente 10 km entra en el tramo medio, no en el largo. Con
    los limites invertidos (si el administrador se colgara y pusiera 10 en el
    corto y 3 en el medio) se devuelven los por defecto, porque antes que
    calcular un precio raro es mejor calcular el precio que todos esperan.
    """
    try:
        km = float(distancia_km)
    except (TypeError, ValueError):
        return Decimal("1.0")

    corto_km = float(promo.get("coef_corto_km") or 0)
    medio_km = float(promo.get("coef_medio_km") or 0)

    if corto_km <= 0 or medio_km <= 0 or corto_km >= medio_km:
        logger.warning("promociones: limites de coeficiente incoherentes "
                       "(corto=%s, medio=%s); se usa el tramo largo", corto_km, medio_km)
        return _a_decimal(promo.get("coef_largo_valor"), Decimal("1.0"))

    if km <= corto_km:
        return _a_decimal(promo.get("coef_corto_valor"), Decimal("0.5"))
    if km <= medio_km:
        return _a_decimal(promo.get("coef_medio_valor"), Decimal("0.6"))
    return _a_decimal(promo.get("coef_largo_valor"), Decimal("1.0"))


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
    coef_corto_km: Optional[float] = Field(
        3.0, description="En km. A esta distancia y por debajo entra el coeficiente corto.")
    coef_corto_valor: Optional[float] = Field(
        0.5, description="Multiplica SOLO al kilometraje. La base y el tiempo van enteros.")
    coef_medio_km: Optional[float] = Field(
        10.0, description="En km. Tope del tramo medio, inclusivo.")
    coef_medio_valor: Optional[float] = Field(0.6)
    coef_largo_valor: Optional[float] = Field(
        1.0, description="Por encima del tramo medio. Con 1.0 el precio es el de siempre.")
    tiempo_espera_cortesia_minutos: Optional[float] = Field(
        4.0, description="Minutos gratis de espera. Lo que pase de ahi se paga al chofer.")


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

    # --- Coeficientes por distancia y espera de cortesía ---
    tarifas = _validar_tarifas(TarifasEsperaIn(
        coef_corto_km=datos.coef_corto_km, coef_corto_valor=datos.coef_corto_valor,
        coef_medio_km=datos.coef_medio_km, coef_medio_valor=datos.coef_medio_valor,
        coef_largo_valor=datos.coef_largo_valor,
        tiempo_espera_cortesia_minutos=datos.tiempo_espera_cortesia_minutos))

    return {
        "comision_porcentaje": comision,
        "bono_chofer_activo": bool(datos.bono_chofer_activo),
        "bono_chofer_monto": monto_bono,
        "bono_chofer_viajes_requeridos": viajes,
        "descuento_cliente_activo": descuento_activo,
        "descuento_cliente_porcentaje": descuento,
        "fecha_expiracion": expiracion,
        **tarifas,
    }


def _a_numero(valor: Any, nombre: str) -> float:
    """Lee un número de un valor del formulario o de la API, con un mensaje que
    diga QUÉ está mal en lugar de un 422 seco de pydantic.

    Los campos son opcionales a proposito: si el panel deja una casilla en blanco
    llega `None` (o "") y aqui se convierte en "la espera de cortesía debe ser un
    número", que el panel sabe señalar. Si fueran `float` a secas, pydantic
    respondería con un error de esquema que no menciona el campo.
    """
    if valor is None:
        raise HTTPException(status_code=400, detail="%s debe ser un número." % nombre)
    try:
        return float(valor)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="%s debe ser un número." % nombre)


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
    # Asegura zona en formato JSON serializable
    try:
        z = promo.get("zona_especial_coords")
        if isinstance(z, str):
            import json
            promo["zona_especial_coords"] = json.loads(z)
    except Exception:
        pass
    return _a_json(promo)


@router.post("")
async def guardar_promocion(datos: PromoIn, admin: dict = Depends(require_admin)):
    limpio = _validar(datos)
    columnas = ("comision_porcentaje, bono_chofer_activo, bono_chofer_monto, "
                "bono_chofer_viajes_requeridos, descuento_cliente_activo, "
                "descuento_cliente_porcentaje, fecha_expiracion, "
                "coef_corto_km, coef_corto_valor, coef_medio_km, coef_medio_valor, "
                "coef_largo_valor, tiempo_espera_cortesia_minutos")
    asignaciones = ", ".join("%s = %%s" % c for c in columnas.split(", "))
    valores = tuple(limpio[c.strip()] for c in columnas.split(", "))
    # El id va al final en los dos UPDATE: es el que se repite.
    # En el primero la fila no existe todavia, asi que se inserta primero y se
    # actualiza despues. Por eso se hace en dos pasos y no con un UPSERT.
    with _conexion() as conn:
        cur = conn.cursor()
        cur.execute("INSERT INTO promociones (id) VALUES (1) ON CONFLICT (id) DO NOTHING")
        cur.execute(
            "UPDATE promociones SET %s, actualizado_at = NOW(), actualizado_por = %%s "
            "WHERE id = 1" % asignaciones,
            valores + (admin.get("email"),))
        conn.commit()
        cur.close()

    logger.info("promociones: guardada por %s -> comision=%s descuento=%s%% "
                "coeficientes=%s/%s/%s cortesia=%s min",
                admin.get("email"), limpio["comision_porcentaje"],
                limpio["descuento_cliente_porcentaje"] * 100,
                limpio["coef_corto_valor"], limpio["coef_medio_valor"],
                limpio["coef_largo_valor"], limpio["tiempo_espera_cortesia_minutos"])

    promo = leer_promocion()
    respuesta = _a_json(promo)
    respuesta["message"] = "Configuración guardada"
    return respuesta


class TarifasEsperaIn(BaseModel):
    """Solo los coeficientes por distancia y la espera de cortesía.

    Van aparte de `PromoIn` a proposito. Las dos cosas viven en la misma fila de
    `promociones` porque comparten periodicidad, pero se editan desde pantallas
    distintas: si la pestaña de tarifas usara el guardado general, cada vez que
    un administrador tocara un coeficiente el formulario de comisiones enviaría
    también sus valores y una promotional caducada volvería a la vida.
    """
    coef_corto_km: Optional[float] = Field(
        3.0, description="En km. A esta distancia y por debajo entra el tramo corto.")
    coef_corto_valor: Optional[float] = Field(
        0.5, description="Multiplica SOLO al kilometraje. Base y tiempo van enteros.")
    coef_medio_km: Optional[float] = Field(
        10.0, description="En km. Tope del tramo medio, inclusivo.")
    coef_medio_valor: Optional[float] = Field(0.6)
    coef_largo_valor: Optional[float] = Field(
        1.0, description="Por encima del tramo medio. Con 1.0 es el precio de siempre.")
    tiempo_espera_cortesia_minutos: Optional[float] = Field(
        4.0, description="Minutos gratis de espera. Lo que pase de ahi se paga al chofer.")
    precio_por_minuto: Optional[float] = Field(5.0)
    precio_km_zona_basico: Optional[float] = Field(1000.0)
    precio_km_zona_confort: Optional[float] = Field(1200.0)
    precio_km_zona_triciclo: Optional[float] = Field(700.0)
    precio_km_zona_moto: Optional[float] = Field(600.0)
    zona_especial_coords: Optional[Any] = Field(
        default_factory=lambda: [
            [23.001228, -82.416735],
            [23.007982, -82.394788],
            [22.989298, -82.413242],
            [23.001007, -82.389251],
        ],
    )


def _validar_tarifas(datos: "TarifasEsperaIn") -> Dict[str, Any]:
    """Valida coeficientes y espera, y devuelve solo esos seis campos.

    Vive suelta para que la guarde tanto el formulario general de promociones
    como la pestaña de tarifas: son las mismas reglas y no tiene sentido que se
    pursiguen en dos sitios, porque un día se tocan una y la otra se queda vieja
    sin que nada lo delate.
    """
    corto_km = _a_numero(datos.coef_corto_km, "el límite de las carreras cortas")
    medio_km = _a_numero(datos.coef_medio_km, "el límite de las carreras medias")
    if corto_km <= 0 or medio_km <= 0:
        raise HTTPException(
            status_code=400, detail="Los límites en kilómetros deben ser mayores que cero.")
    if corto_km >= medio_km:
        raise HTTPException(
            status_code=400,
            detail="El límite de las carreras cortas (%s km) tiene que ser menor que el "
                   "de las medias (%s km)." % (corto_km, medio_km))

    tarifas = {
        "coef_corto_valor": _a_numero(datos.coef_corto_valor, "el coeficiente de las cortas"),
        "coef_medio_valor": _a_numero(datos.coef_medio_valor, "el coeficiente de las medias"),
        "coef_largo_valor": _a_numero(datos.coef_largo_valor, "el coeficiente de las largas"),
    }
    for nombre, valor in tarifas.items():
        if valor <= 0:
            raise HTTPException(
                status_code=400,
                detail="%s debe ser mayor que cero. Un coeficiente de cero haría que las "
                       "carreras de ese tramo no costaran nada." % nombre)

    espera = _a_numero(datos.tiempo_espera_cortesia_minutos, "la espera de cortesía")
    if espera < 0:
        raise HTTPException(
            status_code=400, detail="La espera de cortesía no puede ser negativa.")

    return {"coef_corto_km": corto_km, "coef_medio_km": medio_km,
            "tiempo_espera_cortesia_minutos": espera, **tarifas}


@router.get("/tarifas-espera")
async def obtener_tarifas_espera():
    """Coeficientes y espera de cortesía, sin el resto de la promoción.

    No pide administrador a proposito: el pasajero tiene que ver el precio
    estimado antes de pedir el viaje, y el chófer tiene que saber cuántos
    minutos de espera se le pagan antes de aceptar. Es la misma clase de dato
    publico que la tarifa base. Lo que NO es publico es cambiarla, y eso lo
    protege `guardar_tarifas_espera`.
    """
    promo = leer_promocion()
    return {
        "coef_corto_km": _a_dinero(promo["coef_corto_km"]),
        "coef_corto_valor": _a_dinero(promo["coef_corto_valor"]),
        "coef_medio_km": _a_dinero(promo["coef_medio_km"]),
        "coef_medio_valor": _a_dinero(promo["coef_medio_valor"]),
        "coef_largo_valor": _a_dinero(promo["coef_largo_valor"]),
        "tiempo_espera_cortesia_minutos": _a_dinero(promo["tiempo_espera_cortesia_minutos"]),
        "precio_por_minuto": _a_dinero(promo["precio_por_minuto"]),
        "precio_km_zona_basico": _a_dinero(promo["precio_km_zona_basico"]),
        "precio_km_zona_confort": _a_dinero(promo["precio_km_zona_confort"]),
        "precio_km_zona_triciclo": _a_dinero(promo["precio_km_zona_triciclo"]),
        "precio_km_zona_moto": _a_dinero(promo["precio_km_zona_moto"]),
        "tramos": [
            {"hasta_km": _a_dinero(promo["coef_corto_km"]),
             "coeficiente": _a_dinero(promo["coef_corto_valor"])},
            {"hasta_km": _a_dinero(promo["coef_medio_km"]),
             "coeficiente": _a_dinero(promo["coef_medio_valor"])},
            {"hasta_km": None, "coeficiente": _a_dinero(promo["coef_largo_valor"])},
        ],
    }


@router.post("/tarifas-espera")
async def guardar_tarifas_espera(datos: TarifasEsperaIn,
                                admin: dict = Depends(require_admin)):
    limpio = _validar_tarifas(datos)

    columnas = ("coef_corto_km, coef_corto_valor, coef_medio_km, "
                "coef_medio_valor, coef_largo_valor, tiempo_espera_cortesia_minutos")
    asignaciones = ", ".join("%s = %%s" % c for c in columnas.split(", "))
    valores = tuple(limpio[c.strip()] for c in columnas.split(", "))

    with _conexion() as conn:
        cur = conn.cursor()
        # Sin esto el UPDATE no tocaria nada en una base recien creada.
        cur.execute("INSERT INTO promociones (id) VALUES (1) ON CONFLICT (id) DO NOTHING")
        cur.execute("UPDATE promociones SET %s, actualizado_at = NOW(), "
                    "actualizado_por = %%s WHERE id = 1" % asignaciones,
                    valores + (admin.get("email"),))
        conn.commit()
        cur.close()

    logger.info("tarifas-espera: guardada por %s -> coeficientes=%s/%s/%s "
                "cortesia=%s min", admin.get("email"), limpio["coef_corto_valor"],
                limpio["coef_medio_valor"], limpio["coef_largo_valor"],
                limpio["tiempo_espera_cortesia_minutos"])

    respuesta = await obtener_tarifas_espera()
    respuesta["message"] = "Tarifas y espera guardadas"
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
        "coef_corto_km": float(promo["coef_corto_km"]),
        "coef_corto_valor": float(promo["coef_corto_valor"]),
        "coef_medio_km": float(promo["coef_medio_km"]),
        "coef_medio_valor": float(promo["coef_medio_valor"]),
        "coef_largo_valor": float(promo["coef_largo_valor"]),
        "tiempo_espera_cortesia_minutos": float(promo["tiempo_espera_cortesia_minutos"]),
        "precio_km_zona_basico": float(promo["precio_km_zona_basico"]),
        "precio_km_zona_confort": float(promo["precio_km_zona_confort"]),
        "precio_km_zona_triciclo": float(promo["precio_km_zona_triciclo"]),
        "precio_km_zona_moto": float(promo["precio_km_zona_moto"]),
        "zona_especial_coords": promo.get("zona_especial_coords"),
        "actualizado_at": (promo["actualizado_at"].isoformat()
                           if promo["actualizado_at"] else None),
        "actualizado_por": promo["actualizado_por"],
    }