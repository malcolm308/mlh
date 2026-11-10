import sys
sys.path.insert(0, "E:\\Taxi_Rapid")

from fastapi import APIRouter, HTTPException, status, Depends
from fastapi.security import OAuth2PasswordBearer
from pydantic import BaseModel, Field, model_validator
from typing import List, Optional, Union
from bson import ObjectId
import bcrypt
from datetime import datetime

from db.Chofer.connection import chofer_db
from db.Chofer.models import CHOFER
from db.Chofer.auth import create_access_token as create_access_token_chofer, create_refresh_token as create_refresh_token_chofer, verify_token as verify_token_chofer

from db.Cliente.connection import cliente_db
from db.Cliente.models import CLIENTE
from db.Cliente.auth import create_access_token as create_access_token_cliente, create_refresh_token as create_refresh_token_cliente, verify_token as verify_token_cliente

from services.telefono import buscar_por_telefono, es_telefono_valido, normalizar_telefono
from services.tipo_vehiculo import (normalizar_tipo_vehiculo,
                                    resolver_tipo_vehiculo)
from services.codigos_referido import asegurar_codigo, generar_codigo

from db.Administración.connection import admin_db
from db.Administración.models import ADMINISTRADOR
from db.Administración.auth import create_access_token as create_access_token_admin, create_refresh_token as create_refresh_token_admin, verify_token as verify_token_admin
from db.tokens import ACCESS_TOKEN_EXPIRE_MINUTES

router = APIRouter()

# Estados de habilitacion de un chofer (control de acceso desde el panel admin)
ESTADO_PENDIENTE = "pendiente"
ESTADO_APROBADO = "aprobado"
ESTADO_RECHAZADO = "rechazado"
ESTADO_CORRECCION = "needs_correction"

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="login")

class LoginRequest(BaseModel):
    """La persona entra con su número de celular.

    `email` sigue siendo el nombre del campo porque es lo que mandan las dos
    apps, pero lo que llega ahí puede ser un correo o un teléfono: se detecta
    cuál es por su forma. `telefono` se acepta además por si algún cliente
    prefiere no mezclar los dos conceptos en un mismo campo.

    Da igual qué se mande: el JWT sigue llevando el correo en `sub`. Cambiarlo
    obligaría a revisar documentos.py, admin_panel.py y billetera.py, que hoy lo
    usan como identificador de email.

    `app` declara QUIEN pregunta: 'chofer' o 'cliente'. Es lo que permite tener
    la MISMA persona dada de alta en las dos apps con el MISMO numero: el login
    devuelve el token de la app que pregunta, no el de la primera cuenta que
    aparezca. Las apps viejas no mandan nada y usan el orden legacy
    (chofer -> cliente -> admin).
    """

    email: Optional[str] = None
    telefono: Optional[str] = None
    password: str
    app: Optional[str] = None

    @property
    def identificador(self) -> str:
        return (self.telefono or self.email or "").strip()

    @property
    def parece_telefono(self) -> bool:
        valor = self.identificador
        return any(ch.isdigit() for ch in valor) and "@" not in valor


class TokenResponse(BaseModel):
    """Respuesta del login.

    `refresh_token` se guarda en el movil y solo se usa contra
    `/auth/refresh` para pedir un access nuevo sin volver a teclear la
    contrasena. `expires_in` son los segundos de vida del access (2 h).
    """

    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int = ACCESS_TOKEN_EXPIRE_MINUTES * 60
    status: Optional[str] = None
    missing_fields: Optional[list] = None

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
    # El documento de Mongo guarda el tipo repartido en `type_vehicle`,
    # `vehicle_type`, `vehicle.servicio` y `vehicle.type`. Este campo se declara
    # para que Pydantic no lo borre al validar, que es lo que pasaba y hacia que
    # la app recibiera null. `vehicle_type` sale ya resuelto y normalizado por el
    # validador de abajo.
    type_vehicle: Optional[str] = None
    license_number: Optional[str] = None
    # Guardado en Mongo y devuelto por el perfil para que la app pueda
    # compartirlo en el mensaje de invitacion.
    codigo_referido: Optional[str] = None
    status: Optional[str] = None
    documents_verified: Optional[bool] = None
    max_passengers: Optional[int] = None
    # Vínculo con Telegram. Lo rellena el bot al compartir el número; los choferes
    # que no usan el bot lo traen en None.
    telegram_chat_id: Optional[int] = None
    telegram_username: Optional[str] = None
    telegram_registered_at: Optional[Union[str, datetime]] = None
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

    @model_validator(mode="before")
    @classmethod
    def _resolver_tipo(cls, datos):
        """Rellena `vehicle_type` con el tipo REAL del chofer, ya normalizado.

        Sin esto la app del chofer recibia el tipo en null, no lo mandaba al
        sondeo de ofertas y el backend le enseñaba TODAS las ofertas: un basico
        veia las de moto. El fallo era silencioso en los dos extremos.

        Se hace aqui y no en cada endpoint porque las dos apps leen
        `vehicle_type` de este mismo JSON. Arreglando el contrato una vez se
        arregla para las dos, sin tocar el Dart.
        """
        if not isinstance(datos, dict):
            return datos
        if normalizar_tipo_vehiculo(datos.get("vehicle_type")):
            datos["vehicle_type"] = normalizar_tipo_vehiculo(datos["vehicle_type"])
            return datos

        resuelto = resolver_tipo_vehiculo(datos)
        if resuelto:
            datos["vehicle_type"] = resuelto
            if not datos.get("type_vehicle"):
                datos["type_vehicle"] = resuelto
        return datos

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
    # El codigo propio con el que este pasajero invita a otros.
    codigo_referido: Optional[str] = None

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


