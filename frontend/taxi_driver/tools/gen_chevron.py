"""Genera el icono del chevron (flecha de ubicacion) para MapLibre.

MapLibre no puede orientar un punto de otra forma que girando la imagen, asi que
hace falta un recurso. Se genera aqui en vez de bringing a mano porque:

  * Un SVG no sirve: en Android lo seguro es PNG.
  * El color va incrustado. MapLibre no puede tintar este icono con `icon-color`,
    que solo funciona con imagenes de una sola silueta preparada para eso.

Salida: assets/icons/chevron.png, 96x96, apuntando a ARUBA (0 grados). MapLibre
rota desde esa referencia con `icon-rotation-alignment: map`.

El relleno y el contorno se calculan con distancia con signo al poligono, no
con un margen de un pixel: asi el borde queda centrado en la arista y sale
limpio al girar.
"""
import math
import os
import struct
import zlib

W = H = 96
PUNTA = (48.0, 6.0)        # arriba del todo
BASE_IZQ = (12.0, 68.0)
BASE_DER = (84.0, 68.0)
HUECO_IZQ = (34.0, 50.0)   # la muesca que hace que sea una flecha
HUECO_DER = (62.0, 50.0)

# Antihorario visto en pantalla (y crece hacia abajo): punta, muesca derecha,
# base derecha, muesca izquierda, base izquierda.
POLIGONO = [PUNTA, HUECO_DER, BASE_DER, HUECO_IZQ, BASE_IZQ]

GROSOR_BORDE = 6.0         # ancho de la linea blanca
COL_FILL = (30, 136, 229)  # #1E88E5, el mismo azul de la ruta
COL_BORDO = (255, 255, 255)
SUAVE = 0.7                # margen de antialiasing en pixeles


def dist_segmento(px, py, a, b):
    """Distancia de un punto a un segmento."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    largo2 = dx * dx + dy * dy
    if largo2 == 0.0:
        return math.hypot(px - a[0], py - a[1])
    t = ((px - a[0]) * dx + (py - a[1]) * dy) / largo2
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (a[0] + t * dx), py - (a[1] + t * dy))


def dist_borde(px, py):
    """Distancia al borde del poligono, por el lado mas cercano."""
    return min(
        dist_segmento(px, py, POLIGONO[i], POLIGONO[(i + 1) % len(POLIGONO)])
        for i in range(len(POLIGONO))
    )


def dentro(px, py):
    """Punto dentro del poligono por paridad impar."""
    res = False
    n = len(POLIGONO)
    for i in range(n):
        x1, y1 = POLIGONO[i]
        x2, y2 = POLIGONO[(i + 1) % n]
        if (y1 > py) != (y2 > py):
            xc = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
            if px < xc:
                res = not res
    return res


def escribir_png(ruta, pixeles):
    """PNG RGBA minimo, sin dependencias externas."""
    crudo = b''
    for fila in pixeles:
        crudo += b'\x00' + fila

    def trozo(tipo, datos):
        return (struct.pack('>I', len(datos)) + tipo + datos
                + struct.pack('>I', zlib.crc32(tipo + datos) & 0xffffffff))

    png = b'\x89PNG\r\n\x1a\n'
    png += trozo(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
    png += trozo(b'IDAT', zlib.compress(crudo, 9))
    png += trozo(b'IEND', b'')
    with open(ruta, 'wb') as f:
        f.write(png)


def main():
    pixeles = []
    for y in range(H):
        fila = bytearray()
        for x in range(W):
            # 4 muestras por pixel para el antialiasing.
            pintados = 0
            borde = 0
            for sy in (0.25, 0.75):
                for sx in (0.25, 0.75):
                    px, py = x + sx, y + sy
                    if dentro(px, py):
                        pintados += 1
                        if dist_borde(px, py) <= GROSOR_BORDE / 2:
                            borde += 1

            if pintados == 0:
                fila += bytes((0, 0, 0, 0))
                continue

            # El blanco gana en el borde: si hay mas muestras de borde que de
            # relleno, el pixel es del contorno.
            es_borde = borde * 2 > pintados
            r, g, b = COL_BORDO if es_borde else COL_FILL
            alpha = int(round(255 * pintados / 4.0))
            fila += bytes((r, g, b, alpha))
        pixeles.append(bytes(fila))

    destino = os.path.join('assets', 'icons', 'chevron.png')
    os.makedirs(os.path.dirname(destino), exist_ok=True)
    escribir_png(destino, pixeles)
    print("generado %s (%dx%d)" % (destino, W, H))


if __name__ == '__main__':
    main()