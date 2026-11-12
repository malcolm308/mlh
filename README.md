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
| `MAP_STYLE_URL` | URL de estilo de mapa explicita (tiene prioridad) | vacio |
| `MAPTILER_API_KEY` | Clave de MapTiler; si falta se usa Martin | vacio |

Sin `MAP_STYLE_URL` ni `MAPTILER_API_KEY`, las apps usan el estilo propio
servido por Martin (`https://mlh-tdyg.onrender.com/style/taxi`). Asi el mapa
funciona aunque la build se haga sin clave y no se queda en "Cargando mapa...".

Para una build apuntando a produccion se pasan las URLs HTTPS de Render:

```powershell
flutter build apk --release `
  --dart-define=API_BASE_URL=https://backend.onrender.com `
  --dart-define=MAP_STYLE_URL=https://martin.onrender.com/style/taxi
```

En produccion los valores llegan por variables de entorno; no se escriben
credenciales ni URLs privadas en el repositorio.

## Sesion: access + refresh token

El login (`POST /login`) devuelve dos JWT:

| Token | Vida | Para que |
|---|---|---|
| `access_token` | 2 h | Va en `Authorization: Bearer` de cada peticion |
| `refresh_token` | 30 dias | Solo para `POST /auth/refresh` |

Cuando una peticion devuelve `401`, la app pide un access nuevo a
`/auth/refresh` y **repite la peticion original**; el usuario no ve nada. Varias
peticiones que fallan a la vez comparten un unico refresh (single-flight). Si el
refresh tambien caduca o el backend lo rechaza, se borran los tokens y se vuelve
al Login. Si el fallo es de red, la sesion **no** se borra: se reintenta luego.

Flutter guarda el access y el refresh en el almacenamiento seguro del sistema
(`flutter_secure_storage`), y mantiene una copia del access en
`SharedPreferences` (`client_token` / `driver_token`) para el resto de la app y
para el servicio de ofertas del chofer. Esa copia en claro es del access (2 h),
nunca del refresh.

Variables opcionales en Render:

| Variable | Default | Efecto |
|---|---|---|
| `JWT_SECRET_KEY` | valor historico | Cambiarla invalida todas las sesiones |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | `120` | Vida del access |
| `REFRESH_TOKEN_EXPIRE_DAYS` | `30` | Vida del refresh |

`/healthz`, `/readyz` y `/app/version` siguen **sin autenticacion**: la app
puede comprobar actualizaciones aunque la sesion haya caducado.

Los tokens emitidos antes de este cambio no tienen refresh ni el claim `type`;
siguen valiendo como access hasta que caduquen. Al desplegar, esos usuarios
tendran que iniciar sesion una vez para recibir el par nuevo.

> **Ojo con OTA:** `flutter_secure_storage` es un plugin nativo. La version que
> lo introduce (1.0.4) debe publicarse como **APK completo**, no como parche
> Dart.

## Recuperacion de contrasena por correo (SMTP)

Los endpoints `POST /auth/forgot-password` y `POST /auth/reset-password`
envian un codigo de 6 digitos al correo de la cuenta. El envio usa `smtplib`
(libreria estandar de Python) y estas variables de entorno, que deben
configurarse en Render (**Environment > Environment Variables**):

| Variable | Valor | Obligatoria |
|---|---|---|
| `SMTP_SERVER` | `smtp.gmail.com` | No (ese es el default) |
| `SMTP_PORT` | `587` (STARTTLS) o `465` (SSL) | No (default `587`) |
| `SMTP_USER` | `rapitaxicuba@gmail.com` | No (ese es el default) |
| `SMTP_PASSWORD` | Contrasena de aplicacion de Google (16 caracteres) | **Si** |

Para generar `SMTP_PASSWORD`: entra en la cuenta de Gmail, activa la
verificacion en dos pasos y crea una **Contrasena de aplicacion** en
<https://myaccount.google.com/apppasswords>. La contrasena normal de la
cuenta no funciona por SMTP.

El codigo vence a los 30 minutos, es de un solo uso y se guarda hasheado en
la coleccion `Cliente.password_resets` (indice TTL). Si `SMTP_PASSWORD` falta
o el envio falla, el endpoint responde `502` y borra el codigo generado.

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

## APK y actualizaciones OTA (`/static` + `/app/version`)

Las apps se reparten desde la carpeta `static/` del repositorio y se
actualizan solas contra el backend.

**Distribucion hibrida (64/32 bits).** Cada app se publica partida con
`--split-per-abi` para no obligar a descargar el APK universal (~60 MB):

- `static/app_cliente_64bits.apk` — cliente `arm64-v8a` (~34 MB). Es el enlace
  **principal** (`ApiConfig.appDownloadUrl`) que comparte la app.
- `static/app_cliente_32bits.apk` — cliente `armeabi-v7a` (~28 MB), para
  telefonos antiguos que rechazan el de 64 bits con "paquete no valido".
- `static/app_chofer_64bits.apk` — chofer `arm64-v8a` (~37 MB), enlace
  principal de la app del chofer.
- `static/app_chofer_32bits.apk` — chofer `armeabi-v7a` (~32 MB).
- `static/app_cliente_v2.apk`, `static/app_latest.apk` y
  `static/app_chofer_latest.apk` — copias de los APK de 64 bits, por
  compatibilidad con los enlaces viejos que ya circulan.
- `static/patch_latest.zip` / `static/patch_chofer_latest.zip` — parche ligero.
- `static/ota_client.json` / `static/ota_driver.json` — manifiestos que dicen
  cual es la ultima version, el historial de releases y los parches.
- Endpoints: `GET /healthz` (liveness), `GET /readyz` (Postgres responde) y
  `GET /app/version?version_actual=1.0.1&version_codigo=2002&app=client`.

Regla de decision (`routers/app_updates.py`):

- Al dia -> `tipo_actualizacion: "none"`.
- Exactamente un salto y hay parche para **ese** `versionCode` -> `"patch"`.
- Un salto sin parche, o dos o mas saltos -> `"apk"` (aviso bloqueante en la
  app). El APK se ignora mientras haya un viaje activo y se reevalua al
  terminar.

Un parche solo sirve para el APK base con el que se compilo
(`--target-version-code`), asi que las instalaciones anteriores al sistema OTA
siempre reciben el APK completo.

### Compilar

```powershell
cd E:\Taxi_Rapid\frontend\taxi_client   # o taxi_driver
flutter build apk --split-per-abi
# -> build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Ojo: `--split-per-abi` desplaza el `versionCode` por ABI: `armeabi-v7a`
suma 1000 y `arm64-v8a` suma 2000, y encima va el build number. El `arm64-v8a`
de `1.0.2+3` reporta **2003**. Ese es el numero que va en `--version-code`; el
del APK base 1.0.1+2 es **2002** y va en `--target-version-code`.