def _por_telefono_o_primero(coleccion, digitos: str):
    """Documento cuyo teléfono normalizado es `digitos`, o None.

    OJO: `buscar_por_telefono` proyecta `{"password": 0}` a proposito, porque su
    otro consumidor es el bot de Telegram y un hash de contrasena no tiene por
    que andar suelto por ahi. Aqui hace falta para comprobar la contrasena, asi
    que se vuelve a leer el documento entero por su id. Si se usara el resultado
    de la busqueda tal cual, `bcrypt.checkpw` recibiria una cadena vacia en vez
    del hash y responderia "Invalid salt" en TODOS los accesos por telefono.
    """
    for candidato in buscar_por_telefono(coleccion, digitos):
        documento = coleccion.find_one({"_id": candidato["_id"]})
        if documento:
            return documento
    return None


def _rechazar_telefono_repetido(coleccion, telefono: str) -> None:
    """Impide dar de alta dos cuentas con el mismo número DENTRO de una app.

    La misma persona PUEDE estar dada de alta en la app de chofer y en la de
    cliente con el mismo numero: son cuentas distintas en bases distintas. Lo
    que no puede haber son dos choferes (o dos pasajeros) con el mismo
    telefono, porque el login ya no sabria a quien entregar el token.

    Se compara el teléfono NORMALIZADO y no el texto guardado: sin eso,
    "+5359295207" y "59295207" pasarían los dos y el índice único no serviría,
    porque para Mongo son cadenas distintas.
    """
    if not es_telefono_valido(telefono):
        raise HTTPException(
            status_code=400,
            detail="El número de teléfono no es válido. Escribe los 8 dígitos.")
    if buscar_por_telefono(coleccion, telefono):
        raise HTTPException(
            status_code=409,
            detail="El número de teléfono ya está asociado a otra cuenta.")

def _respuesta_tokens(token_data: dict, crear_access, crear_refresh) -> dict:
    """Arma la respuesta del login con access y refresh del perfil correcto."""
    return {
        "access_token": crear_access(token_data),
        "refresh_token": crear_refresh(token_data),
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_MINUTES * 60,
    }


