package com.taxirapid.taxi_driver

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicReference

/**
 * GPS del dispositivo expuesto a Dart por un MethodChannel.
 *
 * Se usa el LocationManager de Android en lugar de una libreria externa
 * porque la app se compila sin dependencias nuevas de pub.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "taxirapid/location"
        const val REQ_LOCATION = 4711
        const val DEFAULT_TIMEOUT_MS = 12000L

        /**
         * Velocidad por debajo de la cual se considera el vehiculo parado.
         *
         * 1 km/h en m/s. El GPS reporta 0.0 en parado, pero en ralentiz y con
         * error de medicion puede dar 0.3 m/s de ruido.
         */
        const val VELOCIDAD_PARADO_MPS = 0.28

        /**
         * Tiempo por debajo de [VELOCIDAD_PARADO_MPS] antes de pausar el GPS.
         *
         * 10 s. En un semaforo de La Habana el vehiculo se para mas de eso con
         * normalidad, y mantener el GPS a 1 Hz sin razon es gasto de bateria.
         */
        const val PAUSA_PARADO_MS = 10000L

        /**
         * Intervalo de sondeo del GPS en modo navegacion.
         *
         * 1000 ms. El modo flota usa 10 s porque solo necesita refrescar la
         * posicion para el backend; navegando hace falta 1 Hz para que el mapa
         * no de saltos.
         */
        const val NAV_INTERVAL_MS = 1000L

        /**
         * Tiempo sin variacion de azimut para dar el sensor por clavado.
         *
         * 30 s. Medido en este movil: el sensor entrego 48.121 muestras con 2
         * grados de recorrido total, o sea clavado, mientras el GPS se movia 158
         * grados en el mismo tramo. Cuando se detecta, se prueba con el siguiente
         * sensor de la cadena, que suele ser el que si se mueve.
         */
        const val SENSOR_CLAVADO_MS = 30000L

        /**
         * Variacion de azimut minima para considerar que el sensor esta vivo.
         *
         * 8 grados. Es el ruido de fondo de un sensor real; por debajo, la
         * variacion medida es del orden del ruido y no dice nada.
         */
        const val SENSOR_MINIMO_VARIACION_GRADOS = 8.0

        /** Cada cuanto se mira si el sensor se ha quedado clavado. */
        const val SENSOR_VIGILANCIA_PERIODO_MS = 5000L

        /**
         * Etiqueta de posicion del listener de navegacion (1 Hz).
         *
         * Dart la usa para no mezclarla con la del modo flota, que va a 10 s /
         * 20 m. Ver [toMap].
         */
        const val MODO_NAV = "nav"

        /** Etiqueta de posicion del modo flota y de las consultas puntuales. */
        const val MODO_FLOTA = "flota"
    }

    private var channel: MethodChannel? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lastFix = AtomicReference<Location?>(null)

    /**
     * Listener del MODO FLOTA (10 s / 20 m).
     *
     * Antes este unico `listener` lo compartia con el modo navegacion, y al
     * arrancar el modo flota el `startUpdates` se carryaba el de 1 Hz con el
     * (los dos son del mismo LocationManager y no pueden convivir en un solo
     * campo). El resultado era que la navegacion se quedaba sin fixes a 1 Hz:
     * sin velocidad ni rumbo por fix, el heading-up no tenia con que trabajar y
     * el mapa se quedaba en norte arriba y plano. Ahora son dos campos
     * separados y ambos flujos-conviven.
     */
    private var listener: LocationListener? = null

    /** Listener del MODO NAVEGACION (1 Hz). Ver [listener]. */
    private var listenerNav: LocationListener? = null

    private var currentTimeout: Runnable? = null

    /**
     * Sondeo ligero que detecta el arranque del vehiculo mientras el GPS de
     * navegacion esta en pausa por parado. Ver [detectarMovimiento].
     */
    private var detectorMovimiento: LocationListener? = null

    // ---------------- Modo navegacion ----------------

    private var navActivo = false
    private var sensorListener: SensorEventListener? = null
    private var sensorManager: SensorManager? = null

    /** Posicion dentro de [sensoresRumbo] del sensor con el que se esta leyendo. */
    private var sensorEnUso = 0

    /** Nombre del sensor en uso, que se manda a Dart con cada lectura. */
    private var sensorNombre: String? = null

    /** Ultimo azimut emitido, para saber si el sensor se mueve. */
    private var ultimoAzimut = Double.NaN

    /** Recorrido angular acumulado desde la ultima comprobacion del vigilante. */
    private var recorridoAzimut = 0.0

    /** Instante en el que arranco a vigilarse el sensor actual. */
    private var vigilarDesdeMs = 0L

    /** Matrices del calculo de orientacion, reutilizadas por cada lectura. */
    private val matrizRotacion = FloatArray(9)
    private val matrizRemapeada = FloatArray(9)
    private val orientacion = FloatArray(3)

    /**
     * Ultimo instante (monotono) en el que el vehiculo se vio en marcha.
     *
     * Se usa para la pausa automatica: si pasan [PAUSA_PARADO_MS] sin moverse,
     * el GPS se desconecta para no gastar bateria en un semaforo.
     */
    private var ultimoEnMarchaMs = 0L

    /**
     * Tarea periodica que evalua la pausa por parado y reengancha el GPS.
     *
     * Corre cada 2 s, suficiente para no penalizar la bateria y para que la
     * reanudacion tras arrancar sea casi inmediata.
     */
    private val tareaParado = object : Runnable {
        override fun run() {
            if (!navActivo) return
            val ahora = SystemClock.elapsedRealtime()

            if (listenerNav == null) {
                // El GPS de navegacion esta en pausa por parado. Sin listener no
                // llegan fixes, asi que `ultimoEnMarchaMs` (y con el la rama de
                // reanudacion de mas abajo) se quedaba congelado en el pasado y
                // el GPS nunca volvia a arrancar: la ubicacion quedaba estatica
                // para siempre. Aqui se deja un sondeo minimo que detecta el
                // arranque.
                detectarMovimiento()
            } else if (ahora - ultimoEnMarchaMs >= PAUSA_PARADO_MS) {
                // Mas de 10 s sin moverse: pausar el GPS a 1 Hz. El detector
                // barato (1,5 s / 5 m) consume casi nada mientras este parado.
                runCatching { locationManager?.removeUpdates(listenerNav!!) }
                listenerNav = null
                detectarMovimiento()
            }
            mainHandler.postDelayed(this, 2000L)
        }
    }

    private val locationManager: LocationManager?
        get() = getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result -> onCall(call, result) }
        }
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stopUpdates()
        stopNav()
        sensorManager?.unregisterListener(sensorListener)
        sensorListener = null
        channel?.setMethodCallHandler(null)
        channel = null
        sensorManager = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermission" -> ensurePermission(result)
            "isEnabled" -> result.success(isLocationEnabled())
            "getLastKnown" -> result.success(lastKnown())
            "getCurrent" -> getCurrent(
                result,
                call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS
            )
            "start" -> startUpdates(
                result,
                call.argument<Number>("intervalMs")?.toLong() ?: 10000L,
                call.argument<Number>("minDistanceM")?.toDouble() ?: 20.0
            )
            "stop" -> {
                stopUpdates()
                result.success(true)
            }
            // Modo navegacion: GPS a 1 Hz + sensor de rumbo.
            "startNav" -> startNav(result, call.argument<Boolean>("sensor") ?: true)
            "stopNav" -> {
                stopNav()
                result.success(true)
            }
            "hasHeadingSensor" -> result.success(tieneSensorRumbo())

            // Ruta donde la app puede escribir su propio registro de traza.
            //
            // Se pide a Android en vez de ahipertura con una constante porque el
            // camino incluye el paquete y cambia con la version installed. Es el
            // directorio externo propio de la app, que en Android 11 y superior
            // se puede escribir sin permiso y que `adb shell` si puede leer.
            "logPath" -> result.success(
                getExternalFilesDir(null)?.absolutePath?.plus("/navlog.txt")
            )

            "openSettings" -> {
                val intent = android.content.Intent(
                    android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    android.net.Uri.fromParts("package", packageName, null)
                )
                startActivity(intent)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------- PERMISOS ----------------

    private fun hasLocationPermission(): Boolean {
        val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
        return fine == PackageManager.PERMISSION_GRANTED ||
                coarse == PackageManager.PERMISSION_GRANTED
    }

    private fun ensurePermission(result: MethodChannel.Result) {
        if (hasLocationPermission()) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.error("EN_CURSO", "Ya hay una solicitud de permiso pendiente", null)
            return
        }
        pendingPermission = result
        requestPermissions(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ),
            REQ_LOCATION
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_LOCATION) return
        val granted = grantResults.isNotEmpty() &&
                grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    // ---------------- POSICION ----------------

    private fun isLocationEnabled(): Boolean {
        val lm = locationManager ?: return false
        return lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }

    private fun pickProvider(): String? {
        val lm = locationManager ?: return null
        return when {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> null
        }
    }

    private fun lastKnown(): Map<String, Any?>? {
        val lm = locationManager
        val provider = pickProvider()
        if (lm == null || provider == null) return null
        val candidates = listOfNotNull(
            runCatching { lm.getLastKnownLocation(LocationManager.GPS_PROVIDER) }.getOrNull(),
            runCatching { lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER) }.getOrNull(),
            lastFix.get()
        )
        // La mas reciente es la que mejor sirve como posicion inicial inmediata.
        val best = candidates.maxByOrNull { it.time } ?: return null
        return toMap(best, MODO_FLOTA)
    }

    /**
     * Convierte un [Location] al mapa que consume Dart.
     *
     * Se Enriquece con los datos que necesita el modo navegacion:
     *  - `hasBearing` + `bearing`: el GPS aporta rumbo, pero en modo automatico
     *    suele venir sin valor util. Aun asi se manda para cuando el sensor no
     *    exista (ver [emitirRumboSensor]).
     *  - `hasSpeed` + `speed`: m/s, permite distinguir parado de conduciendo.
     *  - `elapsedRealtimeMs`: reloj MONOTONO (milis desde el arranque). Es el
     *    unico seguro para calcular deltas: con `wallTimeMs` un cambio de hora
     *    o de zona horaria del dispositivo daria intervalos negativos y el
     *    dead-reckoning se dispararia.
     *
     * Los flags `hasX` son imprescindiblees: Android devuelve 0.0 tanto para
     * "rumbo norte" como para "no tengo dato", y esa ambiguedad haria que el
     * mapa se orientase al norte en un tunel.
     */
    private fun toMap(location: Location, modo: String): Map<String, Any?> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracy" to location.accuracy.toDouble(),
        "wallTimeMs" to location.time,
        "elapsedRealtimeMs" to SystemClock.elapsedRealtime(),
        "hasBearing" to location.hasBearing(),
        "bearing" to if (location.hasBearing()) location.bearing.toDouble() else null,
        "hasSpeed" to location.hasSpeed(),
        "speed" to if (location.hasSpeed()) location.speed.toDouble() else null,
        "provider" to location.provider,
        // De que listener sale la posicion: `flota` (10 s / 20 m) o `nav` (1 Hz).
        //
        // Sin esto los dos modos comparten un unico stream en Dart, asi que el
        // suscriptor del modo flota recibia tambien las posiciones de navegacion
        // a 1 Hz. Cada una hacia que la pantalla recalculara las rutas, lo que
        // arrastraba al detector de desvios y lo reiniciaba 63 veces por minuto:
        // su contador de 3 muestras consecutivas nunca llegaba a 3.
        "modo" to modo,
        "mocked" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
            location.isFromMockProvider
        } else {
            false
        }
    )

    /**
     * Publica una posicion.
     *
     * [modo] distingue el listener de navegacion (1 Hz) del de flota (10 s /
     * 20 m). Lo consume Dart para no mezclarlos.
     */
    private fun emit(location: Location, modo: String) {
        lastFix.set(location)

        // En modo navegacion se lleva la cuenta de si el vehiculo se mueve, para
        // poder pausar el GPS en un semaforo. Se hace aqui y no en el listener
        // para que cuente tambien la posicion puntual de `getCurrent`.
        if (navActivo && location.hasSpeed() && location.speed >= VELOCIDAD_PARADO_MPS) {
            ultimoEnMarchaMs = SystemClock.elapsedRealtime()
        }

        channel?.invokeMethod("onLocation", toMap(location, modo))
    }

    // ---------------- MODO NAVEGACION ----------------

    /**
     * Arranca el GPS a 1 Hz y, si [usarSensor], el sensor de rumbo.
     *
     * Es un camino separado de [startUpdates] a proposito: el modo flota
     * (10 s / 20 m) sirve para refrescar la posicion que ve el backend y no
     * debe cambiar de comportamiento al a├▒adir navegacion.
     *
     * [usarSensor] en `false` deja el sensor sin registrar. La app lo pide asi
     * porque el heading-up sale de la ruta, no del sensor: en este movil el
     * `TYPE_GAME_ROTATION_VECTOR` devolvia el mismo azimut en 48.121 muestras
     * seguidas y ademas costaba ~50 eventos por segundo por el canal.
     */
    private fun startNav(result: MethodChannel.Result, usarSensor: Boolean = true) {
        android.util.Log.i("RapiTaxi", "startNav: permiso=${hasLocationPermission()} sensor=$usarSensor")
        if (!hasLocationPermission()) {
            result.error("SIN_PERMISO", "Falta el permiso de ubicacion", null)
            return
        }
        val lm = locationManager
        val provider = pickProvider()
        if (lm == null || provider == null) {
            result.error("GPS_APAGADO", "La ubicacion esta desactivada en el dispositivo", null)
            return
        }

        navActivo = true
        ultimoEnMarchaMs = SystemClock.elapsedRealtime()

        // `minTime` a 0 con `minDistance` a 0 haria que Android entregase fixes
        // tan rapido como pudiera. Se deja 1 s de intervalo y 0 m de distancia:
        // la posicion llega a 1 Hz (suficiente para el mapa).
        reanudarNavegacion()

        mainHandler.removeCallbacks(tareaVigilarSensor)
        if (usarSensor) {
            sensorEnUso = 0
            sensorNombre = null
            ultimoAzimut = Double.NaN
            recorridoAzimut = 0.0
            vigilarDesdeMs = SystemClock.elapsedRealtime()
            registrarSensorRumbo()
            mainHandler.postDelayed(tareaVigilarSensor, SENSOR_VIGILANCIA_PERIODO_MS)
        } else {
            sensorManager?.unregisterListener(sensorListener)
            sensorListener = null
            sensorNombre = null
        }

        mainHandler.removeCallbacks(tareaParado)
        mainHandler.postDelayed(tareaParado, 2000L)
        result.success(true)
    }

    /**
     * Registra un sondeo muy ligero para detectar que el coche arranca.
     *
     * Con el GPS de navegacion en pausa no llega ningun fix, asi que este
     * listener (1,5 s / 5 m) es el unico que puede darse cuenta de que el
     * vehiculo se ha puesto en marcha: mientras siga parado casi no emite, y
     * al primer desplazamiento real reengancha el GPS a 1 Hz.
     */
    private fun detectarMovimiento() {
        if (detectorMovimiento != null) return
        val lm = locationManager ?: return
        val provider = pickProvider() ?: return
        val l = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                // Ya hay desplazamiento real: resetea el reloj de la pausa y
                // reengancha el GPS de navegacion de inmediato.
                ultimoEnMarchaMs = SystemClock.elapsedRealtime()
                reanudarNavegacion()
            }
            override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
            override fun onProviderEnabled(p: String) {}
            override fun onProviderDisabled(p: String) {}
        }
        runCatching {
            lm.requestLocationUpdates(provider, 1500L, 5f, l, mainLooper)
        }.onSuccess { detectorMovimiento = l }
    }

    private fun detenerDetector() {
        detectorMovimiento?.let { d ->
            runCatching { locationManager?.removeUpdates(d) }
        }
        detectorMovimiento = null
    }

    /** Registra (o reactiva) las actualizaciones de posicion a 1 Hz. */
    private fun reanudarNavegacion() {
        if (!navActivo) return
        // Si ya esta escuchando, no se toca: el detector de movimiento llama a
        // este metodo cada vez que avanza, y re-registrar el listener en cada
        // llamada lo que haria es desconectar y reconectar el GPS sin parar.
        if (listenerNav != null) return
        val lm = locationManager ?: return
        val provider = pickProvider() ?: return
        // Solo se sustituye el listener de NAVEGACION. El del modo flota se
        // respeta: ambos estan activos a la vez y cada uno con su ritmo.
        listenerNav?.let { runCatching { lm.removeUpdates(it) } }
        val l = object : LocationListener {
            override fun onLocationChanged(location: Location) = emit(location, MODO_NAV)
            override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
            override fun onProviderEnabled(p: String) {}
            override fun onProviderDisabled(p: String) {}
        }
        runCatching {
            lm.requestLocationUpdates(provider, NAV_INTERVAL_MS, 0f, l, mainLooper)
        }.onSuccess { listenerNav = l }
    }

    /** Corta GPS y sensor: el viaje se termino, cancelo o la app se cierra. */
    private fun stopNav() {
        navActivo = false
        mainHandler.removeCallbacks(tareaParado)
        mainHandler.removeCallbacks(tareaVigilarSensor)
        listenerNav?.let { runCatching { locationManager?.removeUpdates(it) } }
        listenerNav = null
        detenerDetector()
        sensorManager?.unregisterListener(sensorListener)
        sensorListener = null
        sensorEnUso = 0
        sensorNombre = null
        ultimoAzimut = Double.NaN
        recorridoAzimut = 0.0
    }

    /**
     * Vigila que el sensor de rumbo se mueva de verdad y, si no, prueba otro.
     *
     * Es la red de seguridad del MethodChannel: el canal entrega SIEMPRE lo que
     * el sensor dice, pero hay sensores que dicen siempre lo mismo. En este movil
     * el `TYPE_GAME_ROTATION_VECTOR` devolvia el mismo azimut en 48.121 muestras
     * seguidas (2 grados de recorrido total) mientras el coche giraba, y el mapa
     * se quedaba clavado apuntando al norte durante todo el viaje.
     *
     * Con solo mirar el valor no se distingue "el coche va recto" de "el sensor
     * esta roto", asi que no se declara nada por el silencio: se mide el
     * recorrido del azimut durante 30 s y, si no llega a 8 grados, se pasa al
     * siguiente sensor de la cadena. Un sensor que se mueve, aunque sea poco, es
     * preferible a uno que no se mueve nunca.
     */
    private val tareaVigilarSensor = object : Runnable {
        override fun run() {
            if (!navActivo) return
            val ahora = SystemClock.elapsedRealtime()

            if (recorridoAzimut >= SENSOR_MINIMO_VARIACION_GRADOS) {
                // Se mueve: se reinicia la ventana. Vive, no hay nada que hacer.
                vigilarDesdeMs = ahora
                recorridoAzimut = 0.0
                mainHandler.postDelayed(this, SENSOR_VIGILANCIA_PERIODO_MS)
                return
            }

            if (ahora - vigilarDesdeMs < SENSOR_CLAVADO_MS) {
                mainHandler.postDelayed(this, SENSOR_VIGILANCIA_PERIODO_MS)
                return
            }

            android.util.Log.w(
                "RapiTaxi",
                "vigilante: $sensorNombre no se ha movido en $SENSOR_CLAVADO_MS ms " +
                    "(recorrido $recorridoAzimut grados), se pasa al siguiente sensor"
            )
            recorridoAzimut = 0.0
            ultimoAzimut = Double.NaN
            vigilarDesdeMs = ahora
            if (sensorEnUso + 1 < sensoresRumbo().size) {
                sensorEnUso++
                registrarSensorRumbo()
            } else {
                // Se han agotado los sensores: no hay nada mejor. Se deja el
                // actual y se vuelve a mirar dentro de 30 s, por si se recupera.
                android.util.Log.w(
                    "RapiTaxi",
                    "vigilante: no queda mas sensor de rumbo que probar"
                )
            }
            mainHandler.postDelayed(this, SENSOR_VIGILANCIA_PERIODO_MS)
        }
    }

    // ---------------- SENSOR DE RUMBO ----------------

    /**
     * Los sensores de rumbo del dispositivo, en orden de preferencia.
     *
     *  1. `TYPE_GAME_ROTATION_VECTOR`: giroscopio + acelerometro, SIN magnetometro.
     *     Es el que mejor viene en un taxi, porque los imanes de la carroceria
     *     desvian la brujula magnetica de forma constante.
     *  2. `TYPE_ROTATION_VECTOR`: idem pero con magnetometro, degrada si el
     *     magnetometro esta sucio. Es ademas el plan B cuando el anterior se
     *     queda clavado: ver [tareaVigilarSensor].
     *  3. `TYPE_MAGNETIC_FIELD` + `TYPE_ACCELEROMETER`: montaje manual de la
     *     matriz. Ultimo recurso.
     *
     * Se devuelve la lista y no solo el primero porque el registro puede fallar,
     * y pasar al siguiente solo es posible si se conocen los candidatos.
     *
     * `location.bearing` del GPS NO se usa como sensor: es dead-reckoning y en
     * conduccion urbana suele devolver 0 o valores que cambian sin rumbo real.
     */
    private fun sensoresRumbo(): List<Sensor> {
        val sm = sensorManager ?: return emptyList()
        return listOfNotNull(
            sm.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR),
            sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR),
            sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD),
        )
    }

    private fun mejorSensorRumbo(): Sensor? = sensoresRumbo().firstOrNull()

    private fun tieneSensorRumbo(): Boolean = mejorSensorRumbo() != null

    /**
     * Registra el sensor de la cadena que toca en [sensorEnUso].
     *
     * Si `registerListener` devuelve `false` se pasa al siguiente. Antes se
     * ignoraba ese valor de retorno: se daba por bueno un sensor que en realidad
     * no estaba registrado y nunca iba a emitir, el canal se quedaba mudo y no
     * habia ni un error ni un aviso por el que enterarse. El fallo tipico es que
     * otro proceso (una app de navegacion, el juego de grabacion) tenga el
     * sensor tomado.
     */
    private fun registrarSensorRumbo() {
        val sm = sensorManager ?: return
        sm.unregisterListener(sensorListener)

        val candidatos = sensoresRumbo()
        if (candidatos.isEmpty()) {
            android.util.Log.w(
                "RapiTaxi",
                "registrarSensorRumbo: el dispositivo NO tiene sensor de rumbo"
            )
            sensorListener = null
            return
        }
        if (sensorEnUso >= candidatos.size) {
            android.util.Log.w(
                "RapiTaxi",
                "registrarSensorRumbo: se han agotado los sensores de rumbo"
            )
            sensorListener = null
            return
        }

        val sensor = candidatos[sensorEnUso]
        sensorNombre = sensor.name
        val listener = oyenteRumbo

        // SENSOR_DELAY_GAME son ~50 Hz: suficiente para que el mapa gire sin
        // tirones sin gastar mas de lo necesario en un taxi durante un viaje.
        val registrado = runCatching {
            sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_GAME)
        }.getOrDefault(false)

        if (!registrado) {
            android.util.Log.w(
                "RapiTaxi",
                "registrarSensorRumbo: ${sensor.name} no se pudo registrar, se prueba el siguiente"
            )
            sensorEnUso++
            registrarSensorRumbo()
            return
        }

        if (sensor.type == Sensor.TYPE_MAGNETIC_FIELD) {
            // El montaje manual necesita tambien el acelerometro.
            sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
                runCatching {
                    sm.registerListener(listener, it, SensorManager.SENSOR_DELAY_GAME)
                }
            }
        }

        sensorListener = listener
        android.util.Log.i("RapiTaxi", "registrarSensorRumbo: usando ${sensor.name}")
    }

    /**
     * Listener de sensor compartido por todos los registros.
     *
     * Vive en un campo y no se construyen en [registrarSensorRumbo] para que el
     * vigilante pueda cambiar de sensor sin rehacerlo, y para que las matrices se
     * reutilicen en cada lectura en vez de reservar tres arrays nuevos por evento.
     */
    private val oyenteRumbo = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            if (event.values.size < 3) return
            SensorManager.getRotationMatrixFromVector(matrizRotacion, event.values)

            // El azimut depende de los ejes que se eligen como referencia.
            //
            // Sin remapear, `getOrientation` mide el azimut sobre el eje Y del
            // telefono (la "arriba" de la pantalla), que en vertical apunta al
            // cielo: el resultado sale 90 grados desviado. La referencia
            // correcta en vertical es la X del telefono (su eje derecho) y la
            // Z (la normal de la pantalla, que es la que mira al conductor).
            //
            // Antes se pasaba `AXIS_X to AXIS_Z`, que parece un remapeo pero
            // no lo es: la funcion de Android calcula `Z = Y xor X` y
            // permuta las filas enteras, asi que con esos dos ejes la
            // permutacion cae en la identidad y el mapa salia girado justo
            // los 90 grados de los que se queja.
            //
            // El remapeo se hace aqui en vez de con
            // `SensorManager.remapCoordinateSystem` porque esa funcion
            // rechaza los ejes negativos (`AXIS_MINUS_X` es -1 y no pasa su
            // comprobacion `X & 0x7C`), que hacen falta en las rotaciones de
            // pantalla, y porque deja `outR` intacto cuando devuelve false:
            // un fallo silencioso que hacia que en horizontal se siguiera
            // leyendo la matriz del evento anterior.
            val (ejeX, ejeY, signoX, signoY) = when (remapSegunPantalla()) {
                0 -> Ejes(
                    SensorManager.AXIS_X, SensorManager.AXIS_Y, 1f, 1f)
                1 -> Ejes(
                    SensorManager.AXIS_Y, SensorManager.AXIS_X, 1f, -1f)
                2 -> Ejes(
                    SensorManager.AXIS_X, SensorManager.AXIS_Y, -1f, -1f)
                else -> Ejes(
                    SensorManager.AXIS_Y, SensorManager.AXIS_X, -1f, 1f)
            }
            remapParaAzimut(matrizRotacion, matrizRemapeada, ejeX, ejeY, signoX, signoY)
            SensorManager.getOrientation(matrizRemapeada, orientacion)

            // orientacion[0] es el azimut en RADIANES, 0 = norte y creciendo en
            // sentido horario, que es justo lo que espera el `bearing` de
            // MapLibre. Se convierte a grados al mandar.
            val azimut = Math.toDegrees(orientacion[0].toDouble())
            val normalizado = ((azimut % 360.0) + 360.0) % 360.0

            // Acumulacion del recorrido angular para el vigilante. Va por el
            // camino corto: un salto de 359 a 1 son 2 grados, no 358.
            if (!ultimoAzimut.isNaN()) {
                val d = (normalizado - ultimoAzimut + 540.0) % 360.0 - 180.0
                recorridoAzimut += if (d < 0) -d else d
            }
            ultimoAzimut = normalizado

            channel?.invokeMethod(
                "onHeading",
                mapOf(
                    "bearing" to normalizado,
                    // Antes se mandaba esto como `accuracyRad` y no era una
                    // precision: era `orientacion[2]`, que es la inclinacion. Con
                    // el nombre correcto deja de invite a usarlo mal.
                    "inclinacionGrados" to Math.toDegrees(orientacion[2].toDouble()).toFloat(),
                    // De que sensor viene: si el vigilante cambia de sensor en
                    // caliente, la traza de Dart lo tiene que poder decir.
                    "source" to sensorNombre,
                    "elapsedRealtimeMs" to SystemClock.elapsedRealtime()
                )
            )
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    /** Par de ejes (y sus signos) con el que se remapea la matriz de rotacion. */
    private data class Ejes(
        val ejeX: Int,
        val ejeY: Int,
        val signoX: Float,
        val signoY: Float,
    )

    /**
     * Reordena [entrada] para que `getOrientation` mida el azimut sobre los ejes
     * indicados.
     *
     * Es el mismo criterio que `SensorManager.remapCoordinateSystem`, pero
     * admitiendo signos: pone la fila del eje X en la fila 0, la del eje Y en
     * la 1, y calcula la tercera como el producto vectorial de las dos para que
     * la matriz siga siendo ortonormal. Sin ese signo la matriz se sesga y el
     * azimut sale peor que un simple desfase.
     *
     * Los indices siguen la convencion de `SensorManager`: AXIS_X=1,
     * AXIS_Y=2, AXIS_Z=3, y la fila `eje` empieza en `eje * 3`.
     */
    private fun remapParaAzimut(
        entrada: FloatArray,
        salida: FloatArray,
        ejeX: Int,
        ejeY: Int,
        signoX: Float,
        signoY: Float,
    ) {
        for (i in 0..2) {
            salida[i] = entrada[ejeX * 3 + i] * signoX
            salida[3 + i] = entrada[ejeY * 3 + i] * signoY
        }
        // Fila 2 = producto vectorial de las filas 0 y 1.
        val ax = salida[0]; val ay = salida[1]; val az = salida[2]
        val bx = salida[3]; val by = salida[4]; val bz = salida[5]
        salida[6] = ay * bz - az * by
        salida[7] = az * bx - ax * bz
        salida[8] = ax * by - ay * bx
    }

    /** Rotacion actual de la pantalla, para remapear los ejes del sensor. */
    private fun remapSegunPantalla(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return 0
        return when (display?.rotation) {
            Surface.ROTATION_90 -> 1
            Surface.ROTATION_180 -> 2
            Surface.ROTATION_270 -> 3
            else -> 0
        }
    }

    private fun getCurrent(result: MethodChannel.Result, timeoutMs: Long) {
        if (!hasLocationPermission()) {
            result.error(
                "SIN_PERMISO",
                "Falta el permiso de ubicacion",
                null
            )
            return
        }
        val provider = pickProvider()
        if (provider == null) {
            result.error("GPS_APAGADO", "La ubicacion esta desactivada en el dispositivo", null)
            return
        }

        // Se entrega la ultima posicion conocida de inmediato para no dejar
        // la app esperando al primer fix del GPS.
        lastKnown()?.let { map ->
            if (map["accuracy"] != null && (map["accuracy"] as Double) <= 500.0) {
                result.success(map)
                return
            }
        }

        val lm = locationManager ?: run {
            result.error("SIN_SISTEMA", "LocationManager no disponible", null)
            return
        }

        // El timeout y el fix del GPS pueden competir: solo se responde una
        // vez, o Flutter lanzaria "Reply already submitted".
        val answered = java.util.concurrent.atomic.AtomicBoolean(false)

        currentTimeout?.let(mainHandler::removeCallbacks)
        fun finish(map: Map<String, Any?>?) {
            if (!answered.compareAndSet(false, true)) return
            currentTimeout = null
            if (map != null) result.success(map)
            else result.error("SIN_FIX", "El GPS no devolvio una posicion a tiempo", null)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            lm.getCurrentLocation(
                provider,
                null,
                mainExecutor
            ) { location ->
                if (location != null) emit(location, MODO_FLOTA)
                finish(location?.let { toMap(it, MODO_FLOTA) } ?: lastKnown())
            }
            return
        }

        val oneShot = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                runCatching { lm.removeUpdates(this) }
                emit(location, MODO_FLOTA)
                finish(toMap(location, MODO_FLOTA))
            }

            override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }
        runCatching {
            lm.requestLocationUpdates(provider, 0L, 0f, oneShot, mainLooper)
        }.onFailure {
            finish(lastKnown())
            return
        }
        currentTimeout = Runnable {
            runCatching { lm.removeUpdates(oneShot) }
            finish(lastKnown())
        }.also { mainHandler.postDelayed(it, timeoutMs) }
    }

    private fun startUpdates(result: MethodChannel.Result, intervalMs: Long, minDistanceM: Double) {
        if (!hasLocationPermission()) {
            result.error("SIN_PERMISO", "Falta el permiso de ubicacion", null)
            return
        }
        val lm = locationManager
        val provider = pickProvider()
        if (lm == null || provider == null) {
            result.error("GPS_APAGADO", "La ubicacion esta desactivada en el dispositivo", null)
            return
        }
        stopUpdates()
        val l = object : LocationListener {
            override fun onLocationChanged(location: Location) = emit(location, MODO_FLOTA)
            override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
            override fun onProviderEnabled(p: String) {}
            override fun onProviderDisabled(p: String) {}
        }
        runCatching {
            lm.requestLocationUpdates(provider, intervalMs, minDistanceM.toFloat(), l, mainLooper)
        }.onSuccess { listener = l; result.success(true) }
            .onFailure { result.error("SIN_SISTEMA", it.message, null) }
    }

    /** Corta SOLO el GPS de modo flota. El de navegacion se corta en [stopNav]. */
    private fun stopUpdates() {
        listener?.let { l ->
            runCatching { locationManager?.removeUpdates(l) }
        }
        listener = null
        currentTimeout?.let(mainHandler::removeCallbacks)
        currentTimeout = null
    }
}