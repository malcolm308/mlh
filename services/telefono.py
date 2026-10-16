"""
Normalizacion de telefonos.

Vive aqui y no dentro de un router porque lo necesitan tres sitios que no se
pueden importar entre si: el login, el registro y el bot de Telegram. Si cada
uno tuviera su propia copia, cualquier correccion a uno dejaria a los otros dos
con el bug.

Por que normalizar: en la base el telefono se guarda tal cual lo escribio la
persona, porque `documentos.py` solo hace `.strip()`. Conviven `59295207`,
`+5359295207` y valores de relleno como `00000000`. Sin normalizar, la misma
persona se registra dos veces con el mismo numero y el indice unico no sirve de
nada, porque las dos cadenas son distintas.
"""
import re
from typing import Any, Dict, List, Optional

# Numeros de relleno que se han visto en la base. No son una persona: se
# rechazan antes de buscar o de crear nada.
TELEFONOS_DE_RELLENO = {"00000000", "11111111", "12345678", "99999999"}

# Cuba: 8 digitos. Con el pais delante son 10, y con el 0 inicial 11.
LARGO_NACIONAL = 8


def normalizar_telefono(raw: Any) -> str:
    """Deja solo los digitos y quita el prefijo de Cuba.

        "+53 5 9295207" -> "59295207"
        "5359295207"    -> "59295207"
        "59295207"      -> "59295207"
        "05359295207"   -> "59295207"

    El `53` solo se quita cuando el numero tiene 10 digitos, que es el largo real
    de un movil cubano con el pais delante. Asi un fijo de 8 digitos que empiece
    por 53 no se mutila.
    """
    digitos = "".join(ch for ch in str(raw or "") if ch.isdigit())
    if digitos.startswith("053") and len(digitos) == LARGO_NACIONAL + 3:
        digitos = digitos[1:]
    if digitos.startswith("53") and len(digitos) == LARGO_NACIONAL + 2:
        digitos = digitos[2:]
    return digitos


def es_telefono_valido(raw: Any) -> bool:
    """Si el numero es utilizable como identidad de una persona."""
    digitos = normalizar_telefono(raw)
    if len(digitos) < LARGO_NACIONAL:
        return False
    return digitos not in TELEFONOS_DE_RELLENO


def variantes(digitos: str) -> List[str]:
    """Como puede estar escrito ese mismo numero en la base."""
    if not digitos:
        return []
    return [digitos, "53" + digitos, "+53" + digitos, "0" + "53" + digitos,
            "53 " + digitos, "+53 " + digitos]


def buscar_por_telefono(coleccion, raw: Any, excluding_id=None) -> List[Dict[str, Any]]:
    """Todos los documentos cuyo telefono, ya normalizado, coincide.

    No se usa `find_one`: si el numero esta en dos cuentas hay que saberlo. Tres
    pasos, porque el campo esta sin normalizar:

      1. Literal sobre las formas habituales. Es el camino rapido y acierta cada
         vez mas, porque al registrar y al vincular el telefono queda normalizado.
      2. Expresion regular sobre los ultimos 8 digitos, para espacios y guiones.
      3. Barrido acotado de la coleccion, normalizando en Python.

    El paso 3 hace falta porque ninguna expresion regular puede encontrar
    `59295207` dentro de `+53 5 9295207`: los digitos estan partidos por los
    separadores y ningun patron los vuelve a juntar. La comparacion final siempre
    es sobre el valor normalizado, asi que un coincidente de mas se descarta.
    """
    digitos = normalizar_telefono(raw)
    if len(digitos) < LARGO_NACIONAL or digitos in TELEFONOS_DE_RELLENO:
        return []

    encontrados: Dict[str, Dict[str, Any]] = {}

    for documento in coleccion.find({"numero_de_telefono": {"$in": variantes(digitos)}},
                                    {"password": 0}):
        encontrados[str(documento["_id"])] = documento

    if not encontrados:
        patron = re.compile(r"(^|\D)(%s)(\D|$)" % re.escape(digitos[-LARGO_NACIONAL:]))
        for documento in coleccion.find({"numero_de_telefono": patron}, {"password": 0}):
            if normalizar_telefono(documento.get("numero_de_telefono")) == digitos:
                encontrados[str(documento["_id"])] = documento

    if not encontrados:
        for documento in coleccion.find({}, {"password": 0}).limit(5000):
            if normalizar_telefono(documento.get("numero_de_telefono")) == digitos:
                encontrados[str(documento["_id"])] = documento

    if excluding_id is not None:
        for documento in list(encontrados.values()):
            if str(documento["_id"]) == str(excluding_id):
                del encontrados[str(documento["_id"])]

    return list(encontrados.values())