@router.post("/login", response_model=TokenResponse)
async def login(request: LoginRequest):
    identificador = request.identificador
    if not identificador:
        raise HTTPException(
            status_code=400, detail="Escribe tu número de teléfono o tu correo")

    # La app que pregunta decide donde mirar: una persona puede darse de alta
    # en la app de chofer Y en la de cliente (e incluso ser administrador) con
    # el MISMO correo; el login tiene que devolver la cuenta de la app que
    # pregunta, no la primera que aparezca. Sin `app` (apps viejas) se
    # conserva el orden legacy, con el admin al final.
    app_destino = (request.app or "").strip().lower()
    if app_destino in ("chofer", "driver"):
        candidatas = [("chofer", chofer_coleccion)]
    elif app_destino in ("cliente", "client", "pasajero"):
        candidatas = [("cliente", cliente_coleccion)]
    elif app_destino in ("admin", "web"):
        # El panel SIEMPRE pide 'admin': con el mismo correo usado en las
        # otras apps, aqui no puedo resolver chofer (fuente del bug
        # "token app=driver" al crear administradores).
        candidatas = [("admin", admin_coleccion)]
    else:
        candidatas = [("chofer", chofer_coleccion),
                      ("cliente", cliente_coleccion),
                      ("admin", admin_coleccion)]

    if request.parece_telefono:
        # Se busca por número normalizado, porque en la base el teléfono está
        # escrito como lo escribió la persona: "+5359295207" y "59295207" son
        # el mismo número y tienen que entrar por la misma puerta.
        digitos = normalizar_telefono(identificador)
        if not es_telefono_valido(digitos):
            raise HTTPException(
                status_code=401,
                detail="Ese número no parece válido. Revisa que esté completo.")
        cuentas = [(rol, _por_telefono_o_primero(col, digitos))
                   for rol, col in candidatas]
    else:
        correo = identificador.lower()
        cuentas = [(rol, col.find_one({"email": correo}))
                   for rol, col in candidatas]

    for rol, cuenta in cuentas:
        if not cuenta:
            continue
        if rol == "chofer":
            # El administrador decide si el chofer está apto para entrar a la app
            estado = _estado_habilitacion(cuenta)
            if estado == ESTADO_PENDIENTE:
                raise HTTPException(
                    status_code=403,
                    detail="Tu cuenta está pendiente de aprobación por el administrador")
            # needs_correction y rejected pueden entrar para corregir datos.
            # Solo se bloquea a los eliminados permanentemente o deshabilitados.
            if cuenta.get("eliminado"):
                raise HTTPException(
                    status_code=403,
                    detail="Tu cuenta fue eliminada. Contacta al soporte.")
            if estado not in (ESTADO_CORRECCION, ESTADO_RECHAZADO, "needs_correction", "rejected") \
               and not cuenta.get("Enable", True):
                raise HTTPException(status_code=403, detail="Tu cuenta está deshabilitada")
        if rol == "admin" and not cuenta.get("Enable", True):
            raise HTTPException(status_code=403, detail="Tu cuenta está deshabilitada")
        if bcrypt.checkpw(request.password.encode('utf-8'),
                          cuenta.get("password", "").encode('utf-8')):
            token_data = {"sub": cuenta["email"], "id": str(cuenta["_id"])}
            if rol == "chofer":
                resp = _respuesta_tokens(
                    token_data, create_access_token_chofer,
                    create_refresh_token_chofer)
                resp["status"] = cuenta.get("status") or cuenta.get("estado_habilitacion") or "pendiente"
                resp["missing_fields"] = cuenta.get("missing_fields") or []
                return resp
            if rol == "admin":
                return _respuesta_tokens(
                    token_data, create_access_token_admin,
                    create_refresh_token_admin)
            return _respuesta_tokens(
                token_data, create_access_token_cliente,
                create_refresh_token_cliente)

    if app_destino:
        # Una app que declara su rol no aprende cuentas de otro tipo: si el
        # correo existe como chofer pero entras al panel, es un 401 limpio
        # antes que un token equivocado.
        raise HTTPException(
            status_code=401,
            detail="El identificador o la contraseña no son correctos para "
                   "esta aplicación")

    raise HTTPException(
        status_code=401,
        detail="El número de teléfono o la contraseña no son correctos")