### Publicar un APK nuevo

```powershell
cd E:\Taxi_Rapid
python scripts/publicar_ota.py --app client --version 1.0.2 --version-code 2003 `
  --apk frontend/taxi_client/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
git add static/ota_client.json static/app_latest.apk
git commit -m "chore: publicar APK 1.0.2"
git push origin main
```

Si el APK anterior se descargo corrupto, publica con un nombre nuevo para
saltarse la cache (`--apk-name app_cliente_v2.apk`) y sube ese archivo:

```powershell
python scripts/publicar_ota.py --app client --version 1.0.3 --version-code 2004 `
  --apk frontend/taxi_client/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk `
  --apk-name app_cliente_v2.apk
git add static/ota_client.json static/app_cliente_v2.apk
```

### Publicar los APK de 64 y 32 bits (distribucion hibrida)

Compila una sola vez con `--split-per-abi` y copia los dos APK a `static/`.
`--apk-name` solo controla el que registra el manifiesto OTA (el de 64 bits);
el de 32 bits se copia aparte:

```powershell
cd E:\Taxi_Rapid\frontend\taxi_client   # o taxi_driver
flutter build apk --release --split-per-abi --no-pub

cd E:\Taxi_Rapid
copy frontend\taxi_client\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk static\app_cliente_64bits.apk
copy frontend\taxi_client\build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk static\app_cliente_32bits.apk
python scripts/publicar_ota.py --app client --version 1.0.22 --version-code 4023 `
  --apk frontend/taxi_client/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk `
  --apk-name app_cliente_64bits.apk
```

Haz lo mismo con `taxi_driver` y `app_chofer_64bits.apk` /
`app_chofer_32bits.apk` (`--app driver`). Recuerda refrescar tambien las copias
legacy de 64 bits (`app_cliente_v2.apk`, `app_latest.apk`,
`app_chofer_latest.apk`) para que los enlaces viejos sigan sirviendo la version
nueva.

El mensaje de "Compartir App" lleva los dos enlaces (`appDownloadUrl` y
`appDownloadUrl32` / `driverDownloadUrl` y `driverDownloadUrl32`, en
`lib/api_config.dart`).

### Publicar un parche ligero (mismo APK, sin reinstalar)

El parche se genera **con el mismo Flutter** y desde el APK ya compilado de la
version nueva:

```powershell
cd E:\Taxi_Rapid\frontend\taxi_client
dart run flutter_patcher:pack `
  --apk build/app/outputs/flutter-apk/app-arm64-v8a-release.apk `
  --version 1.0.2-p1 --target-version-code 2002 --abi arm64-v8a --out dist
# imprime el md5 del zip

cd E:\Taxi_Rapid
python scripts/publicar_ota.py --app client --version 1.0.2 --version-code 2003 `
  --apk frontend/taxi_client/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk `
  --patch frontend/taxi_client/dist/patch.zip `
  --patch-version 1.0.2-p1 --target-version-code 2002
```

El parche se aplica en el **siguiente arranque en frio**, nunca en caliente, y
se revierte solo si la app no arranca.

### Probar OTA contra un servidor local

```powershell
python scripts/servidor_ota_local.py --port 8010
adb reverse tcp:8010 tcp:8010
flutter build apk --split-per-abi `
  --dart-define=OTA_BASE_URL=http://127.0.0.1:8010
```

`OTA_BASE_URL` solo cambia el endpoint OTA; login y viajes siguen yendo a
Render. Para probar por HTTP local el build de prueba necesita
`android:usesCleartextTraffic="true"` en el manifiesto (no debe ir en la release
final). En produccion el define se omite.

