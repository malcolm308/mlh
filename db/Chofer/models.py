from pydantic import BaseModel, Field, EmailStr
from typing import Optional
from bson import ObjectId
from datetime import datetime
from enum import Enum

class Vehicle(BaseModel):
    Marca: str
    model: str
    year: int
    chapa: str
    circulation: str
    color: str
    servicio: str

class Tipo(str, Enum):
    auto_basico="basico"
           
class CHOFER(BaseModel):
    Nombre: str
    Apellidos: str
    email: EmailStr
    numero_de_telefono: str
    Enable: bool = True
    Fondo: float =1000.0
    password: str
    raiting: float =5.0
    vehicle: Vehicle
    type_vehicle: str = Tipo.auto_basico.value
    license_number: str
    status: str = "active"
    documents_verified: bool = True
    max_passengers: int
    last_location: Optional[dict] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)

    class Config:
        populate_by_name = True
        json_encoders = {datetime: lambda v: v.isoformat()}
        
   