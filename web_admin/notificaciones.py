"""Avisos del panel: notificacion del navegador + sonido ante eventos criticos.

El backend no puede abrir una conexion hacia el navegador y Streamlit no
expone endpoints propios, asi que la cadena es:

1. El backend publica el evento en Mongo (`services/eventos_admin.py`).
2. Este modulo inyecta en la pagina principal del panel un vigilante
   JavaScript que consulta `GET /admin/eventos` cada 15 s.
3. Cuando aparece un evento nuevo, muestra una notificacion del sistema y
   reproduce un timbre.

Se usa `st.html(..., unsafe_allow_javascript=True)` porque NO va en un iframe:
la Notification API y el audio funcionan en el documento principal. Un
`components.html` si iria en un iframe y el navegador bloquearia ambas cosas.

El vigilante se instala una sola vez por documento (`window.__rapitaxiBell`);
los reruns de Streamlit solo actualizan la configuracion (sobre todo el access
token, que caduca a las 2 h). El permiso y el desbloqueo del audio los da el
administrador con la campana «🔔» de la cabecera (arriba a la derecha): sin un
gesto previo el navegador bloquea el sonido.

Limite conocido: hace falta la pestana abierta (aunque este en segundo plano).
Avisar con la pestana cerrada exige Web Push con service worker + VAPID, que
no se usa aqui.
"""

from __future__ import annotations

import base64
import json
from typing import Optional

import streamlit as st

from components import _wav_pitido
from config import get_api_base_url

CLAVE_ACTIVO = "rapitaxi_avisos_v1"

_CSS = """
/* La campana vive en la franja superior derecha de la cabecera, a la izquierda
   del boton Deploy y del menu de Streamlit. Antes estaba fija abajo a la
   derecha y tapaba la ultima fila de las tablas. */
#rapitaxi-campana {
  position: fixed; top: 14px; right: 120px; z-index: 2147483600;
  border: 0; border-radius: 999px; padding: 8px 14px; cursor: pointer;
  font: 600 13px/1 system-ui, sans-serif; color: #241a00;
  background: #ffc107; box-shadow: 0 3px 12px rgba(0,0,0,.3);
}
#rapitaxi-campana:hover { filter: brightness(1.06); }
#rapitaxi-campana.activo {
  padding: 7px 10px; font-size: 16px; background: #1f7a3d; color: #fff;
}
.rapitaxi-aviso {
  position: fixed; top: 72px; right: 16px; z-index: 2147483600;
  max-width: 340px; padding: 14px 16px; border-radius: 10px;
  background: #16243a; color: #e8eef6; border: 1px solid #ffc107;
  box-shadow: 0 10px 30px rgba(0,0,0,.45);
  font: 14px/1.35 system-ui, sans-serif;
}
.rapitaxi-aviso strong { color: #ffc107; display: block; margin-bottom: 4px; }
/* En pantallas estrechas no cabe junto al menu: baja justo debajo de la
   cabecera para seguir sin tapar el contenido. */
@media (max-width: 640px) {
  #rapitaxi-campana { top: 62px; right: 10px; }
  .rapitaxi-aviso { top: 112px; }
}
"""

