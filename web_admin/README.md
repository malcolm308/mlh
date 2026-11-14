# Panel de administración web (Streamlit)

Reemplazo web del panel Tkinter de `desktop_admin/`. Es **solo un cliente HTTP**
de la API FastAPI: no importa `pymongo` ni `psycopg2` y nunca toca Mongo o
Postgres directamente.

## Comando local exacto

Desde la carpeta `web_admin/`:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
streamlit run app.py
```

La URL del backend se puede cambiar sin tocar código:

```powershell
$env:API_BASE_URL = "https://rapitaxi-api-fws6.onrender.com"
streamlit run app.py
```

Si no se define, usa `https://rapitaxi-api-fws6.onrender.com`.

## Despliegue en Render

1. Crear un **Web Service** apuntando al repositorio.
2. **Root Directory:** `web_admin`
3. **Build Command:** `pip install -r requirements.txt`
4. **Start Command:**

   ```bash
   streamlit run app.py --server.port $PORT --server.address 0.0.0.0
   ```

5. **Environment Variable:** `API_BASE_URL=https://rapitaxi-api-fws6.onrender.com`

No hace falta configurar Mongo ni Postgres en este servicio.

## Qué incluye

| Pestaña | Qué hace | Endpoints |
| --- | --- | --- |
| Viajes críticos | Viajes en cola sin chófer, alerta roja, pitido y asignación por teléfono. Control manual de inicio/fin. | `GET /admin/alerts/pending`, `POST /admin/trips/{id}/force-assign`, `GET /admin/trips/active`, `POST /admin/trips/{id}/force-start`, `POST /admin/trips/{id}/force-complete` |
| Cron de huérfanos | Publica en Telegram los viajes que pasan el 50 % del tiempo de espera. | `POST /admin/trips/check-orphaned` |
| Vehículos | Revisión de fotos y aprobación/rechazo del garaje. | `GET /admin/vehicles`, `PUT /admin/vehicles/{id}/approve`, `GET /garaje/imagen/{archivo}` |
| Promociones y tarifas | Comisión, bono, descuento, referidos, caducidad, coeficientes por distancia y espera de cortesía. | `GET/PUT /admin/configuracion` |
| Chóferes | Habilitar o rechazar cuentas y ver documentos faltantes. | `GET /admin/choferes`, `POST /admin/choferes/{id}/estado` |
| Billetera | Chóferes y clientes: saldo, recargas/abonos, descuentos y movimientos. | `GET /billetera/choferes`, `GET /billetera/saldo/{id}`, `POST /billetera/recarga`, `POST /billetera/descargo`, `GET /billetera/movimientos`, `GET /billetera/clientes`, `GET /billetera/clientes/{id}`, `POST /billetera/clientes/recarga`, `POST /billetera/clientes/descargo`, `GET /billetera/clientes/{id}/movimientos` |
| Viajes | Totales del día, evolución y detalle. | `GET /admin/trips/resumen`, `GET /admin/trips/diarios`, `GET /admin/trips/dia` |
| Clientes | Tabla completa de pasajeros de la app (buscar por teléfono, correo o nombre; fondo, viajes y estado), exportación a CSV y borrado físico de una cuenta. | `GET /users/admin/buscar`, `POST /users/admin/eliminar/{id}` |

`GET/PUT /admin/configuracion`, `GET /admin/alerts/pending`,
`POST /admin/trips/{id}/force-assign` y `POST /admin/trips/check-orphaned`
viven en `routers/admin_web.py` y reutilizan la lógica ya existente del
backend.

### Billetera de clientes

La pestaña **Billetera** tiene un selector *Chóferes / Clientes*. En la parte
de clientes se busca al pasajero por nombre, teléfono o correo y se abona
(recarga) o descuenta sobre su campo `Fondo` en Mongo (`Cliente.users`). Ese es
el mismo saldo con el que la app del pasajero paga los viajes por Billetera y
hace transferencias entre pasajeros, así que un abono desde el panel se ve al
instante en la app. Los movimientos se guardan en `wallet_movements` con
`user_type = 'client'`, separados de los de chóferes.

## Viajes huérfanos y Telegram

El cron llama cada minuto a:

```bash
curl -X POST "https://rapitaxi-api-fws6.onrender.com/admin/trips/check-orphaned" \
  -H "X-API-Key: $ORPHANED_API_KEY"
```

Variables de entorno del **backend** (servicio del API, no del panel):

| Variable | Ejemplo | Para qué |
| --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | `123456:ABC...` | Ya lo usa el bot existente. |
| `TELEGRAM_GROUP_ID` | `-1001234567890` | Grupo donde se publican los huérfanos. Los grupos empiezan por `-`. |
| `ADMIN_WHATSAPP_NUMBER` | `5359295207` | Número del enlace `wa.me`. Si falta, usa ese por defecto. |
| `ORPHANED_API_KEY` | cadena larga aleatoria | API Key del cron. Si falta, se acepta `CRON_API_KEY`. |

