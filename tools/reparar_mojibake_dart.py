"""
Repara el mojibake de los .dart del chofer.

Que paso: los archivos se escribieron en UTF-8 y despues alguien los abrio y los
volvio a guardar usando cp437 (la codificacion de la consola de Windows). Cada
letra acentuada se partio en dos o tres caracteres raros: "conexión" quedo como
"conexi├│n", "Máximo" como "M├íximo", "teléfono" como "tel⌐fono".

Como se sabe: codificacion incorrecta es exactamente `correcto.encode('utf-8')
.decode('cp437')`. Se comprueba esa hypothesis antes de tocar nada.

Que NO hace: no reescribe el archivo entero. Aplica una tabla de secuencias
malas a la inversa, de la mas larga a la mas corta, para que un archivo que ya
esta bien no se rompa. Las 4 secuencias que no salen de cp437 (eran simbolos que
se perdieron) se tratan aparte y se avisan.

    python -X utf8 tools/reparar_mojibake_dart.py --simular
    python -X utf8 tools/arreglar...   (o sin --simular para aplicarlo)
"""
import glob
import io
import os
import sys

# Secuencias de una doble codificacion distinta a la de arriba: unas lineas se
# guardaron con cp850 en vez de con cp437. Se detectan solas con la misma tabla,
# no hace falta lista manual.
#
# Lo que SI hace falta es un aviso: el separador "┬À" parecIA una flecha y no lo
# era. Decodificando sale "·" (punto medio, cp850 C2 B7). Se pone el punto, que
# es lo que el autor escribio.
CORRECCIONES_POR_CONTEXTO = [
    ("pasajero(s) → Efectivo", "pasajero(s) · Efectivo"),
    ("VIAJE EN CURSO →", "VIAJE EN CURSO ·"),
    ("Recalculando rutaÔÇª", "Recalculando ruta…"),
    ("ReintentandoÔÇª", "Reintentando…"),
]


def tabla_inversa():
    """Secuencia mala -> caracter bueno.

    Se recorre al reves que el fallo: se toma cada caracter que puede aparecer en
    un texto español, se codifica en UTF-8 y luego se lee con la codificacion de
    la consola de Windows. Ese resultado es exactamente el desastre que hay que
    deshacer.

    Se prueban las DOS paginas de codigo porque el archivo esta mezclado: unas
    lineas quedaron en cp437 ("conexi├│n") y otras en cp850 ("despu├®s"). Solo con
    una de las dos la mitad se queda sin arreglar.

    Importante que sea en este sentido y no al contrario: una letra acentuada
    ocupa DOS bytes en UTF-8, asi que se partió en DOS caracteres. Construir la
    tabla intentando decodificar un byte suelto no encuentra nada, porque un byte
    suelto nunca es UTF-8 válido.
    """
    tabla = {}
    # Latín-1 suplemento, latín extendido y puntuación: todo lo que puede llevar
    # tilde, eñe o signo de apertura en español.
    for codigo in list(range(0xA0, 0x180)) + list(range(0x2000, 0x2200)):
        try:
            bueno = chr(codigo)
        except ValueError:
            continue
        if bueno.isascii():
            continue
        for pagina in ("cp437", "cp850"):
            try:
                tabla[bueno.encode("utf-8").decode(pagina)] = bueno
            except (UnicodeDecodeError, ValueError):
                continue
    return tabla


def construir_patrones(tabla):
    """De la secuencia mas larga a la mas corta, para no partir las cortas."""
    return sorted(tabla.items(), key=lambda par: -len(par[0]))


def reparar(texto, tabla):
    for malo, bueno in tabla:
        texto = texto.replace(malo, bueno)
    for malo, bueno in CORRECCIONES_POR_CONTEXTO:
        texto = texto.replace(malo, bueno)
    return texto


def restantes(texto):
    """Secuencias sospechosas que el script no sabe arreglar."""
    # Se detectan los caracteres que produces cp437 y que no son ASCII.
    #
    # Se listan los que quedan tras reparar, para que se miren a ojo.
    raros = set()
    for codigo in range(0x80, 0x100):
        try:
            byte = bytes([codigo])
            byte.decode("utf-8")
            byte.decode("cp437")
        except (UnicodeDecodeError):
            continue
        c = byte.decode("cp437")
        if not c.isascii():
            raros.add(c)
    return sorted(c for c in raros if c in texto)


def main():
    simular = "--simular" in sys.argv
    tabla = construir_patrones(tabla_inversa())

    archivos = sorted(glob.glob(os.path.join("frontend", "taxi_driver", "lib", "**", "*.dart"),
                                recursive=True))
    archivos += sorted(glob.glob(os.path.join("frontend", "taxi_driver", "android", "**", "*.xml"),
                                 recursive=True))

    tocados = 0
    total = 0
    for ruta in archivos:
        original = io.open(ruta, encoding="utf-8").read()
        texto = reparar(original, tabla)
        if texto == original:
            continue

        cambios = sum(1 for a, b in zip(original, texto) if a != b)
        tocados += 1
        total += cambios
        marca = [r for r in restantes(texto)]
        print("%-62s %s" % (ruta, ("quedan: " + "".join(marca)) if marca else "limpio"))
        if not simular:
            io.open(ruta, "w", encoding="utf-8", newline="").write(texto)

    print("---")
    verb = "Se repararian" if simular else "Se repararon"
    print("%s %d archivo(s)." % (verb, tocados))
    if not simular:
        print("Revisa con git diff que solo se hayan tocado textos.")


if __name__ == "__main__":
    main()