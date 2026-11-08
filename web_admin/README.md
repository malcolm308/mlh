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
| Vehículos | Revisión de fotos y aprobación/rechazo del garaje. | `GET /admin/vehicles`, `PUT /admin/vehicles/{id}/approve`, `GET /garaje/imagen/{archivo}` |
| Promociones y tarifas | Comisión, bono, descuento, referidos, caducidad, coeficientes por distancia y espera de cortesía. | `GET/PUT /admin/configuracion` |
| Chóferes | Habilitar o rechazar cuentas y ver documentos faltantes. | `GET /admin/choferes`, `POST /admin/choferes/{id}/estado` |
| Billetera | Saldo, recargas, descuentos y movimientos. | `GET /billetera/choferes`, `GET /billetera/saldo/{id}`, `POST /billetera/recarga`, `POST /billetera/descargo`, `GET /billetera/movimientos` |
| Viajes | Totales del día, evolución y detalle. | `GET /admin/trips/resumen`, `GET /admin/trips/diarios`, `GET /admin/trips/dia` |

`GET/PUT /admin/configuracion`, `GET /admin/alerts/pending` y
`POST /admin/trips/{id}/force-assign` viven en `routers/admin_web.py` y
reutilizan la lógica ya existente del backend.

## Comportamiento

- **Auto-refresco:** cada 10 s (`st_autorefresh`). Solo la pestaña de viajes
  críticos consulta sin caché; el resto usa caché por sesión con TTL para no
  saturar el backend gratuito de Render.
- **Sesión:** el login usa `POST /login` y comprueba con `ping()` que la cuenta
  sea de administrador. Cuando el access token caduca se renueva solo con
  `POST /auth/refresh`; si el refresh falla, vuelve al login.
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
