# Política de Privacidad — RapiTaxi Chofer

**URL pública:** https://rapitaxi-api-fws6.onrender.com/static/politica_privacidad_chofer.html

**Última actualización:** 24 de noviembre de 2026
**Aplicación:** RapiTaxi Chofer (`com.taxirapid.taxi_driver`)
**Titular:** RapiTaxi
**Contacto de privacidad:** rapitaxicuba@gmail.com · WhatsApp: +53 59295207

---

## 1. Quiénes somos

RapiTaxi Chofer es la aplicación que usan los conductores para conectarse,
recibir solicitudes de viaje, navegar hasta el pasajero y completar el servicio.
El responsable del tratamiento de los datos personales es el titular indicado
arriba.

Esta política explica qué datos recogemos, para qué los usamos, con quién los
compartimos, cuánto tiempo los conservamos y cómo puedes ejercer tus derechos.

## 2. Datos que recogemos

### 2.1 Datos de la cuenta y del registro

- Nombre y apellidos.
- Correo electrónico.
- Número de teléfono.
- Contraseña, almacenada en el servidor únicamente como hash criptográfico.
- Foto de perfil y fotos de los documentos de registro.
- Datos del vehículo: marca, modelo, año, chapa/matrícula, permiso de
  circulación, color y tipo de servicio.
- Número de licencia de conducción.
- Estado de verificación de documentos y valoración media.

### 2.2 Ubicación

- **Ubicación precisa y aproximada del dispositivo.** Se usa para mostrar tu
  posición en el mapa, asignarte viajes cercanos, calcular la ruta y permitir
  que el pasajero vea dónde está su conductor.
- **Ubicación en segundo plano.** Mientras el interruptor **«En línea»** está
  activo, la app mantiene un servicio en primer plano con una notificación
  permanente y sigue leyendo el GPS aunque la pantalla esté apagada o estés
  usando otra aplicación. Al desconectarte, el servicio se detiene y la app deja
  de leer la ubicación.
- **Historial de posiciones del viaje.** Se registra el recorrido para calcular
  la tarifa, resolver incidencias y mostrar el historial al pasajero.

No usamos la ubicación para publicidad ni la vendemos a terceros.

### 2.3 Viajes y actividad

- Origen y destino, ruta recorrida, distancia, duración y tarifa.
- Estado del viaje (aceptado, en camino, en curso, completado, cancelado).
- Cancelaciones, incidencias y mensajes de soporte.
- Calificaciones y comentarios.
- Movimientos de la billetera interna (saldo, comisiones y liquidaciones).

### 2.4 Datos técnicos y de seguridad

- Modelo de dispositivo, versión del sistema operativo y versión de la app.
- Dirección IP y registros de errores del servidor.
- Identificadores de sesión y tokens de acceso, guardados en el almacenamiento
  seguro del sistema (`flutter_secure_storage`), nunca en preferencias planas.
- Si activas voluntariamente el bot de Telegram: identificador de chat y nombre
  de usuario de Telegram.

## 3. Para qué usamos los datos

| Finalidad | Datos implicados | Base jurídica |
|---|---|---|
| Crear y gestionar tu cuenta de conductor | Cuenta, documentos, vehículo | Ejecución del contrato |
| Asignarte viajes y mostrarte ofertas cercanas | Ubicación, disponibilidad | Ejecución del contrato |
| Navegación y seguimiento del viaje | Ubicación, ruta | Ejecución del contrato |
| Calcular tarifas, comisiones y liquidaciones | Viajes, billetera | Ejecución del contrato |
| Verificar identidad y documentación | Documentos, licencia | Obligación legal y seguridad |
| Prevenir fraudes y abusos | Actividad, IP, registros | Interés legítimo |
| Atención al cliente e incidencias | Cuenta, viajes, mensajes | Ejecución del contrato |
| Notificaciones de ofertas y servicio | Token del dispositivo, teléfono | Consentimiento / ejecución |
| Cumplir requerimientos de autoridades | Datos necesarios | Obligación legal |

## 4. Permisos del dispositivo

- **Ubicación (precisa y aproximada):** imprescindible para el servicio.
- **Internet:** conexión con el servidor, el mapa y el canal de ofertas.
- **Notificaciones:** avisos de ofertas y estado del servicio.
- **Servicio en primer plano con ubicación:** mantiene el GPS y las ofertas
  activos mientras estás «En línea».
