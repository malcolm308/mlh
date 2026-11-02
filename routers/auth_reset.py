"""Recuperacion de contrasena por correo electronico.

Flujo:
    1. La app pide `POST /auth/forgot-password` con el correo de la cuenta.
    2. El backend genera un codigo de 6 digitos, lo guarda hasheado en Mongo
       (con vencimiento de 30 minutos) y lo envia por SMTP a ese correo.
    3. La app pide `POST /auth/reset-password` con correo + codigo + contrasena
       nueva. El codigo es de un solo uso.

Variables de entorno (se configuran en Render, nunca en el codigo):
    SMTP_SERVER    servidor SMTP. Por defecto: smtp.gmail.com
    SMTP_PORT      puerto SMTP. Por defecto: 587 (STARTTLS). 465 usa SSL.
    SMTP_USER      cuenta remitente. Por defecto: rapitaxicuba@gmail.com
    SMTP_PASSWORD  contrasena de aplicacion de Google (16 caracteres).

El correo de Gmail NO acepta la contrasena normal de la cuenta: hay que crear
una "Contrasena de aplicacion" en https://myaccount.google.com/apppasswords
y copiarla tal cual en SMTP_PASSWORD.
"""
import asyncio
import hashlib
import logging
import os
import secrets
import smtplib
import ssl
from datetime import datetime, timedelta
from email.message import EmailMessage

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from db.Cliente.connection import cliente_db
from db.Chofer.connection import chofer_db

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["Recuperacion de contrasena"])

cliente_coleccion = cliente_db["users"]
chofer_coleccion = chofer_db["users"]
# La misma base de pasajeros guarda los tokens. Son documentos pequenos y el
# indice TTL los borra solos al vencer.
resets_coleccion = cliente_db["password_resets"]

SMTP_SERVER = os.getenv("SMTP_SERVER", "smtp.gmail.com")
try:
    SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
except ValueError:
    SMTP_PORT = 587
SMTP_USER = os.getenv("SMTP_USER", "rapitaxicuba@gmail.com")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")

MINUTOS_VIGENCIA = 30
MAX_INTENTOS = 6
CORREO_SOPORTE = "rapitaxicuba@gmail.com"


class ForgotPasswordIn(BaseModel):
    email: str


class ResetPasswordIn(BaseModel):
    email: str
    codigo: str
    nueva_password: str


def init_password_resets() -> None:
    """Crea los indices de la coleccion de tokens (idempotente)."""
    try:
        resets_coleccion.create_index("email")
        resets_coleccion.create_index("expires_at", expireAfterSeconds=0)
    except Exception:
        logger.warning("No se pudieron crear los indices de password_resets",
                       exc_info=True)


def _normalizar_email(valor: str) -> str:
    return (valor or "").strip().lower()


def _hash_codigo(email: str, codigo: str) -> str:
    return hashlib.sha256(f"{email}:{codigo}".encode("utf-8")).hexdigest()


def _buscar_cuenta(email: str):
    """Devuelve (coleccion, documento, rol) o (None, None, None).

    Un mismo correo podria existir como pasajero y como chofer. Se prioriza el
    pasajero porque es el flujo mas comun; el token queda ligado a ese rol.
    """
    doc = cliente_coleccion.find_one({"email": email})
    if doc:
        return cliente_coleccion, doc, "cliente"
    doc = chofer_coleccion.find_one({"email": email})
    if doc:
        return chofer_coleccion, doc, "chofer"
    return None, None, None


def _cuerpo_correo(codigo: str) -> tuple[str, str]:
    texto = (
        "Hola,\n\n"
        "Recibimos una solicitud para restablecer la contrasena de tu cuenta "
        "RapiTaxi.\n\n"
        f"Tu codigo de verificacion es: {codigo}\n\n"
        f"Este codigo vence en {MINUTOS_VIGENCIA} minutos y solo se puede usar "
        "una vez.\n\n"
        "Si no solicitaste este cambio, ignora este mensaje: tu contrasena "
        "actual sigue funcionando.\n\n"
        "--- Equipo RapiTaxi"
    )
    html = f"""
    <div style="font-family:Arial,sans-serif;max-width:520px;margin:auto">
      <h2 style="color:#007AFF">RapiTaxi</h2>
      <p>Recibimos una solicitud para restablecer la contrasena de tu cuenta.</p>
      <p style="font-size:15px">Tu codigo de verificacion es:</p>
      <p style="font-size:34px;font-weight:bold;letter-spacing:6px;
                color:#111;background:#F2F6FF;padding:14px 18px;
                border-radius:10px;text-align:center">{codigo}</p>
      <p>Este codigo vence en <b>{MINUTOS_VIGENCIA} minutos</b> y solo se puede
         usar una vez.</p>
      <p style="color:#666">Si no solicitaste este cambio, ignora este mensaje:
         tu contrasena actual sigue funcionando.</p>
      <p style="color:#666">Soporte: {CORREO_SOPORTE}</p>
    </div>
    """
    return texto, html


