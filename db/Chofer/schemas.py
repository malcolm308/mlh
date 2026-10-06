from pydantic import BaseModel

class LoginRequest(BaseModel):
    email: str
    password: str

class TokenResponse(BaseModel):
    access_token: str
    token_type: str

class ChoferResponse(BaseModel):
    Nombre: str
    Apellidos: str
    email: str
    numero_de_telefono: str
    Enable: bool
    Fondo: float