import sys
sys.path.insert(0, "E:\\Taxi_Rapid")

import os
import logging
from contextlib import contextmanager

from fastapi import APIRouter, HTTPException, Query, BackgroundTasks
from pydantic import BaseModel
from typing import Optional
import psycopg2
import psycopg2.extras
from psycopg2.pool import ThreadedConnectionPool
from datetime import datetime, timedelta, date, timezone
from zoneinfo import ZoneInfo

try:
    from shapely.geometry import Point, Polygon
except Exception:
    Point = None
    Polygon = None
from routers.promociones import calcular_descuento_cliente, coeficiente_por_distancia, excedente_espera, leer_promocion  # noqa
from decimal import Decimal, ROUND_HALF_UP
from bson import ObjectId
from pymongo import MongoClient
import redis.asyncio as redis
import json
import asyncio
import time
import urllib.request
import urllib.parse

logger = logging.getLogger(__name__)

# Promociones: comision vigente, descuento al cliente y bono diario. Se importa
# aqui y no dentro de las funciones porque `routers.promociones` no importa este
# modulo (usa `get_connection` por dentro, en tiempo de llamada), asi que no
# queda ciclo.
# ===================== ZONA ESPECIAL =====================

_ZONA_ESPECIAL_POR_DEFECTO = [
    [23.001228, -82.416735],
    [23.007982, -82.394788],
    [22.989298, -82.413242],
    [23.001007, -82.389251],
]


def _punto_en_zona_especial(lat: float, lng: float, promo: dict) -> bool:
    if Point is None or Polygon is None:
        return False
    coords = promo.get("zona_especial_coords") or _ZONA_ESPECIAL_POR_DEFECTO
    try:
        if isinstance(coords, str):
            import json
            coords = json.loads(coords)
        if not coords or len(coords) < 3:
            return False
        # coords vienen como [[lat,lng], ...] desde JSON
        pts = []
        for c in coords:
            if not c or len(c) < 2:
                continue
            pts.append((float(c[1]), float(c[0])))
        if len(pts) < 3:
            return False
        try:
            from shapely.geometry import Polygon as ShapelyPolygon, MultiPoint
            # Intentar con orden original
            poly = ShapelyPolygon(pts)
            if not poly.is_valid:
                # Reordenar por convex hull para evitar auto-intersección
                poly = MultiPoint(pts).convex_hull
        except Exception:
            poly = Polygon(pts)
        if not poly.is_valid:
            poly = poly.buffer(0)
        # Si quedó como LineString o Point, intentar con polígono original corregido
        try:
            from shapely.geometry import Polygon as ShapelyPolygon
            if poly.geom_type in ('LineString', 'Point', 'MultiPoint'):
                poly = ShapelyPolygon(pts)
                poly = poly.buffer(0)
        except Exception:
            pass
        p = Point(float(lng), float(lat))
        return poly.contains(p) or poly.covers(p) or poly.intersects(p) or poly.touches(p)
    except Exception:
        return False


def _precio_km_por_zona(promo: dict, vehicle_type: str, lat: float, lng: float):
    if _punto_en_zona_especial(lat, lng, promo):
        tipo = str(vehicle_type).lower()
        if tipo == "confort":
            try:
                return float(promo.get("precio_km_zona_confort") or 1200.0)
            except Exception:
                return 1200.0
        if tipo == "triciclo":
            try:
                return float(promo.get("precio_km_zona_triciclo") or 700.0)
            except Exception:
                return 700.0
        if tipo == "moto":
            try:
                return float(promo.get("precio_km_zona_moto") or 600.0)
            except Exception:
                return 600.0
        try:
            return float(promo.get("precio_km_zona_basico") or 1000.0)
        except Exception:
            return 1000.0
    return None


# Distancia real POR CALLE entre dos puntos, para cobrar lo mismo que ve el
# pasajero en el mapa. La distancia que se factura NO puede ser la linea recta
# de PostGIS: en La Habana la recta y la calle pueden diferir en kilometros, y
# el pasajero ve en pantalla la ruta de OSRM. Si se cobra con otra distancia,
# el recibo no cuadra con el mapa y parece un abuso.
#
# Se consulta OSRM desde el backend (no desde el movil) porque desde Cuba el
# host publico de OSRM es inestable y el backend ya tiene un canal fiable al
# mismo sitio que usa `/api/routing/recalculate`. Si OSRM falla, se cae a la
# recta de PostGIS para no dejar el viaje sin precio.
OSRM_BASE_URL = os.getenv(
    "OSRM_BASE_URL", "https://router.project-osrm.org/route/v1/driving")
_OSRM_TIMEOUT_S = float(os.getenv("OSRM_TIMEOUT_S", "10"))


def _osrm_distance_km(lat1: float, lng1: float, lat2: float, lng2: float) -> Optional[float]:
    """Distancia por calle (km) segun OSRM, o None si OSRM no responde."""
    try:
        url = (
            f"{OSRM_BASE_URL}/{lng1},{lat1};{lng2},{lat2}"
            "?overview=false&alternatives=false"
        )
        with urllib.request.urlopen(url, timeout=_OSRM_TIMEOUT_S) as resp:
            cuerpo = json.loads(resp.read().decode("utf-8"))
        rutas = cuerpo.get("routes") or []
        if not rutas:
            return None
        metros = float(rutas[0].get("distance", 0.0))
        if metros <= 0:
            return None
        return metros / 1000.0
    except Exception:
        logger.warning("OSRM no respondio; se usa distancia en linea recta",
                       exc_info=True)
        return None


def distancia_por_calle_km(
    request_lat: float, request_lng: float,
    dropoff_lat: float, dropoff_lng: float,
) -> float:
    """Distancia facturable: por calle (OSRM) y, si falla, linea recta PostGIS."""
    km = _osrm_distance_km(request_lat, request_lng, dropoff_lat, dropoff_lng)
    if km is not None:
        return km
    return _distancia_recta_km(request_lat, request_lng, dropoff_lat, dropoff_lng)


def _distancia_recta_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Distancia geodesica en linea recta (PostGIS), como respaldo."""
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT ST_Distance(
                ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
                ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography
            ) / 1000.0
            """,
            (lng1, lat1, lng2, lat2),
        )
        valor = float(cur.fetchone()[0] or 0.0)
        cur.close()
        return valor

# ===================== Zona horaria Cuba =====================
CUBA_TZ = ZoneInfo("America/Havana")

# ===================== Garnet (Redis) =====================
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
garnet = redis.from_url(REDIS_URL, decode_responses=True)

# ===================== Traccar (trazado de rutas) =====================
TRACCAR_HTTP = os.getenv("TRACCAR_HTTP", "http://localhost:8082")
TRACCAR_OSMAND = os.getenv("TRACCAR_OSMAND", "http://localhost:5055")
# El token caduca (el actual vence el 2027-07-12). Va en variable de entorno y
# no en el codigo: este repositorio se publica en GitHub.
TRACCAR_TOKEN = os.getenv("TRACCAR_TOKEN")


def _to_utc(dt) -> datetime:
    """Convierte un datetime (aware o naive) a UTC para las consultas a Traccar."""
    if dt is None:
        return datetime.now(timezone.utc)
    if dt.tzinfo is None:
        return dt.replace(tzinfo=CUBA_TZ).astimezone(timezone.utc)
    return dt.astimezone(timezone.utc)


