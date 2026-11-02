from typing import Optional

from pydantic import BaseModel,EmailStr

class CLIENTE(BaseModel):
    Nombre: str
    Apellidos: str
    email: EmailStr
    numero_de_telefono: str
    Enable: bool = True
    Fondo: float = 0.0
    password: str
    # Codigo de quien lo invito. Es solo de entrada: al crear la cuenta se
    # traduce a `referido_por` y no se guarda tal cual.
    codigo_referido: Optional[str] = None

    class Config:
        json_schema_extra = {
            "example": {
                "Nombre": "Juan",
                "Apellidos": "Perez Garcia",
                "email": "juan@ejemplo.com",
                "numero_de_telefono": "+1234567890",
                "Enable": True,
                "Fondo": 0.00,
                "password": "miPassword123"
            }
        }