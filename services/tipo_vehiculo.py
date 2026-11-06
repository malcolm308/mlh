"""
Tipo de vehiculo: normalizacion y resolucion.

Vive aqui y no dentro de un router porque lo necesitan tres sitios que no se
importan entre si de forma limpia: el filtro de ofertas, el modelo de respuesta
del chofer y (a mano) las dos apps. Con dos copias, corregir una deja a la otra
con el bug.

Por que hay que normalizar: el tipo aparece escrito de varias formas segun por
donde se creo la cuenta.

    'basico'   lo escribe el registro con la lista desplegable
    'básico'   lo escribe la base de datos, que si lo guarda CON tilde
    'Basico'   lo escribe una persona en el panel
    ' basico ' llega con espacios de un formulario

Sin normalizar, la comparacion falla y el fallo es silencioso: el chofer con
moto deja de ver ofertas de moto, o peor, un basico ve ofertas de moto.

La comparacion es de igualdad EXACTA sobre el valor normalizado. Nunca 'LIKE',
nunca `contains`: un tipo tiene que ser el suyo y punto.
"""
import re
import unicodedata
from typing import Any, Dict, List, Optional, Sequence, Tuple

# Tipos que el producto reconoce. Si la base define uno mas, se puede agregar:
# la normalizacion no depende de esta lista, solo sirve para avisar.
TIPOS_CONOCIDOS = ("basico", "moto", "triciclo", "confort", "premium")

# Quita tildes para comparar: "básico" y "basico" son el mismo vehiculo.
_ESPACIOS = re.compile(r"\s+")


def normalizar_tipo_vehiculo(valor: Any) -> Optional[str]:
    """'Básico ', ' basico' y 'BASICO' -> 'basico'. Sin valor -> None."""
    if valor is None:
        return None
    texto = unicodedata.normalize("NFKD", str(valor).strip())
    sin_acentos = "".join(c for c in texto if not unicodedata.combining(c))
    limpio = _ESPACIOS.sub(" ", sin_acentos).lower()
    return limpio or None


def tipos_iguales(a: Any, b: Any) -> bool:
    """Igualdad exacta tras normalizar. Dos nulos NO son iguales: si no sabemos
    el tipo de nadie, no se puede afirmar que coincidan."""
    na, nb = normalizar_tipo_vehiculo(a), normalizar_tipo_vehiculo(b)
    if na is None or nb is None:
        return False
    return na == nb


# Vehiculos SIN habitacion de pasajeros: la foto del interior no existe.
# Bastan las 2 exteriores y la circulacion, tanto en el registro como en
# Mi Garaje (los autos basico/confort siguen exigiendo las 2 interiores).
TIPOS_SIN_FOTOS_INTERIOR = ("moto", "triciclo")

# Campos de foto = interior del vehiculo.
CAMPOS_FOTO_INTERIOR = ("vehiculo_interior_frente", "vehiculo_interior_atras")


def campos_exigidos_por_tipo(
        tipo_vehiculo: Any,
        campos: List[Tuple[str, ...]]) -> List[Tuple[str, ...]]:
    """Sublista de documentos obligatorios segun el tipo de vehiculo.

    Cada item `(campo, etiqueta, exigido)`: moto y triciclo quedan sin las
    fotos del interior (las interiores cuentan solo si `exigido` ya era True).
    """
    tipo = normalizar_tipo_vehiculo(tipo_vehiculo)
    if tipo not in TIPOS_SIN_FOTOS_INTERIOR:
        return campos
    return [c for c in campos
            if not (c[0] in CAMPOS_FOTO_INTERIOR and c[-1])]


def resolver_tipo_vehiculo(documento: Optional[Dict[str, Any]]) -> Optional[str]:
    """Saca el tipo de vehiculo de un documento de chofer de Mongo.

    El campo esta repartido en varios sitios segun como se creo la cuenta, y
    ninguno es el canonico. Se prueban todos en orden y se devuelve el primero
    que exista:

        type_vehicle          lo escribe POST /documentos/registro
        vehicle_type          lo escribe POST /chofer (el CRUD legacy)
        vehicle.servicio      lo escribe tambien el registro
        vehicle.type          lo escriben algunos scripts de carga

    Ojo al orden: `vehicle_type` va despues de `type_vehicle` porque el registro
    escribe los dos y son el mismo dato. Si se invirtiera, un documento antiguo sin
    `type_vehicle` seguiria funcionando, pero uno nuevo con las dosKeys
    contradictorias ganaria el equivocado.
    """
    if not documento or not isinstance(documento, dict):
        return None
    vehiculo = documento.get("vehicle")
    if not isinstance(vehiculo, dict):
        vehiculo = {}
    for valor in (
        documento.get("type_vehicle"),
        documento.get("vehicle_type"),
        vehiculo.get("servicio"),
        vehiculo.get("type"),
    ):
        normalizado = normalizar_tipo_vehiculo(valor)
        if normalizado:
            return normalizado
    return None
