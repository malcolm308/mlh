# Política de Privacidad — RapiTaxi Pasajero

**Última actualización:** 21 de noviembre de 2026
**Aplicación:** RapiTaxi (`com.taxirapid.taxi_client`)
**Titular:** [NOMBRE LEGAL DEL TITULAR / EMPRESA]
**Contacto de privacidad:** [CORREO DE PRIVACIDAD] · WhatsApp: +53 59295207

> **Antes de publicar:** sustituye los campos entre corchetes por los datos
> legales reales del titular. El resto del texto ya describe el funcionamiento
> actual de la app.

---

## 1. Quiénes somos

RapiTaxi es la aplicación que permite a los pasajeros solicitar viajes, seguir
el vehículo en el mapa, comunicarse con el conductor y pagar el servicio. El
responsable del tratamiento de los datos personales es el titular indicado
arriba.

Esta política explica qué datos recogemos, para qué los usamos, con quién los
compartimos, cuánto tiempo los conservamos y cómo puedes ejercer tus derechos.

## 2. Datos que recogemos

### 2.1 Datos de la cuenta

- Nombre y apellidos.
- Correo electrónico.
- Número de teléfono.
- Contraseña, almacenada en el servidor únicamente como hash criptográfico.
- Código de referido, si te registraste con uno.

### 2.2 Ubicación

- **Ubicación precisa y aproximada del dispositivo.** Se usa para fijar el punto
  de recogida, calcular la ruta y la tarifa, y mostrar tu posición en el mapa.
- **Ubicación durante el viaje.** Permite seguir el trayecto y compartir el
  estado del servicio. Puedes elegir un punto de recogida distinto al de tu
  ubicación actual moviendo el pin en el mapa.
- **Historial de ubicaciones asociado al viaje.** Se conserva con el viaje para
  calcular la tarifa, atender incidencias y mostrar el historial.

No usamos la ubicación para publicidad ni la vendemos a terceros.

### 2.3 Viajes y actividad

- Origen y destino, ruta, distancia, duración y tarifa.
- Datos del conductor asignado: nombre, foto, valoración y vehículo (marca,
  modelo, color y chapa).
- Estado del viaje, cancelaciones, incidencias y mensajes de soporte.
- Calificaciones y comentarios.
- Billetera interna: saldo, transferencias entre clientes e historial de
  movimientos.

### 2.4 Datos técnicos y de seguridad

- Modelo de dispositivo, versión del sistema operativo y versión de la app.
- Dirección IP y registros de errores del servidor.
- Identificadores de sesión y tokens de acceso, guardados en el almacenamiento
  seguro del sistema (`flutter_secure_storage`), nunca en preferencias planas.

## 3. Para qué usamos los datos

| Finalidad | Datos implicados | Base jurídica |
|---|---|---|
| Crear y gestionar tu cuenta | Cuenta | Ejecución del contrato |
| Fijar recogida, calcular ruta y tarifa | Ubicación, viaje | Ejecución del contrato |
| Asignarte un conductor y seguir el viaje | Ubicación, viaje, conductor | Ejecución del contrato |
| Gestionar la billetera y los pagos | Saldo, movimientos | Ejecución del contrato |
| Atención al cliente e incidencias | Cuenta, viajes, mensajes | Ejecución del contrato |
| Prevenir fraudes y abusos | Actividad, IP, registros | Interés legítimo |
| Cumplir requerimientos de autoridades | Datos necesarios | Obligación legal |

## 4. Permisos del dispositivo

- **Ubicación (precisa y aproximada):** imprescindible para solicitar y seguir
  el viaje.
- **Internet:** conexión con el servidor, el mapa y el seguimiento en tiempo
  real.

La app **no** solicita acceso a cámara, contactos, micrófono, SMS,
almacenamiento ni notificaciones.

## 5. Con quién compartimos los datos

- **Con el conductor del viaje:** tu nombre, punto de recogida y destino, y la
  ubicación necesaria para completar el servicio. El número de teléfono se
  muestra solo cuando es necesario para coordinar la recogida.
- **Proveedores de infraestructura:** alojamiento del backend (Render), base de
  datos (MongoDB Atlas), mapas y teselas (MapTiler y servidor de mapas propio) y
  servicios de correo para recuperación de contraseña. Estos proveedores tratan
  los datos por cuenta nuestra y con contratos de encargado del tratamiento.
- **WhatsApp:** solo si pulsas el botón de soporte; se abre la aplicación y tú
  decides enviar el mensaje.
- **Autoridades:** cuando exista una obligación legal válida.

No vendemos datos personales ni los compartimos con anunciantes.

## 6. Conservación

- Datos de cuenta: mientras la cuenta esté activa.
- Viajes, tarifas y movimientos de billetera: el tiempo necesario para
  obligaciones contables, fiscales y de resolución de disputas.
- Registros técnicos: plazos cortos de seguridad y diagnóstico.
- Ubicación en tiempo real: se conserva asociada al viaje; no se mantiene un
  historial indefinido de tu posición fuera de los viajes.

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

Escríbenos a **[CORREO DE PRIVACIDAD]** o por WhatsApp al **+53 59295207**
indicando tu nombre, teléfono y el derecho que deseas ejercer. Podemos pedirte
una verificación de identidad razonable. Responderemos en el plazo legal
aplicable.

También puedes presentar una reclamación ante la autoridad de protección de
datos competente.

## 9. Menores de edad

El servicio está reservado a personas mayores de 18 años. No recogemos
conscientemente datos de menores. Si detectamos una cuenta de un menor, la
suspendemos y eliminamos sus datos.

## 10. Transferencias internacionales

Los servidores y proveedores pueden estar ubicados fuera de tu país. Cuando
corresponda, aplicamos garantías contractuales adecuadas para proteger los
datos conforme a la normativa aplicable.

## 11. Cambios en esta política

Podemos actualizar esta política para reflejar cambios en la app o en la ley.
Publicaremos la versión vigente en esta misma URL e indicaremos la fecha de
actualización. Si el cambio es sustancial, avisaremos dentro de la app.

## 12. Contacto

- **Responsable:** [NOMBRE LEGAL DEL TITULAR]
- **Correo:** [CORREO DE PRIVACIDAD]
- **WhatsApp de soporte:** +53 59295207
- **Sitio:** https://rapitaxi-api-fws6.onrender.com
