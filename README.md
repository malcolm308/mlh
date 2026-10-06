# RapiTaxi — Backend

API FastAPI del backend de RapiTaxi (clientes, choferes, viajes, billetera y
trazado de rutas con Traccar), junto a las dos apps Flutter del servicio
(RapiTaxi para pasajeros y RapiTaxi Chofer para conductores) y el servidor de
mapas vectoriales.

## Estructura

Es un monorepo: el backend vive en la raiz y las apps en subcarpetas.

```
.
├── main_v2.py                     FastAPI, punto de entrada
├── routers/                       Endpoints (viajes, choferes, billetera, Traccar)
├── services/                      traccar_listener.py: WebSocket de posiciones
├── db/                            Conexiones Mongo/Garnet/PostgreSQL
├── tests/                         Tests del backend
├── frontend/
│   ├── taxi_client/               App del pasajero (MapLibre + Martin)
│   └── taxi_driver/               App del chofer (navegacion MapLibre)
├── tileserver/
│   ├── styles/taxi.json           Estilo de mapa compartido por ambas apps
│   └── fonts/                     Fuentes que necesita el estilo
└── tiles/
    ├── tilesets/cuba.mbtiles      Cuba completo, vectorial (75,9 MB)
    └── backup/cuba_habana_*.mbtiles  Recortes de prueba (vectoriales)
```

Las tres MBTiles son vectoriales (`format=pbf`, zoom 8–16). Los ficheros
`.mbtiles` y el ejecutable de Martin local (`tileserver/martin.exe`) están en
`.gitignore`: no se versionan.

## Arrancar el backend

```powershell
python -X utf8 -m uvicorn main_v2:app --host 127.0.0.1 --port 18000
```

Servicios externos que deben estar levantados: PostgreSQL (5432), MongoDB
(27017), Garnet/Redis (6379) y Traccar (8082).

## Tests

Backend (usa la Mongo y la Garnet reales de desarrollo):

```powershell
python -X utf8 -W ignore::ResourceWarning -m unittest tests.test_traccar_device -v
```

Apps Flutter (cada una en su carpeta `frontend/taxi_client` o `frontend/taxi_driver`):

```powershell
flutter test
```

Estado actual: backend 9 tests, chofer 113 pasan + 1 omitido, pasajero 1 pasa.

## Configuracion por entorno (apps Flutter)

Las dos apps leen su configuracion de `--dart-define`, nunca de codigo fijo:

| dart-define | Que es | Default local |
|---|---|---|
| `API_BASE_URL` | Base de la API FastAPI | `http://localhost:8000` |
| `MAP_STYLE_URL` | URL del estilo de mapa (Martin) | `http://localhost:8010/style/taxi` |

Para una build apuntando a produccion se pasan las URLs HTTPS de Render:

```powershell
flutter build apk --release `
  --dart-define=API_BASE_URL=https://backend.onrender.com `
  --dart-define=MAP_STYLE_URL=https://martin.onrender.com/style/taxi
```

En produccion los valores llegan por variables de entorno; no se escriben
credenciales ni URLs privadas en el repositorio.

## Mapas vectoriales (Martin + MapLibre)

Las dos apps usan el motor MapLibre con teselas vectoriales servidas por Martin.
El pasajero y el chofer comparten el mismo servidor de mapas y el mismo estilo
(`tileserver/styles/taxi.json`).

Para levantar Martin en local, desde la raiz del repo:

```powershell
.\tileserver\martin.exe `
  .\tiles\tilesets `
  --style .\tileserver\styles `
  --font .\tileserver\fonts `
  --listen-addresses 0.0.0.0:8010