- **Vibración:** aviso sonoro y vibratorio de nuevas ofertas.

La app **no** solicita acceso a cámara, contactos, micrófono, SMS ni
almacenamiento. Las fotos de documentos se toman con la aplicación de cámara del
sistema, que entrega solo la imagen elegida.

## 5. Con quién compartimos los datos

- **Con el pasajero del viaje:** tu nombre, foto de perfil, datos del vehículo
  (marca, modelo, color y chapa), valoración y ubicación durante el servicio.
- **Proveedores de infraestructura:** alojamiento del backend (Render), base de
  datos (MongoDB Atlas), mapas y teselas (MapTiler y servidor de mapas propio) y
  servicios de correo para recuperación de contraseña. Estos proveedores tratan
  los datos por cuenta nuestra y con contratos de encargado del tratamiento.
- **Telegram:** solo si decides vincular el bot. Es opcional y puedes
  desvincularlo.
- **WhatsApp:** solo si pulsas el botón de soporte; se abre la aplicación y tú
  decides enviar el mensaje.
- **Autoridades:** cuando exista una obligación legal válida.

No vendemos datos personales ni los compartimos con anunciantes.

## 6. Conservación

- Datos de cuenta: mientras la cuenta esté activa.
- Documentos de conducir y del vehículo: mientras la cuenta esté activa y,
  después, durante los plazos legales aplicables.
- Viajes, tarifas y movimientos de billetera: el tiempo necesario para
  obligaciones contables, fiscales y de resolución de disputas.
- Registros técnicos: plazos cortos de seguridad y diagnóstico.
- Ubicación en tiempo real: se conserva asociada al viaje; no se mantiene un
  historial indefinido de tu posición cuando estás desconectado.

Cuando ya no sea necesario, los datos se eliminan o se anonimizan.

## 7. Seguridad

- Todas las comunicaciones con el servidor usan **HTTPS**; la app bloquea el
  tráfico HTTP no cifrado.
- Los tokens de sesión se guardan cifrados por el sistema operativo
  (`flutter_secure_storage` / Android Keystore) y no en `SharedPreferences`.
- Las contraseñas se almacenan con hash y nunca se devuelven al cliente.
- La app de producción se compila ofuscada y con optimización R8.
- El acceso a la base de datos está restringido por credenciales y red.
- Las copias de seguridad automáticas de Android están desactivadas para evitar
  que los datos de sesión salgan del dispositivo.

Ningún sistema es infalible. Si detectamos una brecha que afecte a tus derechos,
te informaremos conforme a la normativa aplicable.

## 8. Tus derechos

Puedes solicitar:

- **Acceso** a los datos que tenemos sobre ti.
- **Rectificación** de datos inexactos.
- **Eliminación** de tu cuenta y de los datos que ya no debamos conservar.
- **Oposición o limitación** al tratamiento.
- **Portabilidad** de los datos que nos diste.
- **Retirada del consentimiento** en cualquier momento, sin afectar al
  tratamiento previo.

Escríbenos a **rapitaxicuba@gmail.com** o por WhatsApp al **+53 59295207**
indicando tu nombre, teléfono y el derecho que deseas ejercer. Podemos pedirte
una verificación de identidad razonable. Responderemos en el plazo legal
aplicable.

También puedes presentar una reclamación ante la autoridad de protección de
datos competente.

## 9. Menores de edad

El servicio de conductor está reservado a personas mayores de 18 años con
licencia de conducción válida. No recogemos conscientemente datos de menores. Si
detectamos una cuenta de un menor, la suspendemos y eliminamos sus datos.

## 10. Transferencias internacionales

Los servidores y proveedores pueden estar ubicados fuera de tu país. Cuando
corresponda, aplicamos garantías contractuales adecuadas para proteger los
datos conforme a la normativa aplicable.

## 11. Cambios en esta política

Podemos actualizar esta política para reflejar cambios en la app o en la ley.
Publicaremos la versión vigente en esta misma URL e indicaremos la fecha de
actualización. Si el cambio es sustancial, avisaremos dentro de la app.

## 12. Contacto

- **Responsable:** RapiTaxi
- **Correo:** rapitaxicuba@gmail.com
- **WhatsApp de soporte:** +53 59295207
- **Sitio:** https://rapitaxi-api-fws6.onrender.com
