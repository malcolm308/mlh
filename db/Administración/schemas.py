from pydantic import BaseModel

class LoginRequest(BaseModel):
    email: str
    password: str

class TokenResponse(BaseModel):
    access_token: str
    token_type: str

class ChoferResponse(BaseModel):
     Nombre: str
     Apellido: str
     email: str