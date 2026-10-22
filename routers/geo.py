"""
Direcciones de calle en formato cubano: "Calle 23 entre 11 y 12, Vedado".

Las calles con nombre estan descargadas en MongoDB (coleccion `calles` de la
base `Geo`, las importa scripts/importar_calles.py). Asi el "entre que calles
estoy" se responde en local, sin depender de Overpass, que desde aqui esta
permanentemente lento o devuelve 504.

Nominatim se sigue usando, pero solo para lo que las calles no traen: el
numero y el barrio. Si Nominatim tampoco responde, se devuelve la calle con
sus cruces, que es lo importante para orientarse.
"""
import math
import os
import re
import sys
import threading
import time
import unicodedata
from typing import Dict, List, Optional, Tuple

import httpx
import requests
from fastapi import APIRouter, Query
from pymongo import MongoClient

sys.path.insert(0, "E:\\Taxi_Rapid")

try:
    from shapely.geometry import Point
except Exception:  # la busqueda normal sigue funcionando sin shapely
    Point = None

router = APIRouter()

# Mismo area que los tiles locales y que AppConfig en la app Flutter.
MAP_SOUTH, MAP_NORTH = 22.89768, 23.30190
MAP_WEST, MAP_EAST = -82.60071, -82.19971

_geo = MongoClient(os.getenv("MONGODB_URI", "mongodb://localhost:27017"))["Geo"]
_calles = _geo["calles"]
_progreso = _geo["progreso_calles"]

NOMINATIM = "https://nominatim.openstreetmap.org/reverse"
OVERPASS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
USER_AGENT = "TaxiRapid/1.0 (apps de taxi)"

# ---- Geocodificacion por texto (buscador de direcciones) ----
# Photon es gratis y no pide clave. Se consulta desde el backend (no desde el
# movil) porque desde Cuba los hosts publicos de geocoding son poco fiables; el
# movil habla con nuestro backend y el backend con Photon.
PHOTON = os.getenv("PHOTON_URL", "https://photon.komoot.io/api/")
# OpenCage solo se usa si Photon no responde. Su clave va por entorno, como el
# resto de secretos del backend (nunca en la base ni en el repositorio).
OPENCAGE = "https://api.opencagedata.com/geocode/v1/json"
OPENCAGE_API_KEY = os.getenv("OPENCAGE_API_KEY", "")
# Centro y radio por defecto para sesgar los resultados hacia La Habana cuando
# la app no manda coordenadas actuales.
GEO_CENTRO = (23.1136, -82.3666)
GEO_RADIO_M = 30000
GEO_TIMEOUT_S = float(os.getenv("GEO_TIMEOUT_S", "10"))
# Radio (metros) dentro del cual una calle cuenta como "de la interseccion"
# cuando el usuario escribe "Calle A entre Calle B y Calle C".
ENTRE_RADIO_M = 100.0
# Radio (metros) alrededor del usuario/centro dentro del cual se buscan las
# calles del "entre". El usuario puede pedir una direccion lejos de donde esta
# (va en un taxi a otra zona), asi que el radio es amplio: el desempate lo
# hace el cruce real y, a igualdad, la esquina mas cercana al usuario.
RADIO_USUARIO_M = float(os.getenv("GEO_RADIO_USUARIO_M", "15000"))
# Las calles laterales ("entre X y Y") pueden estar algo mas lejos: la principal
# es la que debe estar cerca del usuario.
RADIO_LATERAL_M = float(os.getenv("GEO_RADIO_LATERAL_M", "15000"))
# Tolerancia (metros) para dar por valida la esquina B-C en el respaldo Photon.
ESQUINA_TOL_M = 50.0
# Separacion maxima (m) entre las dos esquinas de "A entre B y C". En La
# Habana las calles numeradas van cada 100-200 m; si los dos cruces
# quedan mas lejos, no es la misma direccion.
MAX_ENTRE_SEPARACION_M = float(os.getenv("GEO_MAX_ENTRE_SEP_M", "350"))
# Radio ampliado (metros) para el "entre" cuando OSM no registra el cruce
# exacto pero las calles si pasan cerca: se devuelve una coordenada aproximada.
APROX_RADIO_M = 800.0

# Se buscan vias cuyo punto medio caiga en este radio; luego se mide la
# distancia real al segmento, asi que el margen extra es porprecision.
RADIO_BUSQUEDA = 260.0
# el centroide de una via larga puede quedar lejos aunque la via pase al lado,
# asi que se pregunta mas amplio y se filtra en Python con RADIO_BUSQUEDA
RADIO_CENTROIDO = 900.0
# Distancia maxima para que una calle cuente como "entre".
RADIO_ENTRE = 130.0
# Distancia maxima para que una calle sea la principal (la calle del punto).
RADIO_PRINCIPAL = 60.0
# Dos calles se consideran perpendiculares si giran al menos esto. 25 grados
# cubre las CALLes que la malla de La Habana no es perfecta, sin meter calles
# que en realidad van casi paralelas.
GRADOS_PERPENDICULAR = 25.0

# Tipos de via por los que un taxi puede circular (para elegir la principal).
VIA_CARRIL = {
    "residential", "unclassified", "tertiary", "secondary", "primary",
    "living_street", "service", "road", "motorway", "trunk",
}

_cache: Dict[str, Tuple[Dict, float]] = {}
_cache_lock = threading.Lock()
TTL_CACHE = 60 * 60 * 24 * 7   # una semana: las calles no cambian
MAX_CACHE = 5000


# --------------------------------------------------------------------------
# geometria (plano local en metros)
# --------------------------------------------------------------------------
def _a_metros(lat: float, lon: float, lat0: float, lon0: float) -> Tuple[float, float]:
    m_lat = 111320.0
    m_lon = 111320.0 * math.cos(math.radians(lat0))
    return ((lon - lon0) * m_lon, (lat - lat0) * m_lat)


def _dist_punto_segmento(lat, lon, a, b) -> float:
    ax, ay = _a_metros(a[0], a[1], lat, lon)
    bx, by = _a_metros(b[0], b[1], lat, lon)
    vx, vy = bx - ax, by - ay
    largo2 = vx * vx + vy * vy
    if largo2 == 0:
        return math.hypot(ax, ay)
    t = max(0.0, min(1.0, (-ax * vx - ay * vy) / largo2))
    return math.hypot(ax + t * vx, ay + t * vy)


def _proyeccion(geom, lat, lon) -> Optional[Tuple[float, float]]:
    """Punto de la via mas cercano a (lat, lon).

    Hace falta porque las vias vienen partidas en varios tramos: el primer
    punto de la geometria puede estar a FCS de cuadras y entonces "a la
    izquierda" y "a la derecha" salen invertidas o del mismo lado.
    """
    if len(geom) < 2:
        return None
    mejor_d, mejor = 1e18, None
    for i in range(len(geom) - 1):
        a, b = geom[i], geom[i + 1]
        ax, ay = _a_metros(a[0], a[1], lat, lon)
        bx, by = _a_metros(b[0], b[1], lat, lon)
        vx, vy = bx - ax, by - ay
        largo2 = vx * vx + vy * vy
        t = 0.0 if largo2 == 0 else max(0.0, min(1.0, (-ax * vx - ay * vy) / largo2))
        px, py = ax + t * vx, ay + t * vy
        d = math.hypot(px, py)
        if d < mejor_d:
            mejor_d = d
            mejor = (lat + py / 111320.0, lon + px / (111320.0 *
                     math.cos(math.radians(lat))))
    return mejor


def _rumbo_geom(geom, lat, lon) -> Optional[float]:
    """Rumbo (grados, 0=norte) del tramo de via mas cercano al punto."""
    if len(geom) < 2:
        return None
    mejor_d, mejor = 1e18, None
    for i in range(len(geom) - 1):
        d = _dist_punto_segmento(lat, lon, geom[i], geom[i + 1])
        if d < mejor_d:
            mejor_d = d
            ax, ay = _a_metros(geom[i][0], geom[i][1], lat, lon)
            bx, by = _a_metros(geom[i + 1][0], geom[i + 1][1], lat, lon)
            mejor = (ax, ay, bx, by)
    if mejor is None:
        return None
    ax, ay, bx, by = mejor
    if ax == bx and ay == by:
        return None
    return math.degrees(math.atan2(bx - ax, by - ay)) % 180.0