def _forward_driver_position_to_traccar(driver_id: str, lat: float, lng: float) -> None:
    """Empuja la posicion del conductor a Traccar (protocolo osmand) para
    registrar el trazado real de la ruta durante el viaje."""
    try:
        doc = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
        if not doc:
            return
        uid = doc.get("traccar_device_uid")
        if not uid:
            return
        ts = int(time.time() * 1000)
        url = (f"{TRACCAR_OSMAND}/?id={urllib.parse.quote(str(uid))}"
               f"&lat={lat}&lon={lng}&timestamp={ts}")
        req = urllib.request.Request(url, headers={"User-Agent": "TaxiRapid/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            resp.read()
    except Exception:
        logger.debug("No se pudo enviar posicion a Traccar", exc_info=True)


def _get_traccar_route(driver_id: str, start_dt, end_dt) -> list[dict]:
    """Consulta a Traccar el historico de posiciones del dispositivo del
    conductor entre dos fechas y lo devuelve como lista de puntos."""
    doc = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
    if not doc:
        return []
    dev_id = doc.get("traccar_device_id")
    if dev_id is None:
        return []
    if not TRACCAR_TOKEN:
        logger.warning(
            "TRACCAR_TOKEN no esta definido: no se puede leer la ruta del viaje. "
            "Definir la variable de entorno con el token de Traccar."
        )
        return []
    since = (_to_utc(start_dt) - timedelta(minutes=2)).isoformat()
    until = (_to_utc(end_dt) + timedelta(minutes=2)).isoformat()
    query = urllib.parse.urlencode({"deviceId": dev_id, "from": since, "to": until})
    req = urllib.request.Request(
        f"{TRACCAR_HTTP}/api/positions?{query}",
        headers={"Authorization": f"Bearer {TRACCAR_TOKEN}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception:
        logger.debug("No se pudo leer ruta de Traccar", exc_info=True)
        return []
    return [
        {"lat": p["latitude"], "lng": p["longitude"], "time": p.get("fixTime")}
        for p in data
    ]

# ===================== MongoDB =====================
mongo_client = MongoClient(os.getenv("MONGODB_URI", "mongodb://localhost:27017"))
chofer_db = mongo_client["Chofer"]
cliente_db = mongo_client["Cliente"]
chofer_coleccion = chofer_db["users"]
cliente_coleccion = cliente_db["users"]
router = APIRouter()

def to_mongo_id(id_str: str) -> ObjectId:
    return ObjectId(id_str)


def from_mongo_id(oid: ObjectId) -> str:
    return str(oid)


def _client_display_name(client_doc: Optional[dict]) -> Optional[str]:
    """Nombre legible del pasajero desde su documento en MongoDB."""
    if not client_doc:
        return None
    profile = client_doc.get("profile", {}) or {}
    nombre = profile.get("name") or client_doc.get("Nombre") or client_doc.get("nombre")
    apellidos = client_doc.get("Apellidos") or client_doc.get("apellidos")
    full = f"{nombre or ''} {apellidos or ''}".strip()
    return full or None


def _client_phone(client_doc: Optional[dict]) -> Optional[str]:
    """Telefono del pasajero (formato libre, ej. '+34 612345678')."""
    if not client_doc:
        return None
    profile = client_doc.get("profile", {}) or {}
    return (
        client_doc.get("numero_de_telefono")
        or client_doc.get("phone")
        or profile.get("phone")
    )


def validate_client_exists(client_id: str) -> bool:
    try:
        result = cliente_coleccion.find_one({"_id": to_mongo_id(client_id)})
        return result is not None
    except Exception:
        return False


def validate_driver_exists(driver_id: str) -> bool:
    try:
        result = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
        return result is not None
    except Exception:
        return False


def saldo_de_chofer(driver_id: str) -> Optional[float]:
    """Fondo actual del chofer, o None si Mongo no responde.

    Devuelve None y no 0 a propósito: si la base no se puede leer, quien llama
    no debe inventarse un saldo y bloquear a un chofer que sí tiene fondo.
    Quien lo use tiene que decidir qué hacer con ese None.
    """
    try:
        documento = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
        if not documento:
            return None
        valor = documento.get("Fondo")
        if valor is None:
            valor = documento.get("fondo")
        return float(valor or 0)
    except Exception:
        logger.exception("No se pudo leer el fondo de %s", driver_id)
        return None


# ===================== PostgreSQL (Pool de conexiones) =====================
DB_CONFIG = {
    "dbname": "taxi_db",
    "user": "postgres",
    "password": os.environ.get("DB_PASSWORD", ""),
    "host": "localhost",
    "port": 5432,
}

pool: Optional[ThreadedConnectionPool] = None
POSTGRES_URL = os.getenv("POSTGRES_URL", "")


def init_pool():
    """Inicializa el pool de conexiones (llamar al arrancar la app)."""
    global pool
    if pool is None:
        if POSTGRES_URL:
            pool = ThreadedConnectionPool(minconn=1, maxconn=20, dsn=POSTGRES_URL)
        else:
            pool = ThreadedConnectionPool(minconn=1, maxconn=20, **DB_CONFIG)


@contextmanager
def get_connection():
    """Context manager que obtiene y devuelve conexiones al pool."""
    if pool is None:
        init_pool()
    conn = pool.getconn()
    try:
        yield conn
    finally:
        pool.putconn(conn)


# ===================== Inicializacion de la BD =====================
def init_db():
    """
    Crea las tablas necesarias ejecutando las sentencias SQL
    directamente desde el codigo Python.
    """
    # Extension necesaria para gen_random_uuid() en PG < 13
    create_pgcrypto = "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
    # trips usa GEOGRAPHY(Point,4326): requiere la extension PostGIS
    create_postgis = "CREATE EXTENSION IF NOT EXISTS postgis;"

    create_trips_table = """
        CREATE TABLE IF NOT EXISTS trips (
            id SERIAL PRIMARY KEY,
            trip_id VARCHAR(50) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
            client_id VARCHAR(50),
            driver_id VARCHAR(50),
            status VARCHAR(20) DEFAULT 'requested',
            request_location GEOGRAPHY(Point, 4326),
            pickup_location GEOGRAPHY(Point, 4326),
            dropoff_location GEOGRAPHY(Point, 4326),
            requested_at TIMESTAMP DEFAULT NOW(),
            started_at TIMESTAMP,
            completed_at TIMESTAMP,
            created_at TIMESTAMP DEFAULT NOW(),
            distance_km NUMERIC(10,2),
            duration_secs INTEGER,
            base_fare NUMERIC(10,2),
            distance_fare NUMERIC(10,2),
            tip NUMERIC(10,2) DEFAULT 0,
            total_fare NUMERIC(10,2),
            currency VARCHAR(10) DEFAULT 'CUP',
            payment_method VARCHAR(50),
            equipaje BOOLEAN DEFAULT FALSE,
            mascota BOOLEAN DEFAULT FALSE,
            num_pasajes INTEGER DEFAULT 1,
            vehicle_type VARCHAR(20) DEFAULT 'basico',
            precio_estimado NUMERIC(10,2),
            request_address TEXT,
            dropoff_address TEXT
        );
    """

    migrate_trips_addresses = """
        ALTER TABLE trips
            ADD COLUMN IF NOT EXISTS request_address TEXT,
            ADD COLUMN IF NOT EXISTS dropoff_address TEXT;
    """

    # Descuento que se le concedio al cliente y comision que se habria cobrado sin
    # el. Se guardan para que el reparto de dinero de cada viaje sea auditable:
    # sin estas dos columnas no hay forma de comprobar despues que al chofer no
    # se le descuento nada de su parte.
    migrate_trips_promociones = """
        ALTER TABLE trips
            ADD COLUMN IF NOT EXISTS descuento_cliente NUMERIC(12,2) DEFAULT 0,
            ADD COLUMN IF NOT EXISTS comision_nominal NUMERIC(12,2),
            ADD COLUMN IF NOT EXISTS hora_llegada TIMESTAMP,
            ADD COLUMN IF NOT EXISTS espera_secs INTEGER DEFAULT 0,
            ADD COLUMN IF NOT EXISTS excedente_espera_secs INTEGER DEFAULT 0,
            -- Que coeficiente se aplico a este viaje. Sin esto no hay forma de
            -- saber despues por que un viaje corto salio mas barato: el
            -- administrador puede haber cambiado los tramos entre la estimacion
            -- y el cobro, y sin guardar el valor la reclamacion no se puede
            -- responder. NULL en los viajes anteriores a esta columna.
            ADD COLUMN IF NOT EXISTS coeficiente_aplicado NUMERIC(6,4);
    """

    create_transactions_table = """
        CREATE TABLE IF NOT EXISTS transactions (
            id SERIAL PRIMARY KEY,
            transaction_id VARCHAR(50) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
            trip_id VARCHAR(50) REFERENCES trips(trip_id),
            user_id VARCHAR(50),
            user_type VARCHAR(20),
            amount NUMERIC(10,2),
            transaction_type VARCHAR(50),
            payment_gateway VARCHAR(50),
            gateway_reference VARCHAR(100),
            status VARCHAR(20) DEFAULT 'pending',
            created_at TIMESTAMP DEFAULT NOW()
        );
    """

    create_driver_payouts_table = """
        CREATE TABLE IF NOT EXISTS driver_payouts (
    id SERIAL PRIMARY KEY,
    payout_id VARCHAR(50) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
    driver_id VARCHAR(50) NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    total_earnings NUMERIC(12,2) NOT NULL,
    commission NUMERIC(12,2) NOT NULL,
    net_amount NUMERIC(12,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    paid_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW()
        );
    """
    create_tariffs_table = """
        CREATE TABLE IF NOT EXISTS tariffs (
    tariff_id SERIAL PRIMARY KEY,
    vehicle_type VARCHAR(20) UNIQUE NOT NULL,  -- moto, triciclo, basico, confort
    base_fare DECIMAL(10,2) NOT NULL,
    price_per_km DECIMAL(10,2) NOT NULL,
    price_per_minute DECIMAL(10,2) NOT NULL,
    max_passengers INT NOT NULL DEFAULT 4,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
    """
    create_daily_trip_metrics_table = """
    CREATE TABLE IF NOT EXISTS daily_trip_metrics(
        dia DATE PRIMARY KEY,
        viajes_completados INTEGER NOT NULL DEFAULT 0,
        facturado NUMERIC(12,2) NOT NULL DEFAULT 0,
        ticket_promedio NUMERIC(12,2) NOT NULL DEFAULT 0,
        choferes_activos INTEGER NOT NULL DEFAULT 0,
        clientes_activos INTEGER NOT NULL DEFAULT 0,
        actualizado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    """

    create_time_pricing_rules = """
    CREATE TABLE IF NOT EXISTS time_pricing_rules (
    id SERIAL PRIMARY KEY,
    vehicle_type VARCHAR(20) NOT NULL,
    start_time TIME NOT NULL,
    end_time TIME NOT NULL,
    base_fare_multiplier NUMERIC(5,2) DEFAULT 1.0,
    price_per_km_multiplier NUMERIC(5,2) DEFAULT 1.0,
    price_per_minute_multiplier NUMERIC(5,2) DEFAULT 1.0,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
    """

    # Indices para rendimiento
    create_indexes = """
    CREATE INDEX IF NOT EXISTS idx_trips_completed_at
        ON trips (completed_at) WHERE status = 'completed';
    CREATE INDEX IF NOT EXISTS idx_trips_driver_status
        ON trips (driver_id, status);
    CREATE INDEX IF NOT EXISTS idx_trips_client
        ON trips (client_id, requested_at DESC);
    CREATE INDEX IF NOT EXISTS idx_trips_status_requested
        ON trips (status, requested_at);
    CREATE INDEX IF NOT EXISTS idx_transactions_trip_id
        ON transactions (trip_id);
    CREATE INDEX IF NOT EXISTS idx_transactions_user
        ON transactions (user_id, user_type);
    """

    # Lista de sentencias a ejecutar (en orden, respetando dependencias)
    sql_statements = [
        create_pgcrypto,
        create_postgis,
        create_trips_table,
        migrate_trips_addresses,
        migrate_trips_promociones,
        create_transactions_table,
        create_driver_payouts_table,
        create_tariffs_table,
        create_daily_trip_metrics_table,
        create_time_pricing_rules,
        create_indexes,
    ]

    with get_connection() as conn:
        cur = conn.cursor()
        try:
            for stmt in sql_statements:
                cur.execute(stmt)
                print("[OK] Sentencia ejecutada correctamente.")
            conn.commit()
            print("[OK] Todas las tablas e indices estan listos.")
        except Exception as e:
            conn.rollback()
            print(f"[X] Error al crear las tablas. Se ha hecho rollback.")
            print(f"   Detalle: {e}")
            raise
        finally:
            cur.close()

# ===================== Tarifas ===================
def _resolve_vehicle_type(value: Optional[str]) -> Optional[str]:
    """Devuelve el tipo de vehiculo tal como esta guardado en `tariffs`.

    El frontend envia 'basico' (normalizado, sin acentos) pero las tarifas
    ahora se guardan como 'básico' con tilde. Esta funcion devuelve el valor
    canonico de la base para que los matchs SQL (exactos) encuentren la fila.
    """
    wanted = _normalize_vehicle_type(value)
    if not wanted:
        return None
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT vehicle_type FROM tariffs")
        for row in cur.fetchall():
            if _normalize_vehicle_type(row["vehicle_type"]) == wanted:
                cur.close()
                return row["vehicle_type"]
        cur.close()
    return None

def get_tariff(vehicle_type: str) -> Optional[dict]:
    """Obtiene la tarifa vigente para un tipo de vehiculo."""
    canonico = _resolve_vehicle_type(vehicle_type)
    if not canonico:
        return None
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT * FROM tariffs WHERE vehicle_type = %s",
            (canonico,)
        )
        row = cur.fetchone()
        cur.close()
        return dict(row) if row else None

def get_all_tariffs() -> list[dict]:
    """Obtiene todas las tarifas configuradas."""
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM tariffs ORDER BY base_fare ASC")
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows

def update_tariff(
    vehicle_type: str,
    base_fare: Optional[Decimal] = None,
    price_per_km: Optional[Decimal] = None,
    price_per_minute: Optional[Decimal] = None,
    max_passengers: Optional[int] = None,
) -> bool:
    """Actualiza una tarifa existente."""
    with get_connection() as conn:
        cur = conn.cursor()

        updates = []
        params = []

        if base_fare is not None:
            updates.append("base_fare = %s")
            params.append(base_fare)
        if price_per_km is not None:
            updates.append("price_per_km = %s")
            params.append(price_per_km)
        if price_per_minute is not None:
            updates.append("price_per_minute = %s")
            params.append(price_per_minute)
        if max_passengers is not None:
            updates.append("max_passengers = %s")
            params.append(max_passengers)

        if not updates:
            return False

        canonic = _resolve_vehicle_type(vehicle_type)
        if not canonic:
            return False

        updates.append("updated_at = NOW()")
        params.append(canonic)

        cur.execute(
            f"UPDATE tariffs SET {', '.join(updates)} WHERE vehicle_type = %s",
            params
        )
        affected = cur.rowcount
        conn.commit()
        cur.close()
        return affected > 0

def get_applicable_time_rule(vehicle_type: str, current_time: datetime) -> Optional[dict]:
    """Retorna la regla horaria que aplica segun la hora actual, o None si no hay ninguna."""
    canonico = _resolve_vehicle_type(vehicle_type)
    if not canonico:
        return None
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        # Manejar cruce de medianoche (start_time > end_time)
        cur.execute("""
            SELECT * FROM time_pricing_rules
            WHERE vehicle_type = %s
              AND (
                (start_time < end_time AND %s::time BETWEEN start_time AND end_time)
                OR
                (start_time > end_time AND (%s::time >= start_time OR %s::time <= end_time))
              )
            ORDER BY start_time
            LIMIT 1
        """, (canonico, current_time, current_time, current_time))
        row = cur.fetchone()
        cur.close()
        return dict(row) if row else None

def _price_breakdown(distance_km: float, vehicle_type: str, pickup_lat=None, pickup_lng=None, dropoff_lat=None, dropoff_lng=None) -> dict:
    """Calcula los componentes de tarifa usando la tarifa vigente y la regla horaria.

    Fórmula exacta:
        Precio_Final = Tarifa_Base + (Distancia_Km * Precio_Km_Aplicable * Coeficiente_Distancia) + (Tiempo_Total_Minutos * Precio_Por_Minuto)

    Precio_Km_Aplicable: zona especial si el DESTINO cae dentro del polígono (1000/1200) o precio estándar.
    Tiempo_Total_Minutos incluye tiempo de viaje + excedente de espera (se calcula en complete_trip).
    """
    tariff = get_tariff(vehicle_type)
    if not tariff:
        raise ValueError(f"No hay tarifa configurada para: {vehicle_type}")
    AVG_SPEED_KMH = 30
    estimated_time_min = (distance_km / AVG_SPEED_KMH) * 60
    base_fare = float(tariff["base_fare"])
    price_per_km = float(tariff["price_per_km"])
    price_per_minute = float(tariff["price_per_minute"])
    time_rule = get_applicable_time_rule(vehicle_type, datetime.now(timezone.utc))
    if time_rule:
        base_fare *= float(time_rule["base_fare_multiplier"])
        price_per_km *= float(time_rule["price_per_km_multiplier"])
        price_per_minute *= float(time_rule["price_per_minute_multiplier"])

    try:
        promo = leer_promocion()
        # Precio por minuto desde configuración global (promociones id=1)
        ppm = promo.get("precio_por_minuto")
        if ppm is not None:
            price_per_minute = float(ppm)
            if time_rule:
                price_per_minute = price_per_minute * float(time_rule["price_per_minute_multiplier"])
    except Exception:
        promo = {}

    coeficiente = coeficiente_por_distancia(distance_km, promo)

    precio_km_aplicable = _precio_km_por_zona(
        promo, vehicle_type,
        dropoff_lat if dropoff_lat is not None else pickup_lat,
        dropoff_lng if dropoff_lng is not None else pickup_lng,
    )
    if precio_km_aplicable is not None:
        price_per_km = float(precio_km_aplicable)

    distance_fare = distance_km * price_per_km * float(coeficiente)
    distance_fare_sin_coeficiente = distance_km * price_per_km
    time_fare = estimated_time_min * price_per_minute
    precio_final = base_fare + distance_fare + time_fare
    return {
        "distance_km": round(distance_km, 2),
        "estimated_time_min": round(estimated_time_min, 1),
        "base_fare": round(base_fare, 2),
        "tarifa_base": round(base_fare, 2),
        "coeficiente": float(coeficiente),
        "coeficiente_distancia": float(coeficiente),
        "price_per_km": round(price_per_km, 4),
        "precio_km_aplicable": round(price_per_km, 4),
        "precio_por_minuto": round(price_per_minute, 4),
        "distance_fare": round(distance_fare, 2),
        "costo_distancia": round(distance_fare, 2),
        "distance_fare_sin_coeficiente": round(distance_fare_sin_coeficiente, 2),
        "ahorro_por_coeficiente": round(distance_fare_sin_coeficiente - distance_fare, 2),
        "time_fare": round(time_fare, 2),
        "costo_tiempo": round(time_fare, 2),
        "precio_estimado": round(precio_final, 2),
        "precio_final": round(precio_final, 2),
        "vehicle_type": vehicle_type,
        "zona_especial_aplicada": _precio_km_por_zona(promo, vehicle_type,
                                                       dropoff_lat if dropoff_lat is not None else pickup_lat,
                                                       dropoff_lng if dropoff_lng is not None else pickup_lng) is not None,
    }


# Los minutos de cortesía valen 4 mientras la tabla de promociones no este
# disponible. Es el valor por defecto del enunciado y es preferible contestar
# con 4 que no contestar: pintar "esperando" sin el dato de la cortesía es
# misinformation, y 4 solo se usa si la base se caido.
_CORTESIA_POR_DEFECTO = 4


def _cortesia_minutos_actual() -> float:
    """Minutos de espera que regala la plataforma ahora mismo.

    Se lee aquí y no en cada sitio que la necesita porque la fila de
    configuracion se cambia en caliente desde el panel, y este valor se pinta en
    la app del chofer.
    """
    try:
        return float(leer_promocion()["tiempo_espera_cortesia_minutos"])
    except Exception:
        logger.warning("no se pudo leer la cortesía; se usa %s min",
                       _CORTESIA_POR_DEFECTO, exc_info=True)
        return float(_CORTESIA_POR_DEFECTO)

def calculate_estimated_price(distance_km: float, vehicle_type: str) -> float:
    return _price_breakdown(distance_km, vehicle_type)["precio_estimado"]

def estimate_trip_price(
    request_lat: float,
    request_lng: float,
    dropoff_lat: float,
    dropoff_lng: float,
    vehicle_type: str = "basico",
) -> dict:
    """Calcula la tarifa estimada sin crear el viaje (misma distancia y formula que create_trip)."""
    distance_km = distancia_por_calle_km(
        request_lat, request_lng, dropoff_lat, dropoff_lng)
    return _price_breakdown(distance_km, vehicle_type, request_lat, request_lng, dropoff_lat, dropoff_lng)


def estimate_all_vehicles(
    request_lat: float,
    request_lng: float,
    dropoff_lat: float,
    dropoff_lng: float,
) -> dict:
    """Calcula precios para los 4 vehículos en una sola llamada.
    
    Reutiliza _price_breakdown (misma lógica que estimate_trip_price).
    Los precios CUP ya están actualizados en la BD por el cron diario.
    """
    distance_km = distancia_por_calle_km(
        request_lat, request_lng, dropoff_lat, dropoff_lng)
    
    # Velocidad promedio para ETA (km/h)
    AVG_SPEED_KMH = 30
    eta_minutes = round((distance_km / AVG_SPEED_KMH) * 60)
    eta_text = f"{eta_minutes} min"
    
    vehicles = []
    for vehicle_type in ["moto", "triciclo", "basico", "confort"]:
        breakdown = _price_breakdown(distance_km, vehicle_type, request_lat, request_lng, dropoff_lat, dropoff_lng)
        vehicles.append({
            "vehicle_type": vehicle_type,
            "price": breakdown["precio_estimado"],
            "base_fare": breakdown["base_fare"],
            "distance_fare": breakdown["distance_fare"],
            "time_fare": breakdown["time_fare"],
            "coeficiente": breakdown["coeficiente"],
        })
    
    return {
        "distance_km": round(distance_km, 2),
        "eta_minutes": eta_minutes,
        "eta_text": eta_text,
        "payment_method": "Efectivo",
        "vehicles": vehicles,
    }
# ===================== TRIPS =====================

def create_trip(
    client_id: str,
    request_lat: float,
    request_lng: float,
    dropoff_lat: float,
    dropoff_lng: float,
    driver_id: Optional[str] = None,  # Opcional: si no se proporciona, el viaje queda 'requested' sin chofer
    equipaje: bool = False,
    mascota: bool = False,
    vehicle_type: str = "basico",
    num_pasajes: int = 1,
    base_fare: Optional[float] = None,
    request_address: Optional[str] = None,
    dropoff_address: Optional[str] = None,
) -> dict:
    vehicle_type = _normalize_vehicle_type(vehicle_type) or "basico"
    if not validate_client_exists(client_id):
        raise ValueError(f"Cliente no encontrado en MongoDB: {client_id}")
    # Solo validar conductor si se proporciono driver_id explicitamente
    if driver_id is not None and not validate_driver_exists(driver_id):
        raise ValueError(f"Conductor no encontrado en MongoDB: {driver_id}")

    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        try:
            # Distancia por calle (OSRM) para que el precio coincida con la ruta
            # que el pasajero ve en el mapa. Se guarda en el viaje para que el
            # cobro real use EXACTAMENTE esta misma distancia y no una distinta.
            distance_km = distancia_por_calle_km(
                request_lat, request_lng, dropoff_lat, dropoff_lng)

            precio_estimado = calculate_estimated_price(distance_km, vehicle_type)

            # Si hay driver_id, el estado es 'accepted'; si no, queda 'requested' sin chofer
            initial_status = "accepted" if driver_id else "requested"

            cur.execute(
                """
                INSERT INTO trips (
                    client_id, driver_id, status, request_location, dropoff_location,
                    equipaje, mascota, num_pasajes, vehicle_type,
                    precio_estimado, base_fare, distance_km, request_address, dropoff_address
                ) VALUES (
                    %s, %s, %s,
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
                    %s, %s, %s, %s, %s, %s, %s, %s, %s
                )
                RETURNING trip_id;
                """,
                (
                    client_id, driver_id, initial_status,
                    request_lng, request_lat,
                    dropoff_lng, dropoff_lat,
                    equipaje, mascota, num_pasajes, vehicle_type,
                    precio_estimado, base_fare, round(distance_km, 3),
                    request_address, dropoff_address
                ),
            )
            trip_id = cur.fetchone()["trip_id"]
            conn.commit()

            return {
                "trip_id": trip_id,
                "driver_id": driver_id,
                "status": initial_status,
                "precio_estimado": precio_estimado,
                "distance_km": round(distance_km, 2),
                "equipaje": equipaje,
                "mascota": mascota,
                "num_pasajes": num_pasajes,
                "vehicle_type": vehicle_type,
            }
        except Exception as e:
            conn.rollback()
            raise e
        finally:
            cur.close()


def get_trip(trip_id: str) -> Optional[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT
                trip_id, client_id, driver_id, status,
                ST_AsText(request_location) as request_location,
                ST_AsText(pickup_location) as pickup_location,
                ST_AsText(dropoff_location) as dropoff_location,
                requested_at, started_at, completed_at, created_at,
                hora_llegada, espera_secs, excedente_espera_secs,
                coeficiente_aplicado,
                GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (
                    COALESCE(started_at, NOW()) - hora_llegada)), 0))::int
                    AS espera_segundos,
                distance_km, duration_secs,
                base_fare, distance_fare, tip, total_fare,
                currency, payment_method,
                equipaje, mascota, num_pasajes, vehicle_type, precio_estimado,
                request_address, dropoff_address
            FROM trips WHERE trip_id = %s;
            """,
            (trip_id,),
        )
        row = cur.fetchone()
        cur.close()
        if row:
            row = dict(row)
        return row


def update_trip_status(trip_id: str, status: str) -> bool:
    valid_statuses = ["requested", "accepted", "driver_arrived", "in_progress", "completed", "cancelled"]
    if status not in valid_statuses:
        raise ValueError(f"Status invalido. Opciones validas: {valid_statuses}")

    with get_connection() as conn:
        cur = conn.cursor()

        extra = {}
        if status == "accepted":
            pass
        elif status == "driver_arrived":
            # Momento en que el chofer llega al punto de recogida. Es el origen
            # del reloj de espera: a partir de aqui el pasajero tiene gratis los
            # primeros minutos de cortesia y lo que pase de ahi se le paga al
            # chofer. Antes este estado no guardaba ninguna hora, y sin ella no
            # habia forma de saber cuanto espero el pasajero.
            extra["hora_llegada"] = datetime.now(timezone.utc)
        elif status == "in_progress":
            extra["started_at"] = datetime.now(timezone.utc)
        elif status == "completed":
            extra["completed_at"] = datetime.now(timezone.utc)
        elif status == "cancelled":
            extra["completed_at"] = datetime.now(timezone.utc)

        # Construir la clausula SET dinamicamente con todos los campos presentes
        set_clauses = ["status = %s"]
        params = [status]

        if "started_at" in extra:
            set_clauses.append("started_at = %s")
            params.append(extra["started_at"])
        if "completed_at" in extra:
            set_clauses.append("completed_at = %s")
            params.append(extra["completed_at"])

        params.append(trip_id)
        cur.execute(
            f"UPDATE trips SET {', '.join(set_clauses)} WHERE trip_id = %s",
            params
        )

        affected = cur.rowcount
        conn.commit()
        cur.close()
        return affected > 0


def set_pickup_location(trip_id: str, lat: float, lng: float) -> bool:
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE trips SET pickup_location = ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography WHERE trip_id = %s",
            (lng, lat, trip_id),
        )
        affected = cur.rowcount
        conn.commit()
        cur.close()
        return affected > 0


def set_dropoff_location(trip_id: str, lat: float, lng: float) -> bool:
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE trips SET dropoff_location = ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography WHERE trip_id = %s",
            (lng, lat, trip_id),
        )
        affected = cur.rowcount
        conn.commit()
        cur.close()
        return affected > 0

def daily_trip_metrics():
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        try:
            actualizar_daily_trip_metrics_table = """
            INSERT INTO daily_trip_metrics (
  dia, viajes_completados, facturado, ticket_promedio,
  choferes_activos, clientes_activos, actualizado_en
)
SELECT
  DATE(completed_at AT TIME ZONE 'America/Havana') AS dia,
  COUNT(*) AS viajes_completados,
  SUM(total_fare) AS facturado,
  AVG(total_fare) AS ticket_promedio,
  COUNT(DISTINCT driver_id) AS choferes_activos,
  COUNT(DISTINCT client_id) AS clientes_activos,
  NOW()
FROM trips
WHERE status = 'completed'
  AND completed_at >= ((NOW() AT TIME ZONE 'America/Havana')::date - INTERVAL '2 days')::timestamp AT TIME ZONE 'America/Havana'
GROUP BY 1
ON CONFLICT (dia) DO UPDATE SET
  viajes_completados = EXCLUDED.viajes_completados,
  facturado          = EXCLUDED.facturado,
  ticket_promedio    = EXCLUDED.ticket_promedio,
  choferes_activos   = EXCLUDED.choferes_activos,
  clientes_activos   = EXCLUDED.clientes_activos,
  actualizado_en     = NOW();
            """
            cur.execute(actualizar_daily_trip_metrics_table)
            conn.commit()
        except Exception as e:
            conn.rollback()
            logger.exception("Error actualizando daily_trip_metrics: %s", e)
            raise e
        finally:
            cur.close()

def complete_trip(trip_id: str, dropoff_lat: float, dropoff_lng: float, tip: float = 0.0) -> dict:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        try:
            # 1. Obtener el viaje actual
            cur.execute("SELECT * FROM trips WHERE trip_id = %s FOR UPDATE", (trip_id,))
            trip = cur.fetchone()
            if not trip:
                raise ValueError("Viaje no encontrado")
            if trip["status"] != "in_progress":
                raise ValueError("El viaje no está en curso")

            # 2. Obtener el conductor desde MongoDB usando _id (coherente con el resto del codigo)
            driver = chofer_coleccion.find_one({"_id": to_mongo_id(trip["driver_id"])})
            if not driver:
                raise ValueError("Conductor no encontrado")
            vehicle_type = _driver_vehicle_type(driver) or "basico"

            # 3. Obtener tarifas desde PostgreSQL
            tariff = get_tariff(vehicle_type)
            if not tariff:
                raise ValueError(f"No hay tarifa configurada para: {vehicle_type}")

            # 4. Obtener regla horaria activa segun la hora actual
            now = datetime.now(timezone.utc)
            time_rule = get_applicable_time_rule(vehicle_type, now)

            # 5. Calcular tarifas base con multiplicadores horarios
            base_fare = float(tariff["base_fare"])
            price_per_km = float(tariff["price_per_km"])
            price_per_minute = float(tariff["price_per_minute"])

            applied_rule_desc = None
            if time_rule:
                base_fare *= float(time_rule["base_fare_multiplier"])
                price_per_km *= float(time_rule["price_per_km_multiplier"])
                price_per_minute *= float(time_rule["price_per_minute_multiplier"])
                applied_rule_desc = time_rule.get("description")

            # 6. Distancia real facturable.
            #    Se usa la distancia POR CALLE que se guardo al crear el viaje
            #    (OSRM), para que el cobro coincida con la ruta que el pasajero
            #    vio en el mapa. Solo si no quedo guardada (viajes viejos) se
            #    recalcula: primero por calle entre pickup y destino, y si OSRM
            #    falla, la recta de PostGIS.
            distance_km = trip.get("distance_km")
            if distance_km is None or float(distance_km) <= 0:
                # Punto de recogida real (o el solicitado si el chofer no lo marco)
                cur.execute("""
                    SELECT ST_Y(COALESCE(pickup_location, request_location)::geometry) AS lat,
                           ST_X(COALESCE(pickup_location, request_location)::geometry) AS lng
                    FROM trips WHERE trip_id = %s
                """, (trip_id,))
                p = cur.fetchone()
                if p and p["lat"] is not None and p["lng"] is not None:
                    distance_km = distancia_por_calle_km(
                        float(p["lat"]), float(p["lng"]), dropoff_lat, dropoff_lng)
                else:
                    distance_km = _distancia_recta_km(
                        trip["request_location"].y if hasattr(trip["request_location"], "y") else 0.0,
                        trip["request_location"].x if hasattr(trip["request_location"], "x") else 0.0,
                        dropoff_lat, dropoff_lng)
            distance_km = float(distance_km or 0.0)

            # 7. Calcular duracion real (desde que se inicio el viaje)
            #
            # Sale de ahi el 500 que veia el chofer al pulsar
            # "Completar viaje" (TypeError: can't subtract offset-naive and
            # offset-aware datetimes):
            #
            #  * `started_at`/`requested_at` pueden venir NULOS: hay viajes que
            #    llegaron a 'in_progress' por una via que no pasa por
            #    `update_trip_status` (por ejemplo, restaurados al reabrir la
            #    app). Sin cubrirlo, la resta reventaba.
            #  * Las columnas `started_at`/`requested_at` son TIMESTAMP **sin
            #    zona horaria**, asi que psycopg2 devuelve datetimes *naive*,
            #    mientras que `now` es *aware* (UTC). Restar uno de otro es un
            #    TypeError directo. Como lo que se guarda en esas columnas es
            #    `datetime.now(timezone.utc)`, el valor ES UTC: solo hay que
            #    volver a pegarle la zona.
            started = trip["started_at"] or trip["requested_at"]
            if started is None:
                duration_secs = 0
            else:
                if getattr(started, "tzinfo", None) is None:
                    started = started.replace(tzinfo=timezone.utc)
                now_cmp = now
                if getattr(now_cmp, "tzinfo", None) is None:
                    now_cmp = now_cmp.replace(tzinfo=timezone.utc)
                duration_secs = max(0, int((now_cmp - started).total_seconds()))

# --- 7b. Tiempo de espera de cortesía ---
            #
            # El chófer marca "He llegado" (estado `driver_arrived`) y luego
            # "Iniciar viaje" (`in_progress`). Entre medias el pasajero puede
            # tardar: eso es espera, y no cuenta como tiempo de trayecto.
            #
            # Al pasajero se le regalan los primeros `cortesia` minutos. Lo que
            # pase de ahi es tiempo que el chófer estuvo esperando con el motor
            # parado, así que se le paga: se suma a la duracion facturable.
            #
            #     espera      = hora_inicio - hora_llegada
            #     excedente   = max(0, espera - cortesia)
            #     duracion    = (hora_fin - hora_inicio) + excedente
            #
            # LA DIFERENCIA SE CALCULA EN SQL, no restando datetimes en Python.
            # En una base donde `hora_llegada` es TIMESTAMP (sin zona) y
            # `started_at` es TIMESTAMP WITH TIME ZONE, restarlos en Python
            # mezclaba dos tipos y salia un desfase de horas: el chofer
            # acababa cobrando 5 horas de espera que no habian ocurrido.
            # Postgres conoce los dos tipos y los resta bien.
            cortesia_min = _cortesia_minutos_actual()
            espera_secs = 0
            if started is not None:
                cur2 = conn.cursor()
                cur2.execute("""
                    SELECT GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (
                        started_at - hora_llegada)), 0))::int AS espera
                    FROM trips WHERE trip_id = %s
                """, (trip_id,))
                fila_espera = cur2.fetchone()
                cur2.close()
                if fila_espera:
                    espera_secs = int(fila_espera[0] or 0)

            # El reparto entre cortesía y exceso lo hace `excedente_espera`, que
            # es la misma función que usan las pruebas y la app. Antes este calculo
            # estaba aqui escrito a mano y usaba `promo`, que en este punto del
            # codigo todavia no existia: NameError en cuanto un chofer cerraba un
            # viaje con espera.
            excedente_secs, duracion_facturable = excedente_espera(
                espera_secs, duration_secs, cortesia_min)
            duration_min = duracion_facturable / 60.0

            # 8. Calcular componentes de tarifa.
            #
            # La promocion se lee AQUI, antes de tocar el dinero. Antes se leia
            # dos lineas mas abajo, despues de haber calculado el precio, y el
            # coeficiente que se aplica ahora necesita de ella.
            promo = leer_promocion()

            # Precio por minuto desde configuración global (id=1)
            try:
                ppm = promo.get("precio_por_minuto")
                if ppm is not None:
                    price_per_minute = float(ppm)
                    if time_rule:
                        price_per_minute = price_per_minute * float(time_rule["price_per_minute_multiplier"])
            except Exception:
                pass

            # Zona especial según DESTINO
            precio_km_aplicable_zona = _precio_km_por_zona(
                promo, vehicle_type,
                dropoff_lat, dropoff_lng,
            )
            if precio_km_aplicable_zona is not None:
                price_per_km = float(precio_km_aplicable_zona)

            # El coeficiente por distancia se aplica aqui y en la estimacion
            coeficiente = coeficiente_por_distancia(distance_km, promo)
            distance_fare = distance_km * price_per_km * float(coeficiente)
            distance_fare_sin_coeficiente = distance_km * price_per_km
            time_fare = duration_min * price_per_minute

            # `precio_bruto` es lo que costaria el viaje sin promociones.
            precio_bruto = base_fare + distance_fare + time_fare + tip

            # 8b. Descuento al cliente con la promocion ya leida.
            descuento_cliente = calcular_descuento_cliente(
                Decimal(str(precio_bruto)), promo)

            # Lo que paga el pasajero. El descuento sale de la comision de la
            # plataforma, nunca del bolsillo del chofer.
            total_fare = float(Decimal(str(precio_bruto)) - descuento_cliente)

            # 9. Actualizar el viaje en PostgreSQL
            cur.execute("""
                UPDATE trips SET
                    status = 'completed',
                    dropoff_location = ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
                    completed_at = %s,
                    distance_km = %s,
                    duration_secs = %s,
                    base_fare = %s,
                    distance_fare = %s,
                    tip = %s,
                    total_fare = %s,
                    descuento_cliente = %s,
                    comision_nominal = %s,
                    espera_secs = %s,
                    excedente_espera_secs = %s,
                    coeficiente_aplicado = %s,
                    currency = 'CUP'
                WHERE trip_id = %s
                RETURNING *;
            """, (
                dropoff_lng, dropoff_lat, now,
                distance_km, duracion_facturable,
                base_fare, distance_fare, tip, total_fare,
                float(descuento_cliente), None,
                espera_secs, excedente_secs, float(coeficiente),
                trip_id
            ))
            updated_trip = cur.fetchone()
            if updated_trip is None:
                # El UPDATE no toco ninguna fila (borrado o viaje movido entre
                # la lectura y la escritura). Antes `dict(None)` reventaba con
                # TypeError y el chofer se comia un 500 sin motivo claro.
                raise ValueError("El viaje ya no existe o cambio de estado")
            updated_trip = dict(updated_trip)
            conn.commit()

            # 10. Descontar la comision del FONDO del conductor.
            #
            #     La comision sale del fondo del chofer, nunca del precio que paga
            #     el pasajero. Y sale sobre el PRECIO BRUTO, no sobre el precio ya
            #     descontado, para que el descuento al cliente lo pague la
            #     plataforma y no el chofer:
            #
            #         comision nominal  = 15% de 10.00 = 1.50
            #         descuento cliente = 10% de 10.00 = 1.00
            #         comision cobrada  = 1.50 - 1.00 = 0.50
            #         conserva chofer   = 10.00 - 1.50 = 8.50
            #
            #     Si se calculara sobre 9.00 serian 1.35 y el chofer se quedaria
            #     con 7.65: perderia 0.85 por un descuento que no es suyo.
            #
            #     El viaje ya quedo guardado como 'completed' mas arriba, asi
            #     que el conteo del dia ya lo incluye y resolve_commission
            #     sabe si este es el tercero.
            driver_id_str = updated_trip["driver_id"]
            comision = {"rate": float(promo["comision_porcentaje"]), "label": _etiqueta_tasa(promo["comision_porcentaje"]),
                        "discount_applied": False, "discount_date": datetime.now(CUBA_TZ).strftime("%Y-%m-%d")}
            comision_nominal = None
            commission = None
            try:
                comision = resolve_commission(driver_id_str, promo["comision_porcentaje"])
                comision_nominal = float(
                    (Decimal(str(precio_bruto)) * comision["rate"]).quantize(
                        Decimal("0.01"), rounding=ROUND_HALF_UP))
                commission = max(0.0, round(comision_nominal - float(descuento_cliente), 2))
                commit_commission(
                    driver_id_str,
                    commission,
                    comision["discount_applied"],
                    comision["discount_date"],
                )

                # La comision nominal queda guardada junto al descuento para que el
                # calculo sea auditable despues: sin esto no habria forma de saber
                # de donde salio lo que se desconto del fondo.
                cur.execute(
                    "UPDATE trips SET comision_nominal = %s WHERE trip_id = %s",
                    (comision_nominal, trip_id))
                conn.commit()
            except Exception:
                # Si falla la comision, el viaje ya esta 'completed' con precio.
                # No se deshace: logueamos y seguimos.
                logger.exception("complete_trip: fallo en comision para viaje %s", trip_id)
                comision_nominal = None
                commission = None

            # 11. Retornar el viaje completo con informacion adicional
            completed_at_iso = None
            try:
                completed_at_iso = updated_trip["completed_at"].isoformat() if updated_trip.get("completed_at") else None
            except Exception:
                completed_at_iso = None
            return {
                "trip_id": updated_trip["trip_id"],
                "client_id": updated_trip["client_id"],
                "driver_id": updated_trip["driver_id"],
                "status": updated_trip["status"],
                "distance_km": round(float(updated_trip.get("distance_km") or 0), 2),
                "duration_secs": updated_trip.get("duration_secs"),
                "espera_secs": espera_secs,
                "excedente_espera_secs": excedente_secs,
                "espera_segundos": espera_secs,
                "excedente_espera_segundos": excedente_secs,
                "espera_cortesia_minutos": cortesia_min,
                "tiempo_espera_cortesia_minutos": cortesia_min,
                "hora_llegada": (trip["hora_llegada"].isoformat()
                                 if trip.get("hora_llegada") else None),
                "hora_inicio_viaje": (started.isoformat() if started else None),
                "base_fare": float(updated_trip.get("base_fare") or 0),
                "tarifa_base": float(updated_trip.get("base_fare") or 0),
                "distance_fare": float(updated_trip.get("distance_fare") or 0),
                "costo_distancia": float(updated_trip.get("distance_fare") or 0),
                "distance_fare_sin_coeficiente": round(distance_fare_sin_coeficiente, 2),
                "coeficiente_aplicado": float(coeficiente),
                "coeficiente_distancia": float(coeficiente),
                "precio_km_aplicable": round(price_per_km, 4),
                "precio_por_minuto": round(price_per_minute, 4),
                "time_fare": round(time_fare, 2),
                "costo_tiempo": round(time_fare, 2),
                "costo_tiempo_total": round(time_fare, 2),
                "tiempo_total_minutos": round(duration_min, 4),
                "tip": float(updated_trip.get("tip") or 0),
                "precio_bruto": round(float(precio_bruto), 2),
                "precio_final": float(updated_trip.get("total_fare") or 0),
                "descuento_cliente": float(descuento_cliente),
                "total_fare": float(updated_trip.get("total_fare") or 0),
                "commission": commission,
                "commission_nominal": comision_nominal,
                "commission_rate": comision.get("rate") if isinstance(comision, dict) else None,
                "commission_label": comision.get("label") if isinstance(comision, dict) else None,
                "commission_discount": comision.get("discount_applied") if isinstance(comision, dict) else None,
                "currency": updated_trip.get("currency") or "CUP",
                "vehicle_type": vehicle_type,
                "applied_rule": applied_rule_desc,
                "completed_at": completed_at_iso
            }

        except Exception as e:
            conn.rollback()
            # Traza completa en el log del servidor. Sin esto, un fallo aqui
            # salia como "Internal Server Error" y no habia forma de saber que
            # campo o consulta lo habia provocado.
            logger.exception("complete_trip fallo para el viaje %s", trip_id)
            raise
        finally:
            cur.close()


def cancel_trip(trip_id: str) -> bool:
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE trips SET status = 'cancelled', completed_at = %s WHERE trip_id = %s AND status NOT IN ('completed', 'cancelled')",
            (datetime.now(timezone.utc), trip_id),
        )
        affected = cur.rowcount
        conn.commit()
        cur.close()
        return affected > 0


def get_trips_by_client(client_id: str, limit: int = 50) -> list[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT
                trip_id, client_id, driver_id, status,
                ST_AsText(request_location) as request_location,
                ST_AsText(pickup_location) as pickup_location,
                ST_AsText(dropoff_location) as dropoff_location,
                requested_at, started_at, completed_at, created_at,
                hora_llegada, espera_secs, excedente_espera_secs,
                coeficiente_aplicado,
                GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (
                    COALESCE(started_at, NOW()) - hora_llegada)), 0))::int
                    AS espera_segundos,
                distance_km, duration_secs,
                base_fare, distance_fare, tip, total_fare,
                currency, payment_method,
                equipaje, mascota, num_pasajes, vehicle_type, precio_estimado
            FROM trips WHERE client_id = %s ORDER BY requested_at DESC LIMIT %s;
            """,
            (client_id, limit),
        )
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows


def get_trips_by_driver(driver_id: str, limit: int = 50) -> list[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT
                trip_id, client_id, driver_id, status,
                ST_AsText(request_location) as request_location,
                ST_AsText(pickup_location) as pickup_location,
                ST_AsText(dropoff_location) as dropoff_location,
                requested_at, started_at, completed_at, created_at,
                hora_llegada, espera_secs, excedente_espera_secs,
                coeficiente_aplicado,
                GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (
                    COALESCE(started_at, NOW()) - hora_llegada)), 0))::int
                    AS espera_segundos,
                distance_km, duration_secs,
                base_fare, distance_fare, tip, total_fare,
                currency, payment_method,
                equipaje, mascota, num_pasajes, vehicle_type, precio_estimado
            FROM trips WHERE driver_id = %s ORDER BY requested_at DESC LIMIT %s;
            """,
            (driver_id, limit),
        )
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows


def get_trips_by_status(status: str, limit: int = 50) -> list[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT
                trip_id, client_id, driver_id, status,
                ST_AsText(request_location) as request_location,
                ST_AsText(pickup_location) as pickup_location,
                ST_AsText(dropoff_location) as dropoff_location,
                requested_at, started_at, completed_at, created_at,
                hora_llegada, espera_secs, excedente_espera_secs,
                coeficiente_aplicado,
                GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (
                    COALESCE(started_at, NOW()) - hora_llegada)), 0))::int
                    AS espera_segundos,
                distance_km, duration_secs,
                base_fare, distance_fare, tip, total_fare,
                currency, payment_method,
                equipaje, mascota, num_pasajes, vehicle_type, precio_estimado
            FROM trips WHERE status = %s ORDER BY requested_at DESC LIMIT %s;
            """,
            (status, limit),
        )
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows


def get_nearby_requested_trips(
    lat: float,
    lng: float,
    radius_km: float = 5,
    limit: int = 20,
    vehicle_type: Optional[str] = None,
) -> list[dict]:
    """Viajes 'requested' cercanos, opcionalmente filtrados por tipo de vehiculo.

    El filtro por ``vehicle_type`` es lo que evita que un chofer con moto vea
    ofertas de un viaje 'confort'. Va en el propio SQL (y no en un filtrado de
    Python) para que el ``LIMIT`` no se llene de viajes que luego se descartan
    y deje al conductor sin ofertas aunque las tenga compatibles.
    """
    where = """
        WHERE status = 'requested'
          AND ST_DWithin(
              request_location,
              ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography,
              %s * 1000
          )
    """
    params: list = [lng, lat, radius_km]

    # FALLO CERRADO A PROPOSITO.
    #
    # Antes aqui solo se filtraba si el conductor mandaba su tipo:
    #
    #     if tipo_norm:  where += " AND lower(vehicle_type) = %s"
    #
    # y si no lo mandaba, se le devolvian TODAS las ofertas. Como la app del
    # chofer llegaba sin tipo (el campo no venía en la respuesta del perfil), el
    # filtro no se aplicaba nunca: un conductor 'basico' veia ofertas de 'moto',
    # de 'triciclo' y de 'confort', que no puede atender.
    #
    # Un filtro que se salta cuando falta un dato no es un filtro. Si el
    # conductor no declara que vehiculo tiene, no se le ofrece nada: es la unica
    # forma de que el error se vea (no le llegan ofertas) en vez de dejarle
    # aceptar un viaje que no puede hacer.
    tipo_norm = _normalize_vehicle_type(vehicle_type)
    if not tipo_norm:
        logger.warning("Sondeo de ofertas sin vehicle_type: no se devuelve nada. "
                       "El conductor tiene que declarar su vehiculo.")
        return []

    where += "          AND lower(vehicle_type) = %s"
    params.append(tipo_norm)

    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            f"""
            SELECT
                trip_id, client_id, driver_id, status,
                ST_AsText(request_location) as request_location,
                ST_AsText(pickup_location) as pickup_location,
                ST_AsText(dropoff_location) as dropoff_location,
                requested_at, started_at, completed_at, created_at,
                hora_llegada, espera_secs, excedente_espera_secs,
                coeficiente_aplicado,
                GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (
                    COALESCE(started_at, NOW()) - hora_llegada)), 0))::int
                    AS espera_segundos,
                distance_km, duration_secs,
                base_fare, distance_fare, tip, total_fare,
                currency, payment_method,
                equipaje, mascota, num_pasajes, vehicle_type, precio_estimado,
                request_address, dropoff_address,
                ST_Distance(
                    request_location,
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography
                ) / 1000 AS distance_from_driver_km
            FROM trips
            {where}
            ORDER BY requested_at ASC
            LIMIT %s;
            """,
            [lng, lat, *params, limit],
        )
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows


def get_driver_earnings(driver_id: str, from_date: Optional[date] = None, to_date: Optional[date] = None) -> dict:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        where = "WHERE driver_id = %s AND status = 'completed'"
        params: list = [driver_id]

        # `completed_at` se guarda en UTC, pero from_date/to_date son fechas
        # locales de Cuba. Convertimos a hora Cuba antes de comparar para que
        # el corte del dia coincida con la medianoche de Cuba, no con UTC.
        if from_date:
            where += " AND (completed_at AT TIME ZONE 'America/Havana')::date >= %s"
            params.append(from_date)
        if to_date:
            where += " AND (completed_at AT TIME ZONE 'America/Havana')::date < %s"
            params.append(to_date + timedelta(days=1))

        cur.execute(
            f"""
            SELECT
                COUNT(*) AS total_trips,
                COALESCE(SUM(total_fare), 0) AS total_earnings,
                COALESCE(AVG(total_fare), 0) AS avg_fare,
                COALESCE(SUM(distance_km), 0) AS total_distance_km,
                COALESCE(SUM(duration_secs), 0) AS total_duration_secs
            FROM trips {where};
            """,
            tuple(params),
        )
        row = dict(cur.fetchone())
        cur.close()
        return row

# ===================== BONIFICACION DIARIA =====================

# Saldo que se abona al Fondo del chofer cuando supera el umbral de viajes del
# dia. Se paga una sola vez por dia (ver `apply_daily_bonus`).
BONIFICATION_THRESHOLD = 10
BONIFICATION_AMOUNT = 1100