##################################CRUD Chofer########################################
@router.post("/chofer", response_model=ChoferResponse, status_code=status.HTTP_201_CREATED)
async def create_chofer(chofer: CHOFER):
    """Registro legacy sin documentos (solo para herramientas de prueba).

    El alta real de choferes es `POST /documentos/registro`, que exige las 10
    fotos. Aqui no se pueden subir fotos, asi que la cuenta quedara bloqueada
    para siempre en el panel (nunca podra aprobarse por falta de documentos).
    """
    if chofer_coleccion.find_one({"email": chofer.email}):
        raise HTTPException(status_code=400, detail="Correo ya registrado")

    # El teléfono identifica la cuenta DENTRO de la app de chofer. La misma
    # persona puede tener cuenta de pasajero con este mismo numero: son bases
    # distintas y el login distingue por la app que pregunta.
    _rechazar_telefono_repetido(chofer_coleccion, chofer.numero_de_telefono)

    # Convertir a dict CON fechas como string (gracias a mode='json')
    chofer_dict = chofer.model_dump(mode='json')
    # Se guarda ya normalizado: si no, la misma persona podría registrarse otra
    # vez con "+53..." y el índice único no lo detectaría.
    chofer_dict["numero_de_telefono"] = normalizar_telefono(chofer.numero_de_telefono)

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
        raise HTTPException(status_code=401, detail="Token inválido")
    
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
        raise HTTPException(status_code=401, detail="Token inválido")
    
    doc = chofer_coleccion.find_one({"_id": ObjectId(id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    # Los choferes anteriores al sistema de referidos no tienen codigo. Se
    # crea aqui, en la primera consulta del perfil, para que la app pueda
    # compartirlo sin una pantalla ni un endpoint aparte.
    asegurar_codigo(chofer_coleccion, doc)
    doc["_id"] = str(doc["_id"])
    doc.pop("password", None)
    return doc

@router.put("/chofer/{id}", response_model=ChoferResponse)
async def update_chofer(id: str, chofer: CHOFER, token: str = Depends(oauth2_scheme)):
    if not verify_token_chofer(token):
        raise HTTPException(status_code=401, detail="Token inválido")
    
    chofer_dict = chofer.model_dump()
    if chofer_dict.get("password"):
        chofer_dict["password"] = bcrypt.hashpw(chofer_dict["password"].encode('utf-8'), bcrypt.gensalt()).decode('utf-8')

    # Cambiar el teléfono no puede.convertir a dos choferes en uno solo.
    if chofer_dict.get("numero_de_telefono"):
        repetidos = [d for d in buscar_por_telefono(chofer_coleccion,
                                                    chofer_dict["numero_de_telefono"])
                     if str(d["_id"]) != str(id)]
        if repetidos:
            raise HTTPException(
                status_code=409,
                detail="El número de teléfono ya está asociado a otra cuenta.")
        chofer_dict["numero_de_telefono"] = normalizar_telefono(
            chofer_dict["numero_de_telefono"])
    
    result = chofer_coleccion.update_one({"_id": ObjectId(id)}, {"$set": chofer_dict})
    if result.matched_count == 0:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    chofer_dict["_id"] = id
    chofer_dict.pop("password", None)
    return serialize_mongo_doc(chofer_dict)


class PerfilChoferPatch(BaseModel):
    """Edicion de PERFIL por la app del chofer.

    No esta el `PUT /chofer/{id}` de arriba: ese reemplaza el documento entero
    con los valores del modelo y aqui solo se tocan los campos que el chofer
    envia (el saldo, el vehiculo y el resto quedan intactos).
    """
    Nombre: Optional[str] = None
    Apellidos: Optional[str] = None
    numero_de_telefono: Optional[str] = None


@router.patch("/chofer/{id}/perfil")
async def actualizar_perfil_chofer(id: str, body: PerfilChoferPatch,
                                   token: str = Depends(oauth2_scheme)):
    """La app del chofer edita su nombre/apellidos/telefono.

    Solo el chofer con su token y solo los campos recibidos. El telefono se
    valida y anti-duplica igual que en el registro: es el identificador del
    login internacional.
    """
    if not verify_token_chofer(token):
        raise HTTPException(status_code=401, detail="Token inválido")
    if not ObjectId.is_valid(id):
        raise HTTPException(status_code=400, detail="Id de chofer inválido")

    cambios: dict = {}
    if body.Nombre is not None:
        cambios["Nombre"] = body.Nombre.strip()
    if body.Apellidos is not None:
        cambios["Apellidos"] = body.Apellidos.strip()
    if body.numero_de_telefono is not None and body.numero_de_telefono.strip():
        telefono = body.numero_de_telefono
        if not es_telefono_valido(telefono):
            raise HTTPException(
                status_code=400,
                detail="El número de teléfono no es válido. Escribe los 8 dígitos.")
        repetidos = [d for d in buscar_por_telefono(chofer_coleccion, telefono)
                     if str(d["_id"]) != id]
        if repetidos:
            raise HTTPException(
                status_code=409,
                detail="El número de teléfono ya está asociado a otra cuenta.")
        cambios["numero_de_telefono"] = normalizar_telefono(telefono)

    if not cambios:
        raise HTTPException(status_code=400, detail="Nada que actualizar")

    resultado = chofer_coleccion.update_one(
        {"_id": ObjectId(id)}, {"$set": cambios})
    if resultado.matched_count == 0:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    return {"ok": True, "actualizados": sorted(cambios)}

@router.delete("/chofer/{id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_chofer(id: str, token: str = Depends(oauth2_scheme)):
    if not verify_token_chofer(token):
        raise HTTPException(status_code=401, detail="Token inválido")
    
    result = chofer_coleccion.delete_one({"_id": ObjectId(id)})
    if result.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Chofer no encontrado")
    return None


##################################CRUD Clientes########################################
@router.post("/cliente", response_model=ClienteResponse, status_code=status.HTTP_201_CREATED)
async def create_cliente(cliente: CLIENTE):
    if cliente_coleccion.find_one({"email": cliente.email}):
        raise HTTPException(status_code=400, detail="Correo ya registrado")

    # Único entre pasajeros: es lo que usa la app para reconocer al pasajero.
    # La misma persona puede tener cuenta de chofer con este mismo numero; el
    # login ya distingue por la app que pregunta.
    _rechazar_telefono_repetido(cliente_coleccion, cliente.numero_de_telefono)

    # El código de referido llega como dato de entrada. Si es válido se guarda
    # el `_id` del referidor en `referido_por`; el código propio del pasajero se
    # genera siempre y es otro distinto.
    codigo_invitacion = (cliente.codigo_referido or "").strip().upper()

    cliente_dict = cliente.model_dump()
    cliente_dict.pop("codigo_referido", None)
    cliente_dict["numero_de_telefono"] = normalizar_telefono(cliente.numero_de_telefono)
    cliente_dict["referido_por"] = None
    cliente_dict["descuentos_disponibles"] = 0
    cliente_dict["viajes_completados"] = 0

    if codigo_invitacion:
        try:
            from routers.promociones import leer_promocion
            referidos_activos = bool(leer_promocion().get("referidos_activos", True))
        except Exception:
            referidos_activos = True

        if not referidos_activos:
            raise HTTPException(
                status_code=400,
                detail="El sistema de referidos está desactivado.")

        referidor = cliente_coleccion.find_one(
            {"codigo_referido": codigo_invitacion})
        if not referidor:
            raise HTTPException(
                status_code=400, detail="Código de referido no válido")

        cliente_dict["referido_por"] = str(referidor["_id"])
        # Igual que /referidos/canjear-codigo: el pasajero referido recibe su
        # descuento de bienvenida. El referidor recibe el suyo cuando este
        # pasajero complete su primer viaje (complete_trip).
        cliente_dict["descuentos_disponibles"] = 1

    # El codigo propio se genera antes de insertar: una cuenta nueva ya puede
    # compartirlo desde el primer inicio de sesion.
    cliente_dict["codigo_referido"] = generar_codigo(cliente_coleccion)

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
        raise HTTPException(status_code=401, detail="Token inválido")
    
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
        raise HTTPException(status_code=401, detail="Token inválido")
    
    doc = cliente_coleccion.find_one({"_id": ObjectId(id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    # Igual que en el perfil del chofer: una cuenta antigua recibe su codigo
    # en la primera consulta y queda guardado.
    asegurar_codigo(cliente_coleccion, doc)
    doc["_id"] = str(doc["_id"])
    doc.pop("password", None)
    return doc

@router.put("/cliente/{id}", response_model=ClienteResponse)
async def update_cliente(id: str, cliente: CLIENTE, token: str = Depends(oauth2_scheme)):
    if not verify_token_cliente(token):
        raise HTTPException(status_code=401, detail="Token inválido")
    
    cliente_dict = cliente.model_dump()
    # El código propio no se toca desde este endpoint: se generó al registrarse.
    cliente_dict.pop("codigo_referido", None)
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
        raise HTTPException(status_code=401, detail="Token inválido")
    
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
        raise HTTPException(status_code=400, detail="Correo ya registrado")
    
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
        raise HTTPException(status_code=401, detail="Token inválido")
    
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
        raise HTTPException(status_code=401, detail="Token inválido")
    
    doc = admin_coleccion.find_one({"_id": ObjectId(id)})
    if not doc:
        raise HTTPException(status_code=404, detail="Admin no encontrado")
    doc["_id"] = str(doc["_id"])
    doc.pop("password", None)
    return doc 

@router.put("/admin/{id}", response_model=ClienteResponse)
async def update_admin(id: str, ADMIN: ADMINISTRADOR, token: str = Depends(oauth2_scheme)):
    if not verify_token_admin(token):
        raise HTTPException(status_code=401, detail="Token inválido")
    
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
        raise HTTPException(status_code=401, detail="Token inválido")
    
    result = admin_coleccion.delete_one({"_id": ObjectId(id)})
    if result.deleted_count == 0:
        raise HTTPException(status_code=404, detail="Admin no encontrado")
    return None
