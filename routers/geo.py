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

import requests
from fastapi import APIRouter, Query
from pymongo import MongoClient

sys.path.insert(0, "E:\\Taxi_Rapid")

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


@router.get("/geo/estado")
def estado():
    """Como esta la base local de calles (util para el panel y el import)."""
    importadas = _calles.estimated_document_count()
    cajas = _progreso.count_documents({})
    verificadas = _progreso.count_documents({"completa": True})
    return {
        "ok": importadas > 0,
        "calles": importadas,
        "cuadros_importados": cajas,
        "cuadros_verificados": verificadas,
        "cuadros_totales": CUADROS_ESPERADOS,
        "listo": importadas > 0 and verificadas >= CUADROS_ESPERADOS,
    }
