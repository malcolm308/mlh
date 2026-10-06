import sys
sys.path.insert(0, "E:\\Taxi_Rapid")

from fastapi import APIRouter, HTTPException, status, Depends
from fastapi.security import OAuth2PasswordBearer
from pydantic import BaseModel, Field
from typing import List, Optional, Union
from bson import ObjectId
import bcrypt
from datetime import datetime

from db.Chofer.connection import chofer_db
from db.Chofer.models import CHOFER
from db.Chofer.auth import create_access_token as create_access_token_chofer, verify_token as verify_token_chofer

from db.Cliente.connection import cliente_db
from db.Cliente.models import CLIENTE
from db.Cliente.auth import create_access_token as create_access_token_cliente, verify_token as verify_token_cliente

from db.Administración.connection import admin_db
from db.Administración.models import ADMINISTRADOR
from db.Administración.auth import create_access_token as create_access_token_admin, verify_token as verify_token_admin

router = APIRouter()

# Estados de habilitacion de un chofer (control de acceso desde el panel admin)
ESTADO_PENDIENTE = "pendiente"
ESTADO_APROBADO = "aprobado"
ESTADO_RECHAZADO = "rechazado"

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="login")

class LoginRequest(BaseModel):
    email: str
    password: str

class TokenResponse(BaseModel):
    access_token: str
    token_type: str

class ChoferResponse(BaseModel):
    id: str = Field(alias="_id") 
    Nombre: Optional[str] = None
    Apellidos: Optional[str] = None
    email: Optional[str] = None
    numero_de_telefono: Optional[str] = None
    Enable: Optional[bool] = None
    Fondo: Optional[float] = None
    raiting: Optional[float] = None
    vehicle: Optional[dict] = None
    vehicle_type: Optional[str] = None
    license_number: Optional[str] = None
    status: Optional[str] = None
    documents_verified: Optional[bool] = None
    max_passengers: Optional[int] = None
    last_location: Optional[dict] = None
    # Device de Traccar asignado a este chofer. Opcional: los choferes sin
    # GPS todavia no lo tienen y el listener los ignora. Ver docstring de
    # services/traccar_listener.py.
    traccar_device_id: Optional[int] = None
    traccar_device_uid: Optional[str] = None
    # Mongo devuelve datetime o texto segun como se escribio el documento,
    # asi que se acepta cualquiera de los dos y se serializa como ISO.
    created_at: Optional[Union[str, datetime]] = None
    updated_at: Optional[Union[str, datetime]] = None

    class Config:
        populate_by_name = True
        json_encoders = {datetime: lambda v: v.isoformat()}

class ClienteResponse(BaseModel):
    id: str = Field(alias="_id") 
    Nombre: Optional[str] = None
    Apellidos: Optional[str] = None
    email: Optional[str] = None
    numero_de_telefono: Optional[str] = None
    Enable: Optional[bool] = None
    Fondo: Optional[float] = None

    class Config:
        populate_by_name = True
    
class AdminResponse(BaseModel):
    id: str = Field(alias="_id") 
    Nombre: Optional[str] = None
    Apellidos: Optional[str] = None
    email: Optional[str] = None
    numero_de_telefono: Optional[str] = None
    rol: Optional[str] = None
    

    class Config:
        populate_by_name = True

chofer_coleccion = chofer_db.users
cliente_coleccion = cliente_db.users
admin_coleccion = admin_db.users

# Choferes dados de alta antes del panel de administracion (sin estado) cuentan como aprobados
def _estado_habilitacion(chofer: dict) -> str:
    return chofer.get("estado_habilitacion") or ESTADO_APROBADO

@router.post("/login", response_model=TokenResponse)
async def login(request: LoginRequest):
    chofer = chofer_coleccion.find_one({"email": request.email})
    if chofer:
        # El administrador decide si el chofer esta apto para entrar a la app
        estado = _estado_habilitacion(chofer)
        if estado == ESTADO_PENDIENTE:
            raise HTTPException(
                status_code=403,
                detail="Tu cuenta esta pendiente de aprobacion por el administrador")
        if estado == ESTADO_RECHAZADO:
            raise HTTPException(
                status_code=403,
                detail="Tu cuenta fue rechazada por el administrador. Contacta al soporte.")
        if not chofer.get("Enable", True):
            raise HTTPException(status_code=403, detail="Tu cuenta esta deshabilitada")
        if bcrypt.checkpw(request.password.encode('utf-8'), chofer.get("password", "").encode('utf-8')):
            token_data = {"sub": chofer["email"], "id": str(chofer["_id"])}
            access_token = create_access_token_chofer(token_data)
            return {"access_token": access_token, "token_type": "bearer"}
    
    cliente = cliente_coleccion.find_one({"email": request.email})
    if cliente:
        if bcrypt.checkpw(request.password.encode('utf-8'), cliente.get("password", "").encode('utf-8')):
            token_data = {"sub": cliente["email"], "id": str(cliente["_id"])}
            access_token = create_access_token_cliente(token_data)
            return {"access_token": access_token, "token_type": "bearer"}
    admin = admin_coleccion.find_one({"email": request.email})
    if admin:
            if bcrypt.checkpw(request.password.encode('utf-8'), admin.get("password", "").encode('utf-8')):
                token_data = {"sub": admin["email"], "id": str(admin["_id"])}
                access_token = create_access_token_cliente(token_data)
                return {"access_token": access_token, "token_type": "bearer"}
    
    raise HTTPException(status_code=401, detail="Email o contrasena incorrectos")