def _enviar_correo(destino: str, codigo: str) -> None:
    """Envia el codigo por SMTP. Lanza una excepcion si no se puede."""
    if not SMTP_PASSWORD:
        raise RuntimeError(
            "SMTP_PASSWORD no esta configurada en el servidor. "
            f"Configura las variables SMTP_* en Render (soporte: {CORREO_SOPORTE})."
        )

    texto, html = _cuerpo_correo(codigo)
    msg = EmailMessage()
    msg["Subject"] = "Recuperación de contraseña - RapiTaxi"
    msg["From"] = f"RapiTaxi <{SMTP_USER}>"
    msg["To"] = destino
    msg.set_content(texto)
    msg.add_alternative(html, subtype="html")

    contexto = ssl.create_default_context()
    if SMTP_PORT == 465:
        with smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT, timeout=25,
                              context=contexto) as servidor:
            servidor.login(SMTP_USER, SMTP_PASSWORD)
            servidor.send_message(msg)
    else:
        with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=25) as servidor:
            servidor.ehlo()
            servidor.starttls(context=contexto)
            servidor.ehlo()
            servidor.login(SMTP_USER, SMTP_PASSWORD)
            servidor.send_message(msg)


@router.post("/forgot-password")
async def forgot_password(datos: ForgotPasswordIn):
    email = _normalizar_email(datos.email)
    if not email or "@" not in email or "." not in email.split("@")[-1]:
        raise HTTPException(status_code=400,
                            detail="Escribe un correo electronico valido.")

    coleccion, cuenta, rol = _buscar_cuenta(email)
    if not cuenta:
        # Mensaje claro, como pidio el producto. No se envia nada.
        raise HTTPException(
            status_code=404,
            detail="No existe una cuenta con ese correo. Revisa el correo o "
                   f"contacta a soporte: {CORREO_SOPORTE}",
        )

    if not (cuenta.get("Enable", True) if rol == "chofer" else True):
        raise HTTPException(
            status_code=403,
            detail="Tu cuenta esta deshabilitada. Contacta al administrador.",
        )

    codigo = f"{secrets.randbelow(900000) + 100000:06d}"

    # Un solo codigo vigente por correo: al pedir otro se invalida el anterior.
    resets_coleccion.delete_many({"email": email})
    resets_coleccion.insert_one({
        "email": email,
        "rol": rol,
        "codigo_hash": _hash_codigo(email, codigo),
        "expires_at": datetime.utcnow() + timedelta(minutes=MINUTOS_VIGENCIA),
        "used": False,
        "intentos": 0,
        "created_at": datetime.utcnow(),
    })

    try:
        await asyncio.to_thread(_enviar_correo, email, codigo)
    except Exception as exc:
        # Si el correo no sale, el codigo no sirve: se borra.
        resets_coleccion.delete_many({"email": email})
        logger.exception("No se pudo enviar el correo de recuperacion a %s", email)
        raise HTTPException(
            status_code=502,
            detail="No se pudo enviar el correo de recuperacion. "
                   f"Intenta de nuevo mas tarde o contacta a soporte: {CORREO_SOPORTE}",
        ) from exc

    logger.info("Codigo de recuperacion enviado a %s (rol=%s)", email, rol)
    return {
        "ok": True,
        "rol": rol,
        "mensaje": "Te enviamos un codigo de 6 digitos a tu correo. "
                   f"Vence en {MINUTOS_VIGENCIA} minutos.",
    }


@router.post("/reset-password")
async def reset_password(datos: ResetPasswordIn):
    email = _normalizar_email(datos.email)
    codigo = (datos.codigo or "").strip()
    nueva = datos.nueva_password or ""

    if not email or "@" not in email:
        raise HTTPException(status_code=400,
                            detail="Escribe un correo electronico valido.")
    if not (codigo.isdigit() and len(codigo) == 6):
        raise HTTPException(status_code=400,
                            detail="El codigo debe tener 6 digitos.")
    if len(nueva) < 4:
        raise HTTPException(status_code=400,
                            detail="La contrasena debe tener al menos 4 caracteres.")

    registro = resets_coleccion.find_one(
        {"email": email, "used": False},
        sort=[("created_at", -1)],
    )
    if not registro:
        raise HTTPException(
            status_code=400,
            detail="El codigo no es valido o ya vencio. Solicita uno nuevo.",
        )

    if registro.get("expires_at") and registro["expires_at"] < datetime.utcnow():
        resets_coleccion.delete_many({"email": email})
        raise HTTPException(
            status_code=400,
            detail="El codigo vencio. Solicita uno nuevo.",
        )

    intentos = int(registro.get("intentos") or 0)
    if intentos >= MAX_INTENTOS:
        resets_coleccion.delete_many({"email": email})
        raise HTTPException(
            status_code=429,
            detail="Demasiados intentos. Solicita un codigo nuevo.",
        )

    if not secrets.compare_digest(
            registro.get("codigo_hash", ""), _hash_codigo(email, codigo)):
        resets_coleccion.update_one(
            {"_id": registro["_id"]}, {"$inc": {"intentos": 1}})
        raise HTTPException(status_code=400, detail="Codigo incorrecto.")

    coleccion, cuenta, rol = _buscar_cuenta(email)
    if not cuenta:
        resets_coleccion.delete_many({"email": email})
        raise HTTPException(
            status_code=404,
            detail="La cuenta ya no existe. Contacta a soporte: "
                   f"{CORREO_SOPORTE}",
        )

    import bcrypt

    hash_nuevo = bcrypt.hashpw(nueva.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
    coleccion.update_one(
        {"_id": cuenta["_id"]},
        {"$set": {"password": hash_nuevo, "updated_at": datetime.utcnow().isoformat()}},
    )
    resets_coleccion.update_one(
        {"_id": registro["_id"]},
        {"$set": {"used": True, "used_at": datetime.utcnow()}},
    )
    resets_coleccion.delete_many({"email": email})

    logger.info("Contrasena restablecida para %s (rol=%s)", email, rol)
    return {
        "ok": True,
        "rol": rol,
        "mensaje": "Contrasena actualizada. Ya puedes iniciar sesion.",
    }
