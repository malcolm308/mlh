# Reporte de seguridad y checklist de publicación — RapiTaxi

**Fecha:** 21 de noviembre de 2026
**Apps:** RapiTaxi Chofer (`com.taxirapid.taxi_driver`) y RapiTaxi Pasajero
(`com.taxirapid.taxi_client`)
**Backend de producción:** https://rapitaxi-api-fws6.onrender.com

---

## 1. Resumen ejecutivo

Se auditaron las dos aplicaciones Flutter y su configuración Android antes de
generar los AAB para Google Play. Se corrigieron los puntos de configuración que
impedían una publicación limpia (tráfico sin cifrar, permisos innecesarios,
`targetSdk` antiguo, ausencia de R8 y de ofuscación Dart). No se encontraron
credenciales escritas a mano en el código Dart ni en los archivos Android: los
tokens de sesión están en `flutter_secure_storage` y las claves de servicios se
inyectan en tiempo de compilación.

Quedan **tres pendientes externos** que no se pueden cerrar desde el código de
la app: rotar la clave de MapTiler que se compartió por chat, publicar la
política de privacidad en una URL pública y ofrecer la eliminación de cuenta
desde la app o desde una URL web (requisito de Play Console).

## 2. Alcance y metodología

- Revisión estática de `lib/**/*.dart` y de los manifests de las dos apps.
- Búsqueda de patrones de secretos (`API keys`, JWT, cadenas de MongoDB,
  Supabase, QvaPay, Telegram, MapTiler).
- Revisión de almacenamiento de sesión (`TokenStore`, `SharedPreferences`).
- Revisión de la configuración Gradle (firma, `targetSdk`, R8, recursos).
- Revisión del empaquetado y de los permisos efectivos del AAB.
- Pruebas unitarias de regresión del zoom de navegación.
- No se realizó pentesting dinámico ni análisis de tráfico en dispositivo
  físico; el alcance es configuración y código.

## 3. Cambios aplicados

| Área | Chofer | Pasajero |
|---|---|---|
| Zoom de navegación con viaje | 20.0 en recogida, espera y traslado; techo y recentrar 20 | Sin cambios (no usa modo navegación) |
| `INTERNET` explícito | Añadido | Añadido |
| `usesCleartextTraffic` | `false` | `false` |
| `allowBackup` | `false` | `false` |
| Permiso `CAMERA` | Eliminado (se usa la cámara del sistema) | No existía |
| `targetSdk` | 36 (Android 16) | 36 (Android 16) |
| Firma release | `keystore.properties` / `key.properties` | Igual |
| R8 / ProGuard | `isMinifyEnabled=true` + reglas propias | Igual |
| Ofuscación Dart | `--obfuscate --split-debug-info` | Igual |
| Auto-update propio | Desactivado en el build de Play | Desactivado en el build de Play |
| Tokens JWT | `flutter_secure_storage`, espejo legacy eliminado | `flutter_secure_storage` |

### 3.1 Zoom de navegación (chofer)

- `ApiConfig.zoomRecogida`, `zoomEsperando` y `zoomTraslado` = **20.0**.
- `ApiConfig.zoomTechoNavegacion` = **20.0** (tope del zoom dinámico).
- `ApiConfig.zoomRecentrar` = **20.0**.
- Sin viaje se conserva `zoomIdle = 16` para ver las ofertas de la zona.
- Regresión cubierta por `test/navigation_zoom_test.dart` (3/3 OK).

### 3.2 Auto-actualización y política de Play

Ambas apps usaban `flutter_patcher` para descargar parches de código en tiempo
de ejecución. La política **Device and Network Abuse** de Google Play prohíbe
que una app distribuida por Play descargue código ejecutable para actualizarse o
que dirija al usuario a instalar APKs externos.

Solución: el build de Play se compila con
`--dart-define=PLAY_STORE_BUILD=true`. Con ese flag:

- No se inicializa el cargador de parches (`FlutterPatcher.init`).
- `UpdateService.revisar()` no consulta ni aplica parches ni muestra el aviso de
  APK.

El APK que se reparte desde Render mantiene el OTA de siempre porque el valor
por defecto del flag es `false`.

## 4. Hallazgos