# ===================== COMISION =====================
#
# La comision NUNCA se descuenta del precio que paga el pasajero: `total_fare`
# es el precio final del viaje y se muestra tal cual. Lo que sale de la comision
# es el `Fondo` del chofer en MongoDB.
#
# Regla del 3er viaje: el tercero del dia paga solo el 10% en vez del 15%, y
# una unica vez al dia.
COMMISSION_RATE = 0.15
COMMISSION_DISCOUNT_RATE = 0.10
COMMISSION_DISCOUNT_TRIP = 3

# Etiquetas legibles de las tasas, para el log y las respuestas.
COMMISSION_RATE_LABEL = {0.15: "15%", 0.10: "10%"}


def _etiqueta_tasa(rate) -> str:
    """'%s%%' de la tasa, con los decimales justos.

    Antes se buscaba en `COMMISSION_RATE_LABEL` y solo tenia dos claves. Con la
    comision configurable eso reventaba con KeyError en cuanto el administrador
    pusiera, por ejemplo, 12%.
    """
    try:
        valor = float(rate) * 100
    except (TypeError, ValueError):
        return "0%"
    if abs(valor - round(valor)) < 0.005:
        return "%d%%" % round(valor)
    return ("%s%%" % round(valor, 2)).replace(".", ",")

def get_daily_trip_count(driver_id: str) -> int:
    with get_connection() as conn:
        cur = conn.cursor()
        # `completed_at` se guarda en UTC, pero queremos contar los viajes
        # completados en el día local de Cuba. Convertimos en SQL.
        today_cuba = datetime.now(CUBA_TZ).strftime('%Y-%m-%d')

        cur.execute(
            """
            SELECT COUNT(*) AS trip_count
            FROM trips
            WHERE driver_id = %s
              AND status = 'completed'
              AND (completed_at AT TIME ZONE 'America/Havana')::date = %s
            """,
            (driver_id, today_cuba),
        )
        count = cur.fetchone()[0]
        cur.close()
        return count


def apply_daily_bonus(driver_id: str) -> dict:
    """Abono al Fondo cuando el chofer llega al umbral de viajes del dia.

    Los valores salen de Promociones, no de constantes: `BONIFICATION_THRESHOLD` y
    `BONIFICATION_AMOUNT` quedan como respaldo si la tabla todavia no existe, para
    que arrancar sin base de promociones no rompa los viajes.

    Antes el `BONIFICATION_THRESHOLD` de 10 se comparaba con `>`, asi que el bono
    saltaba en el viaje 11 y el administrador que escribiera "10 viajes" en el
    panel contaria hasta 10 esperando algo que no llegaba. Ahora la comparacion es
    `>=`: "10 viajes requeridos" significa que al tenth viaje se paga.
    """
    driver = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
    if not driver:
        raise ValueError(f"Conductor no encontrado: {driver_id}")

    promo = leer_promocion()
    if not promo["bono_chofer_activo"]:
        return {
            "driver_id": driver_id,
            "bonus_applied": False,
            "reason": "Bono de chofer desactivado en Promociones",
            "amount": 0,
        }

    umbral = promo["bono_chofer_viajes_requeridos"]
    monto = promo["bono_chofer_monto"]

    # Usar fecha de Cuba para el bono diario
    now_cuba = datetime.now(CUBA_TZ)
    today_str = now_cuba.strftime("%Y-%m-%d")
    last_bonus_date = driver.get("last_bonus_date")

    if last_bonus_date == today_str:
        return {
            "driver_id": driver_id,
            "bonus_applied": False,
            "reason": "Bonificacion ya aplicada hoy",
            "amount": 0
        }

    daily_trips = get_daily_trip_count(driver_id)
    if daily_trips < umbral:
        return {
            "driver_id": driver_id,
            "bonus_applied": False,
            "reason": f"Viajes insuficientes: {daily_trips}/{umbral}",
            "amount": 0,
            "daily_trips": daily_trips
        }

    saldo_anterior = float(driver.get("Fondo") or 0)
    saldo_nuevo = round(saldo_anterior + float(monto), 2)
    chofer_coleccion.update_one(
        {"_id": to_mongo_id(driver_id)},
        {"$inc": {"Fondo": monto},
         "$set": {"last_bonus_date": today_str}}
    )

    # El bono entra al mismo campo `Fondo` que una recarga, asi que se anota igual
    # que una recarga. Antes no se anotaba nada y el administrador no tenia forma
    # de saber de donde salia cada peso del saldo.
    _registrar_movimiento_bono(driver_id, saldo_anterior, saldo_nuevo, float(monto),
                               today_str, daily_trips)

    return {
        "driver_id": driver_id,
        "bonus_applied": True,
        "reason": f"Bonificacion por {daily_trips} viajes completados",
        "amount": float(monto),
        "daily_trips": daily_trips,
        "umbral": umbral
    }


def _registrar_movimiento_bono(driver_id: str, saldo_anterior: float,
                               saldo_nuevo: float, monto: float,
                               dia: str, viajes: int) -> None:
    """Deja el bono en `wallet_movements` como movimiento tipo `bono`.

    `admin_email` va vacio a proposito: no lo hizo un administrador, lo hizo el
    sistema. `metodo` = 'automatico' y `referencia` = el dia, para poder
    auditar de un vistazo quedia se pago cada bono.
    """
    try:
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                """
                INSERT INTO wallet_movements
                    (driver_id, tipo, monto, saldo_anterior, saldo_nuevo,
                     metodo, referencia, nota, created_at)
                VALUES (%s, 'bono', %s, %s, %s, 'automatico', %s, %s, NOW())
                """,
                (driver_id, monto, saldo_anterior, saldo_nuevo, dia,
                 "Bono diario por %d viajes completados" % viajes),
            )
            conn.commit()
            cur.close()
    except Exception:
        # Que el saldo se haya abonado es lo importante. Si el movimiento no se
        # guarda, el saldo es correcto igual y avisar por log basta: perder el
        # bono por no poder escribir en el historial seria peor.
        logger.exception("Bono acreditado a %s pero no se pudo registrar el movimiento",
                         driver_id)


def resolve_commission(driver_id: str, tasa_base=None) -> dict:
    """Devuelve la tasa de comision que corresponde al viaje que se esta cerrando.

    La regla del TERCER viaje se mantiene: el tercero del dia paga la mitad de la
    tasa base, y solo una vez al dia. `tasa_base` es la comision que fijo el
    administrador en Promociones; si no se pasa, se usa `COMMISSION_RATE`, que es
    lo que pasaba antes de que existiera la configuracion.

    La tasa del 3er viaje se deriva de la base (`COMMISSION_DISCOUNT_TRIP` = media
    tasa), no es un numero fijo: si el administrador pone la comision en 0 no hay
    mitad que aplicar, y quedaria un 5% fantasma cobrando a los choferes durante
    una promocion de captacion.
    """
    if tasa_base is None:
        tasa_base = Decimal(str(COMMISSION_RATE))
    tasa_base = Decimal(str(tasa_base))

    oid = to_mongo_id(driver_id)
    if not chofer_coleccion.find_one({"_id": oid}):
        raise ValueError(f"Conductor no encontrado: {driver_id}")

    today_str = datetime.now(CUBA_TZ).strftime("%Y-%m-%d")
    daily_trips = get_daily_trip_count(driver_id)
    es_el_tercero = daily_trips == COMMISSION_DISCOUNT_TRIP

    # Media tasa base. Es lo que significa "el 3er viaje paga la mitad". Con
    # comision 0 se queda en 0, que es lo correcto.
    tasa_descuento = (tasa_base * Decimal(str(COMMISSION_DISCOUNT_RATE))
                      / Decimal(str(COMMISSION_RATE))) if tasa_base > 0 else Decimal("0")

    if es_el_tercero and tasa_descuento > 0 and claim_commission_discount(driver_id, today_str):
        rate = tasa_descuento
        motivo = (
            f"3er viaje del dia ({daily_trips}): comision reducida a "
            f"{_etiqueta_tasa(rate)}"
        )
    else:
        rate = tasa_base
        if es_el_tercero:
            motivo = "Descuento del 3er viaje ya consumido hoy"
        else:
            motivo = f"Comision normal (viaje {daily_trips} del dia)"

    return {
        "rate": float(rate),
        "label": _etiqueta_tasa(rate),
        "discount_applied": rate < tasa_base,
        "discount_date": today_str,
        "driver_id": driver_id,
        "trip_of_day": daily_trips,
        "reason": motivo,
    }


def claim_commission_discount(driver_id: str, travel_date: str) -> bool:
    """Intenta reservar el descuento de comision del dia para este viaje.

    Se hace ANTES de tocar el `Fondo` y sin modificar el saldo, de modo que si
    la operacion no encuentra documento no hay nada que revertir.

    Devuelve `True` solo para la primera peticion que consigue reservarlo. Como
    el filtro incluye `{"$ne": travel_date}` y Mongo opera de forma atomica
    sobre el documento, dos peticiones simultaneas no pueden reservarlo las dos.
    """
    resultado = chofer_coleccion.find_one_and_update(
        {"_id": to_mongo_id(driver_id),
         "last_commission_discount_date": {"$ne": travel_date}},
        {"$set": {"last_commission_discount_date": travel_date}},
    )
    return resultado is not None


def commit_commission(driver_id: str, commission: float, discount_applied: bool,
                      travel_date: str) -> None:
    """Descuenta la comision del `Fondo` del chofer.

    El precio del viaje (`total_fare`) NO se toca aqui: la comision sale del
    fondo del chofer, nunca del precio que paga el pasajero.

    El descuento del dia se reserva con `claim_commission_discount` antes de
    llegar aqui, asi que esta funcion solo hace un unico `$inc` y no necesita
    ninguna logica de compensacion.
    """
    chofer_coleccion.update_one(
        {"_id": to_mongo_id(driver_id)},
        {"$inc": {"Fondo": -commission}},
    )

#====================== Garnet ===========================

async def update_driver_location(driver_id: str, lon: float, lat: float):
    """Actualiza la posicion de un conductor en tiempo real."""
    await garnet.geoadd("drivers:geo", (lon, lat, driver_id))

async def get_nearby_drivers(lon: float, lat: float, radius_km: float = 3.0):
    """Devuelve lista de (driver_id, distancia_km) ordenados por cercania."""
    res = await garnet.geosearch(
        "drivers:geo", longitude=lon, latitude=lat,
        radius=radius_km, unit="km", withdist=True, sort="ASC"
    )
    return [(r[0], r[1]) for r in res]

async def set_driver_status(driver_id: str, status: str):
    """Establece el estado actual del conductor ('available', 'busy', 'on_trip', etc.)."""
    await garnet.set(f"driver:status:{driver_id}", status)

async def get_driver_status(driver_id: str) -> Optional[str]:
    """Obtiene el estado actual del conductor o None si no existe."""
    return await garnet.get(f"driver:status:{driver_id}")

async def remove_driver_location(driver_id: str):
    """Elimina la ubicacion de un conductor (util al desconectarse)."""
    await garnet.zrem("drivers:geo", driver_id)

async def publish_trip_event(trip_id: str, event: str, extra: dict = None):
    """Publica un evento de viaje en un canal Pub/Sub para notificaciones en tiempo real."""
    msg = {"trip_id": trip_id, "event": event}
    if extra:
        msg.update(extra)
    await garnet.publish(f"trip:{trip_id}:events", json.dumps(msg))


async def mark_driver_declined(trip_id: str, driver_id: str) -> None:
    """Registra que un conductor rechazo la oferta de un viaje.

    El conductor queda excluido de TODAS las rondas de oferta (y del sondeo de
    viajes cercanos) para ESTE trip_id. Como cada solicitud del cliente crea un
    trip_id nuevo, vuelve a ser elegible automaticamente cuando el cliente
    haga una nueva solicitud.
    """
    await garnet.sadd(f"trip:{trip_id}:declined", driver_id)
    await garnet.expire(f"trip:{trip_id}:declined", 3600)


async def filter_declined_trips(trips: list[dict], driver_id: Optional[str]) -> list[dict]:
    """Quita de la lista los viajes que el conductor ya rechazo.

    Sin esto el sondeo de la app (/trips/requested-nearby) le devolveria una y
    otra vez el mismo viaje, porque el viaje sigue en 'requested' esperando a
    otro conductor. La distancia se sigue evaluando en la consulta SQL: solo se
    descartan rechazos, no viajes fuera de radio.
    """
    if not driver_id or not trips:
        return trips

    ids = [str(t.get("trip_id")) for t in trips if t.get("trip_id")]
    if not ids:
        return trips

    # Garnet no soporta MULTI/EXEC sobre sets (cierra la conexion), asi que se
    # usa un pipeline sin transaccion: una sola ida y vuelta con un smismember
    # por viaje.
    pipe = garnet.pipeline(transaction=False)
    for tid in ids:
        pipe.smismember(f"trip:{tid}:declined", driver_id)
    results = await pipe.execute()

    # smismember devuelve una lista [0|1, ...] por viaje.
    declined = {tid for tid, res in zip(ids, results) if res and res[0]}
    if not declined:
        return trips
    return [t for t in trips if str(t.get("trip_id")) not in declined]


# ===================== ASIGNACION AUTOMATICA DE CONDUCTOR =====================

# ===================== OFERTA DE VIAJE A CONDUCTORES CERCANOS =====================
# ===================== CONFIGURACION DE OFERTA / EXPIRACION =====================
# Tiempo que un viaje queda 'requested' esperando que un conductor lo acepte.
# La app del conductor sondea cada 4 s y el conductor necesita tiempo a mano
# para ver la oferta y tocarla, asi que 20 s hacia que el viaje expirara solo.
TRIP_ACCEPT_TIMEOUT_SECS = int(os.getenv("TRIP_ACCEPT_TIMEOUT_SECS", "120"))

# Tiempo que una OFERTA concreta queda viva para un conductor, es decir lo que
# viaja en `expires_in_secs`. La app lo usa como temporizador local del FSI: si
# el conductor no responde en ese plazo, la oferta se cierra sola.
#
# 60 s y no 30: la oferta se presenta como una llamada entrante a pantalla
# completa y el conductor necesita ver la pantalla, leer la direccion y decidir.
# Con 30 s el FSI se cerraba antes de que el conductor llegara a reaccionar.
# Se puede ajustar por entorno sin tocar el codigo.
OFFER_TTL_SECS = int(os.getenv("OFFER_TTL_SECS", "60"))

_DRIVER_VEHICLE_KEYS = ("vehicle_type", "type_vehicle", "type")

_ACCENTS = str.maketrans("áàäâãéèëêíìïîóòöôõúùüûñç", "aaaaaeeeeiiiiooooouuuunc")


def _normalize_vehicle_type(value) -> Optional[str]:
    """Normaliza un tipo de vehiculo para poder compararlo.

    El registro de choferes guarda el valor como lo escribe la persona
    ('Basico', 'Basico'), mientras que las tarifas y los viajes usan
    'basico'. Sin normalizar, la oferta nunca coincide y `get_tariff`
    no encuentra la tarifa.
    """
    if value is None:
        return None
    text = str(value).strip().translate(_ACCENTS).lower()
    return text or None


