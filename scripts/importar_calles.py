"""
Descarga las calles con nombre de La Habana desde Overpass y las guarda en
MongoDB para poder responder "entre que calles estoy" sin depender de la red.

El bbox se trocea en cuadros pequenos porque las consultas grandes de Overpass
devuelven 504. El script es reanudable: guarda el estado en MongoDB y al
relanzarlo sigue donde se quedo.

Uso:
    python scripts/importar_calles.py
    python scripts/importar_calles.py --forzar          # vuelve a empezar
    python scripts/importar_calles.py --revisar          # solo informa
"""
import argparse
import math
import sys
import time
from typing import Dict, List, Tuple

import requests
from pymongo import MongoClient
from pymongo.errors import BulkWriteError

# Mismo area que los tiles locales y que AppConfig en la app Flutter.
MAP_SOUTH, MAP_NORTH = 22.89768, 23.30190
MAP_WEST, MAP_EAST = -82.60071, -82.19971

# Lado del cuadro en grados (~5 km). Chunks pequenos = consultas rapidas.
PASO = 0.05

ESPEJOS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.osm.jp/api/interpreter",
]
UA = "TaxiRapid/1.0 (importador de calles de La Habana)"

client = MongoClient("mongodb://localhost:27017")
db = client["Geo"]
calles = db["calles"]
progreso = db["progreso_calles"]


def _cuadros() -> List[Tuple[float, float, float, float]]:
    """Divide el bbox en cuadros de PASO grados, empezando por la ciudad densa.

    Overpass va lento y falla mucho, asi que el orden importa: lo primero es lo
    que de verdad usa un taxi (Vedado, Centro Habana, Habana Vieja, Playa).
    """
    out = []
    n_lat = int(math.ceil((MAP_NORTH - MAP_SOUTH) / PASO))
    n_lon = int(math.ceil((MAP_EAST - MAP_WEST) / PASO))
    for i in range(n_lat):
        for j in range(n_lon):
            s = MAP_SOUTH + i * PASO
            n = min(s + PASO, MAP_NORTH)
            w = MAP_WEST + j * PASO
            e = min(w + PASO, MAP_EAST)
            out.append((s, w, n, e))

    def prioridad(c):
        s, w, n, e = c
        centro_lat = (s + n) / 2.0
        centro_lon = (w + e) / 2.0
        # nucleo urbano (la malla de calles que mas se usa)
        if 23.08 <= centro_lat <= 23.17 and -82.45 <= centro_lon <= -82.20:
            return (0, 0.0)
        # el resto, de cerca a lejos del centro de la ciudad: asi lo que de
        # verdad importa queda importado antes y los pueblos sin callejero al final
        d_lat = (centro_lat - 23.13) * 111.0
        d_lon = (centro_lon + 82.36) * 105.0
        return (1, math.hypot(d_lat, d_lon))

    out.sort(key=prioridad)
    return out


def _pregunta(host: str, cuerpo: str, espera: int = 110):
    """POST a Overpass. Devuelve el JSON o None."""
    try:
        r = requests.post(host, data=cuerpo.encode("utf-8"),
                          headers={"User-Agent": UA,
                                   "Content-Type": "application/x-www-form-urlencoded"},
                          timeout=espera)
        if r.status_code == 200:
            return r.json() or {}
    except Exception:
        pass
    return None


def _cuantas(s, w, n, e) -> int:
    """Cuantas vias con nombre hay en el cuadro (consulta barata y fiable).

    Sirve para saber si la descarga de geometria salio completa: Overpass a
    veces responde 200 con la lista a medias y si nos fiamos se nos quedan
    calles sin importar sin avisar.

    Da -1 si no se pudo averiguar. No se insiste mucho porque cuando Overpass
    esta saturado cada reintento son minutos, y un cuadro sin verificar se
    vuelve a intentar en la pasada siguiente.
    """
    q = ('[out:json][timeout:60];'
         'way["highway"]["name"](%f,%f,%f,%f);out count;' % (s, w, n, e))
    for host in ESPEJOS:
        j = _pregunta(host, q, espera=30)
        if j is None:
            continue
        # "out count" mete el total en elements[0].tags
        for el in (j.get("elements") or []):
            total = (el.get("tags") or {}).get("total")
            if total is not None:
                try:
                    return int(total)
                except (TypeError, ValueError):
                    return -1
    return -1


def _geometria(s, w, n, e) -> List[Dict]:
    """Vias con nombre del cuadro, con geometria.

    Se prueban los espejos y se queda con el que devuelve mas elementos: si
    uno responde a medias, otro suele traer la lista entera.
    """
    q = ('[out:json][timeout:90];'
         'way["highway"]["name"](%f,%f,%f,%f);'
         "out geom;" % (s, w, n, e))
    mejor: List[Dict] = []
    for host in ESPEJOS:
        j = _pregunta(host, q)
        if j is None:
            continue
        elementos = j.get("elements") or []
        if len(elementos) > len(mejor):
            mejor = elementos
        if mejor:
            break          # el primero que responde vale
    return mejor