##################################CRUD Chofer########################################
@router.post("/chofer", response_model=ChoferResponse, status_code=status.HTTP_201_CREATED)
async def create_chofer(chofer: CHOFER):
    """Registro legacy sin documentos (solo para herramientas de prueba).

    El alta real de choferes es `POST /documentos/registro`, que exige las 10
    fotos. Aqui no se pueden subir fotos, asi que la cuenta quedara bloqueada
    para siempre en el panel (nunca podra aprobarse por falta de documentos).
    """
    if chofer_coleccion.find_one({"email": chofer.email}):
        raise HTTPException(status_code=400, detail="Email ya registrado")

    # Convertir a dict CON fechas como string (gracias a mode='json')
    chofer_dict = chofer.model_dump(mode='json')

    # Todo chofer nuevo entra pendiente: el administrador lo habilita desde el panel
    chofer_dict["estado_habilitacion"] = ESTADO_PENDIENTE
    chofer_dict["Enable"] = False
    chofer_dict["status"] = "pending_review"

    # Hashear la contrasena
    chofer_dict["password"] = bcrypt.hashpw(
        chofer_dict["password"].encode('utf-8'), bcrypt.gensalt()
    ).decode('utf-8')

    # Insertar en MongoDB (las fechas se guardaran como string ISO, que es lo que queremos)
    result = chofer_coleccion.insert_one(chofer_dict)

    # Anadir el _id como string
    chofer_dict["_id"] = str(result.inserted_id)   # <- conversion clave

    # Eliminar la contrasena de lo que se va a devolver
    chofer_dict.pop("password", None)

    # Ahora el dict contiene:
    #   "_id": "6a0514216184605ccfebd5ec" (string)
    #   "created_at": "2026-05-14T00:15:28.772542" (string)
    #   "updated_at": "2026-05-14T00:15:28.772545" (string)
    return chofer_dict

