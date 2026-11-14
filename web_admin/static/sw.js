/* Service worker mínimo del panel de Rapitaxi.
 *
 * No hace push ni cachea nada: solo muestra las notificaciones que le pide el
 * vigilante de `notificaciones.py` y trae la pestaña al frente al pulsarlas.
 *
 * Se sirve desde `/app/static/sw.js` (server.enableStaticServing = true) y su
 * scope queda en `/app/static/`, lo cual basta para `showNotification`; no
 * necesita controlar la página.
 */

self.addEventListener("install", function () {
  self.skipWaiting();
});

self.addEventListener("activate", function (evento) {
  evento.waitUntil(self.clients.claim());
});

self.addEventListener("notificationclick", function (evento) {
  evento.notification.close();
  evento.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true })
      .then(function (ventanas) {
        for (var i = 0; i < ventanas.length; i++) {
          if ("focus" in ventanas[i]) {
            return ventanas[i].focus();
          }
        }
        if (self.clients.openWindow) {
          return self.clients.openWindow("/");
        }
      })
  );
});