def _separacion(a: float, b: float) -> float:
    """Diferencia minima entre dos rumbos, en grados (0..90)."""
    d = abs(a - b) % 180.0
    return min(d, 180.0 - d)


def _sin_acentos(s: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", s or "")
                   if unicodedata.category(c) != "Mn")


def _normaliza(nombre: Optional[str]) -> str:
    n = _sin_acentos(nombre or "").lower()
    n = re.sub(r"[^a-z0-9 ]+", "", n)
    return re.sub(r"\s+", " ", n).strip()


def _orden_natural(nombre: str):
    """'Calle 9' va antes que 'Calle 10'."""
    palabras = nombre.split()
    return (palabras[0] if palabras else "",
            [int(x) for x in re.findall(r"\d+", nombre)], nombre)


# --------------------------------------------------------------------------
#Mongo: calles cercanas
# --------------------------------------------------------------------------
def _hay_calles() -> bool:
    return bool(_calles.estimated_document_count())


# cuadros que debe cubrir el import (9 columnas x 9 filas del area del mapa)
CUADROS_ESPERADOS = 81
_estado_import = {"completo": False, "ts": 0.0}


def _import_completo() -> bool:
    """Si ya se importaron todos los cuadros, no hace falta preguntar a Overpass.

    Se recalcula cada 30 s para no ir a la base en cada peticion.
    """
    ahora = time.time()
    if ahora - _estado_import["ts"] < 30.0:
        return _estado_import["completo"]
    _estado_import["ts"] = ahora
    try:
        completos = _progreso.count_documents({"completa": True})
    except Exception:
        completos = 0
    _estado_import["completo"] = completos >= CUADROS_ESPERADOS
    return _estado_import["completo"]


def _radianes(metros: float) -> float:
    """$centerSphere trabaja en radianes, no en metros."""
    return metros / 6371008.8


def _calles_cerca(lat: float, lon: float) -> List[Dict]:
    """Vias con nombre alrededor del punto, con su distancia y rumbo.

    Se piden por centroide con un radio holgado (una avenida larga puede tener
    el centro lejos y aun asi cruzar por aqui) y luego se descarta en Python
    lo que de verdad queda lejos del punto.
    """
    docs = list(_calles.find(
        {"punto": {"$geoWithin": {"$centerSphere": [
            [lon, lat], _radianes(RADIO_CENTROIDO)]}}},
        {"nombre": 1, "tipo": 1, "geom": 1, "_id": 0},
    ))
    salida = []
    for d in docs:
        geom = d.get("geom") or []
        if len(geom) < 2:
            continue
        dist = min(_dist_punto_segmento(lat, lon, geom[i], geom[i + 1])
                   for i in range(len(geom) - 1))
        if dist > RADIO_BUSQUEDA:
            continue
        rumbo = _rumbo_geom(geom, lat, lon)
        if rumbo is None:
            continue
        salida.append({"nombre": d["nombre"], "tipo": d.get("tipo"),
                       "geom": geom, "dist": dist, "rumbo": rumbo,
                       "norm": _normaliza(d["nombre"])})
    salida.sort(key=lambda m: m["dist"])
    return salida


def _overpass_cerca(lat: float, lon: float) -> List[Dict]:
    """Solo si la base local todavia no tiene calles (import en curso)."""
    q = ('[out:json][timeout:25];'
         'way["highway"]["name"](around:140,%.6f,%.6f);out geom;' % (lat, lon))
    cabeceras = {"User-Agent": USER_AGENT,
                 "Content-Type": "application/x-www-form-urlencoded"}
    for host in OVERPASS:
        try:
            r = requests.post(host, data=q.encode("utf-8"),
                              headers=cabeceras, timeout=30)
            if r.status_code != 200:
                continue
            elementos = (r.json() or {}).get("elements") or []
            salida = []
            for el in elementos:
                tags = el.get("tags") or {}
                geom = el.get("geometry") or []
                if not tags.get("name") or len(geom) < 2:
                    continue
                puntos = [[g["lat"], g["lon"]] for g in geom]
                salida.append({"nombre": tags["name"], "tipo": tags.get("highway"),
                               "geom": puntos,
                               "dist": min(_dist_punto_segmento(lat, lon,
                                                                 puntos[i], puntos[i + 1])
                                           for i in range(len(puntos) - 1)),
                               "rumbo": _rumbo_geom(puntos, lat, lon),
                               "norm": _normaliza(tags["name"])})
            if salida:
                salida.sort(key=lambda m: m["dist"])
                return salida
        except Exception:
            continue
    return []


# --------------------------------------------------------------------------
# Nominatim: numero y barrio
# --------------------------------------------------------------------------
def _nominatim(lat: float, lon: float) -> Dict:
    try:
        r = requests.get(NOMINATIM, params={
            "lat": lat, "lon": lon, "zoom": 18, "format": "json",
        }, headers={"User-Agent": USER_AGENT}, timeout=10)
        r.raise_for_status()
        addr = (r.json() or {}).get("address") or {}
    except Exception:
        addr = {}

    def _(*claves):
        for c in claves:
            if addr.get(c):
                return str(addr[c])
        return None

    return {
        "calle": _("road", "pedestrian", "footway", "residential",
                   "living_street", "unclassified", "secondary", "primary",
                   "tertiary"),
        "numero": _("house_number"),
        "barrio": _("suburb", "neighbourhood", "quarter", "city_district"),
    }


# --------------------------------------------------------------------------
# arme de la direccion
# --------------------------------------------------------------------------
def _principal(medidas: List[Dict], calle_nominatim: Optional[str]):
    """La calle sobre la que esta el punto.

    Se descartan las vias que estan lejos: una autopista larga puede tener su
    punto medio cerca sin pasar por aqui. De lo que queda se prefiere la que
    coincide con Nominatim y, si no, la mas cercana por la que un taxi puede
    circular.
    """
    if not medidas:
        return None
    cercanas = [m for m in medidas if m["dist"] <= RADIO_PRINCIPAL]
    if not cercanas:
        # El pin cayo en medio de una manzana, que en Playa, Miramar o el
        # Vedado pasa de 100 m. El chofer lo que necesita es la calle por la
        # que tiene que entrar, asi que se usa la circulable mas cercana.
        lejanas = [m for m in medidas
                   if m["dist"] <= RADIO_BUSQUEDA and m.get("tipo") in VIA_CARRIL]
        if not lejanas:
            return None
        return min(lejanas, key=lambda m: m["dist"])
    if calle_nominatim:
        objetivo = _normaliza(calle_nominatim)
        for m in cercanas:
            if m["norm"] == objetivo:
                return m
    circulables = [m for m in cercanas if m.get("tipo") in VIA_CARRIL]
    if circulables:
        return min(circulables, key=lambda m: m["dist"])
    return min(cercanas, key=lambda m: m["dist"])


# Palabras queenanta "tipo" delante del nombre de la via. Sirven para acortar
# el "entre" y para saber que "Avenida Universidad" y "Universidad" son la misma.
TIPOS_VIA = {"calle", "avenida", "av", "paseo", "callejon", "calleja", "via",
             "carretera", "boulevard", "blvd", "circunvalacion", "tunel",
             "autopista", "parada", "pasaje", "alameda", "malecin"}


def _sin_tipo(nombre: str) -> str:
    palabras = nombre.split()
    while len(palabras) > 1 and _normaliza(palabras[0]) in TIPOS_VIA:
        palabras = palabras[1:]
    return " ".join(palabras)


def _misma_via(a: Dict, b: Dict) -> bool:
    """Si las dos medidas son en realidad la misma calle."""
    if a.get("norm") == b.get("norm"):
        return True
    return _normaliza(_sin_tipo(a["nombre"])) == _normaliza(_sin_tipo(b["nombre"]))