@router.get("/chofer", response_model=List[ChoferResponse])
async def get_all_choferes(token: str = Depends(oauth2_scheme)):
    if not verify_token_chofer(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    docs = chofer_coleccion.find()
    choferes = []
    for doc in docs:
        doc["_id"] = str(doc["_id"])
        doc.pop("password", None)
        choferes.append(doc)
    return choferes

@router.get("/chofer/{id}", response_model=ChoferResponse)
async def get_chofer(id: str, token: str = Depends(oauth2_scheme)):
    if not verify_token_chofer(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    doc = chofer_coleccion.find_one({"_id": ObjectId(id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    doc["_id"] = str(doc["_id"])
    doc.pop("password", None)
    return doc

@router.put("/chofer/{id}", response_model=ChoferResponse)
async def update_chofer(id: str, chofer: CHOFER, token: str = Depends(oauth2_scheme)):
    if not verify_token_chofer(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    chofer_dict = chofer.model_dump()
    if chofer_dict.get("password"):
        chofer_dict["password"] = bcrypt.hashpw(chofer_dict["password"].encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    
    result = chofer_coleccion.update_one({"_id": ObjectId(id)}, {"$set": chofer_dict})
    if result.matched_count == 0:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    chofer_dict["_id"] = id
    chofer_dict.pop("password", None)
    return serialize_mongo_doc(chofer_dict)

@router.delete("/chofer/{id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_chofer(id: str, token: str = Depends(oauth2_scheme)):
    if not verify_token_chofer(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    result = chofer_coleccion.delete_one({"_id": ObjectId(id)})
    if result.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    return None


##################################CRUD Clientes########################################
@router.post("/cliente", response_model=ClienteResponse, status_code=status.HTTP_201_CREATED)
async def create_cliente(cliente: CLIENTE):
    if cliente_coleccion.find_one({"email": cliente.email}):
        raise HTTPException(status_code=400, detail="Email ya registrado")
    
    cliente_dict = cliente.model_dump()
    # Hashear la contrasena
    cliente_dict["password"] = bcrypt.hashpw(
        cliente_dict["password"].encode('utf-8'), 
        bcrypt.gensalt()
    ).decode('utf-8')
    
    # Insertar en MongoDB
    result = cliente_coleccion.insert_one(cliente_dict)
    
    # Agregar el _id generado y convertirlo a string
    cliente_dict["_id"] = result.inserted_id
    cliente_dict.pop("password", None)          # eliminar password de la respuesta
    cliente_dict["id"] = str(cliente_dict.pop("_id"))  # renombrar _id -> id
    
    return cliente_dict

@router.get("/cliente", response_model=List[ClienteResponse])
async def get_all_clientes(token: str = Depends(oauth2_scheme)):
    if not verify_token_cliente(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    docs = cliente_coleccion.find()
    clientes = []
    for doc in docs:
        doc["_id"] = str(doc["_id"])
        doc.pop("password", None)
        clientes.append(doc)
    return clientes

@router.get("/cliente/{id}", response_model=ClienteResponse)
async def get_cliente(id: str, token: str = Depends(oauth2_scheme)):
    if not verify_token_cliente(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    doc = cliente_coleccion.find_one({"_id": ObjectId(id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    doc["_id"] = str(doc["_id"])
    doc.pop("password", None)
    return doc

@router.put("/cliente/{id}", response_model=ClienteResponse)
async def update_cliente(id: str, cliente: CLIENTE, token: str = Depends(oauth2_scheme)):
    if not verify_token_cliente(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    cliente_dict = cliente.model_dump()
    if cliente_dict.get("password"):
        cliente_dict["password"] = bcrypt.hashpw(cliente_dict["password"].encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    
    result = cliente_coleccion.update_one({"_id": ObjectId(id)}, {"$set": cliente_dict})
    if result.matched_count == 0:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    cliente_dict["_id"] = id
    cliente_dict.pop("password", None)
    return cliente_dict

@router.delete("/cliente/{id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_cliente(id: str, token: str = Depends(oauth2_scheme)):
    if not verify_token_cliente(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    result = cliente_coleccion.delete_one({"_id": ObjectId(id)})
    if result.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    return None

def serialize_mongo_doc(doc: dict) -> dict:
    """Convierte ObjectId a str y datetime a str ISO en un documento de MongoDB."""
    if doc is None:
        return doc
    # Copia para no modificar el original (buena practica)
    data = dict(doc)
    # Convertir _id a string y renombrar a "id" si se usa alias, o mantener _id
    if "_id" in data:
        data["_id"] = str(data["_id"])   # o data["id"] = ... segun tu modelo
    # Convertir fechas a ISO string si son datetime
    for field in ("created_at", "updated_at"):
        if field in data and isinstance(data[field], datetime):
            data[field] = data[field].isoformat()
    # Eliminar password si existe
    data.pop("password", None)
    return data

##################################CRUD Administrador########################################
@router.post("/admin", response_model=AdminResponse, status_code=status.HTTP_201_CREATED)
async def create_admin(ADMIN: ADMINISTRADOR):
    if admin_coleccion.find_one({"email": ADMIN.email}):
        raise HTTPException(status_code=400, detail="Email ya registrado")
    
    admin_dict = ADMIN.model_dump()
    
    # Hashear la contrasena
    admin_dict["password"] = bcrypt.hashpw(
        admin_dict["password"].encode('utf-8'), 
        bcrypt.gensalt()
    ).decode('utf-8')

    # Insertar en MongoDB
    result = admin_coleccion.insert_one(admin_dict)
    
    # Agregar el _id generado y convertirlo a string
    admin_dict["_id"] = result.inserted_id
    admin_dict.pop("password", None)          # eliminar password de la respuesta
    admin_dict["id"] = str(admin_dict.pop("_id"))  # renombrar _id -> id
    
    return admin_dict

@router.get("/admin", response_model=List[AdminResponse])
async def get_all_admin(token: str = Depends(oauth2_scheme)):
    if not verify_token_admin(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    docs = admin_coleccion.find()
    admins = []
    for doc in docs:
        doc["_id"] = str(doc["_id"])
        doc.pop("password", None)
        admins.append(doc)
    return admins  

@router.get("/admin/{id}", response_model=AdminResponse)
async def get_admin(id: str, token: str = Depends(oauth2_scheme)):
    if not verify_token_admin(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    doc = admin_coleccion.find_one({"_id": ObjectId(id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Admin no encontrado")
    doc["_id"] = str(doc["_id"])
    doc.pop("password", None)
    return doc 

@router.put("/admin/{id}", response_model=ClienteResponse)
async def update_admin(id: str, ADMIN: ADMINISTRADOR, token: str = Depends(oauth2_scheme)):
    if not verify_token_admin(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    admin_dict = ADMIN.model_dump()
    if admin_dict.get("password"):
        admin_dict["password"] = bcrypt.hashpw(admin_dict["password"].encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    
    result = admin_coleccion.update_one({"_id": ObjectId(id)}, {"$set": admin_dict})
    if result.matched_count == 0:
        raise HTTPException(status_code=404, detail="Admin no encontrado")
    admin_dict["_id"] = id
    admin_dict.pop("password", None)
    return admin_dict

@router.delete("/admin/{id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_admin(id: str, token: str = Depends(oauth2_scheme)):
    if not verify_token_admin(token):
        raise HTTPException(status_code=401, detail="Token invalido")
    
    result = admin_coleccion.delete_one({"_id": ObjectId(id)})
    if result.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Admin no encontrado")
    return None
