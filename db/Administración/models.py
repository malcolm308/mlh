from pydantic import BaseModel, Field, EmailStr
from typing import Optional
from bson import ObjectId
from datetime import datetime

class ADMINISTRADOR (BaseModel):
    Nombre: str
    Apellido: str
    email: EmailStr
    numero_de_telefono: str
    password: str
    rol: str 
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)
    