El mensaje incluye ID, origen, destino, precio y el enlace
`https://wa.me/<ADMIN_WHATSAPP_NUMBER>?text=Hola,%20quiero%20el%20viaje%20<ID>`.
Cuando el chófer escribe por WhatsApp, el administrador pega su número en la
tarjeta del viaje y pulsa **Asignar**.

Para comprobar el grupo sin esperar a que exista un viaje huérfano:

```bash
curl -X POST "https://rapitaxi-api-fws6.onrender.com/admin/telegram/test-group?vehicle_type=moto" \
  -H "X-API-Key: $ORPHANED_API_KEY"
```

`vehicle_type` es opcional (`basico` por defecto; también `moto`, `triciclo`,
`confort`, `premium`). El mensaje es el mismo que publica el cron, con
`🚘 Tipo:`, así que sirve para comprobar tanto el grupo como la etiqueta del
vehículo. Devuelve el status code y el JSON exacto de `getChat` y
`sendMessage` (200 = enviado, 400 = `chat_id` incorrecto o bot fuera del
grupo, 403 = el bot no es administrador).

## Avisos con sonido (notificaciones)

El panel avisa de dos eventos críticos sin depender de Firebase ni de un
servicio de pago:

| Evento | Quién lo publica | Quién lo ve |
| --- | --- | --- |
| Viaje sin chófer | `POST /admin/trips/check-orphaned` (cron), justo después de Telegram | `trip_operator` y `super_admin` |
| Nuevo chófer registrado | `POST /documentos/registro`, después de guardar las fotos | `user_operator` y `super_admin` |

Cadena completa:

1. El backend guarda el evento en Mongo (`Chofer.eventos_admin`, TTL de 7 días;
   si Mongo falla, cae a una cola en memoria para no bloquear el cron ni el
   registro).
2. `notificaciones.py` inyecta un vigilante JavaScript en la **página
   principal** con `st.html(..., unsafe_allow_javascript=True)`. No usa
   `components.html` porque eso va en un iframe y el navegador bloquea ahí la
   Notification API y el audio.
3. El vigilante consulta `GET /admin/eventos` cada 15 s con el access token de
   la sesión y muestra una notificación del sistema más un timbre (Web Audio,
   WAV generado en el propio panel, sin CDN).
4. `POST /admin/eventos/prueba` (botón **🔔 Probar aviso** de la barra
   lateral) recorre el mismo camino para probarlo sin esperar a un viaje real.

**Primera vez:** al entrar, pulsa la campana **🔔 Activar avisos** de la
esquina superior derecha y permite las notificaciones. Ese gesto es
obligatorio: sin un clic previo el navegador mantiene el audio bloqueado. El
estado queda en `localStorage`. Si el permiso está denegado, el panel sigue
avisando con sonido y un cartel dentro de la página, que se retira solo a los
3 segundos.

`server.enableStaticServing = true` sirve `web_admin/static/sw.js` en
`/app/static/sw.js`; el service worker es necesario para que Android muestre
la notificación del sistema. El `GET /admin/eventos` sin `desde` solo devuelve
el puntero actual, así que abrir el panel o pulsar F5 no dispara avisos viejos.

**Límite conocido:** hace falta la pestaña abierta, aunque esté en segundo
plano (Chrome puede retrasar el polling a ~1/min cuando la pestaña está oculta).
Avisar con la pestaña cerrada exigiría Web Push con VAPID, que no se usa aquí.

## Comportamiento

- **Auto-refresco:** `@st.fragment(run_every=10)` en Viajes críticos. Solo esa
  pestaña se vuelve a ejecutar cada 10 s y consulta sin caché; el resto usa
  caché por sesión con TTL para no saturar el backend gratuito de Render.
- **Sesión:** el login usa `POST /login` y comprueba con `ping()` que la cuenta
  sea de administrador. Cuando el access token caduca se renueva solo con
  `POST /auth/refresh`; si el refresh falla, vuelve al login. El refresh token
  se guarda en una cookie (30 días), así que un F5 o reiniciar el navegador no
  obliga a escribir la contraseña mientras siga vigente.
- **Pitido:** se genera un WAV en Python y se reproduce con `st.audio`. Solo
  suena cuando aparece o cambia el conjunto de viajes sin chófer, no cada 10 s.
- **Privacidad:** la interfaz no muestra `_id` de Mongo. Los `driver_id` y
  `vehiculo_id` se usan por dentro para llamar a la API, nunca como etiqueta.
- **Fotos:** se convierten con Pillow/pillow-heif para que las HEIC de iPhone se
  vean en el navegador.

## Notas de operación

- El backend gratuito de Render se duerme a los 15 min sin tráfico. La primera
  petición puede tardar 30-60 s; el timeout de lectura es de 90 s.
- Si el backend todavía no tiene `routers/admin_web.py` desplegado, el panel
  sigue funcionando con promociones y tarifas: `api_client.py` cae a
  `/admin/promociones` y `/admin/promociones/tarifas-espera`. La asignación
  forzada y las alertas sí requieren el endpoint nuevo.