| # | Hallazgo | Severidad | Estado |
|---|---|---|---|
| 1 | Clave de MapTiler compartida por chat | **Alta** | **Pendiente externo:** rotar y restringir por app |
| 2 | Auto-update con parches nativos incompatible con Play | **Alta** | Mitigado con `PLAY_STORE_BUILD=true` |
| 3 | Sin eliminación de cuenta desde la app | **Alta (requisito Play)** | **Pendiente:** endpoint + pantalla o URL web |
| 4 | Tráfico HTTP sin cifrar permitido | Media | Corregido: `usesCleartextTraffic=false` |
| 5 | Token JWT del WebSocket viaja en la URL y queda en logs | Media | **Pendiente:** mover a cabecera o ticket efímero |
| 6 | `targetSdk` por debajo de 36 | Media | Corregido: 36 |
| 7 | Sin R8 ni ofuscación Dart | Media | Corregido |
| 8 | Permiso `CAMERA` innecesario | Baja | Corregido |
| 9 | Copias de seguridad automáticas de Android activas | Baja | Corregido: `allowBackup=false` |
| 10 | Comentarios obsoletos sobre tokens en `SharedPreferences` | Informativa | Corregidos |
| 11 | Firma cae a debug si falta el keystore | Media | Aceptado para desarrollo; **el AAB de Play se verificó firmado con release** |

### 4.1 Detalle de los pendientes

**1. Rotar la clave de MapTiler.** La clave `ZsGcg7…` se compartió en el chat y
debe considerarse comprometida. Pasos:

1. En MapTiler Cloud → *Account → Keys*, crear una clave nueva por app.
2. Restringirla, si el plan lo permite, por paquete Android
   (`com.taxirapid.taxi_driver` y `com.taxirapid.taxi_client`) o por dominio.
3. Revocar la clave antigua.
4. Recompilar ambos AAB con la clave nueva.

La clave no está en el repositorio: se inyecta solo con
`--dart-define=MAPTILER_API_KEY=...`. Aun así, cualquier clave usada por una app
móvil es extraíble del binario; la restricción por paquete es la defensa real.

**3. Eliminación de cuenta.** Play Console exige que toda app con registro
permita eliminar la cuenta y los datos desde dentro de la app y, además,
ofrezca una URL web para solicitarlo. Hoy existen borrados administrativos,
pero no un endpoint público autenticado ni una pantalla de baja. Antes de enviar
a revisión hay que:

- Añadir `DELETE /clientes/{id}` y `DELETE /choferes/{id}` autenticados, con
  borrado o anonimización de viajes y documentos según los plazos legales.
- Añadir la opción «Eliminar mi cuenta» en el perfil de ambas apps.
- Publicar una URL de solicitud de baja y declararla en Play Console.

**5. Token del WebSocket en la URL.** El JWT del canal de ofertas viaja como
parámetro de consulta y aparece en los logs de uvicorn/Render. Recomendación:
autenticar el `WebSocket` con la cabecera `Authorization: Bearer` o con un
ticket de un solo uso de vida corta. Mientras no se cambie, limitar la retención
de logs y no registrar la query completa.

## 5. Verificación de secretos

Búsquedas realizadas en `frontend/taxi_driver` y `frontend/taxi_client`:

- `api.telegram.org/bot`, `qvapay`, `mongodb+srv`, `supabase.co`, `sk_live`,
  `sk_test`, `AIza...`, JWT `eyJhbGciOi...`: **sin coincidencias**.
- `MAPTILER_API_KEY` solo aparece como `String.fromEnvironment(...)`.
- `.env.local` contiene únicamente `MONGODB_URI`, `POSTGRES_URL` y `REDIS_URL`,
  y está en `.gitignore`.
- `keystore.properties` y los `.jks` están en `.gitignore` y no hay ninguno
  versionado (`git ls-files` no devuelve coincidencias).
- Los tokens de sesión se leen con `TokenStore.leerAccess()` desde
  `flutter_secure_storage`; el espejo legacy en `SharedPreferences`
  (`driver_token` / `client_token`) se migra y se elimina.

**Corrección adicional:** `scripts/compilar_apks.ps1` tenía la clave de
MapTiler como valor por defecto y el README la repetía. Ahora el script exige
`$env:MAPTILER_API_KEY` (o `-MaptilerKey` para una corrida puntual) y falla con
un mensaje claro si falta; la documentación usa `<TU_CLAVE>`. La clave sigue en
el historial de git y dentro de los APK ya publicados en `static/`, por lo que
rotarla es obligatorio.

