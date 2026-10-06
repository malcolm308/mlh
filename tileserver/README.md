# Vector tiles locales: del PBF al mapa en la app

Como queda el stack de mapas tras la migracion de `flutter_map` (tiles PNG) a
`maplibre_gl` (tiles vectoriales PBF).

Antes: `tiles_server.py` servia PNG raster generados con OSM, y `flutter_map`
los pintaba sin rotacion ni inclinacion real.
Ahora: planetiler genera un MBTiles vectorial desde el mismo OSM, Martin lo
sirve como PBF, y `maplibre_gl` lo pinta con `pitch` y `bearing` nativos.


## 1. Por que Martin y no tileserver-gl

El plan original pedia el binario portable de `tileserver-gl` para Windows.
**No existe.** Se distribuye solo por npm y por Docker:

    https://api.github.com/repos/maptiler/tileserver-gl/releases/latest
    -> tag v5.6.0, assets: 0

Las 10 ultimas releases tienen `assets=0`. Sin Node.js y sin Docker no hay
ninguna via de instalarlo.

La alternativa de reserva, `mbtileserver`, tampoco publica binario de Windows
desde 2021.

Se usa **Martin** (`maplibre/martin`), que es Rust, binario unico y si publica
Windows:

    martin-x86_64-pc-windows-msvc.zip   37.3 MB   v1.16.1

Ademas trae cache, gzip/brotli y `--style` para publicar estilos.


## 2. Por que planetiler y no el MBTiles de MapTiler

El MBTiles de MapTiler es una descarga comercial: la pagina
`maptiler.com/on-prem-datasets/...` exige cuenta de pago y aceptar licencia.
No es un enlace directo.

Ademas, para una ciudad, 150-300 MB es innecesario. Los datos se generan
localmente con planetiler desde el PBF de Geofabrik.

Geofabrik sirve Cuba en `central-america/`, no en `north-america/`:

    https://download.geofabrik.de/central-america/cuba-latest.osm.pbf   59.4 MB


## 3. Descargas

    tools/planetiler.jar                        89 MB    v0.10.2
    tools/martin.zip                            37.3 MB
    tileserver/martin.exe                                 v1.16.1
    tileserver/fonts/NotoSans-{Regular,Bold,Italic}.ttf
    data/sources/cuba.osm.pbf                   59.4 MB
    data/sources/lake_centerline.shp.zip        77.2 MB
    data/sources/natural_earth_vector.sqlite.zip 414.1 MB
    data/sources/water-polygons-split-3857.zip  887.9 MB

Las tres ultimas son de todo el planeta y las exige planetiler aunque solo se
genere La Habana. Ver "anadir agua despues" al final.

**Nota sobre la conexion.** La descarga concurrente de planetiler se quedaba
congelada: abria los tres ficheros a la vez, llegaba al tamaño completo y se
paraba sin avanzar un byte. Descargarlos de uno en uno con `curl -C -` (que
ademas reanuda) funciona:

    curl -L -C - --retry 999 --retry-delay 5 --retry-all-errors ^
         --speed-time 180 --speed-limit 1024 ^
         -o data\sources\water-polygons-split-3857.zip ^
         https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip


## 4. Generar el MBTiles

    java -Xmx6g -jar tools\planetiler.jar ^
      --download=data\sources ^
      --osm_path=data\sources\cuba.osm.pbf ^
      "--bounds=-82.60071,22.89768,-82.19971,23.30190" ^
      --schema=vector ^
      --output=tiles\tilesets\cuba.mbtiles ^
      --maxzoom=16 --minzoom=8 --force

**Los bounds van en `lon_min,lat_min,lon_max,lat_max`**, no en latitud primero.
Este detalle costo bastante: pasando `22.89768,-82.60071,23.30190,-82.19971`
(el orden habitual, como en las bbox de OSM) planetiler NO se queja, escribe
los metadatos correctamente y genera un MBTiles **con 0 tiles**, en 1 minuto,
sin ningun error en el log. Solo un `# features: 0` en el nivel DEBUG lo delata.

Con el orden correcto:

    # features: 1,404,856
    8073 tiles   (z8: 2, z9: 4, z10: 6, z11: 12, z12: 30, z13: 110,
                  z14: 399, z15: 1517, z16: 5993)
    24.6 MB

Tarda unos 90 segundos y necesita ~6 GB de RAM.