def _driver_vehicle_type(doc: dict) -> Optional[str]:
    """Extrae el tipo de vehiculo (normalizado) de un documento de chofer.

    El documento guarda el tipo en distintos sitios segun como se creo:
    - `vehicle.servicio` (esquema del registro de choferes)
    - `vehicle.type`
    - `vehicle_type` / `type_vehicle` a nivel raiz
    """
    if not doc:
        return None
    vehicle = doc.get("vehicle") or {}
    if not isinstance(vehicle, dict):
        vehicle = {}
    for value in (
        doc.get("vehicle_type"),
        doc.get("type_vehicle"),
        vehicle.get("servicio"),
        vehicle.get("type"),
    ):
        normalized = _normalize_vehicle_type(value)
        if normalized:
            return normalized
    return None


async def offer_trip_to_nearby_drivers(
    trip_id: str,
    request_lat: float,
    request_lng: float,
    vehicle_type: str = "basico",
    radius_km: float = 3.0,
    offer_ttl_secs: int | None = None,
) -> list[dict]:
    """
    Busca conductores 'available' en un radio y les ENVIA UNA OFERTA.
    NO asigna el viaje. El viaje permanece en 'requested'.
    Filtra por vehicle_type para que solo reciban la oferta choferes cuyo
    vehiculo coincida con el solicitado.
    Retorna la lista de conductores notificados.
    """
    vehicle_type = _normalize_vehicle_type(vehicle_type) or "basico"
    if offer_ttl_secs is None:
        offer_ttl_secs = OFFER_TTL_SECS
    nearby = await get_nearby_drivers(request_lng, request_lat, radius_km)

    offered = []
    for driver_id, dist_km in nearby:
        # 1. Debe estar 'available' en Garnet
        status = await get_driver_status(driver_id)
        if status != "available":
            continue

        # 2. Debe existir en MongoDB y tener el vehicle_type solicitado
        doc = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
        if not doc:
            continue
        driver_vehicle = _driver_vehicle_type(doc)
        if driver_vehicle != _normalize_vehicle_type(vehicle_type):
            continue

        # 3. Evitar re-ofertar al mismo chofer en la misma ronda
        already = await garnet.sismember(f"trip:{trip_id}:offered", driver_id)
        if already:
            continue

        # 4. Registrar la oferta (TTL para limpieza automatica)
        await garnet.sadd(f"trip:{trip_id}:offered", driver_id)
        await garnet.expire(f"trip:{trip_id}:offered", 3600)

        # 5. Notificar al chofer por SU canal
        await garnet.publish(f"driver:{driver_id}:offers", json.dumps({
            "trip_id": trip_id,
            "event": "trip_offer",
            "pickup": {"lat": request_lat, "lng": request_lng},
            "vehicle_type": vehicle_type,
            "distance_to_pickup_km": round(dist_km, 2),
            "expires_in_secs": offer_ttl_secs,
        }))

        # 6. Notificar tambien al canal del viaje (para que el cliente vea el dispatch)
        await publish_trip_event(trip_id, "trip_offered", {
            "driver_id": driver_id,
            "distance_km": round(dist_km, 2),
        })

        offered.append({"driver_id": driver_id, "distance_km": round(dist_km, 2)})

    return offered

# ===================== TRANSACTIONS =====================

def create_transaction(
    trip_id: Optional[str],
    user_id: str,
    user_type: str,
    amount: float,
    transaction_type: str,
    payment_gateway: Optional[str] = None,
    gateway_reference: Optional[str] = None,
) -> str:
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO transactions (
                trip_id, user_id, user_type, amount,
                transaction_type, payment_gateway, gateway_reference
            ) VALUES (%s, %s, %s, %s, %s, %s, %s)
            RETURNING transaction_id;
            """,
            (trip_id, user_id, user_type, amount, transaction_type, payment_gateway, gateway_reference),
        )
        transaction_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        return transaction_id


def update_transaction_status(transaction_id: str, status: str) -> bool:
    valid_statuses = ["pending", "completed", "failed"]
    if status not in valid_statuses:
        raise ValueError(f"Status invalido. Opciones validas: {valid_statuses}")

    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE transactions SET status = %s WHERE transaction_id = %s",
            (status, transaction_id),
        )
        affected = cur.rowcount
        conn.commit()
        cur.close()
        return affected > 0


def get_transaction(transaction_id: str) -> Optional[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM transactions WHERE transaction_id = %s", (transaction_id,))
        row = cur.fetchone()
        cur.close()
        if row:
            row = dict(row)
        return row


def get_transactions_by_trip(trip_id: str) -> list[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM transactions WHERE trip_id = %s ORDER BY created_at DESC", (trip_id,))
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows


def get_transactions_by_user(user_id: str, user_type: str, limit: int = 50) -> list[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT * FROM transactions WHERE user_id = %s AND user_type = %s ORDER BY created_at DESC LIMIT %s",
            (user_id, user_type, limit),
        )
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows


# ===================== DRIVER PAYOUTS =====================

def create_driver_payout(
    driver_id: str,
    period_start: date,
    period_end: date,
    total_earnings: float,
    commission: float,
    net_amount: float,
) -> str:
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO driver_payouts (
                driver_id, period_start, period_end,
                total_earnings, commission, net_amount
            ) VALUES (%s, %s, %s, %s, %s, %s)
            RETURNING payout_id;
            """,
            (driver_id, period_start, period_end, total_earnings, commission, net_amount),
        )
        payout_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        return payout_id


def update_payout_status(payout_id: str, status: str) -> bool:
    valid_statuses = ["pending", "processing", "completed", "cancelled"]
    if status not in valid_statuses:
        raise ValueError(f"Status invalido. Opciones validas: {valid_statuses}")

    with get_connection() as conn:
        cur = conn.cursor()

        if status == "completed":
            cur.execute(
                "UPDATE driver_payouts SET status = %s, paid_at = %s WHERE payout_id = %s",
                (status, datetime.now(timezone.utc), payout_id),
            )
        else:
            cur.execute(
                "UPDATE driver_payouts SET status = %s WHERE payout_id = %s",
                (status, payout_id),
            )

        affected = cur.rowcount
        conn.commit()
        cur.close()
        return affected > 0


def get_payout(payout_id: str) -> Optional[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM driver_payouts WHERE payout_id = %s", (payout_id,))
        row = cur.fetchone()
        cur.close()
        if row:
            row = dict(row)
        return row


def get_payouts_by_driver(driver_id: str, limit: int = 50) -> list[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT * FROM driver_payouts WHERE driver_id = %s ORDER BY period_start DESC LIMIT %s",
            (driver_id, limit),
        )
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows


def get_pending_payouts(limit: int = 50) -> list[dict]:
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT * FROM driver_payouts WHERE status = 'pending' ORDER BY period_start ASC LIMIT %s",
            (limit,),
        )
        rows = [dict(r) for r in cur.fetchall()]
        cur.close()
        return rows




# ===================== PYDANTIC MODELS =====================

class TripCreate(BaseModel):
    client_id: str
    driver_id: Optional[str] = None  # Opcional: si no se proporciona, se asigna automaticamente
    request_lat: float
    request_lng: float
    dropoff_lat: float
    dropoff_lng: float
    num_pasajes: int = 1
    equipaje: bool = False
    mascota: bool = False
    vehicle_type: str = "basico"
    base_fare: Optional[float] = None
    request_address: Optional[str] = None
    dropoff_address: Optional[str] = None

class TripEstimateRequest(BaseModel):
    request_lat: float
    request_lng: float
    dropoff_lat: float
    dropoff_lng: float
    vehicle_type: str = "basico"

class TripStatusUpdate(BaseModel):
    status: str

class PickupLocation(BaseModel):
    lat: float
    lng: float

class DropoffLocation(BaseModel):
    lat: float
    lng: float

class TripComplete(BaseModel):
    dropoff_lat: float
    dropoff_lng: float
    tip: float = 0
    # Campos legacy: se ignoran en el backend, se mantienen por compatibilidad
    distance_km: Optional[float] = None
    duration_secs: Optional[int] = None
    base_fare: Optional[float] = None
    distance_fare: Optional[float] = None
    total_fare: Optional[float] = None
    currency: str = "CUP"
    payment_method: Optional[str] = None

class TransactionCreate(BaseModel):
    trip_id: str
    user_id: str
    user_type: str
    amount: float
    transaction_type: str
    payment_gateway: Optional[str] = None
    gateway_reference: Optional[str] = None

class TransactionStatusUpdate(BaseModel):
    status: str

class TransferCreate(BaseModel):
    to_driver_email: str
    amount: float

class DriverPayoutCreate(BaseModel):
    driver_id: str
    period_start: date
    period_end: date
    total_earnings: float
    commission: float
    net_amount: float

class PayoutStatusUpdate(BaseModel):
    status: str

class EarningsQuery(BaseModel):
    driver_id: str
    from_date: Optional[date] = None
    to_date: Optional[date] = None


# ===================== ENDPOINTS: TRIPS =====================

