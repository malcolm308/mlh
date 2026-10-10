"""Configuracion del panel de administracion.

Centraliza la URL del backend y los parametros de red. Antes cada modulo
definia su propia constante y el panel apuntaba a `127.0.0.1:18000`, asi que
cambiar de destino obligaba a tocar varios archivos a la vez.

La URL se puede fijar con la variable de entorno `API_URL` sin editar nada:

    set API_URL=https://otro-backend.onrender.com
    python main.py

Sobre el timeout: el backend de produccion esta en Render con plan gratuito,
que apaga la instancia tras 15 min sin trafico. La primera peticion que llega
despues tiene que despertarla, y eso puede tardar 30-60 s. Con el timeout
generico de 30 s de antes, esa primera llamada moria y el panel creía que el
servidor no existia. Por eso el margen es de 90 s: no es pereza, es para que
llegue a tiempo la primera peticion del dia.
"""

import os

# Backend API en Render. Sin barra final: se normaliza en ApiClient.
API_URL = os.getenv("API_URL", "https://rapitaxi-api-fws6.onrender.com").rstrip("/")

# Margen por peticion. Cubre el despertar de una instancia gratuita de Render
# (30-60 s) con holgura, sin dejar el panel colgando sin limite.
API_TIMEOUT = int(os.getenv("API_TIMEOUT", "90"))

# Tiempo que se considera "el servidor esta despertando". Antes de agotar el
# timeout se avisa, para que el administrador entienda la espera en vez de
# pensar que el panel se cuelgo.
API_TIMEOUT_AVISO = int(os.getenv("API_TIMEOUT_AVISO", "20"))

# Cada cuanto se comprueba que el token sigue vivo, en segundos.
# El token del backend dura 30 min; 5 min de margen esta de sobra.
PING_CADA_SEGUNDOS = int(os.getenv("PING_CADA_SEGUNDOS", "300"))