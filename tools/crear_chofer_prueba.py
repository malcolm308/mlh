import copy, sys
from datetime import datetime, timezone

import bcrypt
from bson import ObjectId
from pymongo import MongoClient

EMAIL = "prueba@taxirapid.cu"
PASSWORD = "prueba123"

client = MongoClient("mongodb://localhost:27017")
chofer = client["Chofer"]["users"]

if chofer.find_one({"email": EMAIL}):
    print("  el usuario ya existe, no se toca")
    sys.exit(0)

base = chofer.find_one({"email": "malcolmlamarhurtado@gmail.com"})
if not base:
    print("  no hay documento base para clonar")
    sys.exit(1)

doc = copy.deepcopy(base)
doc.pop("_id", None)
doc["_id"] = ObjectId()
doc["email"] = EMAIL
doc["password"] = bcrypt.hashpw(PASSWORD.encode("utf-8"), bcrypt.gensalt(rounds=12)).decode("utf-8")
doc["nombre"] = "Chofer"
doc["apellidos"] = "De Prueba"
doc["numero_de_telefono"] = "00000000"
doc["Enable"] = True
doc["status"] = "active"
doc["estado_habilitacion"] = "aprobado"
doc["documents_verified"] = True
doc["Fondo"] = 0.0
doc["raiting"] = 5
doc["type_vehicle"] = "basico"
doc["vehicle"] = {
    "marca": "Lada",
    "modelo": "2105",
    "anio": 1983,
    "chapa": "PRUEBA01",
    "circulacion": "",
    "color": "Rojo",
    "servicio": "basico",
}
doc["documentos"] = []
doc["created_at"] = datetime.now(timezone.utc).isoformat()
doc["updated_at"] = datetime.now(timezone.utc).isoformat()
doc["documentos_subidos_at"] = datetime.now(timezone.utc).isoformat()
doc["motivo_habilitacion"] = "Usuario de prueba creado para validar el mapa"
doc.pop("revisado_at", None)
doc.pop("revisado_por", None)

res = chofer.insert_one(doc)
print("  chofer de prueba creado")
print("  _id    : %s" % res.inserted_id)
print("  email  : %s" % EMAIL)
print("  pass   : %s" % PASSWORD)
print("  total choferes: %d" % chofer.count_documents({}))
