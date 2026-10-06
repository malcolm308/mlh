package com.taxirapid.taxi_client

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
    }

    private var channel: MethodChannel? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lastFix = AtomicReference<Location?>(null)
    private var listener: LocationListener? = null
    private var currentTimeout: Runnable? = null

    private val locationManager: LocationManager?
        get() = getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result -> onCall(call, result) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stopUpdates()
        channel?.setMethodCallHandler(null)
        channel = null
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

    private fun toMap(location: Location): Map<String, Any?> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracy" to location.accuracy.toDouble(),
        "timestamp" to location.time
    )

    private fun emit(location: Location) {
        lastFix.set(location)
        channel?.invokeMethod("onLocation", toMap(location))
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

    private fun stopUpdates() {
        listener?.let { l ->
            runCatching { locationManager?.removeUpdates(l) }
        }
        listener = null
        currentTimeout?.let(mainHandler::removeCallbacks)
        currentTimeout = null
    }
}

