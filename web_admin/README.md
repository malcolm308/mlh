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
