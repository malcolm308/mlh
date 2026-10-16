"""
Indices de Mongo que sostienen las reglas de identidad de la plataforma.

Esto vive aparte y no dentro de un router porque son garantías de la base, no
endpoints: se aseguran al arrancar y si fallan avisan, pero nunca tumban la app.

Que se asegura aquí: `numero_de_telefono` único e indexado, en choferes y en
pasajeros. Es lo que impide dar de alta dos cuentas con el mismo número.

El índice de `telegram_chat_id` lo asegura el propio bot, en
`routers/telegram_webhook.py`, porque es el único que lo usa.

Sobre el índice único del teléfono, y por qué no basta solo: el índice compara
las CADENAS que hay en la base, no los números. Si un chofer quedó guardado como
"+5359295207" y otro como "59295207", para Mongo son dos valores distintos y el
índice los deja pasar. Por eso todo el código que compara teléfonos pasa antes por
`normalizar_telefono` (`services/telefono.py`) y por eso los registros nuevos se
guardan ya normalizados. El índice atrapa la carrera entre dos peticiones
simultáneas; la comparación normalizada atrapa el resto de casos.
"""
import logging
from typing import Dict, List

from db.Chofer.connection import chofer_db
from db.Cliente.connection import cliente_db

from services.telefono import normalizar_telefono

logger = logging.getLogger(__name__)

INDICE_TELEFONO = "numero_de_telefono_unico"

# Colecciones donde el teléfono tiene que ser único.
COLECCIONES_TELEFONO = {
    "choferes": chofer_db.users,
    "clientes": cliente_db.users,
}


def _duplicados_de_telefono(coleccion) -> List[Dict]:
    """Números, ya normalizados, que están en más de un documento."""
    conteo: Dict[str, int] = {}
    for documento in coleccion.find({}, {"numero_de_telefono": 1}):
        digitos = normalizar_telefono(documento.get("numero_de_telefono"))
        if digitos:
            conteo[digitos] = conteo.get(digitos, 0) + 1
    return [{"telefono": digitos, "veces": veces}
            for digitos, veces in sorted(conteo.items()) if veces > 1]


def asegurar_indice_telefono() -> None:
    """Índice único del teléfono en choferes y pasajeros.

    Antes de crearlo mira si ya hay números repetidos: si los hay, crearlo
    fallaría y, peor, dejaría a medias. En ese caso no se crea y se dice
    exactamente qué números hay que resolver, en vez de tragarse el error.
    """
    for nombre, coleccion in COLECCIONES_TELEFONO.items():
        try:
            repetidos = _duplicados_de_telefono(coleccion)
            if repetidos:
                logger.error(
                    "No se creo el indice %s en %s: ya hay %s numero(s) repetido(s): %s. "
                    "Hay que resolverlos a mano antes de poder aplicar la unicidad.",
                    INDICE_TELEFONO, nombre, len(repetidos),
                    ", ".join("%s (%s veces)" % (d["telefono"], d["veces"])
                              for d in repetidos[:10]))
                continue

            coleccion.create_index("numero_de_telefono", unique=True, name=INDICE_TELEFONO)
            logger.info("Indice %s asegurado en %s", INDICE_TELEFONO, nombre)
        except Exception:
            logger.warning("No se pudo asegurar el indice %s en %s; se sigue sin el",
                           INDICE_TELEFONO, nombre, exc_info=True)


def asegurar_indices_de_identidad() -> None:
    """Se llama al arrancar la API. Cada colección va por su cuenta: que una falle
    no impide que la otra quede con su índice."""
    asegurar_indice_telefono()