@router.post("/trips", status_code=201)
async def api_create_trip(body: TripCreate, background: BackgroundTasks):
    """
    Crea un viaje. Dos flujos posibles:

    1) Con driver_id -> asignacion manual: verifica que el chofer este 'available'
       y crea el viaje con estado 'accepted'.

    2) Sin driver_id -> oferta automatica: crea el viaje con estado 'requested'
       y notifica a los conductores cercanos que coincidan con el vehicle_type.
       El viaje permanece 'requested' hasta que un chofer llame a
       POST /trips/{trip_id}/accept?driver_id=...
    """
    # ---- Flujo 1: el cliente ya eligio chofer ----
    if body.driver_id is not None:
        status = await get_driver_status(body.driver_id)
        if status != "available":
            raise HTTPException(
                status_code=400,
                detail=f"El conductor no esta disponible (estado: {status}).",
            )

    # ---- Crear el viaje en PostgreSQL ----
    try:
        result = create_trip(
            client_id=body.client_id,
            driver_id=body.driver_id,
            request_lat=body.request_lat,
            request_lng=body.request_lng,
            dropoff_lat=body.dropoff_lat,
            dropoff_lng=body.dropoff_lng,
            equipaje=body.equipaje,
            mascota=body.mascota,
            vehicle_type=body.vehicle_type,
            num_pasajes=body.num_pasajes,
            base_fare=body.base_fare,
            request_address=body.request_address,
            dropoff_address=body.dropoff_address,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.exception("Error creando viaje para cliente %s", body.client_id)
        raise HTTPException(status_code=500, detail="Error interno creando el viaje")

    trip_id = result["trip_id"]

    # ---- Flujo 1 (continuacion): chofer elegido manualmente ----
    if body.driver_id is not None:
        await set_driver_status(body.driver_id, "busy")
        await publish_trip_event(trip_id, "trip_accepted", {
            "client_id": body.client_id,
            "driver_id": body.driver_id,
        })
        return {
            **result,
            "message": "Viaje creado con el conductor seleccionado",
        }

    # ---- Flujo 2: oferta automatica a choferes cercanos ----
    offered = await offer_trip_to_nearby_drivers(
        trip_id=trip_id,
        request_lat=body.request_lat,
        request_lng=body.request_lng,
        vehicle_type=body.vehicle_type,
        radius_km=3.0,
    )

    if offered:
        return {
            **result,                       # driver_id=None, status='requested'
            "drivers_offered": len(offered),
            "message": (
                f"Viaje creado. Ofertado a {len(offered)} conductor(es). "
                "Esperando aceptacion."
            ),
        }

    # ---- Sin choferes disponibles: encolar reintentos ----
    await publish_trip_event(trip_id, "trip_requested_no_driver", {
        "client_id": body.client_id,
        "request_lat": body.request_lat,
        "request_lng": body.request_lng,
        "vehicle_type": body.vehicle_type,
    })
    background.add_task(
        _retry_offer_trip,
        trip_id,
        body.request_lat,
        body.request_lng,
        body.vehicle_type,      # <- propagar vehicle_type
    )
    return {
        **result,
        "drivers_offered": 0,
        "message": "Viaje creado. No hay conductores cercanos. Reintentando...",
    }


@router.post("/trips/estimate")
async def api_estimate_trip(body: TripEstimateRequest):
    """
    Calcula la tarifa estimada sin crear el viaje.
    Usa la misma distancia (PostGIS) y la misma formula que POST /trips,
    con las tarifas vigentes y las reglas horarias del backend.
    """
    try:
        return estimate_trip_price(
            request_lat=body.request_lat,
            request_lng=body.request_lng,
            dropoff_lat=body.dropoff_lat,
            dropoff_lng=body.dropoff_lng,
            vehicle_type=body.vehicle_type,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.exception("Error estimando precio")
        raise HTTPException(status_code=500, detail="Error calculando la tarifa estimada")


class EstimateAllRequest(BaseModel):
    request_lat: float
    request_lng: float
    dropoff_lat: float
    dropoff_lng: float


@router.post("/trips/estimate-all")
async def api_estimate_all(body: EstimateAllRequest):
    """Calcula precios para los 4 vehículos en una sola llamada."""
    try:
        return estimate_all_vehicles(
            request_lat=body.request_lat,
            request_lng=body.request_lng,
            dropoff_lat=body.dropoff_lat,
            dropoff_lng=body.dropoff_lng,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.exception("Error estimando todos los vehículos")
        raise HTTPException(status_code=500, detail="Error calculando tarifas")


async def _retry_offer_trip(
    trip_id: str,
    request_lat: float,
    request_lng: float,
    vehicle_type: str = "basico",
    max_retries: int = 3,
    delay_secs: int = 5,
):
    """
    Reintenta OFERTAR un conductor al viaje con delays progresivos y radio expandido.
    Se ejecuta como BackgroundTask para no bloquear la respuesta al cliente.
    """
    import asyncio
    for attempt in range(1, max_retries + 1):
        await asyncio.sleep(delay_secs * attempt)  # backoff progresivo: 5s, 10s, 15s

        # Verificar que el viaje sigue en estado 'requested' (no fue aceptado ni cancelado)
        trip = get_trip(trip_id)
        if not trip or trip["status"] != "requested":
            return

        # Expandir radio en cada intento: 3km -> 5.5km -> 8km
        radius = 3.0 + (attempt - 1) * 2.5
        offered = await offer_trip_to_nearby_drivers(
            trip_id=trip_id,
            request_lat=request_lat,
            request_lng=request_lng,
            vehicle_type=vehicle_type,
            radius_km=radius,
        )
        if offered:
            logger.info(
                "Viaje %s ofertado a %d nuevos choferes (intento %d, radio %.1f km)",
                trip_id, len(offered), attempt, radius,
            )

    logger.warning("Viaje %s sin aceptacion tras %d reintentos", trip_id, max_retries)
    # Avisar al cliente que nadie acepto (puede cancelar o seguir esperando)
    await publish_trip_event(trip_id, "trip_no_driver_available")
    
    
@router.get("/trips/requested-nearby")
async def api_get_requested_trips_nearby(
    lat: float,
    lng: float,
    radius_km: float = Query(5.0, ge=0.5, le=50),
    limit: int = Query(20, le=100),
    driver_id: Optional[str] = Query(
        None,
        description="Si se envia, se excluyen los viajes que este conductor ya rechazo",
    ),
    vehicle_type: Optional[str] = Query(
        None,
        description=(
            "Tipo de vehiculo del conductor, obligatorio en la practica. Solo "
            "devuelve viajes que piden EXACTAMENTE ese tipo: es lo que evita que "
            "un chofer con moto vea ofertas de un viaje 'confort'. Si no se envia, "
            "no devuelve nada, porque un filtro que se salta cuando falta un dato "
            "dejaria ver todas las ofertas."
        ),
    ),
):
    """
    Retorna viajes en estado 'requested' (sin conductor asignado) cercanos a
    la ubicacion del conductor. Usa la funcion existente get_nearby_requested_trips().
    Permite a los choferes ver viajes disponibles para aceptar.
    Los rechazos del conductor se filtran aqui para que un viaje rechazado no
    le vuelva a salir: solo reaparece con una solicitud nueva del cliente.

    Tambien se filtra por `vehicle_type`: el conductor declara con que vehiculo
    sale y solo le llegan los viajes de ese tipo. Sin este filtro el sondeo
    devolvia TODO lo que hubiera alrededor, y un chofer de moto se encontraba
    ofertas de un viaje 'confort' que no podia atender.
    """
    trips = get_nearby_requested_trips(
        lat, lng, radius_km, limit, vehicle_type=vehicle_type
    )
    trips = await filter_declined_trips(trips, driver_id)
    # Enriquecer con datos del cliente desde MongoDB
    enriched = []
    for trip in trips:
        client_doc = cliente_coleccion.find_one({"_id": to_mongo_id(trip["client_id"])})
        entry = {
            **trip,
            "client_name": None,
            "client_rating": None,
            "client_phone": None,
        }
        if client_doc:
            profile = client_doc.get("profile", {})
            entry["client_name"] = _client_display_name(client_doc)
            entry["client_rating"] = profile.get("rating")
            entry["client_phone"] = _client_phone(client_doc)
        # Segundos que le quedan al viaje para que un conductor lo acepte.
        # La app NO debe calcularlo con su propio reloj: si el dispositivo
        # va adelantado se descartaria la oferta antes de mostrarse.
        entry["offer_expires_in_secs"] = _offer_secs_left(trip)
        enriched.append(entry)
    return enriched


def _offer_secs_left(trip: dict) -> int:
    """Segundos restantes de oferta, calculados con el reloj del servidor.

    Se mide contra ``OFFER_TTL_SECS`` y no contra
    ``TRIP_ACCEPT_TIMEOUT_SECS``: son dos cosas distintas. El primero es el
    plazo que el conductor ve en la pantalla y del que nace el aviso de
    pantalla completa. El segundo es la ventana de margen para aceptar un viaje
    que ya esta en curso, que tiene que ser mas amplia.

    Si se mezclaran, la appcerraria el aviso a los 60 s y volveria a recibir la
    misma oferta en el siguiente sondeo, encadenando avisos de un viaje que el
    conductor ya dio por perdido.
    """
    requested_at = trip.get("requested_at")
    if not requested_at:
        return OFFER_TTL_SECS
    now = datetime.now(timezone.utc)
    if requested_at.tzinfo is None:
        requested_at = requested_at.replace(tzinfo=timezone.utc)
    elapsed = (now - requested_at).total_seconds()
    return max(0, int(OFFER_TTL_SECS - elapsed))


@router.get("/trips/{trip_id}")
async def api_get_trip(trip_id: str):
    trip = get_trip(trip_id)
    if not trip:
        raise HTTPException(status_code=404, detail="Viaje no encontrado")

    # Enriquecer con datos del pasajero desde MongoDB (nombre y telefono).
    trip["client_name"] = None
    trip["client_phone"] = None
    if trip.get("client_id"):
        client_doc = cliente_coleccion.find_one({"_id": to_mongo_id(trip["client_id"])})
        trip["client_name"] = _client_display_name(client_doc)
        trip["client_phone"] = _client_phone(client_doc)

    # Los minutos de cortesía viajan con el viaje para que el chofer pueda
    # pintar el contador sin tener que recordar un número que el administrador
    # puede cambiar en cualquier momento.
    trip["tiempo_espera_cortesia_minutos"] = _cortesia_minutos_actual()
    return trip


@router.patch("/trips/{trip_id}/status")
async def api_update_trip_status(trip_id: str, body: TripStatusUpdate):
    try:
        ok = update_trip_status(trip_id, body.status)  # funcion sincrona original
        if not ok:
            raise HTTPException(status_code=404, detail="Viaje no encontrado")

        # Obtener driver_id para actualizar Garnet (puede ser None si viaje sin chofer asignado)
        trip = get_trip(trip_id)
        if trip:
            driver_id = trip.get("driver_id")
            if body.status == "accepted" and driver_id:
                await set_driver_status(driver_id, "busy")  # ya esta asignado, lo mantenemos
                await publish_trip_event(trip_id, "trip_accepted")
            elif body.status == "driver_arrived" and driver_id:
                await publish_trip_event(trip_id, "driver_arrived")
            elif body.status == "in_progress" and driver_id:
                # Podriamos cambiar a 'on_trip' si queremos diferenciar
                await set_driver_status(driver_id, "on_trip")
                await publish_trip_event(trip_id, "trip_started")
            elif body.status == "cancelled":
                if driver_id:
                    await set_driver_status(driver_id, "available")
                await publish_trip_event(trip_id, "trip_cancelled")
            elif body.status == "completed" and driver_id:
                # Normalmente se completa en otro endpoint, pero por si acaso
                await set_driver_status(driver_id, "available")
                await publish_trip_event(trip_id, "trip_completed")
        return {"message": f"Estado actualizado a '{body.status}'"}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/trips/{trip_id}/accept")
async def api_accept_trip(trip_id: str, driver_id: str = Query(...)):
    """
    El chofer acepta una oferta. Aqui SI se escribe el driver_id.
    UPDATE atomico: solo el primero gana.
    """
    if not validate_driver_exists(driver_id):
        raise HTTPException(404, "Conductor no encontrado en MongoDB")
    status = await get_driver_status(driver_id)
    if status != "available":
        raise HTTPException(400, f"El conductor no está disponible (estado: {status})")

    # Un chofer en números rojos no trabaja: se le avisa antes de que pierda el
    # viaje, no después. La comprobación va aquí, en el servidor, porque un reloj
    # desajustado o un SharedPreferences borrado en el móvil no pueden permitir
    # lo que el servidor veta.
    saldo = saldo_de_chofer(driver_id)
    if saldo is not None and saldo < 0:
        raise HTTPException(402, {
            "code": "saldo_negativo",
            "detail": "Tu saldo está en rojo (%s CUP). Recarga tu fondo antes de "
                      "aceptar viajes." % saldo,
            "saldo": saldo,
        })

    trip = get_trip(trip_id)
    if not trip:
        raise HTTPException(404, "Viaje no encontrado")
    if trip["status"] != "requested":
        raise HTTPException(400, f"El viaje no está disponible (estado: {trip['status']})")

    # TERCERA BARRERA, y la que de verdad importa: el tipo de vehiculo.
    #
    # El sondeo ya filtra y la app del chofer tambien descarta lo que no sea de su
    # tipo, pero aceptar es el punto sin retorno. Si aqui no se comprueba, una
    # oferta que se colara por cualquier motivo (un fallo de cache, un endpoint
    # nuevo, una app vieja sin el filtro) dejaria a un chofer de basico atado a un
    # viaje de moto, y ese chofer no tendria forma de deshacerlo.
    #
    # Se compara el tipo NORMALIZADO y con igualdad exacta. Y si el chofer no
    # tiene tipo declarado, no puede aceptar: no sabemos que vehiculo maneja.
    doc_chofer = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)}) or {}
    tipo_chofer = _driver_vehicle_type(doc_chofer)
    tipo_viaje = _normalize_vehicle_type(trip.get("vehicle_type"))

    if tipo_chofer is None or tipo_viaje is None or tipo_chofer != tipo_viaje:
        logger.warning("intento de aceptar con vehiculo que no toca: "
                       "chofer=%s (%s) trip=%s (%s)",
                       driver_id, tipo_chofer, trip_id, tipo_viaje)
        raise HTTPException(400, {
            "code": "tipo_vehiculo_no_coincide",
            "detail": "Este viaje pide un vehículo de tipo %s y tu ficha dice %s. "
                      "No puedes aceptarlo."
                      % (tipo_viaje or "desconocido", tipo_chofer or "sin definir"),
            "tipo_chofer": tipo_chofer,
            "tipo_viaje": tipo_viaje,
        })

    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        try:
            cur.execute("""
                UPDATE trips SET driver_id = %s, status = 'accepted'
                WHERE trip_id = %s AND status = 'requested'
                RETURNING trip_id, client_id;
            """, (driver_id, trip_id))
            row = cur.fetchone()
            if not row:
                conn.rollback()
                raise HTTPException(409, "El viaje ya fue aceptado por otro conductor o cancelado")
            conn.commit()
        except HTTPException:
            raise
        except Exception as e:
            conn.rollback()
            logger.exception("accept_trip fallo para el viaje %s", trip_id)
            raise e

        finally:
            cur.close()

    # Cambiar estado del chofer y notificar al cliente
    await set_driver_status(driver_id, "busy")
    await publish_trip_event(trip_id, "trip_accepted", {
        "driver_id": driver_id,
        "client_id": trip.get("client_id"),
    })

    # Avisar a los DEMAS choferes que el viaje ya fue tomado
    others = await garnet.smembers(f"trip:{trip_id}:offered")
    for other in others:
        if other != driver_id:
            await garnet.publish(f"driver:{other}:offers", json.dumps({
                "trip_id": trip_id,
                "event": "trip_taken",
                # A quien se le avisa (el chofer que estaba viendo la oferta).
                # Sin esto, si el canal se llegara a compartir o mostrar, el
                # chofer no podria saber si el aviso es para el.
                "target_driver_id": other,
                # Quien se llevo el viaje, para el mensaje de la app.
                "taken_by_driver_id": driver_id,
            }))

    # Limpiar la lista de ofertados (ya no aplica)
    await garnet.delete(f"trip:{trip_id}:offered")

    return {
        "trip_id": trip_id,
        "driver_id": driver_id,
        "status": "accepted",
        "message": "Viaje aceptado por el conductor",
    }


@router.post("/trips/{trip_id}/decline")
async def api_decline_trip(trip_id: str, driver_id: str = Query(...)):
    """El chofer rechaza la oferta. El viaje sigue en 'requested' para otro conductor.

    NO se saca al chofer de 'trip:{trip_id}:offered': si se sacara, el siguiente
    reintento de despacho (radio 3 -> 5.5 -> 8 km) se lo volveria a ofrecer. Se
    registra en 'trip:{trip_id}:declined', que el sondeo de la app tambien
    consulta, asi el viaje no le reaparece hasta que el cliente haga una nueva
    solicitud (que genera otro trip_id).
    """
    await mark_driver_declined(trip_id, driver_id)
    await garnet.publish(f"driver:{driver_id}:offers", json.dumps({
        "trip_id": trip_id, "event": "trip_declined",
    }))
    return {"message": "Oferta rechazada", "trip_id": trip_id, "driver_id": driver_id}


@router.put("/trips/{trip_id}/pickup")
async def api_set_pickup(trip_id: str, body: PickupLocation):
    ok = set_pickup_location(trip_id, body.lat, body.lng)
    if not ok:
        raise HTTPException(status_code=404, detail="Viaje no encontrado")
    return {"message": "Ubicacion de recogida actualizada"}


@router.put("/trips/{trip_id}/dropoff")
async def api_set_dropoff(trip_id: str, body: DropoffLocation):
    ok = set_dropoff_location(trip_id, body.lat, body.lng)
    if not ok:
        raise HTTPException(status_code=404, detail="Viaje no encontrado")
    return {"message": "Ubicacion de destino actualizada"}


@router.put("/trips/{trip_id}/complete")
async def api_complete_trip(trip_id: str, body: TripComplete, background: BackgroundTasks):
    try:
        result = complete_trip(
            trip_id=trip_id,
            dropoff_lat=body.dropoff_lat,
            dropoff_lng=body.dropoff_lng,
            tip=body.tip,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception:
        # Cualquier otra excepcion (Mongo caido, campo nulo, error de Postgres)
        # llegaba como un 500 sin texto. Se registra con traza y se devuelve un
        # mensaje que el chofer pueda entender, sin filtrar detalles internos.
        logger.exception("api_complete_trip fallo para el viaje %s", trip_id)
        raise HTTPException(
            status_code=500,
            detail=(
                "No se pudo completar el viaje. Vuelve a intentarlo; si sigue "
                "fallando, el viaje quedo pendiente y hay que cerrarlo a mano."
            ),
        )

    # Los pasos siguientes (comision, bono, status del chofer) se ejecutan
    # DESPUES de que el viaje ya esta 'completed' en BD. Si alguno falla, el
    # viaje sigue cerrado: no hay que devolver 500 al chofer por eso.
    driver_id = result.get("driver_id")
    if driver_id:
        try:
            await set_driver_status(driver_id, "available")
        except Exception as e:
            logger.warning("No se pudo poner chofer %s en available: %s", driver_id, e)
        try:
            await publish_trip_event(trip_id, "trip_completed", {
                "total_fare": result.get("total_fare"),
                "currency": result.get("currency")
            })
        except Exception as e:
            logger.warning("No se pudo publicar trip_completed para %s: %s", trip_id, e)
        # Verificar bonificacion diaria
        try:
            bonus_result = apply_daily_bonus(driver_id)
            if bonus_result.get("bonus_applied"):
                result["bonus"] = bonus_result
        except Exception as e:
            logger.exception("Error aplicando bono a %s: %s", driver_id, e)
    else:
        logger.warning("complete_trip no devolvio driver_id para viaje %s", trip_id)

    # Metricas diarias en background para no bloquear la respuesta
    background.add_task(daily_trip_metrics)
    return result


@router.post("/trips/{trip_id}/cancel")
async def api_cancel_trip(trip_id: str, body: Optional[dict] = None):
    """Cancela un viaje.

    Hay dos formas de cancelar y solo una cuenta:

      * El PASAJERO cancela desde su app (sin cuerpo). No toca el limite del
        chofer, porque no es culpa suya.
      * El CHOFER cancela un viaje ya aceptado (con `driver_id`). Si ya ha
        gastado las tres del dia, se rechaza con `code: limite_alcanzado` y la
        app deshabilita el boton.
    """
    body = body or {}
    driver_id = body.get("driver_id")
    motivo = body.get("reason")

    trip_actual = get_trip(trip_id)

    # El limite solo se aplica al chofer, y solo si el viaje ya estaba aceptado:
    # cancelar un viaje que aun no tiene chofer no es una cancelacion de este.
    if driver_id and trip_actual and trip_actual.get("driver_id") == driver_id:
        # `get_connection` y `get_trip` son de ESTE modulo: no hace falta
        # importarlos aqui. Importarlos otra vez desde dentro creaba una sombra
        # que rompia la llamada.
        from routers.chofer_cancelaciones import (
            MAXIMO_CANCELACIONES_DIA,
            _clave_dia,
        )

        clave = _clave_dia()
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT count FROM driver_cancellations WHERE driver_id = %s AND day = %s",
                (driver_id, clave),
            )
            fila = cur.fetchone()
            cur.close()
        usadas = int((fila[0] if fila else 0) or 0)

        if usadas >= MAXIMO_CANCELACIONES_DIA:
            return {
                "ok": False,
                "code": "limite_alcanzado",
                "detail": (
                    f"Llegaste al limite de {MAXIMO_CANCELACIONES_DIA} "
                    "cancelaciones de hoy"
                ),
                "restantes": 0,
            }

    estado_previo = (trip_actual or {}).get("status")
    if estado_previo in ("completed", "cancelled"):
        return {
            "ok": False,
            "code": "no_cancelable",
            "detail": "Ese viaje ya no se puede cancelar",
        }

    ok = cancel_trip(trip_id)
    if not ok:
        raise HTTPException(status_code=400, detail="No se pudo cancelar el viaje")

    trip = get_trip(trip_id)
    if trip:
        did = trip.get("driver_id")
        if did:
            await set_driver_status(did, "available")
        await publish_trip_event(trip_id, "trip_cancelled")

    # El conteo va DESPUES de confirmar la cancelacion, para que un fallo de red
    # no descuente una de las tres oportunidades sin cancelar nada.
    restantes = None
    if driver_id:
        try:
            from routers.chofer_cancelaciones import contar_cancelacion
            info = contar_cancelacion(driver_id)
            restantes = info.get("restantes")
        except Exception:
            pass

    return {
        "ok": True,
        "message": "Viaje cancelado",
        "driver_id": driver_id,
        "reason": motivo,
        "restantes": restantes,
    }