**`--maxzoom=16` es el maximo** de este perfil (`Max zoom must be <= 16`). Da
suficiente detalle para el zoom 18 que usa la app: por encima de 16 no hay mas
informacion en los tiles, solo se repite la de 16.

Los limites son los del area ya cubierta por el mapa actual, en `config.dart`:
mapSouth 22.89768, mapNorth 23.30190, mapWest -82.60071, mapEast -82.19971.


## 5. Arrancar el servidor

    powershell -ExecutionPolicy Bypass -File scripts_local_dev\start_tiles.ps1

O a mano:

    cd E:\Taxi_Rapid\tileserver
    .\martin.exe E:\Taxi_Rapid\tiles\tilesets ^
      --style E:\Taxi_Rapid\tileserver\styles ^
      --font  E:\Taxi_Rapid\tileserver\fonts ^
      --listen-addresses 0.0.0.0:8010

El **8010 no se cambia**: es el que usan la app y el `adb reverse`.

Comprobaciones:

    http://127.0.0.1:8010/catalog
    http://127.0.0.1:8010/style/taxi
    http://127.0.0.1:8010/cuba/14/4443/7110.pbf     -> HTTP 200, 212.8 KB

**Ojo con la URL del tile.** La que aparece en la documentacion de ejemplo
(`/data/cuba/14/4838/6213.pbf`) da 204: son coordenadas de otro sitio. Las de
La Habana en z14 son `14/4443/7110`.


## 6. El estilo

Vive en `tileserver\styles\taxi.json` y se publica en:

    http://127.0.0.1:8010/style/taxi

Detalles que_costaron_tiempo:

* **`--style` exporta, no lee.** No es una carpeta de donde cargar estilos
  existentes. Los estilos se publican en `/style/<nombre>`, y el nombre sale del
  nombre de fichero.
* **Un `.json` suelto en la carpeta de tilesets rompe el arranque.** Martin lo
  detecta como GeoJSON y falla con `missing field 'type' at line 191`. Por eso
  la carpeta de estilos va separada de la de tilesets.
* **Las fuentes van con espacio:** `"Noto Sans Regular"`, no
  `"NotoSans Regular"`. Martin genera la pila a partir del nombre del fichero
  TTF, y con guion el nombre no casa y los nombres de calle no salen.
* **No hay `sprite`**, porque no hay capas con iconos. Dejarlo apuntado hacia
  `/sprites/cuba` hace que maplibre pida un recurso que no existe.

Para editarlo visualmente: <https://maplibre.org/maputnik/>


## 7. Notas para la app

* La URL del estilo es `http://127.0.0.1:8010/style/taxi`. En el telefono
  `127.0.0.1` es el propio movil, asi que hace falta el reenvio adb, que ya
  pone el script: `adb reverse tcp:8010 tcp:8010`.
* Las capas disponibles estan en `GET /cuba` (TileJSON): `transportation`,
  `transportation_name`, `building`, `water`, `water_name`, `landcover`,
  `landuse`, `park`, `place`, `poi`, `boundary`, `waterway`, `housenumber`,
  `aeroway`, `aerodrome_label`, `mountain_peak`.
* Fuentes disponibles: `Noto Sans Regular`, `Noto Sans Bold`, `Noto Sans
  Italic`, con 3748 glifos cada una.


## 8. Anadir el agua despues (pendiente)

**Esta seccion esta pendiente, no ejecutada.**

El MBTiles actual **SI tiene agua**: se genero con los `water-polygons`
completos. Se Documenta el procedimiento por si hay que regenerarlo.

Si algun dia se regenera el MBTiles sin los ficheros auxiliares, el mar y los
rios desaparecen. En ese caso:

1. Descargar solo los que falten, con `curl -C -` y de uno en uno (ver seccion 3).
2. `natural_earth_vector.sqlite.zip` **no se puede evitar**: planetiler lo
   exige siempre para las fronteras en zoom bajo. Excluir `water` y
   `lake_centerlines` con `--exclude-layers` funciona; excluir
   `natural_earth` no, y el proceso aborta.
3. Sin agua, el estilo debe compensarlo: la capa `fondo` ya es azul mar
   (`#a5bfdd`), igual que la capa `agua`, de modo que el mar se ve continuo y
   no aparece el gris del fondo por defecto.

    "background-color": "#a5bfdd"

Un parche alternativo, si el mar quedara raro, es poner un `fill` sobre la
capa `landcover` para tapar la tierra por debajo del nivel del mar.