def _distinto(candidatos: List[Dict], otro: Dict) -> Optional[Dict]:
    """El candidato mas cercano cuya via no es la misma que [otro]."""
    for c in sorted(candidatos, key=lambda m: m["dist"]):
        if not _misma_via(c, otro):
            return c
    return None


def _calles_que_cruzan(lat: float, lon: float, principal: Optional[Dict],
                       medidas: List[Dict]) -> List[str]:
    """Nombres de las dos calles que cruzan [principal], una a cada lado."""
    if not principal or not medidas:
        return []

    perpendiculares = [
        m for m in medidas
        if m is not principal
        and m["norm"] != principal["norm"]
        and m["dist"] <= RADIO_ENTRE
        and _separacion(m["rumbo"], principal["rumbo"]) >= GRADOS_PERPENDICULAR
    ]
    if not perpendiculares:
        return []

    # Direccion de la principal en el punto donde el pin la toca, y no el
    # primer vertice de la geometria, que puede estar lejos.
    p0 = _proyeccion(principal["geom"], lat, lon)
    if p0 is None:
        return []
    rumbo = principal["rumbo"]
    ax = math.sin(math.radians(rumbo))
    ay = math.cos(math.radians(rumbo))

    # En una malla "Calle 23 entre 11 y 12" son las dos calles que la cortan
    # por detras y por delante del pin, asi que se separan por la posicion a lo
    # largo de la principal, no por el lado. Eso ademas ordena bien los numeros.
    lados: Dict[str, List[Dict]] = {"bajo": [], "alto": []}
    for m in perpendiculares:
        q = _proyeccion(m["geom"], lat, lon)
        if q is None:
            continue
        bx, by = _a_metros(q[0], q[1], lat, lon)
        avance = ax * bx + ay * by
        lados["alto" if avance > 0 else "bajo"].append(m)

    bajo = min(lados["bajo"], key=lambda m: m["dist"], default=None)
    alto = min(lados["alto"], key=lambda m: m["dist"], default=None)

    if bajo and alto and _misma_via(bajo, alto):
        # OSM parte una misma calle en varios tramos, asi que la calle de un
        # lado puede aparecer tambien en el otro. Se busca el siguiente nombre
        # de verdad distinto para no repetirla en el "entre".
        alt_bajo = _distinto(lados["bajo"], alto)
        alt_alto = _distinto(lados["alto"], bajo)
        if alt_bajo and alt_alto:
            bajo, alto = alt_bajo, alt_alto
        elif alt_bajo:
            bajo, alto = alt_bajo, None
        elif alt_alto:
            alto = alt_alto
        else:
            return [bajo["nombre"]]        # solo hay una calle alrededor

    if bajo and alto:
        return sorted([bajo["nombre"], alto["nombre"]], key=_orden_natural)
    unico = bajo or alto
    return [unico["nombre"]] if unico else []


def _abrevia(principal: Optional[str], cruces: List[str]) -> List[str]:
    """'Calle 23' entre 'Calle 11' y 'Calle 12'  ->  '11 y 12'.

    Solo acorta si los tres nombres empiezan por el mismo tipo de via; si la
    principal se llama "Ronda" no hay nada que quitar.
    """
    if not principal or len(cruces) != 2:
        return cruces
    pp = principal.split()
    if len(pp) < 2:
        return cruces
    tipo = _normaliza(pp[0])
    if tipo not in TIPOS_VIA:
        return cruces
    if not all(c.split() and _normaliza(c.split()[0]) == tipo for c in cruces):
        return cruces
    return [_sin_tipo(c) or c for c in cruces]


def _arma_texto(calle, numero, cruces, barrio) -> str:
    partes = []
    if calle:
        base = "%s %s" % (calle, numero) if numero else calle
        if len(cruces) == 2:
            base += " entre %s y %s" % (cruces[0], cruces[1])
        elif len(cruces) == 1:
            base += " cerca de %s" % cruces[0]
        partes.append(base)
    if barrio and _sin_acentos(barrio).lower() not in _sin_acentos(" ".join(partes)).lower():
        partes.append(barrio)
    return ", ".join(partes)


# --------------------------------------------------------------------------
# cache
# --------------------------------------------------------------------------
def _de_cache(clave: str) -> Optional[Dict]:
    with _cache_lock:
        golpe = _cache.get(clave)
        if golpe and (time.time() - golpe[1]) < TTL_CACHE:
            d = dict(golpe[0])
            d["cache"] = True
            return d
    return None


def _a_cache(clave: str, valor: Dict) -> None:
    with _cache_lock:
        if len(_cache) > MAX_CACHE:
            _cache.clear()
        _cache[clave] = (dict(valor), time.time())


def _en_mapa(lat: float, lon: float) -> bool:
    return MAP_SOUTH <= lat <= MAP_NORTH and MAP_WEST <= lon <= MAP_EAST


