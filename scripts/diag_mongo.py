# -*- coding: utf-8 -*-
"""
diag_mongo.py  (SOLO LECTURA: no escribe nada)

¿Dónde están DE VERDAD los polígonos (mallas) de las zonas en tu MongoDB?
Recorre todas las bases/colecciones y marca lo que huela a polígono.

Ejecutar en la misma ventana:
    python scripts\\diag_mongo.py

Al terminar, pégame TODA la salida en el chat.
"""
import os
import sys

try:
    from pymongo import MongoClient
except ImportError:
    print("ERROR: falta pymongo. Instálalo con: pip install pymongo")
    sys.exit(1)

CLAVES = ["MONGO_URI", "MONGODB_URI", "MONGO_URL", "MONGODB_URL",
          "ATLAS_URI", "MONGO_CONNECTION_STRING"]

uri = None
fuente = None
for v in CLAVES:
    if os.environ.get(v):
        uri = os.environ[v]
        fuente = "variable " + v
        break
if not uri:
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rutas = [os.path.join(base, ".env"), os.path.join(os.getcwd(), ".env")]
    for ruta in rutas:
        if os.path.isfile(ruta):
            with open(ruta, "r", encoding="utf-8", errors="replace") as f:
                for linea in f:
                    linea = linea.strip()
                    if linea and not linea.startswith("#") and "=" in linea:
                        k, _, v = linea.partition("=")
                        k = k.strip()
                        v = v.strip().strip('"').strip("'")
                        if k in CLAVES and v:
                            uri = v
                            fuente = "%s (%s)" % (ruta, k)
                            break
        if uri:
            break

if not uri:
    print("No encontré la URI de Mongo. Ponla en esta ventana, por ejemplo:")
    print('   $env:MONGO_URI = "mongodb+srv://usuario:CLAVE@cluster0.xxxx.mongodb.net/rapidtaxi"')
    sys.exit(1)

try:
    host = uri.split("@")[-1].split("/")[0]
    usuario = uri.split("://")[-1].split(":")[0].split("@")[0]
except Exception:
    host, usuario = "?", "?"
print("Conectando a: %s (usuario: %s) via %s" % (host, usuario, fuente))

try:
    client = MongoClient(uri, serverSelectionTimeoutMS=8000)
    client.admin.command("ping")
except Exception as e:
    print("NO conecta con Mongo: %s: %s" % (type(e).__name__, str(e)[:150]))
    sys.exit(1)

print("")
print("Colecciones con pinta de guardar polígonos / mallas:")
print("-" * 66)
alguno = False
PALABRAS = ("geometry", "coord", "poligono", "polígono", "polygon",
            "malla", "bounds", "geo")
for dbname in client.list_database_names():
    if dbname in ("admin", "local", "config"):
        continue
    db = client[dbname]
    try:
        nombres = db.list_collection_names()
    except Exception:
        continue
    for nombre in nombres:
        coll = db[nombre]
        try:
            n = coll.estimated_document_count()
        except Exception:
            n = -1
        if n == 0:
            continue
        try:
            doc = coll.find_one()
        except Exception:
            doc = None
        pistas = []
        if doc:
            for k, v in doc.items():
                kl = k.lower()
                if isinstance(v, dict) and "polygon" in str(v.get("type", "")).lower():
                    pistas.append(k + " (GeoJSON)")
                elif isinstance(v, dict) and "coordinates" in v:
                    pistas.append(k + " (dict con coordinates)")
                elif isinstance(v, list) and v and isinstance(v[0], (list, dict)):
                    pistas.append(k + " (lista anidada)")
                elif any(p in kl for p in PALABRAS):
                    pistas.append(k)
        if pistas:
            alguno = True
            print("  %s.%s  docs=%s  ->  %s" % (dbname, nombre, n,
                                                ", ".join(pistas[:8])))

if not alguno:
    print("  (nada obvio en una primera muestra de cada colección)")

print("")
print("Comprobación de lo que lee el script del agente (promociones):")
try:
    dbs = client.list_database_names()
    if "promociones" in dbs:
        cols = client["promociones"].list_collection_names()
        if "zona_especial_coords" in cols:
            print("   promociones.zona_especial_coords: EXISTE")
        else:
            print("   promociones.zona_especial_coords: NO existe")
            print("   (por eso el WARNING 'se usan coordenadas por defecto')")
    else:
        print("   la base 'promociones' NO existe en este cluster")
        print("   (por eso el WARNING 'se usan coordenadas por defecto')")
except Exception as e:
    print("   no pude comprobarlo: %s" % str(e)[:120])
