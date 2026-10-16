# Bot de Telegram de RapiTaxi

Bot para que los chóferes cierren y cancelen viajes, y para que el administrador
revise solicitudes desde Telegram.

La vinculación entre el chat y el chófer se hace **únicamente por número de
celular**, con el botón nativo de Telegram que comparte el número ya verificado.
El chófer no escribe nada a mano y **el bot no registra chóferes nuevos**: el alta
se sigue haciendo por la app o por el panel de administración.

## Cómo se vincula un chófer

1. El chófer abre el bot y manda `/start`.
2. El bot responde con el botón **Compartir mi número de celular**
   (`request_contact`). Telegram garantiza que el número viene verificado y que
   pertenece a quien pulsó el botón.
3. El bot normaliza el número, busca el chófer y guarda el `chat_id`.

| Situación | Qué contesta el bot |
|---|---|
| El chófer existe y no está vinculado | ✅ ¡Bienvenido, {nombre}! + comandos |
| Ya está vinculado a ese mismo chat | ✅ Ya estás vinculado |
| Está vinculado a **otro** chat | ❌ Este número ya está vinculado a otra cuenta, y avisa al administrador |
| El número no está en la base | ❌ No encontramos tu número. Contacta al soporte, y avisa al administrador |
| Compartió el número de otra persona | ❌ Debes compartir TU PROPIO número |
| El número está en más de un chófer | ❌ Tu número aparece en más de una cuenta. Contacta al soporte, y avisa al administrador |
| La cuenta está rechazada | ❌ Tu cuenta está rechazada |

El `chat_id` se guarda **una sola vez** en el documento del chófer y lo identifica
en cada interacción posterior.

## Campos del chófer

El teléfono se llama `numero_de_telefono` (base `Chofer`, colección `users`). No
existe un campo `phone`.

El bot añade tres campos, todos opcionales:

| Campo | Tipo | Para qué |
|---|---|---|
| `telegram_chat_id` | `int` | Identifica al chófer en cada mensaje. Único e indexado |
| `telegram_username` | `str` | Para poder men `@nombre` en avisos |
| `telegram_registered_at` | `datetime` | Cuándo se hizo el vínculo |

## El teléfono no está normalizado en la base

Conviven `+5359295207`, `59295207` y valores de relleno como `00000000`. El bot lo
solapa sin editar nada que ya exista:

1. Busca literal sobre las formas habituales (`59295207`, `+5359295207`, ...).
2. Si no aparece, busca por expresión regular los últimos 8 dígitos.
3. Si tampoco, recorre la colección (acotado a `TELEGRAM_MAX_BARRIDO`, 5000 por
   defecto) normalizando en Python.

El paso 3 hace falta porque **ninguna expresión regular puede encontrar
`59295207` dentro de `+53 5 9295207`**: los dígitos están partidos por los
separadores y ningún patrón los vuelve a juntar. La comparación final siempre es
sobre el número normalizado, así que un coincidente de más se descarta.

Cuando encuentra al chófer, **reescribe `numero_de_telefono`** con la forma
normalizada. Cada vinculación deja el campo más limpio, así que el paso 1 acierta
cada vez más.

Los números de relleno (`00000000`, `11111111`, `12345678`, `99999999`) se
rechazan: son datos de prueba, no una persona.

## Comandos del chófer

| Comando | Qué hace |
|---|---|
| `/start` | Menú, o el botón de compartir número si no está vinculado |
| `/estado` | Viaje activo, habilitación, documentos y cancelaciones que le quedan |
| `/completar` | Cierra el viaje. El bot pide la ubicación de destino por el icono de Clip |
| `/cancelar` | Cancela el viaje. Pide el motivo y pide confirmación |
| `/precio` | Tarifas de referencia del vehículo |
| `/fondo` | Saldo disponible |
| `/mi_id` | Su `chat_id` y su identificador de chófer |
| `/documentos` | Poner las fotos que le falten |
| `/soporte` | Contacto |
| `/ayuda` | Lista de comandos |

El **precio no lo calcula el bot**. Lo calcula `PUT /trips/{id}/complete`, que
aplica la tarifa horaria y la comisión; el bot pide la ubicación, confirma y
muestra el desglose que devuelve el servidor. `/precio` muestra las tarifas de
referencia, no una cotización.

El **límite de 3 cancelaciones al día** tampoco lo lleva la cuenta el bot:
`POST /trips/{id}/cancel` ya lo descuenta cuando el chófer cancela un viaje suyo.

## Comandos del administrador

Solo funcionan desde los chats de `TELEGRAM_ADMIN_CHAT_ID`.

