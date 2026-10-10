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
            "startNav" -> startNav(result)
            "stopNav" -> {
                stopNav()
                result.success(true)
            }
            "hasHeadingSensor" -> result.success(tieneSensorRumbo())

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
        return toMap(best)
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
    private fun toMap(location: Location): Map<String, Any?> = mapOf(
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
        "mocked" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
            location.isFromMockProvider
        } else {
            false
        }
    )

    private fun emit(location: Location) {
        lastFix.set(location)

        // En modo navegacion se lleva la cuenta de si el vehiculo se mueve, para
        // poder pausar el GPS en un semaforo. Se hace aqui y no en el listener
        // para que cuente tambien la posicion puntual de `getCurrent`.
        if (navActivo && location.hasSpeed() && location.speed >= VELOCIDAD_PARADO_MPS) {
            ultimoEnMarchaMs = SystemClock.elapsedRealtime()
        }

        channel?.invokeMethod("onLocation", toMap(location))
    }

    // ---------------- MODO NAVEGACION ----------------

    /**
     * Arranca el GPS a 1 Hz y registra el sensor de rumbo.
     *
     * Es un camino separado de [startUpdates] a proposito: el modo flota
     * (10 s / 20 m) sirve para refrescar la posicion que ve el backend y no
     * debe cambiar de comportamiento al añadir navegacion.
     */
    private fun startNav(result: MethodChannel.Result) {
        android.util.Log.i("RapiTaxi", "startNav: permiso=${hasLocationPermission()} sensor=${mejorSensorRumbo()?.name}")
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
        // la posicion llega a 1 Hz (suficiente para el mapa) y el sensor de
        // rumbo, que va a ~50 Hz, es lo que aporta la fluidez.
        reanudarNavegacion()

        registrarSensorRumbo()

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
            override fun onLocationChanged(location: Location) = emit(location)
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
        listenerNav?.let { runCatching { locationManager?.removeUpdates(it) } }
        listenerNav = null
        detenerDetector()
        sensorManager?.unregisterListener(sensorListener)
        sensorListener = null
    }

    // ---------------- SENSOR DE RUMBO ----------------

    /**
     * Elige el mejor sensor de rumbo disponible, en este orden.
     *
     *  1. `TYPE_GAME_ROTATION_VECTOR`: giroscopio + acelerometro, SIN magnetometro.
     *     Es el unico que sirve en un taxi, porque los imanes de la carroceria
     *     desvian la brujula magnetica de forma constante.
     *  2. `TYPE_ROTATION_VECTOR`: idem pero con magnetometro, degrada si el
     *     magnetometro esta sucio.
     *  3. `TYPE_MAGNETIC_FIELD` + `TYPE_ACCELEROMETER`: montaje manual de la
     *     matriz. Ultimo recurso.
     *
     * `location.bearing` del GPS NO se usa como sensor: es dead-reckoning y en
     * conduccion urbana suele devolver 0 o valores que cambian sin rumbo real.
     */
    private fun mejorSensorRumbo(): Sensor? {
        val sm = sensorManager ?: return null
        return sm.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?: sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            ?: sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)
    }

    private fun tieneSensorRumbo(): Boolean = mejorSensorRumbo() != null

    private fun registrarSensorRumbo() {
        val sm = sensorManager ?: return
        sm.unregisterListener(sensorListener)

        val sensor = mejorSensorRumbo() ?: run {
            android.util.Log.w("RapiTaxi", "registrarSensorRumbo: el dispositivo NO tiene sensor de rumbo")
            return
        }
        val necesitaAcelerometro =
            sensor.type == Sensor.TYPE_MAGNETIC_FIELD

        val l = object : SensorEventListener {
            private val matriz = FloatArray(9)
            private val matrizRemapeada = FloatArray(9)
            private val orientacion = FloatArray(3)

            override fun onSensorChanged(event: SensorEvent) {
                if (event.values.size < 3) return
                SensorManager.getRotationMatrixFromVector(matriz, event.values)

                // El azimut depende de los ejes que se eligen como referencia.
                //
                // Sin remapear, `getOrientation` mide el azimut sobre el eje Y del
                // telefono (la "arriba" de la pantalla), que en vertical apunta al
                // cielo: el resultado sale 90 grados desviado. La referencia
                // correcta en vertical es la X del telefono (su ejederecho) y la
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
                remapParaAzimut(matriz, matrizRemapeada, ejeX, ejeY, signoX, signoY)
                SensorManager.getOrientation(matrizRemapeada, orientacion)

                // orientacion[0] es el azimut en RADIANES, 0 = norte y growing en
                // sentido horario, que es justo lo que espera el `bearing` de
                // MapLibre. Se convierte a grados al mandar.
                val azimut = Math.toDegrees(orientacion[0].toDouble())
                channel?.invokeMethod(
                    "onHeading",
                    mapOf(
                        "bearing" to ((azimut % 360.0 + 360.0) % 360.0),
                        "accuracyRad" to Math.toDegrees(orientacion[2].toDouble()).toFloat(),
                        "elapsedRealtimeMs" to SystemClock.elapsedRealtime()
                    )
                )
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }

        // SENSOR_DELAY_GAME son ~50 Hz: suficiente para que el mapa gire sin
        // tirones sin gastar mas de lo necesario en un taxi durante un viaje.
        sm.registerListener(l, sensor, SensorManager.SENSOR_DELAY_GAME)
        sensorListener = l

        if (necesitaAcelerometro) {
            // El montage manual necesita tambien el acelerometro.
            sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
                sm.registerListener(l, it, SensorManager.SENSOR_DELAY_GAME)
            }
        }
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
                if (location != null) emit(location)
                finish(location?.let { toMap(it) } ?: lastKnown())
            }
            return
        }

        val oneShot = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                runCatching { lm.removeUpdates(this) }
                emit(location)
                finish(toMap(location))
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
            override fun onLocationChanged(location: Location) = emit(location)
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
