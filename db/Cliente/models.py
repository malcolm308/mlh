from pydantic import BaseModel,EmailStr

class CLIENTE(BaseModel):
    Nombre: str
    Apellidos: str
    email: EmailStr
    numero_de_telefono: str
    Enable: bool = True
    Fondo: float = 0.0
    password: str

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