"""Eliminacion de la cuenta del chofer desde la app.

La app de Chofer ofrece "Eliminar cuenta" en Configuracion. La peticion llega
con el token del propio chofer: nadie puede borrar una cuenta ajena.

Al borrar:
    * Se rechaza si el chofer tiene un viaje activo (accepted / driver_arrived
      / in_progress): no se puede dejar a un pasajero sin chofer.
    * Se borran sus vehiculos de Mi Garaje y sus fotos (Cloudinary y disco).
    * Se borran sus documentos del registro (las 10 fotos).
    * El documento del chofer se ANONIMIZA, no se elimina del todo: quedan los
      datos que la facturacion y los historiales de viajes necesitan
      (preferencias, raiting, Fondo), y los datos personales se sustituyen.
    * Queda `eliminado: True` y `Enable: False`: el login ya no lo encuentra
      (telefono/correo anonimizados) y los tokens viejos no sirven.

La cuenta de pasajero tiene su equivalente en `routers/users.py`.
"""
import bcrypt
import logging
import os
import uuid
from datetime import datetime
from typing import Optional

from bson import ObjectId
from fastapi import APIRouter, Header, HTTPException

from db.Chofer.auth import verify_token as verify_chofer_token
from db.Chofer.connection import chofer_db
from routers.Solicitud_de_viajes_v4 import get_connection
from routers.documentos import _borrar_archivos
from routers.garaje import FOTO_DIR
from services.fotos_nube import borrar as borrar_nube

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Cuenta del chofer"])

chofer_coleccion = chofer_db.users
vehiculos_coleccion = chofer_db["vehiculos"]


def _chofer_actual(authorization: Optional[str]) -> dict:
    """Chofer identificado por su token; el driver_id sale de ahi."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Token requerido")
    payload = verify_chofer_token(authorization.split(" ", 1)[1].strip())
    if not payload:
        raise HTTPException(status_code=401, detail="Token invalido o expirado")
    driver_id = payload.get("id")
    if not driver_id or not ObjectId.is_valid(driver_id):
        raise HTTPException(status_code=401, detail="Token sin chofer valido")
    chofer = chofer_coleccion.find_one({"_id": ObjectId(driver_id)})
    if not chofer:
        raise HTTPException(status_code=403, detail="Chofer no encontrado")
    if chofer.get("eliminado"):
        raise HTTPException(status_code=403, detail="La cuenta ya fue eliminada")
    return {"id": driver_id, "doc": chofer}


def _viaje_activo_de(driver_id: str) -> Optional[str]:
    """trip_id del viaje en curso del chofer, o None."""
    try:
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT trip_id FROM trips WHERE driver_id = %s AND status IN "
                "('accepted','driver_on_the_way','driver_arrived','in_progress') "
                "LIMIT 1",
                (str(driver_id),),
            )
            fila = cur.fetchone()
            cur.close()
        return fila[0] if fila else None
    except Exception:
        # Si no se puede comprobar, NO se bloquea el borrado por un fallo de
        # lectura: el borrado igualmente anonimiza la cuenta, no la borra.
        logger.exception("No se pudo leer el viaje activo de %s", driver_id)
        return None


def _borrar_fotos_de_vehiculos(driver_id: str) -> None:
    """Borra cada vehiculo del garaje con sus fotos (nube y disco)."""
    docs = list(vehiculos_coleccion.find({"driver_id": driver_id}))
    for doc in docs:
        fotos = (doc.get("fotos") or {}).values() \
            if isinstance(doc.get("fotos"), dict) else []
        n_fotos = 0
        for ref in fotos:
            if not isinstance(ref, dict):
                continue
            borrar_nube(ref.get("nube_public_id"))
            nombre = ref.get("archivo")
            if nombre:
                # Respaldo de disco (desarrollo): silencioso, la nube manda.
                try:
                    os.remove(os.path.join(FOTO_DIR, nombre))
                except OSError:
                    pass
                n_fotos += 1
        vehiculos_coleccion.delete_one({"_id": doc["_id"]})
        logger.info("Vehiculo %s borrado con %d fotos (cuenta %s)",
                    doc.get("_id"), n_fotos, driver_id)


@router.delete("/driver/account")
async def eliminar_cuenta(authorization: Optional[str] = Header(None)):
    """El chofer elimina SU cuenta (token requerido).

    No acepta driver_id en el body: lo da el token. Borrar una cuenta es
    irreversible desde la app; el anonimizado del documento conserva los
    registros que la facturacion necesita.
    """
    chofer = _chofer_actual(authorization)
    driver_id = chofer["id"]
    documento = chofer["doc"]

    viaje = _viaje_activo_de(driver_id)
    if viaje:
        raise HTTPException(
            status_code=409,
            detail="Tienes un viaje en curso. Termina o cancela el viaje antes "
                   "de eliminar tu cuenta.")

    # 1. Documentos del registro (rostro, carnet, licencia...).
    try:
        _borrar_archivos(documento.get("documentos") or [])
    except Exception:
        logger.exception("No se pudieron borrar los documentos de %s", driver_id)

    # 2. Vehiculos de Mi Garaje con sus fotos.
    try:
        _borrar_fotos_de_vehiculos(driver_id)
    except Exception:
        logger.exception("No se pudieron borrar los vehiculos de %s", driver_id)

    # 3. Anonimizar el documento. La contrasena se reemplaza por un hash de un
    #    secreto aleatorio: asi el login jamas la acepta y el check de bcrypt no
    #    rompe con un hash vacio.
    secreto = uuid.uuid4().hex + uuid.uuid4().hex
    chofer_coleccion.update_one(
        {"_id": ObjectId(driver_id)},
        {
            "$set": {
                "email": "deleted_%s@deleted.local" % driver_id,
                # Placeholder UNICO en vez de None: la coleccion tiene un
                # indice unico con `numero_de_telefono`; un segundo borrado
                # chocaria con E11000 si apenas existe otro null.
                "numero_de_telefono": "eliminado_%s@borrado" % driver_id,
                "password": bcrypt.hashpw(
                    secreto.encode("utf-8"), bcrypt.gensalt()).decode("utf-8"),
                "Nombre": "Chofer eliminado",
                "Apellidos": "",
                "Enable": False,
                "status": "deleted",
                "estado_habilitacion": "eliminado",
                "eliminado": True,
                "fecha_eliminacion": datetime.utcnow().isoformat(),
                "updated_at": datetime.utcnow().isoformat(),
            },
            "$unset": {
                "documentos": "",
                "documentos_subidos_at": "",
                "vehicle": "",
                "license_number": "",
                "codigo_referido": "",
                "referido_recompensado": "",
                "type_vehicle": "",
                "max_passengers": "",
            },
        },
    )
    logger.info("Cuenta del chofer %s eliminada desde la app", driver_id)
    return {"ok": True, "message": "Cuenta eliminada"}