@router.get("/trips/client/{client_id}")
async def api_get_trips_by_client(client_id: str, limit: int = Query(50, le=200)):
    return get_trips_by_client(client_id, limit)


@router.get("/trips/driver/{driver_id}")
async def api_get_trips_by_driver(driver_id: str, limit: int = Query(50, le=200)):
    viajes = get_trips_by_driver(driver_id, limit)
    # Se lee una sola vez y se reparte: `leer_promocion` va a la base y esta
    # llamada se hace en cada sondeo del chofer, no en cada uno de los viajes.
    cortesia = _cortesia_minutos_actual()
    for viaje in viajes:
        viaje["tiempo_espera_cortesia_minutos"] = cortesia
    return viajes


@router.get("/trips/status/{status}")
async def api_get_trips_by_status(status: str, limit: int = Query(50, le=200)):
    return get_trips_by_status(status, limit)


@router.get("/drivers/nearby")
async def find_nearby_drivers(
    lat: float,
    lng: float,
    radius_km: float = Query(3.0, ge=0.5, le=50)
):
    """
    Retorna conductores disponibles cercanos a una coordenada,
    usando la cache en tiempo real de Garnet y perfiles de MongoDB.
    """
    nearby = await get_nearby_drivers(lng, lat, radius_km)
    drivers = []
    for driver_id, dist in nearby:
        # Solo los que estan 'available'
        status = await get_driver_status(driver_id)
        if status != "available":
            continue

        doc = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
        if not doc:
            continue

        # --- Extraer nombre tolerando distintos esquemas ---
        profile = doc.get("profile") or {}
        name = (
            profile.get("name")
            or doc.get("name")
            or doc.get("Nombre")
            or doc.get("nombre")
        )
        if name:
            apellidos = doc.get("Apellidos") or doc.get("apellidos") or ""
            full_name = f"{name} {apellidos}".strip()
        else:
            full_name = None

        # --- Rating tolerando variantes ---
        rating = (
            profile.get("rating")
            or doc.get("rating")
            or doc.get("Rating")
            or 5.0
        )

        # --- Vehiculo tolerando variantes ---
        vehicle = doc.get("vehicle") or {}
        if isinstance(vehicle, dict) and vehicle:
            vtype = _driver_vehicle_type(doc) or "basico"
            brand = vehicle.get("Marca") or vehicle.get("brand") or ""
            model = vehicle.get("model") or ""
            plate = vehicle.get("chapa") or vehicle.get("plate") or ""
            vehicle_str = f"{brand} {model} ({plate}) [{vtype}]".strip()
        else:
            vehicle_str = _driver_vehicle_type(doc) or "desconocido"

        drivers.append({
            "driver_id": driver_id,
            "name": full_name,
            "vehicle": vehicle_str,
            "rating": rating,
            "distance_km": round(dist, 2),
        })
    return drivers


@router.get("/drivers/{driver_id}/earnings")
async def api_driver_earnings(driver_id: str, from_date: Optional[date] = None, to_date: Optional[date] = None):
    # Ignoramos las fechas del frontend: el dispositivo puede estar en otra
    # zona horaria y enviar el día equivocado. Siempre usamos la fecha de Cuba.
    today_cuba = datetime.now(CUBA_TZ).date()
    row = get_driver_earnings(driver_id, today_cuba, today_cuba)
    # Los agregados de Postgres vienen como Decimal; la app espera float.
    return {
        "total_trips": int(row.get("total_trips") or 0),
        "total_earnings": float(row.get("total_earnings") or 0),
        "avg_fare": float(row.get("avg_fare") or 0),
        "total_distance_km": float(row.get("total_distance_km") or 0),
        "total_duration_secs": int(row.get("total_duration_secs") or 0),
    }


@router.post("/drivers/{driver_id}/bonus")
async def api_apply_daily_bonus(driver_id: str):
    try:
        result = apply_daily_bonus(driver_id)
        return result
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/drivers/{driver_id}/daily-trip-count")
async def api_daily_trip_count(driver_id: str):
    count = get_daily_trip_count(driver_id)
    return {"driver_id": driver_id, "daily_trips": count, "threshold": BONIFICATION_THRESHOLD}


# ===================== ENDPOINTS: TRANSACTIONS =====================

@router.post("/transactions", status_code=201)
async def api_create_transaction(body: TransactionCreate):
    try:
        txn_id = create_transaction(
            trip_id=body.trip_id,
            user_id=body.user_id,
            user_type=body.user_type,
            amount=body.amount,
            transaction_type=body.transaction_type,
            payment_gateway=body.payment_gateway,
            gateway_reference=body.gateway_reference,
        )
        return {"transaction_id": txn_id, "message": "Transaccion creada correctamente"}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.patch("/transactions/{transaction_id}/status")
async def api_update_transaction_status(transaction_id: str, body: TransactionStatusUpdate):
    try:
        ok = update_transaction_status(transaction_id, body.status)
        if not ok:
            raise HTTPException(status_code=404, detail="Transaccion no encontrada")
        return {"message": f"Estado de transaccion actualizado a '{body.status}'"}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/transactions/{transaction_id}")
async def api_get_transaction(transaction_id: str):
    txn = get_transaction(transaction_id)
    if not txn:
        raise HTTPException(status_code=404, detail="Transaccion no encontrada")
    return txn


@router.get("/transactions/trip/{trip_id}")
async def api_get_transactions_by_trip(trip_id: str):
    return get_transactions_by_trip(trip_id)


@router.get("/transactions/user/{user_id}")
async def api_get_transactions_by_user(user_id: str, user_type: str = Query("client", pattern="^(client|driver)$"), limit: int = Query(50, le=200)):
    return get_transactions_by_user(user_id, user_type, limit)


# ===================== ENDPOINTS: FONDO Y TRANSFERENCIAS =====================

@router.get("/drivers/{driver_id}/fondo")
async def api_get_driver_fondo(driver_id: str):
    try:
        doc = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
    except Exception:
        doc = None
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    return {
        "driver_id": driver_id,
        "email": doc.get("email"),
        "nombre": doc.get("Nombre"),
        "apellidos": doc.get("Apellidos"),
        "fondo": float(doc.get("Fondo") or doc.get("fondo") or 0),
    }


@router.post("/drivers/{driver_id}/transfer")
async def api_transfer_fondo(driver_id: str, body: TransferCreate):
    amount = round(float(body.amount), 2)
    if amount <= 0:
        raise HTTPException(status_code=400, detail="El monto debe ser mayor que 0")

    try:
        sender = chofer_coleccion.find_one({"_id": to_mongo_id(driver_id)})
    except Exception:
        sender = None
    if not sender:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")

    recipient_email = body.to_driver_email.strip().lower()
    if not recipient_email:
        raise HTTPException(status_code=400, detail="Email del destinatario requerido")

    recipient = chofer_coleccion.find_one({"email": recipient_email})
    if not recipient:
        raise HTTPException(status_code=404, detail="Chofer destino no encontrado")

    recipient_id = from_mongo_id(recipient["_id"])
    if recipient_id == driver_id:
        raise HTTPException(status_code=400, detail="No puedes transferirte a ti mismo")

    sender_fondo = float(sender.get("Fondo") or sender.get("fondo") or 0)
    if sender_fondo < amount:
        raise HTTPException(status_code=400, detail="Fondo insuficiente")

    try:
        chofer_coleccion.update_one(
            {"_id": to_mongo_id(driver_id)}, {"$inc": {"Fondo": -amount}})
        chofer_coleccion.update_one(
            {"_id": to_mongo_id(recipient_id)}, {"$inc": {"Fondo": amount}})

        txn_out = create_transaction(
            None, driver_id, "driver", -amount, "transfer",
            payment_gateway="fondo_transfer", gateway_reference=recipient_id)
        txn_in = create_transaction(
            None, recipient_id, "driver", amount, "transfer",
            payment_gateway="fondo_transfer", gateway_reference=driver_id)
        update_transaction_status(txn_out, "completed")
        update_transaction_status(txn_in, "completed")
    except Exception:
        # Compensar si falla cualquier paso posterior a los debitos creditos
        chofer_coleccion.update_one(
            {"_id": to_mongo_id(driver_id)}, {"$inc": {"Fondo": amount}})
        chofer_coleccion.update_one(
            {"_id": to_mongo_id(recipient_id)}, {"$inc": {"Fondo": -amount}})
        raise HTTPException(status_code=500, detail="No se pudo completar la transferencia")

    return {
        "ok": True,
        "amount": amount,
        "to_driver_email": recipient_email,
        "fondo_restante": round(sender_fondo - amount, 2),
        "transaction_out": txn_out,
        "transaction_in": txn_in,
    }


# ===================== ENDPOINTS: DRIVER PAYOUTS =====================

@router.post("/driver-payouts", status_code=201)
async def api_create_payout(body: DriverPayoutCreate):
    try:
        payout_id = create_driver_payout(
            driver_id=body.driver_id,
            period_start=body.period_start,
            period_end=body.period_end,
            total_earnings=body.total_earnings,
            commission=body.commission,
            net_amount=body.net_amount,
        )
        return {"payout_id": payout_id, "message": "Liquidacion creada correctamente"}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.patch("/driver-payouts/{payout_id}/status")
async def api_update_payout_status(payout_id: str, body: PayoutStatusUpdate):
    try:
        ok = update_payout_status(payout_id, body.status)
        if not ok:
            raise HTTPException(status_code=404, detail="Liquidacion no encontrada")
        return {"message": f"Estado de liquidacion actualizado a '{body.status}'"}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/driver-payouts/{payout_id}")
async def api_get_payout(payout_id: str):
    payout = get_payout(payout_id)
    if not payout:
        raise HTTPException(status_code=404, detail="Liquidacion no encontrada")
    return payout


@router.get("/driver-payouts/driver/{driver_id}")
async def api_get_payouts_by_driver(driver_id: str, limit: int = Query(50, le=200)):
    return get_payouts_by_driver(driver_id, limit)


@router.get("/driver-payouts/pending")
async def api_get_pending_payouts(limit: int = Query(50, le=200)):
    return get_pending_payouts(limit)


# ===================== ENDPOINT: INICIALIZAR BD =====================

@router.post("/init-db")
async def api_init_db():
    init_db()
    return {"message": "Base de datos inicializada correctamente"}


class DriverLocation(BaseModel):
    lat: float
    lng: float

class DriverStatusUpdate(BaseModel):
    status: str  # available | busy | on_trip | offline

@router.post("/drivers/{driver_id}/location")
async def api_set_driver_location(driver_id: str, body: DriverLocation):
    await update_driver_location(driver_id, body.lng, body.lat)
    # Envia la posicion a Traccar para ir tejiendo la ruta del viaje.
    asyncio.create_task(
        asyncio.to_thread(_forward_driver_position_to_traccar, driver_id, body.lat, body.lng)
    )
    return {"message": "Ubicacion actualizada", "driver_id": driver_id}


@router.get("/trips/{trip_id}/route")
async def api_trip_route(trip_id: str):
    """Devuelve la ruta recorrida (posiciones registradas en Traccar)
    durante el viaje, para dibujarla en los mapas de chofer y cliente."""
    trip = get_trip(trip_id)
    if not trip:
        raise HTTPException(status_code=404, detail="Viaje no encontrado")
    driver_id = trip.get("driver_id")
    start = trip.get("started_at")
    points: list[dict] = []
    if driver_id and start:
        end = trip.get("completed_at") or datetime.now(timezone.utc)
        points = await asyncio.to_thread(_get_traccar_route, driver_id, start, end)
    return {"trip_id": trip_id, "points": points}

@router.post("/drivers/{driver_id}/status")
async def api_set_driver_status(driver_id: str, body: DriverStatusUpdate):
    await set_driver_status(driver_id, body.status)
    return {"message": f"Estado = {body.status}", "driver_id": driver_id}


# ===================== MAIN =====================

#if __name__ == "__main__":
    #init_pool()
    #init_db()
    #print("Base de datos inicializada correctamente.")

    #print("\nVerificando usuarios en MongoDB...")
    #for c in cliente_coleccion.find():
     #   print(f"  Cliente: {from_mongo_id(c['_id'])} - {c.get('Nombre', 'N/A')} {c.get('Apellidos', '')}")
    #for d in chofer_coleccion.find():
    #    print(f"  Conductor: {from_mongo_id(d['_id'])} - {d.get('Nombre', 'N/A')} {d.get('Apellidos', '')}")

    #import uvicorn
    #uvicorn.run(app, host="0.0.0.0", port=8000)