_JS = r"""
(function () {
  "use strict";
  var cfg = __CONFIG__;
  var instalado = window.__rapitaxiBell;
  if (instalado) { instalado.actualizar(cfg); return; }

  var LS = "rapitaxi_avisos_v1";
  var ultimo = null;
  var timer = null;
  var ctx = null;
  var buffer = null;
  var corriendo = false;
  var activado = false;
  var swReg = null;
  var boton = null;
  // Firma -> instante del último aviso mostrado. Evita el doble aviso cuando
  // la pestaña de Viajes Críticos ya avisó y el polling recoge el mismo evento
  // del buzón unos segundos después.
  var vistos = {};

  function log() {
    try {
      var args = ["[rapitaxi-avisos]"].concat([].slice.call(arguments));
      console.log.apply(console, args);
    } catch (e) {}
  }

  function estilos() {
    if (document.getElementById("rapitaxi-css")) return;
    var s = document.createElement("style");
    s.id = "rapitaxi-css";
    s.textContent = __CSS__;
    document.head.appendChild(s);
  }

  function audioCtx() {
    if (!ctx) {
      var AC = window.AudioContext || window.webkitAudioContext;
      if (AC) { try { ctx = new AC(); } catch (e) { ctx = null; } }
    }
    return ctx;
  }

  function desbloquear() {
    var c = audioCtx();
    if (c && c.state === "suspended") { c.resume().catch(function () {}); }
  }

  function cargarSonido() {
    var c = audioCtx();
    if (!c) return Promise.reject(new Error("sin Web Audio"));
    if (buffer) return Promise.resolve(buffer);
    return fetch(cfg.sonido)
      .then(function (r) { return r.arrayBuffer(); })
      .then(function (datos) {
        return new Promise(function (ok, mal) {
          var p = c.decodeAudioData(datos, ok, mal);
          if (p && p.then) { p.then(ok, mal); }
        });
      })
      .then(function (b) { buffer = b; return b; });
  }

  function sonar() {
    var c = audioCtx();
    if (!c) return;
    if (c.state === "suspended") { c.resume().catch(function () {}); }
    cargarSonido().then(function (b) {
      var fuente = c.createBufferSource();
      fuente.buffer = b;
      fuente.connect(c.destination);
      fuente.start(0);
      log("timbre");
    }).catch(function (e) {
      log("audio bloqueado:", e && e.message);
    });
  }

  function porConstructor(titulo, opciones) {
    try {
      var n = new Notification(titulo, opciones);
      n.onclick = function () {
        try { window.focus(); } catch (e) {}
        n.close();
      };
    } catch (e) {
      log("Notification() no disponible:", e && e.message);
      avisoEnPantalla(titulo, opciones.body);
    }
  }

  function porSW(reg, titulo, opciones) {
    try {
      reg.showNotification(titulo, opciones).catch(function (e) {
        log("showNotification fallo:", e && e.message);
        porConstructor(titulo, opciones);
      });
    } catch (e) {
      porConstructor(titulo, opciones);
    }
  }

  function mostrar(titulo, cuerpo, etiqueta) {
    var firma = (titulo || "") + "|" + (cuerpo || "");
    var ahora = Date.now();
    if (vistos[firma] && ahora - vistos[firma] < 120000) {
      log("aviso repetido, se omite");
      return false;
    }
    vistos[firma] = ahora;

    var opciones = {
      body: cuerpo || "",
      tag: etiqueta || "rapitaxi",
      renotify: true,
      // Sin `requireInteraction`: con esa opcion la notificacion del sistema
      // se queda en pantalla hasta que el usuario la cierra. Aqui es un
      // aviso rapido; el sonido y el cartel de la pagina ya llaman la atencion.
      requireInteraction: false
    };
    if (cfg.icono) { opciones.icon = cfg.icono; }
    if (!("Notification" in window)) {
      avisoEnPantalla(titulo, cuerpo);
      return true;
    }
    if (Notification.permission !== "granted") {
      // Sin permiso no se puede notificar, pero el aviso en pantalla y el
      // sonido siguen funcionando mientras el panel este abierto.
      avisoEnPantalla(titulo, cuerpo);
      return true;
    }
    if (swReg) { porSW(swReg, titulo, opciones); return true; }
    if (navigator.serviceWorker) {
      navigator.serviceWorker.ready
        .then(function (reg) { swReg = reg; porSW(reg, titulo, opciones); })
        .catch(function () { porConstructor(titulo, opciones); });
      return true;
    }
    porConstructor(titulo, opciones);
    return true;
  }

  function avisoEnPantalla(titulo, cuerpo) {
    var caja = document.createElement("div");
    caja.className = "rapitaxi-aviso";
    var fuerte = document.createElement("strong");
    fuerte.textContent = titulo;
    var texto = document.createElement("div");
    texto.textContent = cuerpo || "";
    caja.appendChild(fuerte);
    caja.appendChild(texto);
    document.body.appendChild(caja);
    // El cartel es un aviso, no un cuadro de dialogo: se retira solo a los 3 s.
    window.setTimeout(function () {
      if (caja.parentNode) { caja.parentNode.removeChild(caja); }
    }, 3000);
  }

  function programar() {
    if (!corriendo) return;
    if (timer) { window.clearTimeout(timer); }
    timer = window.setTimeout(consultar, cfg.intervalo);
  }

  function parar() {
    corriendo = false;
    if (timer) { window.clearTimeout(timer); timer = null; }
  }

  function arrancar() {
    if (corriendo) return;
    corriendo = true;
    consultar();
  }

  function consultar() {
    if (!corriendo) return;
    var url = cfg.base + "/admin/eventos?limite=20";
    if (ultimo) { url += "&desde=" + encodeURIComponent(ultimo); }
    fetch(url, {
      headers: { "Authorization": "Bearer " + cfg.token },
      cache: "no-store"
    }).then(function (r) {
      if (r.status === 401) {
        log("token caducado; se reanuda cuando el panel lo refresque");
        parar();
        return null;
      }
      if (!r.ok) { throw new Error("HTTP " + r.status); }
      return r.json();
    }).then(function (datos) {
      if (!datos) { return; }
      var eventos = datos.eventos || [];
      if (!ultimo) {
        ultimo = datos.ultimo || null;
        log("vigilando desde", ultimo);
      } else {
        if (datos.ultimo) { ultimo = datos.ultimo; }
        var mostrados = 0;
        for (var i = 0; i < eventos.length; i++) {
          if (mostrar(eventos[i].titulo, eventos[i].mensaje, eventos[i].id)) {
            mostrados++;
          }
        }
        if (mostrados) { sonar(); }
      }
      programar();
    }).catch(function (e) {
      log("fallo la consulta:", e && e.message);
      programar();
    });
  }

  function estadoActivo() {
    activado = true;
    try { window.localStorage.setItem(LS, "1"); } catch (e) {}
    if (boton) {
      boton.textContent = "🔔";
      boton.className = "activo";
      boton.title = "Avisos activos. Pulsa para probar.";
    }
    arrancar();
  }

  function activar() {
    desbloquear();
    sonar();
    if (!("Notification" in window)) {
      avisoEnPantalla("Sonido activado",
        "Este navegador no soporta notificaciones del sistema; el panel avisará con sonido y un cartel.");
      estadoActivo();
      return;
    }
    if (Notification.permission === "granted") {
      estadoActivo();
      avisoEnPantalla("Avisos activados",
        "Llegarán aunque estés en otra pestaña. Se comprueba cada 15 segundos.");
      return;
    }
    if (Notification.permission === "denied") {
      avisoEnPantalla("Notificaciones bloqueadas",
        "El navegador las tiene bloqueadas para este sitio. Actívalas en los ajustes del sitio; el sonido y los carteles seguirán funcionando.");
      estadoActivo();
      return;
    }
    Notification.requestPermission().then(function (perm) {
      if (perm === "granted") {
        avisoEnPantalla("Avisos activados",
          "Llegarán aunque estés en otra pestaña. Se comprueba cada 15 segundos.");
      } else {
        avisoEnPantalla("Notificaciones no permitidas",
          "El panel avisará con sonido y un cartel dentro de la página.");
      }
      estadoActivo();
    }).catch(function () { estadoActivo(); });
  }

  function crearBoton() {
    if (document.getElementById("rapitaxi-campana")) {
      boton = document.getElementById("rapitaxi-campana");
      return;
    }
    boton = document.createElement("button");
    boton.id = "rapitaxi-campana";
    boton.type = "button";
    boton.textContent = "🔔 Activar avisos";
    boton.title = "Permite las notificaciones y el sonido de alertas";
    boton.addEventListener("click", function () {
      if (activado) {
        mostrar("Prueba de aviso",
          "Si ves esta notificación y suena el timbre, todo está listo.",
          "prueba-manual-" + Date.now());
        sonar();
      } else {
        activar();
      }
    });
    document.body.appendChild(boton);
  }

  window.__rapitaxiBell = {
    actualizar: function (nueva) {
      var tokenCambio = nueva.token !== cfg.token;
      cfg = nueva;
      if (boton) { boton.style.display = ""; }
      if (tokenCambio && activado && !corriendo) { arrancar(); }
    },
    detener: function () {
      parar();
      if (boton) { boton.style.display = "none"; }
    },
    avisar: function (titulo, cuerpo) {
      mostrar(titulo, cuerpo, "manual-" + Date.now());
      sonar();
    }
  };

  estilos();
  crearBoton();

  if (navigator.serviceWorker) {
    navigator.serviceWorker.register(cfg.sw).then(function (reg) {
      swReg = reg;
      log("service worker listo");
    }).catch(function (e) {
      log("sin service worker:", e && e.message);
    });
  }

  // Chrome/Safari solo dejan sonar audio tras un gesto. El primer clic en
  // cualquier parte del panel (entrar, cambiar de seccion) desbloquea el
  // contexto de audio.
  document.addEventListener("pointerdown", desbloquear, { once: true });

  try {
    if (window.localStorage.getItem(LS) === "1") {
      activado = true;
      if (boton) {
        boton.textContent = "🔔";
        boton.className = "activo";
        boton.title = "Avisos activos. Pulsa para probar.";
      }
      arrancar();
    }
  } catch (e) {}
})();
"""