| Comando | Qué hace |
|---|---|
| `/pendientes` | Chóferes por revisar, con botones de aprobar y rechazar |
| `/aprobar <id>` | Habilita un chófer |
| `/rechazar <id> [motivo]` | Rechaza un chófer |
| `/desvincular <número>` | Quita el vínculo de Telegram, para que pueda revincularse |
| `/autoactivar [off]` | Aprueba la cola. Tope de 20 acciones por pasada |
| `/autocancelar [minutos] [off]` | Cancela ofertas sin tomar de más de N minutos. Tope de 20 |
| `/autoestado` | Cómo va la última pasada automática |
| `/audit` | Últimos eventos |

`/autoactivar` y `/autocancelar` son **una pasada, no un ciclo continuo**: ejecutan,
informs y se apagan. El tope de 20 sale de `TELEGRAM_AUTO_MAX`.

## Variables de entorno

Ninguna va en el código; todas se leen del entorno.

| Variable | Para qué |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Token de @BotFather. También es el `{token}` de la ruta del webhook |
| `TELEGRAM_WEBHOOK_SECRET` | Secreto de la cabecera `X-Telegram-Bot-Api-Secret-Token` |
| `TELEGRAM_ADMIN_CHAT_ID` | Chats de administrador, separados por comas |
| `TELEGRAM_ADMIN_EMAIL` | Correo del administrador, para iniciar sesión y usar el panel |
| `TELEGRAM_ADMIN_PASSWORD` | Contraseña de ese administrador |
| `TELEGRAM_API_BASE_URL` | Base del propio backend. Por defecto `http://127.0.0.1:$PORT` |
| `TELEGRAM_SOPORTE` | Texto de contacto que ve el chófer |
| `TELEGRAM_AUTO_MAX` | Tope de acciones por pasada automática. 20 por defecto |
| `TELEGRAM_MAX_BARRIDO` | Tope del barrido de chóferes. 5000 por defecto |

Sin `TELEGRAM_ADMIN_EMAIL` y `TELEGRAM_ADMIN_PASSWORD` no hay modo
administrador: `/pendientes`, `/aprobar`, `/rechazar`, `/desvincular` y `/audit`
avisan que no está configurado, y `/estado` y `/documentos` funcionan sin revisar
los documentos.

## Seguridad

El webhook es `POST /webhook/{token}` y exige **las dos** cosas:

- el `{token}` de la ruta, que debe coincidir con `TELEGRAM_BOT_TOKEN`;
- la cabecera `X-Telegram-Bot-Api-Secret-Token`, que debe coincidir con
  `TELEGRAM_WEBHOOK_SECRET`.

Sin las dos, cualquiera que conozca la URL podría mandar mensajes en nombre del
bot. La comparación es con `secrets.compare_digest`, y el endpoint devuelve 404 si
el token de la ruta no cuadra, para no confirmar que el webhook existe.

La respuesta es 200 inmediatamente y el trabajo va en segundo plano: si el bot se
demora, Telegram reintenta el envío y el chófer recibe el mensaje duplicado.

Cada acción queda registrada en el log del servidor y en una lista de Redis que
`/audit` consulta.

`GET /telegram/status` informa de si el bot está configurado, cuántos
administradores hay y cuál es el tope por pasada. **No devuelve ningún secreto.**

## Índice único

`telegram_chat_id` lleva un índice único y disperso (`sparse`), así que los
chóferes que no usan el bot no entran en él. Se crea al arrancar, dentro de un
`try`: si falla, por ejemplo porque ya hubiera dos chóferes con el mismo chat, se
avisa por log y el bot sigue funcionando. El índice es una red de seguridad, no un
requisito para usarlo.

La vinculación usa un `update_one` con filtro `telegram_chat_id: None`, que es la
comparación atómica de Mongo. Si dos personas comparten el número y pulsan el
botón a la vez, una gana y la otra recibe el aviso de que ya se vincule con otra
cuenta.

## Registrar el webhook

```powershell
$env:TELEGRAM_BOT_TOKEN = "..."
$env:TELEGRAM_WEBHOOK_SECRET = "..."
.\scripts\registrar_webhook_telegram.ps1
```

El script valida el token con `getMe`, registra el webhook con `secret_token`,
comprueba el resultado con `getWebhookInfo` y termina contra
`/telegram/status`. Para borrarlo: `.\scripts\registrar_webhook_telegram.ps1 -Remove`.

## Pruebas

```powershell
python -m unittest tests.test_telegram_webhook -v
```

29 pruebas. No necesitan Mongo, Redis ni internet: la colección de chóferes y el
cliente de Telegram se sustituyen por dobles, y Redis por uno que siempre falla,
para que el bot use su respaldo en memoria.

Cubren la normalización del teléfono, los cinco casos de vinculación, el número
repetido, el de relleno, el chófer rechazado, el formato de teléfono con
separadores raros, `/desvincular`, la creación del índice y que un índice que
falla no tumba el arranque, y toda la seguridad del webhook.