def _punto_medio(geom) -> Tuple[float, float]:
    """Punto medio de la via como (lon, lat), que es el orden que exige GeoJSON.

    geom guarda [lat, lon]; el Point del indice 2dsphere necesita [lon, lat].
    """
    lat, lon = geom[len(geom) // 2]
    return (lon, lat)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--forzar", action="store_true",
                    help="borra lo importado y empieza de cero")
    ap.add_argument("--revisar", action="store_true",
                    help="solo informa del estado actual")
    args = ap.parse_args()

    if args.forzar:
        calles.delete_many({})
        progreso.delete_many({})

    total_cajas = calles.count_documents({})
    print("calles guardadas: %d" % total_cajas)
    if args.revisar:
        for p in progreso.find().sort("bbox", 1):
            print("   %-24s %5d vias  %s" %
                  (p["bbox"], p.get("n", 0),
                   "ok" if p.get("completa") else "PENDIENTE"))
        return

    # indice geoespacial del punto medio de cada via
    calles.create_index([("punto", "2dsphere")])
    calles.create_index("nombre")

    cajas = _cuadros()

    # El progreso se lleva por bbox, no por posicion: asi se puede cambiar el
    # orden de importacion sin perder lo ya hecho.
    def _marcadas(solo_completas):
        q = {"completa": True} if solo_completas else {"completa": {"$ne": True}}
        return {p["bbox"] for p in progreso.find(q, {"bbox": 1})}

    # Solo se saltan los cuadros que se pudieron verificar de verdad.
    hechas = _marcadas(True)
    print("cuadros verificados: %d de %d" % (len(hechas), len(cajas)))

    t0 = time.time()
    pendientes = []
    hechos_esta = 0
    for s, w, n, e in cajas:
        bstr = "%.2f,%.2f,%.2f,%.2f" % (s, w, n, e)
        if bstr in hechas:
            continue
        hechos_esta += 1
        pos = "%d/%d" % (hechos_esta, len(cajas) - len(hechas))
        # cuantas vias deberia haber: para no aceptar respuestas a medias
        esperadas = _cuantas(s, w, n, e)
        elementos = _geometria(s, w, n, e)
        if esperadas > 0 and len(elementos) < esperadas:
            print("   [%s] INCOMPLETA %d de %d, reintentando" %
                  (pos, len(elementos), esperadas))
            sys.stdout.flush()
            time.sleep(5)
            elementos = _geometria(s, w, n, e)

        docs = []
        for el in elementos:
            tags = el.get("tags") or {}
            nombre = tags.get("name")
            geom = el.get("geometry") or []
            if not nombre or len(geom) < 2:
                continue
            puntos = [[g["lat"], g["lon"]] for g in geom]
            clon, clat = _punto_medio(puntos)
            docs.append({
                "osm_id": el.get("id"),
                "nombre": nombre,
                "tipo": tags.get("highway"),
                "geom": puntos,
                "n_puntos": len(puntos),
                "punto": {"type": "Point", "coordinates": [clon, clat]},
            })
        if docs:
            try:
                calles.bulk_write([
                    __import__("pymongo").UpdateOne(
                        {"osm_id": d["osm_id"]}, {"$set": d}, upsert=True)
                    for d in docs
                ])
            except BulkWriteError as e:
                print("   aviso al guardar: %s" % e.details.get("nWriteErrors"))

        completa = esperadas >= 0 and len(elementos) >= esperadas
        if not completa:
            pendientes.append(bstr)
        progreso.update_one(
            {"bbox": bstr},
            {"$set": {"bbox": bstr, "n": len(docs), "esperadas": esperadas,
                      "completa": completa, "ts": time.time()}},
            upsert=True)
        marca = "ok" if completa else "PENDIENTE (esperadas=%d)" % esperadas
        print("   [%s] %s  %5d vias  (total %d)  %.0fs  %s" %
              (pos, bstr, len(docs), calles.count_documents({}),
               time.time() - t0, marca))
        sys.stdout.flush()

    print("\nTOTAL: %d calles con nombre, %d cuadros verificados (%.0f s)" %
          (calles.count_documents({}), len(_marcadas(True)), time.time() - t0))
    if pendientes:
        print("PENDIENTES (%d):" % len(pendientes))
        for b in pendientes:
            print("   %s" % b)
        print("Relanza el script para completar esos cuadros.")


if __name__ == "__main__":
    main()