# --------------------------------------------------------------------------
# Geocodificacion por texto: Photon (+ OpenCage de respaldo)
# --------------------------------------------------------------------------
def _separar_entre(texto: str) -> Optional[Tuple[str, str, str]]:
    """Descompone "Calle A entre Calle B y Calle C".

    Devuelve (principal, calle_A, calle_B) o None si no hay "entre".
    Se acepta "entre ... y ..." y "entre ... e ..." (delante de i- o hi-).
    """
    m = re.search(r"\bentre\b", texto, flags=re.IGNORECASE)
    if not m:
        return None
    principal = texto[:m.start()].strip(" ,.")
    resto = texto[m.end():]
    partes = re.split(r"\s+(?:y|e)\s+", resto, maxsplit=1, flags=re.IGNORECASE)
    if len(partes) != 2:
        return None
    calle_a = partes[0].strip(" ,.")
    calle_b = partes[1].strip(" ,.")
    if not principal or not calle_a or not calle_b:
        return None
    return principal, calle_a, calle_b


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distancia en metros entre dos puntos (para el filtro de 100 m)."""
    r = 6371008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = (math.sin(dp / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(a))


def _props(entrada: Dict) -> Dict:
    """Propiedades de una feature de Photon u OpenCage, ya aplanadas."""
    return entrada.get("properties") or {}


def _texto_desde_props(p: Dict, fallback: str = "") -> Tuple[str, str]:
    """(nombre corto, nombre largo) legibles de las propiedades de Photon."""
    nombre = p.get("name") or ""
    calle = p.get("street") or ""
    ciudad = p.get("city") or p.get("district") or ""
    pais = p.get("country") or ""
    corto = ", ".join([x for x in (nombre or calle, ciudad) if x]).strip(", ")
    largo = ", ".join([x for x in (nombre or calle, p.get("street"), ciudad, pais)
                       if x]).strip(", ")
    return (corto or fallback, largo or fallback)


def _tipos_via_photon() -> set:
    """Tipos de vía de Photon que cuentan como calle circulable."""
    return {"street", "highway", "residential", "primary", "secondary",
            "tertiary", "unclassified", "service", "living_street", "road",
            "footway", "pedestrian", "path", "trunk", "motorway"}


def _es_relevante(p: Dict) -> bool:
    """Si el resultado es una calle o un lugar útil (no un límite administrativo)."""
    tipo = (p.get("type") or "").lower()
    if tipo in {"house", "locality", "district", "city", "state", "country",
                "county", "postcode"}:
        return False
    return bool(p.get("name") or p.get("street"))


async def _photon(q: str, lat: float, lon: float, limit: int) -> List[Dict]:
    """Consulta Photon y devuelve sus features. Lista vacía si falla."""
    params = {
        "q": q,
        "lat": "%.5f" % lat,
        "lon": "%.5f" % lon,
        "limit": str(max(1, min(limit * 3, 30))),
    }
    try:
        async with httpx.AsyncClient(timeout=GEO_TIMEOUT_S) as cliente:
            resp = await cliente.get(PHOTON, params=params,
                                     headers={"User-Agent": USER_AGENT})
        if resp.status_code != 200:
            return []
        return (resp.json() or {}).get("features") or []
    except Exception:
        return []


async def _opencage(q: str, lat: float, lon: float, limit: int) -> List[Dict]:
    """Respaldo de Photon. Sin clave configurada no se intenta."""
    if not OPENCAGE_API_KEY:
        return []
    params = {
        "q": q,
        "key": OPENCAGE_API_KEY,
        "limit": str(max(1, min(limit, 10))),
        "language": "es",
        "countrycode": "cu",
        "proximity": "%.5f,%.5f" % (lat, lon),
    }
    try:
        async with httpx.AsyncClient(timeout=GEO_TIMEOUT_S) as cliente:
            resp = await cliente.get(OPENCAGE, params=params,
                                     headers={"User-Agent": USER_AGENT})
        if resp.status_code != 200:
            return []
        return (resp.json() or {}).get("results") or []
    except Exception:
        return []


def _a_resultado(lat: float, lon: float, corto: str, largo: str,
                 extra: Optional[Dict] = None) -> Dict:
    r = {"lat": round(lat, 6), "lng": round(lon, 6),
         "display_name": largo or corto, "short_label": corto or largo}
    if extra:
        r.update(extra)
    return r


def _desde_photon(features: List[Dict]) -> List[Dict]:
    resultados = []
    for f in features:
        geom = f.get("geometry") or {}
        coords = geom.get("coordinates") or []
        if len(coords) < 2:
            continue
        p = _props(f)
        if not _es_relevante(p):
            continue
        corto, largo = _texto_desde_props(p)
        resultados.append(_a_resultado(coords[1], coords[0], corto, largo))
    return resultados


def _desde_opencage(results: List[Dict]) -> List[Dict]:
    salida = []
    for r in results:
        geom = r.get("geometry") or {}
        lat, lng = geom.get("lat"), geom.get("lng")
        if lat is None or lng is None:
            continue
        comp = r.get("components") or {}
        nombre = (comp.get("road") or comp.get("neighbourhood")
                  or comp.get("suburb") or "")
        ciudad = comp.get("city") or comp.get("town") or comp.get("county") or ""
        corto = ", ".join([x for x in (nombre, ciudad) if x]).strip(", ")
        largo = r.get("formatted") or corto
        salida.append(_a_resultado(lat, lng, corto or largo, largo))
    return salida


def _dedup(resultados: List[Dict], limit: int) -> List[Dict]:
    """Quita duplicados por nombre+cercanía y recorta a `limit`."""
    vistos, salida = [], []
    for r in resultados:
        repetido = any(
            abs(r["lat"] - v["lat"]) < 1e-4 and abs(r["lng"] - v["lng"]) < 1e-4
            for v in vistos)
        if repetido:
            continue
        vistos.append(r)
        salida.append(r)
        if len(salida) >= limit:
            break
    return salida


# --------------------------------------------------------------------------
# Busqueda en la base LOCAL de calles (la malla cubana no esta en Photon)
# --------------------------------------------------------------------------
# Photon y OpenCage casi no tienen las calles de La Habana: indexan POIs
# ("Hotel Nacional") pero no la malla "Virtudes", "Industria", "Salud". Esa
# malla SI esta en MongoDB (Geo.calles, la misma que usa el reverse). Por eso
# el buscador mira primero aqui y solo cae a Photon para lo que no tenga.
# Barrios de La Habana. El usuario los anade al final de la direccion
# ("calle 23 vedado", "avenida 26 entre 23 y 25 centro") y no forman parte
# del nombre de la via, asi que se descartan al buscar en la base de calles.
BARRIOS = {
    "vedado", "centro", "habana vieja", "miramar", "playa", "marianao",
    "cerro", "la vibora", "vibora", "jesus del monte", "jesus maria",
    "purisima", "capurro", "san miguel", "new york", "regla", "guanabacoa",
    "guiteras", "habana del este", "reina", "sevillana", "santa fe",
    "cristina", "luis marquez", "pintores", "arango", "paseo de marti",
    "marti", "bellsa", "arleta", "arleta este", "concepcion", "laustralia",
    "manteca", "friki", "nuevo vedado", "villa mia", "villa moria",
    "las mesas", "las palmas", "el prado", "prado", "arboleda", "palmilla",
    "pueblito", "pueblo nuevo", "jesus del monte", "villa moria",
}


# Barrios de La Habana. El usuario los anade al final de la direccion
# ("calle 23 vedado", "avenida 26 entre 23 y 25 centro") y no forman parte
# del nombre de la via, asi que se descartan al buscar en la base de calles.
BARRIOS = {
    "vedado", "centro", "habana vieja", "miramar", "playa", "marianao",
    "cerro", "la vibora", "vibora", "jesus del monte", "jesus maria",
    "purisima", "capurro", "san miguel", "new york", "regla", "guanabacoa",
    "guiteras", "habana del este", "reina", "sevillana", "santa fe",
    "cristina", "luis marquez", "pintores", "arango", "paseo de marti",
    "marti", "bellsa", "arleta", "arleta este", "concepcion", "laustralia",
    "manteca", "friki", "nuevo vedado", "villa mia", "villa moria",
    "las mesas", "las palmas", "el prado", "prado", "arboleda", "palmilla",
    "pueblito", "pueblo nuevo",
}

# Tipos de via que puede escribir el usuario.
TIPOS_AVENIDA = {"avenida", "av", "ave", "avda", "aven", "ave.", "avenida."}
TIPOS_VIA = TIPOS_AVENIDA | {
    "calle", "callejon", "callejón", "pasaje", "paseo", "ruta", "carretera",
    "boulevard", "carril", "lateral", "autopista", "circunvalacion",
    "circunvalación", "malecon", "malecón", "quinta", "parque", "finca",
}


def _tipo_buscado(texto: str) -> str:
    """Tipo de via que escribio el usuario ("avenida", "calle", "" si no)."""
    palabras = (texto or "").split()
    if not palabras:
        return ""
    t = _normaliza(palabras[0])
    return t if t in TIPOS_VIA else ""


def _alias_avenida(texto: str) -> Optional[str]:
    """Alias de nombre para las avenidas del Vedado.

    Los datos de Yahoo (los que trae OSM en La Habana) nombran esas vias con
    un "1" pegado: "Avenida 26" esta como "126". Sin este alias, "avenida 26
    entre calle 25 y calle 23" (Vedado) no se encuentra nunca.
    """
    if _tipo_buscado(texto) not in TIPOS_AVENIDA:
        return None
    tokens = _tokens_calle(texto)
    for t in tokens:
        if t.isdigit() and len(t) == 2:
            return "1" + t
    return None


def _tokens_calle(texto: str) -> List[str]:
    """Palabras significativas de un nombre de calle, sin el tipo ("calle","avenida").

    Se descartan tambien los terminos de barrio/ciudad que el usuario anade
    ("calle 23 vedado" -> ["23"]) porque no forman parte del nombre de la via.
    """
    sin_tipo = _sin_tipo(texto)
    ruido = {"la", "habana", "el", "los", "las", "de", "del", "ciudad", "en"}
    palabras = [t for t in _normaliza(sin_tipo).split() if t and t not in ruido]
    # Los barrios de varias palabras ("jesus del monte") se quitan por frase.
    frase = " ".join(palabras)
    for b in sorted(BARRIOS, key=len, reverse=True):
        if len(b.split()) < 2:
            continue
        if (" " + b + " ") in (" " + frase + " "):
            frase = frase.replace(b, " ")
    resultado = [t for t in frase.split() if t and t not in BARRIOS]
    if not resultado:
        # "San Miguel" es a la vez un barrio y una calle: si al quitar el barrio
        # no queda nada, el nombre es el de la calle y se conserva.
        return palabras
    return resultado


def _coincide_palabra(palabra: str, token: str, alias: Optional[str] = None) -> bool:
    """True si [token] es la palabra [palabra] y no una parte de otra.

    Importa con los numeros: "25" NO es "250" ni "225" ni "126", pero si es
    "25" y "25a" (la calle 25A es la misma via con un sufijo).
    """
    if not palabra or not token:
        return False
    if token.isdigit():
        numeros = re.findall(r"\d+", palabra)
        if token in numeros:
            return True
        return bool(alias) and alias in numeros
    if palabra == token:
        return True
    return len(token) >= 4 and token in palabra


def _puntua_calle(nombre_db: str, tokens: List[str],
                  alias: Optional[str] = None) -> int:
    """Cuanto se parece el nombre de la via a lo buscado. 0 = no sirve.

    Coincidencia exacta gana siempre; si no, se exige que TODAS las palabras
    buscadas aparezcan en el nombre como palabras completas (asi 'industria' no
    confunde con 'Zona Industrial de Berroa' cuando se busca la calle
    'Industria'... bueno, esa si aparece; se ordena por nombre mas corto para
    preferir la mas parecida).
    """
    nb = _normaliza(_sin_tipo(nombre_db))
    norm_tokens = _normaliza(" ".join(tokens))
    if nb == norm_tokens:
        return 1000
    palabras = nb.split()
    if all(any(_coincide_palabra(p, t, alias) for p in palabras) for t in tokens):
        # mas palabras de mas = peor; nombre exacto corto = mejor
        return 500 - len(palabras)
    return 0


# Variantes con acento de cada letra: la regex de Mongo no sabe de acentos,
# asi que "malecón" tiene que encontrar "Malecón" y "malecon" tambien.
_VARIANTES = {
    "a": "aáàäâã", "e": "eéèëê", "i": "iíìïî", "o": "oóòöôõ",
    "u": "uúùüû", "n": "nñ", "c": "cç", "y": "yý",
}


def _regex_palabra(token: str) -> str:
    """Regex que acepta el token con o sin acentos."""
    partes = []
    for ch in token:
        if ch in _VARIANTES:
            partes.append("[%s]" % _VARIANTES[ch])
        else:
            partes.append(re.escape(ch))
    return "".join(partes)


def _palabra_limites():
    # MongoDB regex (PCRE) no reconoce \b tras letras acentuadas; usamos
    # un lookaround con alfabeto unicode.
    cls = r"[0-9A-Za-zÁÉÍÓÚÜÑáéíóúüñ]"
    return r"(?<!%s)" % cls, r"(?!%s)" % cls


def _patron_tokens(texto: str, alias: Optional[str] = None) -> str:
    """Regex de Mongo que busca los nombres que contienen [texto] completo.

    Para los numeros se exige que el numero no sea parte de otro ("25" no
    aparece en "250" ni en "225"), asi que la busqueda en la base no trae de
    mas las calles parecidas.
    """
    tokens = _tokens_calle(texto)
    if not tokens:
        return ""
    izq, der = _palabra_limites()
    partes = []
    for t in tokens:
        if t.isdigit():
            if alias and t != alias:
                partes.append(r"(?<![0-9])(?:%s|%s)(?![0-9])" % (
                    re.escape(t), re.escape(alias)))
            else:
                partes.append(r"(?<![0-9])%s(?![0-9])" % re.escape(t))
        else:
            partes.append(r"%s%s%s" % (izq, _regex_palabra(t), der))
    return "|".join(partes)


def _buscar_calles_mongo(texto: str, limit: int,
                         centro_lat: float = None,
                         centro_lng: float = None) -> List[Dict]:
    """Calles cuyo nombre coincide con [texto], de la base local."""
    tokens = _tokens_calle(texto)
    if not tokens:
        return []
    alias = _alias_avenida(texto)
    patron = _patron_tokens(texto, alias)
    docs = list(_calles.find({"nombre": {"$regex": patron, "$options": "i"}})
                .limit(400))
    puntuados = _puntuar_docs(docs, tokens, centro_lat, centro_lng, alias)
    if not puntuados and len(tokens) > 1:
        # El usuario anadio el barrio al final ("calle 23 vedado"). Se reintenta
        # quitando tokens de la derecha, que suelen ser el barrio.
        for k in range(len(tokens) - 1, 0, -1):
            sub = tokens[:k]
            if not sub:
                continue
            patron2 = _patron_tokens(" ".join(sub), alias)
            docs2 = list(_calles.find(
                {"nombre": {"$regex": patron2, "$options": "i"}}).limit(400))
            puntuados = _puntuar_docs(docs2, sub, centro_lat, centro_lng, alias)
            if puntuados:
                break
    puntuados.sort(key=lambda x: (x[0], x[1]))
    salida = []
    for _, _, d in puntuados[:limit]:
        coords = (d.get("punto") or {}).get("coordinates") or [0, 0]
        salida.append(_a_resultado(coords[1], coords[0], d.get("nombre") or texto,
                                    "%s, La Habana" % (d.get("nombre") or texto)))
    return salida


def _calles_coincidentes(texto: str, tope: int = 400,
                         centro_lat: float = None,
                         centro_lng: float = None,
                         alias: Optional[str] = None) -> List[Dict]:
    """Docs de calles cuyo nombre puntua > 0 para [texto], mejor primero.

    Se ordena por parecido del nombre y, en empate, por cercania al centro
    (util para "23", "11", "12", repetidos por toda la ciudad).
    """
    tokens = _tokens_calle(texto)
    if not tokens:
        return []
    if alias is None:
        alias = _alias_avenida(texto)
    patron = _patron_tokens(texto, alias)
    docs = list(_calles.find({"nombre": {"$regex": patron, "$options": "i"}})
                .limit(tope))
    puntuados = _puntuar_docs(docs, tokens, centro_lat, centro_lng, alias)
    if not puntuados and len(tokens) > 1:
        # El usuario anadio el barrio al final ("calle 23 vedado"). Se reintenta
        # quitando tokens de la derecha, que suelen ser el barrio.
        for k in range(len(tokens) - 1, 0, -1):
            sub = tokens[:k]
            if not sub:
                continue
            patron2 = _patron_tokens(" ".join(sub), alias)
            docs2 = list(_calles.find(
                {"nombre": {"$regex": patron2, "$options": "i"}}).limit(tope))
            sub_p = _puntuar_docs(docs2, sub, centro_lat, centro_lng, alias)
            if sub_p:
                puntuados = sub_p
                break
    puntuados.sort(key=lambda x: (x[0], x[1]))
    return [d for _, _, d in puntuados]


def _puntuar_docs(docs: List[Dict], tokens: List[str],
                   centro_lat: float = None,
                   centro_lng: float = None,
                   alias: Optional[str] = None) -> List[Tuple]:
    """Puntua [docs] contra [tokens]: devuelve (-puntaje, distancia, doc)."""
    salida = []
    for d in docs:
        p = _puntua_calle(d.get("nombre") or "", tokens, alias)
        if p <= 0:
            continue
        salida.append((-p, _dist_al_centro(d, centro_lat, centro_lng), d))
    return salida


def _dist_al_centro(doc: Dict, centro_lat: float = None,
                    centro_lng: float = None) -> float:
    """Distancia (m) del tramo de la calle al punto de referencia."""
    if centro_lat is None or centro_lng is None:
        return 0.0
    coords = (doc.get("punto") or {}).get("coordinates") or []
    if len(coords) < 2:
        return 0.0
    linea = _linea_de(doc)
    try:
        if linea is not None:
            from shapely.geometry import Point
            return linea.distance(Point(centro_lng, centro_lat)) * 111320.0
        return _haversine_m(centro_lat, centro_lng, float(coords[1]),
                            float(coords[0]))
    except Exception:
        return 0.0


def _linea_de(doc: Dict):
    """LineString (shapely) de la geometria de una calle, o None.

    Ojo: `geom` guarda las coordenadas como [lat, lon], mientras que `punto`
    es GeoJSON [lon, lat]. shapely usa (x=lon, y=lat).
    """
    geom = doc.get("geom") or []
    puntos = []
    for p in geom:
        if isinstance(p, (list, tuple)) and len(p) >= 2:
            try:
                puntos.append((float(p[1]), float(p[0])))
            except (TypeError, ValueError):
                continue
    if len(puntos) < 2:
        return None
    from shapely.geometry import LineString
    return LineString(puntos)


def _ancla_cerca_centro(docs: List[Dict], centro_lat: float, centro_lng: float,
                        radio_m: float = GEO_RADIO_M) -> List[Dict]:
    """Se queda con los docs dentro del radio de busqueda, mas cercanos primero.

    Se mide la distancia del tramo completo a [centro], no del centroide: un
    segmento largo puede pasar por delante del usuario con su punto medio lejos.
    """
    from shapely.geometry import Point
    objetivo = Point(centro_lng, centro_lat)
    dentro = []
    for d in docs:
        coords = (d.get("punto") or {}).get("coordinates") or []
        if len(coords) < 2:
            continue
        linea = _linea_de(d)
        if linea is not None:
            dist = linea.distance(objetivo) * 111320.0
        else:
            lng, lat = float(coords[0]), float(coords[1])
            dist = _haversine_m(centro_lat, centro_lng, lat, lng)
        if dist <= radio_m:
            dentro.append((dist, d))
    dentro.sort(key=lambda x: x[0])
    return [d for _, d in dentro]


def _union_lineas(docs: List[Dict]):
    """Une los segmentos de varias medidas de una calle en una sola geometria."""
    from shapely.ops import unary_union
    lineas = [l for l in (_linea_de(d) for d in docs) if l is not None]
    if not lineas:
        return None
    return unary_union(lineas)


def _interseccion_estricta(docs_a: List[Dict], docs_b: List[Dict]):
    """Punto (lat, lng) donde A y B se cruzan de verdad, o None.

    La malla llega segmentada y los vertices de dos vias no siempre coinciden,
    asi que se acepta como esquina un par de segmentos a menos de ESQUINA_TOL_M.
    Un "casi cruce" mas lejano se descarta para no inventar esquinas.
    """
    lineas_a = [l for l in (_linea_de(d) for d in docs_a) if l is not None]
    lineas_b = [l for l in (_linea_de(d) for d in docs_b) if l is not None]
    from shapely.ops import nearest_points
    mejor = None
    for la in lineas_a:
        for lb in lineas_b:
            inter = la.intersection(lb)
            if not inter.is_empty:
                p = inter
                while hasattr(p, "geoms"):
                    geoms = list(p.geoms)
                    if not geoms:
                        break
                    p = geoms[0]
                if hasattr(p, "x") and hasattr(p, "y"):
                    return (p.y, p.x)
                if hasattr(p, "interpolate"):
                    q = p.interpolate(p.length / 2)
                    return (q.y, q.x)
            d = la.distance(lb)
            if mejor is None or d < mejor[0]:
                mejor = (d, la, lb)
    if mejor is None:
        return None
    dist, la, lb = mejor
    if dist * 111320.0 > ESQUINA_TOL_M:
        return None
    pa, pb = nearest_points(la, lb)
    return ((pa.y + pb.y) / 2.0, (pa.x + pb.x) / 2.0)


def _punto_mas_cercano_a(docs: List[Dict], lat: float, lng: float):
    """Punto (lat, lng) del conjunto de [docs] mas cercano a (lat, lng)."""
    from shapely.geometry import Point
    objetivo = Point(lng, lat)
    geom = _union_lineas(docs)
    if geom is None:
        return None
    from shapely.ops import nearest_points
    p = nearest_points(geom, objetivo)[0]
    return (p.y, p.x)


def _geojson_de(docs: List[Dict]) -> Optional[Dict]:
    """GeoJSON MultiLineString con la geometria de un conjunto de calles."""
    tramos = []
    for d in docs:
        g = d.get("geom_geojson")
        if not g:
            continue
        if g.get("type") == "LineString":
            coords = g.get("coordinates") or []
            if len(coords) >= 2:
                tramos.append(coords)
        elif g.get("type") == "MultiLineString":
            for c in g.get("coordinates") or []:
                if len(c) >= 2:
                    tramos.append(c)
    if not tramos:
        return None
    return {"type": "MultiLineString", "coordinates": tramos}


def _cruza_en_mongo(geom_principal: Dict, nombres: List[str]) -> List[Dict]:
    """Docs de esas vias que intersectan de verdad la geometria principal.

    Esta es la prueba dura: Mongo decide (con $geoIntersects) si las dos vias
    se cruzan de verdad o no. Sin cruce real no hay direccion, por muy parecidas
    que sean las lineas.
    """
    if geom_principal is None or not nombres:
        return []
    try:
        docs = list(_calles.find({
            "geom_geojson": {"$geoIntersects": {"$geometry": geom_principal}},
            "nombre": {"$in": nombres},
        }).limit(600))
    except Exception:
        return []
    return docs


def _puntos_cruce(docs_principal: List[Dict], docs_lateral: List[Dict],
                  centro_lat: float, centro_lng: float,
                  tope: int = 30) -> List[Tuple[float, float]]:
    """Puntos donde la principal cruza a la lateral, los mas cercanos primero."""
    gp = _union_lineas(docs_principal)
    gl = _union_lineas(docs_lateral)
    if gp is None or gl is None:
        return []
    try:
        inter = gp.intersection(gl)
    except Exception:
        return []
    if inter.is_empty:
        return []
    puntos = []
    try:
        geoms = list(inter.geoms)
    except AttributeError:
        geoms = [inter]
    for g in geoms:
        if hasattr(g, "x") and hasattr(g, "y"):
            puntos.append((g.y, g.x))
        elif hasattr(g, "geoms"):
            for gg in g.geoms:
                if hasattr(gg, "x") and hasattr(gg, "y"):
                    puntos.append((gg.y, gg.x))
    unicos = []
    for p in puntos:
        if all(_haversine_m(p[0], p[1], q[0], q[1]) > 5.0 for q in unicos):
            unicos.append(p)
    unicos.sort(key=lambda p: _haversine_m(p[0], p[1], centro_lat, centro_lng))
    return unicos[:tope]


# Distancia maxima (m) a la que se acepta que dos vias se cruzen aunque la
# malla tenga un hueco (segmentos que no comparten vertice).
MAX_APROX_M = float(os.getenv("GEO_MAX_APROX_M", "500"))


def _direccion_en(docs: List[Dict], lat: float, lng: float) -> Optional[float]:
    """Rumbo (grados) del tramo de [docs] mas cercano a (lat, lng)."""
    from shapely.geometry import Point
    from shapely.ops import nearest_points
    objetivo = Point(lng, lat)
    mejor = None
    for d in docs:
        linea = _linea_de(d)
        if linea is None:
            continue
        try:
            p = nearest_points(linea, objetivo)[0]
            pos = linea.project(p)
            a = linea.interpolate(max(0.0, pos - 0.0005))
            b = linea.interpolate(min(linea.length, pos + 0.0005))
        except Exception:
            continue
        if a.x == b.x and a.y == b.y:
            continue
        ang = math.degrees(math.atan2(b.y - a.y, b.x - a.x))
        dist = linea.distance(objetivo)
        if mejor is None or dist < mejor[0]:
            mejor = (dist, ang)
    return mejor[1] if mejor else None


def _se_cruzan(docs_a: List[Dict], docs_b: List[Dict], lat: float,
               lng: float) -> bool:
    """True si las dos vias se cruzan de verdad y no van paralelas.

    Calle y avenida paralelas (Virtudes, Industria y Salud) nunca se cruzan:
    por mucho que se acerquen, "Virtudes entre Industria y Salud" no es una
    direccion que exista.
    """
    ang_a = _direccion_en(docs_a, lat, lng)
    ang_b = _direccion_en(docs_b, lat, lng)
    if ang_a is None or ang_b is None:
        return False
    dif = abs((ang_a - ang_b + 180.0) % 360.0 - 180.0)
    return 30.0 <= dif <= 150.0


def _punto_aproximado(docs_principal: List[Dict], docs_lateral: List[Dict],
                      centro_lat: float, centro_lng: float) -> List[Tuple[float, float]]:
    """Punto de la principal mas cercano a la lateral, si se cruzan de verdad.

    Respaldo para cuando Mongo $geoIntersects no ve el cruce porque la malla
    esta segmentada y los segmentos no comparten vertice. Si las dos vias van
    paralelas, no se acepta: no hay esquina.
    """
    gp = _union_lineas(docs_principal)
    gl = _union_lineas(docs_lateral)
    if gp is None or gl is None:
        return []
    from shapely.ops import nearest_points
    try:
        p1, p2 = nearest_points(gp, gl)
    except Exception:
        return []
    dist = p1.distance(p2) * 111320.0
    if dist > MAX_APROX_M:
        return []
    lat, lng = p1.y, p1.x
    if not _se_cruzan(docs_principal, docs_lateral, lat, lng):
        return []
    return [(lat, lng)]


def _grupos_nombre(texto: str, centro_lat: float, centro_lng: float,
                   max_grupos: int = 6) -> List[Tuple[str, List[Dict]]]:
    """Docs de la via buscada agrupados por nombre canonico.

    Un mismo numero puede estar en varias zonas de la ciudad ("23" en el
    Vedado y en Guanabacoa), asi que se agrupa por nombre y se prueban los
    grupos por orden de parecido y cercania.
    """
    tokens = _tokens_calle(texto)
    if not tokens:
        return []
    alias = _alias_avenida(texto)
    docs = _calles_coincidentes(texto, tope=600, centro_lat=centro_lat,
                                centro_lng=centro_lng, alias=alias)
    grupos = {}
    for d in docs:
        p = _puntua_calle(d.get("nombre") or "", tokens, alias)
        if p <= 0:
            continue
        grupos.setdefault(d.get("nombre") or "", []).append(d)
    # Se descartan los tramos lejanos: para resolver un "entre" solo cuentan
    # las vias de la zona del usuario, y ademas la geometria se manejaria
    # mucho mejor (y la respuesta seria mas rapida).
    radio = RADIO_USUARIO_M if max_grupos <= 6 else RADIO_LATERAL_M
    salida = []
    for nombre, ds in grupos.items():
        pmax = max(_puntua_calle(d.get("nombre") or "", tokens, alias) for d in ds)
        cercanos = [d for d in ds
                    if _dist_al_centro(d, centro_lat, centro_lng) <= radio]
        if not cercanos:
            continue
        dmin = min(_dist_al_centro(d, centro_lat, centro_lng) for d in cercanos)
        salida.append((-pmax, dmin, nombre, cercanos))
    salida.sort(key=lambda x: (x[0], x[1]))
    if not salida:
        return []
    return [(nombre, ds) for _, _, nombre, ds in salida[:max_grupos]]


def _resolver_entre(docs_principal: List[Dict], grupos_a: List[Tuple[str, List[Dict]]],
                    grupos_b: List[Tuple[str, List[Dict]]],
                    centro_lat: float, centro_lng: float) -> Optional[Dict]:
    """Cruces reales entre la principal y las dos laterales. None si no hay."""
    geom_principal = _geojson_de(docs_principal)
    if geom_principal is None:
        return None
    nombres_lateral = [n for n, _ in grupos_a] + [n for n, _ in grupos_b]
    if not nombres_lateral:
        return None
    cruzan = _cruza_en_mongo(geom_principal, list(dict.fromkeys(nombres_lateral)))
    if not cruzan:
        return None
    por_nombre = {}
    for d in cruzan:
        por_nombre.setdefault(d.get("nombre") or "", []).append(d)

    def _puntos_de(grupos):
        salida = {}
        for nombre, docs in grupos:
            cruz = por_nombre.get(nombre) or []
            if cruz:
                pts = _puntos_cruce(docs_principal, cruz, centro_lat, centro_lng)
            else:
                # La malla tiene un hueco: se busca el punto mas cercano, pero
                # solo si las dos vias se cruzan de verdad (no van paralelas).
                pts = _punto_aproximado(docs_principal, docs, centro_lat,
                                        centro_lng)
            if pts:
                salida[nombre] = pts
        return salida

    pts_a = _puntos_de(grupos_a)
    pts_b = _puntos_de(grupos_b)
    if not pts_a or not pts_b:
        return None

    mejor = None
    for nombre_a, lista_a in pts_a.items():
        for nombre_b, lista_b in pts_b.items():
            for pa in lista_a:
                for pb in lista_b:
                    sep = _haversine_m(pa[0], pa[1], pb[0], pb[1])
                    if sep > MAX_ENTRE_SEPARACION_M:
                        continue
                    mid = ((pa[0] + pb[0]) / 2.0, (pa[1] + pb[1]) / 2.0)
                    dist = _haversine_m(mid[0], mid[1], centro_lat, centro_lng)
                    if mejor is None or dist < mejor["dist"]:
                        mejor = {"lat": mid[0], "lng": mid[1], "dist": dist,
                                 "sep": sep, "lateral_a": nombre_a,
                                 "lateral_b": nombre_b}
    return mejor


def _buscar_entre_mongo(principal: str, calle_a: str, calle_b: str, limit: int,
                        centro_lat: float, centro_lng: float) -> List[Dict]:
    """Resuelve "A entre B y C" con las geometrias reales de las calles.

    Reglas:
      1. A, B y C tienen que existir de verdad (por nombre, en la ciudad).
      2. A tiene que CRUZAR a B y a C (Mongo $geoIntersects sobre las
         geometrias de la base).
      3. Las dos esquinas tienen que estar cerca la una de la otra; si estan
         a cientos de metros, "A entre B y C" no describe un solo punto y la
         direccion no existe.
    """
    grupos_p = _grupos_nombre(principal, centro_lat, centro_lng, max_grupos=6)
    grupos_a = _grupos_nombre(calle_a, centro_lat, centro_lng, max_grupos=16)
    grupos_b = _grupos_nombre(calle_b, centro_lat, centro_lng, max_grupos=16)
    if not grupos_p or not grupos_a or not grupos_b:
        return []

    mejor = None
    for nombre_p, docs_p in grupos_p:
        r = _resolver_entre(docs_p, grupos_a, grupos_b, centro_lat, centro_lng)
        if r is None:
            continue
        r["nombre_principal"] = nombre_p
        if mejor is None or r["dist"] < mejor["dist"]:
            mejor = r
    if mejor is None:
        return []

    nombre = mejor["nombre_principal"]
    corto = "%s entre %s y %s" % (_nombre_limpio(nombre),
                                 _nombre_limpio(mejor["lateral_a"]),
                                 _nombre_limpio(mejor["lateral_b"]))
    largo = "%s entre %s y %s, La Habana" % (nombre,
                                              _nombre_limpio(mejor["lateral_a"]),
                                              _nombre_limpio(mejor["lateral_b"]))
    return [_a_resultado(mejor["lat"], mejor["lng"], corto, largo)]


def _punto_sobre(principal_docs: List[Dict], lateral_docs: List[Dict],
                 tolerancia_m: float):
    """Punto (lat, lng) de la principal donde cruza la lateral, o None.

    Vale si comparte un punto con la lateral o si pasa a menos de
    [tolerancia_m] de ella.
    """
    geom = _union_lineas(principal_docs)
    lateral = _union_lineas(lateral_docs)
    if geom is None or lateral is None:
        return None
    inter = geom.intersection(lateral)
    if not inter.is_empty:
        p = inter
        while hasattr(p, "geoms"):
            geoms = list(p.geoms)
            if not geoms:
                break
            p = geoms[0]
        if hasattr(p, "x") and hasattr(p, "y"):
            return (p.y, p.x)
        if hasattr(p, "interpolate"):
            q = p.interpolate(p.length / 2)
            return (q.y, q.x)
    if geom.distance(lateral) * 111320.0 > tolerancia_m:
        return None
    from shapely.ops import nearest_points
    p = nearest_points(geom, lateral)[0]
    return (p.y, p.x)


def _nombre_principal(texto: str, centro_lat: float = None,
                      centro_lng: float = None) -> str:
    """Nombre canonico de la via buscada, si esta en la base; si no, el texto.

    Se prefiere el nombre que coincide exactamente con lo pedido ("Avenida 26"
    antes que "126" o "Avenida 26 de Julio"), y a igualdad el mas cercano.
    """
    tokens = _tokens_calle(texto)
    if not tokens:
        return texto
    objetivo = " ".join(tokens)
    docs = _calles_coincidentes(texto, tope=600, centro_lat=centro_lat,
                                centro_lng=centro_lng)
    exactos = [d for d in docs
               if _normaliza(_sin_tipo(d.get("nombre") or "")) == objetivo]
    if exactos:
        # Si el usuario escribio el tipo de via ("avenida 26"), se prefiere la
        # calle con ese mismo tipo ("Avenida 26" antes que "Calle 26").
        palabras = texto.split()
        tipo = _normaliza(palabras[0]) if palabras else ""
        if tipo in TIPOS_VIA:
            mismo_tipo = [d for d in exactos
                          if _normaliza((d.get("nombre") or "").split()[0]
                                         if (d.get("nombre") or "").split()
                                         else "") == tipo]
            if mismo_tipo:
                exactos = mismo_tipo
        return exactos[0].get("nombre")
    if docs:
        return docs[0].get("nombre")
    return texto


def _nombre_limpio(texto: str) -> str:
    """Nombre de via sin el barrio ni el tipo ("calle 23 vedado" -> "23")."""
    tokens = _tokens_calle(texto)
    if not tokens:
        return _sin_tipo(texto)
    return " ".join(tokens)


async def _buscar_entre(principal: str, calle_a: str, calle_b: str,
                        lat: float, lon: float, limit: int) -> List[Dict]:
    """Respaldo Photon de "Calle A entre Calle B y Calle C".

    Photon no tiene la malla cubana, pero sirve para direcciones que si indexa.
    Validacion estricta: B y C deben geocodificar a menos de ESQUINA_TOL_M uno
    del otro (esquina real) y A debe pasar a menos de ENTRE_RADIO_M de ella.
    """
    res_a = _desde_photon(await _photon("%s La Habana" % calle_a, lat, lon, 3))
    res_b = _desde_photon(await _photon("%s La Habana" % calle_b, lat, lon, 3))
    if not res_a or not res_b:
        return []
    pa, pb = res_a[0], res_b[0]
    if _haversine_m(pa["lat"], pa["lng"], pb["lat"], pb["lng"]) > ESQUINA_TOL_M:
        return []
    esp_lat = (pa["lat"] + pb["lat"]) / 2.0
    esp_lng = (pa["lng"] + pb["lng"]) / 2.0

    candidatos = _desde_photon(
        await _photon("%s La Habana" % principal, lat, lon, limit * 3))
    cercanos = [c for c in candidatos
                if _haversine_m(esp_lat, esp_lng, c["lat"], c["lng"]) <= ENTRE_RADIO_M]
    for c in cercanos:
        c["display_name"] = "%s entre %s y %s" % (principal, calle_a, calle_b)
        c["short_label"] = "%s entre %s y %s" % (
            _sin_tipo(principal), _sin_tipo(calle_a), _sin_tipo(calle_b))
    return cercanos


@router.get("/geo/buscar")
async def buscar(q: str = Query(..., min_length=2),
                 lat: Optional[float] = Query(None, ge=-90, le=90),
                 lon: Optional[float] = Query(None, ge=-180, le=180),
                 limit: int = Query(8, ge=1, le=20)):
    """Busca direcciones por texto ("Calle 23 entre 11 y 12").

    Mira primero la base local de calles (la malla de La Habana no esta en
    Photon), resuelve el "entre" con las geometrias y, para lo que no tenga,
    cae a Photon y luego a OpenCage.
    """
    texto = (q or "").strip()
    if len(texto) < 2:
        return {"ok": False, "resultados": [], "origen": "vacio",
                "motivo": "texto demasiado corto"}

    centro_lat = lat if lat is not None else GEO_CENTRO[0]
    centro_lng = lon if lon is not None else GEO_CENTRO[1]
    if not _en_mapa(centro_lat, centro_lng):
        centro_lat, centro_lng = GEO_CENTRO

    entre = _separar_entre(texto)
    if entre:
        principal, calle_a, calle_b = entre
        resultados = []
        origen = None
        try:
            resultados = _buscar_entre_mongo(principal, calle_a, calle_b, limit,
                                             centro_lat, centro_lng)
            if resultados:
                origen = "mongo-entre"
        except Exception:
            resultados = []
        if not resultados:
            try:
                resultados = await _buscar_entre(principal, calle_a, calle_b,
                                                 centro_lat, centro_lng, limit)
                if resultados:
                    origen = "photon-entre"
            except Exception:
                resultados = []
        resultados = _dedup(resultados, limit)
        if not resultados:
            return {"ok": False, "resultados": [], "origen": "sin-resultados",
                    "motivo": "Direccion no encontrada"}
        return {"ok": True, "resultados": resultados,
                "origen": origen or "mongo-entre"}

    resultados = _buscar_calles_mongo(texto, limit, centro_lat, centro_lng)
    origen = "mongo" if resultados else None

    if not resultados:
        # No esta en la base local: Photon (POIs, calles no importadas).
        resultados = _desde_photon(
            await _photon(texto, centro_lat, centro_lng, limit))
        origen = "photon" if resultados else None

    if not resultados:
        resultados = _desde_opencage(
            await _opencage(texto, centro_lat, centro_lng, limit))
        origen = "opencage" if resultados else "sin-resultados"

    resultados = _dedup(resultados, limit)
    return {"ok": bool(resultados), "resultados": resultados,
            "origen": origen or "sin-resultados"}


# --------------------------------------------------------------------------
# endpoints
# --------------------------------------------------------------------------
@router.get("/geo/direccion")
def direccion(lat: float = Query(..., ge=-90, le=90),
              lon: float = Query(..., ge=-180, le=180),
              numero: bool = False):
    """Direccion de calle del punto, con las dos calles que lo cruzan.

    El numero de portal solo se devuelve si se pide (numero=1): un geocodificador
    inventa numeros para un punto suelto y un "454" equivocado en la pantalla
    del chofer es peor que no mostrarlo. Las calles que cruzan si se basal en
    OpenStreetMap y son de fiar.
    """
    if not _en_mapa(lat, lon):
        return {"ok": False, "texto": "", "calle": None, "numero": None,
                "barrio": None, "entre": [], "cache": False,
                "motivo": "fuera del area del mapa"}

    clave = "%.5f,%.5f|%d" % (lat, lon, 1 if numero else 0)
    guardada = _de_cache(clave)
    if guardada is not None:
        return guardada

    base = _nominatim(lat, lon)
    medidas = _calles_cerca(lat, lon)
    origen = "mongo" if medidas else "nominatim"
    if not medidas and not _import_completo():
        # el import aun no cubre esta zona: se pregunta a Overpass
        extra = _overpass_cerca(lat, lon)
        if extra:
            medidas = extra
            origen = "overpass"

    principal = _principal(medidas, base["calle"])
    n_casa = None
    barrio = base["barrio"]
    if principal is None:
        # ninguna calle local sirve: lo que diga Nominatim es lo mejor que hay
        origen = "nominatim"
    else:
        # de Nominatim solo se cree si su calle es la misma que hallamos aqui
        calle_nom = _normaliza(base["calle"])
        if not calle_nom or calle_nom != principal["norm"]:
            barrio = None
            n_casa = None
        elif numero:
            n_casa = base["numero"]

    calle = principal["nombre"] if principal else base["calle"]
    cruces = _abrevia(calle, _calles_que_cruzan(lat, lon, principal, medidas))
    texto = _arma_texto(calle, n_casa, cruces, barrio)

    respuesta = {
        "ok": bool(texto),
        "texto": texto,
        "calle": calle,
        "numero": n_casa,
        "barrio": barrio,
        "entre": cruces,
        "origen": origen,
        "dist_calle": round(principal["dist"], 1) if principal else None,
        "cache": False,
    }
    _a_cache(clave, respuesta)
    return respuesta