**Ojo con la rotación:** los APK actuales (1.0.42 del chofer y 1.0.40 del
pasajero) llevan la clave antigua compilada. Si se revoca de inmediato, esos
teléfonos pierden el mapa de MapTiler. Plan recomendado: crear la clave nueva
restringida por paquete, publicar los AAB de Play y un APK/OTA nuevos con la
clave nueva, y revocar la antigua cuando la mayoría haya migrado. Mientras
tanto, la clave antigua debe seguir restringida a los dos paquetes.

## 6. Firma y empaquetado

- Firma release leída de `key.properties`, `app/key.properties` o
  `app/keystore.properties` (el primero que exista).
- Keystore de carga nuevo por app en `android/app/upload-keystore.jks`, con
  alias `rapitaxi-driver-upload` / `rapitaxi-client-upload`. Los `.jks` y los
  `keystore.properties` están ignorados por Git.
- `targetSdk = 36`, `minSdk` el de Flutter.
- R8 activo con reglas para Flutter, MapLibre, `flutter_secure_storage` (Tink) y
  los plugins usados.
- Shrinker de recursos **desactivado** en el chofer para no perder
  `res/raw/spacebell.mp3`; en el cliente también se deja desactivado por
  coherencia.
- Ofuscación Dart con `--obfuscate` y símbolos en
  `build/app/outputs/symbols`.

Comandos usados (la clave se pasa solo en la línea de comandos):

```powershell
# Chofer
flutter build appbundle --release --no-pub --obfuscate `
  --split-debug-info=build/app/outputs/symbols `
  --build-name 1.0.46 --build-number 6053 `
  --dart-define=MAPTILER_API_KEY=<CLAVE> `
  --dart-define=PLAY_STORE_BUILD=true

# Pasajero
flutter build appbundle --release --no-pub --obfuscate `
  --split-debug-info=build/app/outputs/symbols `
  --build-name 1.0.42 --build-number 6045 `
  --dart-define=MAPTILER_API_KEY=<CLAVE> `
  --dart-define=PLAY_STORE_BUILD=true
```

### 6.1 Por qué el AAB usa `6053` y `6045`

Los APK que se reparten desde Render se compilan con `--split-per-abi`, y
Flutter suma un desplazamiento al `versionCode` según la ABI: `armeabi-v7a`
queda en `5xxx` y `arm64-v8a` en `6xxx`. Los APK instalados hoy son:

- Chofer: `1.0.42`, `versionCode 6049` (arm64). Es la APK de prueba; sigue
  reportando ese número para que `/app/version` responda `tipo_actualizacion:
  "none"` en las pruebas.
- Pasajero: `1.0.40`, `versionCode 6043` (arm64).

El AAB de Play es universal y **no** lleva ese desplazamiento. Para que Google
lo acepte sin obligar a desinstalar, se compila con `6053` y `6045`, por encima
de los versionCode instalados y de cualquier AAB subido antes. El chofer pasó de
`6052` a `6053` porque este AAB incluye el avance estimado fuera de ruta y el
aviso de GPS débil; el pasajero no cambió.

### 6.2 Artefactos generados y verificados

| App | Archivo de entrega | `versionName` | `versionCode` | Peso | Firma release (SHA-256 del certificado) |
|---|---|---|---|---|---|
| Chofer | `dist_play/RapiTaxi_Chofer/RapiTaxi_Chofer_1.0.46_vc6053.aab` | 1.0.46 | **6053** | 57,1 MiB (59.919.834 B) | `FD:7D:AB:E3:AF:6C:9E:30:A3:66:51:3C:9D:BF:9D:CB:F5:45:50:EB:30:B8:E3:88:D8:74:53:1D:0E:36:3B:C4` |
| Pasajero | `dist_play/RapiTaxi_Pasajero_1.0.42_vc6045.aab` | 1.0.42 | **6045** | 57,2 MiB (60.009.425 B) | `E2:B9:CC:51:D6:A8:4F:AB:69:74:6A:47:8F:68:4E:B2:E2:FD:AD:41:78:36:39:5D:E8:19:8B:48:1D:D3:63:BF` |

Hashes de los archivos (para verificar la subida):