```

El cliente y el chofer piden el estilo en `/style/taxi`. En la version de
produccion se serves el mismo estilo desde un contenedor en Render, alimentado
con una MBTiles publicada como asset de release de GitHub.

Puntos importantes de la migracion del pasajero (de raster a vectorial):
- El mapa se dibuja con fuentes GeoJSON y capas del estilo
  (`addGeoJsonSource` + `addLineLayer` / `addCircleLayer`), el mismo patron que
  usa la app del chofer. `maplibre_gl` no ofrece widgets `Marker`/`Polyline`.
- Los marcadores de color (mi ubicacion, recogida, destino, vehiculo) se pintan
  como circulos del estilo. Los POIs se tocan por proximidad y abren su detalle.
- La triangulacion de latitud/longitud sigue usando `latlong2` como tipo de
  dato en todo el codigo; la conversion a `LatLng` de MapLibre ocurre solo en
  el borde del mapa (`frontend/taxi_client/lib/widgets/client_map_view.dart`).

## Firma de release (Android)

Cada app tiene su keystore, generado en local y **fuera** del repositorio
(`.gitignore` ignora `*.jks` y `keystore.properties`).

| App | Keystore | Alias | `applicationId` |
|---|---|---|---|
| Pasajero | `frontend/taxi_client/android/app/rapitaxi-cliente.jks` | `rapitaxi-cliente` | `com.taxirapid.taxi_client` |
| Chofer | `frontend/taxi_driver/android/app/rapitaxi-chofer.jks` | `rapitaxi-chofer` | `com.taxirapid.taxi_driver` |

Las credenciales estan en `android/app/keystore.properties` de cada app. Para
firmar, ese fichero tiene que existir con `storeFile` como **nombre de archivo
puro** (sin ruta): los `.properties` de Java interpretan los backslashes de una
ruta Windows como secuencias de escape y el build falla al no encontrar el
`.jks`. Si falta el fichero, la build release cae a la firma de debug.

Para compilar release en otra maquina hay que copiar a mano el `.jks` y su
`keystore.properties`.

## Notas de build en este entorno (Windows)

En `android/gradle.properties` de cada app hay tres ajustes no obvios,
necesarios para que el build release termine en esta maquina:

- `kotlin.incremental=false` y `kotlin.compiler.execution.strategy=in-process`:
  sin ellos el compilador de Kotlin falla al volcar sus caches `.tab` en la
  unidad `E:` ("Could not close incremental caches"), el daemon se cae y Gradle
  reintenta en bucle sin llegar a producir el APK.
- `org.gradle.jvmargs=-Xmx4G` en vez de `-Xmx8G`: la maquina tiene ~16 GB y
  dejar 8 GB al heap deja al resto del sistema sin margen.
- `org.gradle.parallel=false`: menos procesos Kotlin vivos a la vez.

Compilar las apps es lento la primera vez (compila el codigo nativo de
`maplibre_gl` y aplica R8). En redes restringidas usar el mirror oficial de
Flutter para pub:

```powershell
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
```

## Integracion con Traccar

Traccar aporta la posicion GPS de los choferes y el historico de rutas. Hay
tres piezas:

| Pieza | Fichero | Puerto |
|---|---|---|
| Listener WebSocket (posiciones en vivo) | `services/traccar_listener.py` | `ws://localhost:8082` |
| Envio de posiciones (protocolo OsmAnd) | `routers/Solicitud_de_viajes_v4.py` -> `_forward_driver_position_to_traccar` | `http://localhost:5055` |
| Lectura de ruta de un viaje | `routers/Solicitud_de_viajes_v4.py` -> `_get_traccar_route` | `http://localhost:8082` |

### Token

Las tres rutas usan un token de usuario de Traccar que se lee de la variable de
entorno **`TRACCAR_TOKEN`** (no esta en el codigo, porque el repositorio se
publica en GitHub):

```powershell
$env:TRACCAR_TOKEN = "<token de Traccar>"
```

Los tokens de Traccar **caducan**: cuando pasa la fecha de expiracion el
listener recibe `HTTP 500` al hacer el handshake y `_get_traccar_route` recibe
`HTTP 401`. Se renueva en la interfaz web de Traccar y se vuelve a definir en la
variable de entorno.

Si `TRACCAR_TOKEN` no esta definida, el listener no arranca y `_get_traccar_route`
devuelve una ruta vacia dejando un aviso en el log, en vez de fallar o enviar
`Bearer None`.

La URL del servidor tambien es configurable: `TRACCAR_HTTP`, `TRACCAR_OSMAND` y
`TRACCAR_WS` (esta ultima es la del WebSocket, por defecto
`ws://localhost:8082/api/socket`).

### Campo `traccar_device_id`

Vive en los documentos de la coleccion Mongo **`Chofer.users`** (no en
`drivers`), y es **opcional**: los choferes sin GPS todavia no lo tienen.

- **Que es**: el ID numerico del dispositivo dentro del servidor de Traccar. No
  es el `uniqueId` de Traccar ni el `_id` de Mongo. El device `1` de este
  entorno es el que Traccar muestra como "Taxi Test" con `uniqueId` `taxi-001`.
- **Como se asigna**: cada chofer tiene su propio device. Se escribe una sola
  vez a mano, desde el shell de Mongo:

  ```
  db.getSiblingDB("Chofer").users.updateOne(
      { _id: ObjectId("<id del chofer>") },
      { $set: { traccar_device_id: 1 } }
  )
  ```

  Para que ademas el backend empuje posiciones del chofer hacia Traccar durante
  el viaje (protocolo OsmAnd, puerto 5055) hace falta tambien el `uniqueId`:

  ```
  db.getSiblingDB("Chofer").users.updateOne(
      { _id: ObjectId("<id del chofer>") },
      { $set: { traccar_device_id: 1, traccar_device_uid: "taxi-001" } }
  )
  ```

  El mismo device no debe asignarse a dos choferes: `find_one` devuelve el
  primero que encuentra.
- **Si no esta asignado**: el listener recibe las posiciones del device, no
  encuentra chofer y las descarta (log `Device X sin chofer asignado,
  ignorando evento`). El chofer sigue funcionando, pero no aparece en el
  matching por geolocalizacion ni tiene trazado de ruta.
- **Quien lo lee**: `services/traccar_listener.py` para el matching en vivo, y
  `_get_traccar_route` / `_forward_driver_position_to_traccar` en
  `routers/Solicitud_de_viajes_v4.py` para el trazado del viaje.

El campo esta declarado en `ChoferResponse`
(`routers/CRUD_MONGODB.py`) como `Optional[int]`, asi que aparece en la API sin
romper a los choferes que no lo tienen.