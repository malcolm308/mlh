"""
Codigos de referido: generacion y creacion perezosa.

Vive aqui y no dentro de un router porque el mismo codigo se crea en cuatro
sitios que no deberian importarse entre si: el alta de pasajeros, el alta de
choferes, el perfil autenticado y el endpoint de referidos. Con una copia en
cada uno, cualquier cambio de formato dejaria codigos incompatibles entre si.

Formato: 8 caracteres en mayusculas. El alfabeto es el de
`secrets.token_urlsafe`, asi que puede incluir `-` o `_`; las dos apps suben a
mayusculas lo que escribe el invitado, y `-`/`_` no cambian con `.upper()`.
No se cambia el formato sin migrar los codigos ya repartidos: los invitados
tienen el codigo impreso en conversaciones de WhatsApp.
"""
import logging
import secrets
from typing import Any, Dict

logger = logging.getLogger(__name__)

CODIGO_LARGO = 8

# `token_urlsafe(6)` produce 8 caracteres; se recorta por si alguna version de
# la libreria cambia el largo.
_BYTES = 6


def generar_codigo(coleccion) -> str:
    """Devuelve un codigo unico para `coleccion`, sin guardarlo.

    La unicidad se comprueba contra el indice `codigo_referido` de la propia
    coleccion. Se proyecta solo `_id` porque el valor no se usa: basta con saber
    si existe.
    """
    while True:
        codigo = secrets.token_urlsafe(_BYTES)[:CODIGO_LARGO].upper()
        if not coleccion.find_one({"codigo_referido": codigo}, {"_id": 1}):
            return codigo


def asegurar_codigo(coleccion, doc: Dict[str, Any]) -> str:
    """Devuelve el codigo del documento y lo crea si todavia no tiene.

    Los usuarios antiguos se registraron antes de que existiera el sistema de
    referidos y no tienen `codigo_referido`. Se genera en la primera consulta
    de su perfil y se guarda, para que el codigo que compartan no cambie entre
    sesiones ni dependa de que abran una pantalla concreta.
    """
    codigo = (doc.get("codigo_referido") or "").strip()
    if codigo:
        return codigo

    codigo = generar_codigo(coleccion)
    coleccion.update_one(
        {"_id": doc["_id"]},
        {"$set": {"codigo_referido": codigo}},
    )
    doc["codigo_referido"] = codigo
    logger.info("Codigo de referido creado para %s", doc["_id"])
    return codigo