- Chofer: `56A88BF836DD9BAA0D57ED47151866B230EB3AD75B793518E2139E2E3C852C12`
- Pasajero: `A9D0988B42A57B8530A41879BBD943B622207ECED7AAD40E2707832897DF9640`

Nota sobre el nombre: la marca es **RapiTaxi**, pero el `applicationId` histórico
es `com.taxirapid.taxi_driver` y `com.taxirapid.taxi_client`. No se renombran:
cambiarlos crearía una app distinta en Play y dejaría de actualizar las
instalaciones existentes. En Play Console se pone ese id, no el nombre comercial.

Los dos AAB quedan muy por debajo del límite de 150 MB. Se comprobó que la
clave de MapTiler está embebida en `libapp.so` de ambos paquetes, que el
`targetSdk` es 36 y que `usesCleartextTraffic` y `allowBackup` son `false`.

Permisos efectivos tras la fusión de manifests:

- **Chofer:** Internet, ubicación precisa y aproximada, notificaciones,
  vibración, servicio en primer plano, servicio en primer plano de ubicación,
  `WAKE_LOCK` y los permisos de insignia de lanzadores (Samsung, Huawei, Sony,
  etc., de firma y opcionales). Se eliminó `RECEIVE_BOOT_COMPLETED` y el
  `BootReceiver` del plugin porque `autoStartOnBoot` es `false`.
- **Pasajero:** Internet, ubicación precisa y aproximada, estado de red/Wi-Fi
  (MapLibre) y el permiso interno de receivers dinámicos de AndroidX. Sin
  cámara, contactos, notificaciones ni arranque automático.

Verificación de firma y versión:

```powershell
keytool -printcert -jarfile build\app\outputs\bundle\release\app-release.aab
```

También se puede inspeccionar el manifest del AAB con `bundletool` o subirlo a
Play Console, que muestra el `versionCode` y la huella de firma.

### 6.3 Cambio funcional de esta versión del chofer

Cuando el GPS deja de entregar fixes, el marcador avanza con el último rumbo y
velocidad filtrados. Dentro de ruta el avance sigue la polilínea; fuera de ruta
se hace en línea recta, con tope de 30 m desde el último fix real y velocidad máxima
estimada de 54 km/h. Al llegar un fix nuevo se vuelve a la posición medida sin
histéresis. Si no hay fix en 1,5 s el botón de GPS pasa a naranja con el aviso
«GPS débil: posición estimada», y a los 3 s el punto deja de avanzar para no
inventar una posición falsa. La APK de prueba mantiene `1.0.42 / 6049` para no
alterar lo que reporta `/app/version`.

## 7. Data safety (formulario de Play Console)

Declarar para **ambas apps**:

| Categoría | Datos | Recogido | Compartido | Finalidad |
|---|---|---|---|---|
| Ubicación | Aproximada y precisa | Sí | Sí (con el otro usuario del viaje) | Funcionalidad de la app |
| Información personal | Nombre, correo, teléfono | Sí | Con el otro usuario del viaje | Funcionalidad, cuenta |
| Información personal | Número de licencia (chofer) | Sí | No | Verificación |
| Fotos | Documentos y foto de perfil (chofer) | Sí | No | Verificación, perfil |
| Información financiera | Saldo e historial de billetera | Sí | No | Funcionalidad |
| Actividad en la app | Viajes, cancelaciones, calificaciones | Sí | No | Funcionalidad, seguridad |
| Información y rendimiento | Registros de errores y diagnóstico | Sí | No | Diagnóstico |
| Información del dispositivo | Modelo, versión de SO y de app, IP | Sí | No | Seguridad, diagnóstico |

- **Cifrado en tránsito:** sí (HTTPS obligatorio).
- **Solicitud de eliminación:** sí, pero hay que habilitar el flujo (ver 4.1).
- **Datos de salud, contactos, SMS, micrófono:** no.
- **Publicidad:** no se usa SDK de anuncios.
- **Compras dentro de la app:** los viajes son un servicio del mundo real; no se
  venden bienes digitales, por lo que no aplica Play Billing. La billetera
  interna no procesa tarjetas.

## 8. Checklist para Play Console

### 8.1 Común a las dos apps

- [ ] Cuenta de desarrollador verificada y datos fiscales completos.
- [ ] Política de privacidad publicada en URL pública y añadida en
      *Contenido de la app → Política de privacidad*.