_UNO = r"""
(function () {
  var titulo = __TITULO__;
  var mensaje = __MENSAJE__;
  if (window.__rapitaxiBell) {
    window.__rapitaxiBell.avisar(titulo, mensaje);
    return;
  }
  if ("Notification" in window && window.Notification.permission === "granted") {
    try { new Notification(titulo, { body: mensaje, tag: "rapitaxi-directo" }); }
    catch (e) {}
  }
})();
"""


def _json(valor) -> str:
    """JSON seguro dentro de un <script>."""
    return json.dumps(valor, ensure_ascii=False).replace("</", "<\\/")


def _sonido() -> str:
    """WAV del panel en data URI: no depende de un CDN externo."""
    datos = base64.b64encode(_wav_pitido()).decode("ascii")
    return "data:audio/wav;base64," + datos


def campana(api) -> None:
    """Instala/actualiza el vigilante de eventos en la pagina principal."""
    token = (getattr(api, "access_token", None) or "").strip()
    if not token:
        return
    config = {
        "base": get_api_base_url(),
        "token": token,
        "intervalo": 15000,
        "sonido": _sonido(),
        "sw": "app/static/sw.js",
        "icono": "",
    }
    guion = (_JS
             .replace("__CONFIG__", _json(config))
             .replace("__CSS__", _json(_CSS)))
    st.html(
        "<script>" + guion + "</script>",
        unsafe_allow_javascript=True,
        width="content",
    )


def detener() -> None:
    """Apaga el vigilante (se usa al cerrar sesion)."""
    st.html(
        "<script>window.__rapitaxiBell && window.__rapitaxiBell.detener();</script>",
        unsafe_allow_javascript=True,
        width="content",
    )


def notificar(titulo: str, mensaje: str, *, clave: Optional[str] = None) -> None:
    """Dispara YA una notificacion con sonido, sin esperar al polling.

    `clave` evita que un rerun de Streamlit repita el mismo aviso: pásale un
    identificador estable del evento (por ejemplo el id del viaje).
    """
    if clave:
        firma = "%s|%s|%s" % (clave, titulo, mensaje)
        if st.session_state.get("_aviso_emitido") == firma:
            return
        st.session_state["_aviso_emitido"] = firma
    guion = (_UNO
             .replace("__TITULO__", _json(titulo))
             .replace("__MENSAJE__", _json(mensaje)))
    st.html(
        "<script>" + guion + "</script>",
        unsafe_allow_javascript=True,
        width="content",
    )