- [ ] Formulario **Data safety** completado según la tabla anterior.
- [ ] **Account deletion**: opción en la app + URL web declarada.
- [ ] Clasificación de contenido completada.
- [ ] Público objetivo: mayores de 18 años (no dirigida a niños).
- [ ] Anuncios: «No contiene anuncios».
- [ ] Capturas de pantalla, icono 512×512, gráfico destacado 1024×500 y textos
      de la ficha.
- [ ] País/región de distribución y precio.
- [ ] Confirmar que el AAB está firmado con la clave de release y que el
      `versionCode` es mayor que el de la versión anterior.
- [ ] Activar **Play App Signing** (recomendado): Google guarda la clave de
      firma de la app y tú conservas la clave de carga.

### 8.2 Chofer (`com.taxirapid.taxi_driver`)

- [ ] Declarar el uso de **ubicación en segundo plano** para el servicio en
      primer plano. Play puede pedir un vídeo demostrativo del flujo «En línea»
      y de la notificación persistente.
- [ ] Justificar `FOREGROUND_SERVICE_LOCATION` en la declaración de permisos
      sensibles.
- [ ] Comprobar que `ACCESS_BACKGROUND_LOCATION` **no** está declarado (no se
      usa).
- [ ] Verificar que la app sigue funcionando si el usuario deniega
      notificaciones (degradación controlada).

### 8.3 Pasajero (`com.taxirapid.taxi_client`)

- [ ] Confirmar que no se piden permisos de cámara, contactos ni
      notificaciones.
- [ ] Revisar la función de billetera y transferencias entre clientes con el
      equipo legal: si se interpreta como servicio financiero, Play puede pedir
      documentación adicional.
- [ ] Verificar el flujo de recuperación de contraseña por correo.

## 9. Cómo publicar la política de privacidad en una URL pública

La política debe estar en una URL HTTPS accesible sin iniciar sesión. Hay tres
opciones sencillas:

### Opción A — GitHub Pages (gratis, recomendada)

1. Convierte `docs/POLITICA_PRIVACIDAD_CHOFER.md` y
   `docs/POLITICA_PRIVACIDAD_CLIENTE.md` a HTML (por ejemplo con
   `pandoc archivo.md -o archivo.html` agregando una cabecera CSS).
2. Crea en el repositorio una carpeta `docs/privacidad/` con
   `chofer.html` y `cliente.html`.
3. En GitHub → *Settings → Pages*, selecciona la rama principal y la carpeta
   `/docs`.
4. Las URLs quedarán así:
   - `https://<usuario>.github.io/<repo>/privacidad/chofer.html`
   - `https://<usuario>.github.io/<repo>/privacidad/cliente.html`
5. Si el repositorio es privado, GitHub Pages requiere un plan que lo permita;
   en ese caso usa la opción B.

### Opción B — Render Static Site (mismo proveedor del backend)

1. En Render → *New → Static Site*.
2. Conecta el repositorio y usa como *Publish directory* `docs/privacidad`.
3. Render entrega una URL `https://<nombre>.onrender.com`.
4. Añade las rutas `chofer.html` y `cliente.html` en Play Console.

### Opción C — Servir el HTML desde el backend FastAPI

Si prefieres una sola URL, crea `static/privacidad/chofer.html` y
`static/privacidad/cliente.html`. El backend ya sirve `/static`, así que
quedarían en:

- `https://rapitaxi-api-fws6.onrender.com/static/privacidad/chofer.html`
- `https://rapitaxi-api-fws6.onrender.com/static/privacidad/cliente.html`

Ventaja: no hay que crear otro servicio. Desventaja: depende de que Render esté
despierto y del mismo despliegue del backend.

> En las tres opciones, verifica la URL en una ventana de incógnito y sin sesión
> antes de pegarla en Play Console.

## 10. Recomendaciones posteriores a la publicación

1. Rotar la clave de MapTiler y recompilar (prioridad alta).
2. Mover el JWT del WebSocket a una cabecera `Authorization`.
3. Implementar la eliminación de cuenta autenticada.
4. Configurar alertas de errores y revisar los logs sin datos sensibles.
5. Revisar periódicamente las dependencias con `flutter pub outdated` y
   `dart pub audit` cuando esté disponible.
6. Mantener las claves de firma en un gestor de secretos y con copia de
   seguridad offline; sin ella no se pueden publicar actualizaciones.
