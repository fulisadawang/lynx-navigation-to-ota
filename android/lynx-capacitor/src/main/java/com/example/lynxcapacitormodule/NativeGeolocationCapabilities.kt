package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.util.WeakHashMap
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/** Android framework 的异步单次定位实现，不依赖 Google Play Services 或 Capacitor。 */
object NativeGeolocationCapabilities {
    private const val METHOD_CURRENT_POSITION = "getCurrentPosition"
    private const val DEFAULT_TIMEOUT_MS = 10_000L
    private const val MAX_TIMEOUT_MS = 60_000L

    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingRequests = WeakHashMap<Activity, PendingRequest>()

    /** 返回 true 表示认领 getCurrentPosition，并在定位回调或超时时完成一次。 */
    fun dispatch(
        activity: Activity,
        methodName: String,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ): Boolean {
        if (methodName != METHOD_CURRENT_POSITION) return false
        val run = Runnable {
            requestCurrentPosition(activity, options, complete)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run.run() else activity.runOnUiThread(run)
        return true
    }

    /** Activity 销毁时停止 LocationManager 回调，避免单例保留请求和 callback。 */
    fun release(activity: Activity) {
        val request = synchronized(lock) { pendingRequests.remove(activity) } ?: return
        request.cancel()
        request.completion.invoke(error("ACTIVITY_DESTROYED", "Activity 已销毁，定位请求已取消"))
    }

    private fun requestCurrentPosition(
        activity: Activity,
        options: JSONObject,
        complete: (JSONObject) -> Unit,
    ) {
        val completion = CompletionOnce(complete)
        if (!hasLocationPermission(activity)) {
            completion.invoke(error("PERMISSION_DENIED", "未授予定位权限"))
            return
        }

        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (manager == null) {
            completion.invoke(error("NO_PROVIDER", "LocationManager 不可用"))
            return
        }

        val highAccuracy = options.optBoolean("enableHighAccuracy", false)
        val providers = enabledProviders(activity, manager, highAccuracy)
        if (providers.isEmpty()) {
            completion.invoke(error("NO_PROVIDER", "没有可用的定位 provider"))
            return
        }

        val maximumAge = options.optLong("maximumAge", 0L).coerceAtLeast(0L)
        if (maximumAge > 0L) {
            val now = System.currentTimeMillis()
            providers.asSequence()
                .mapNotNull { provider -> runCatching { manager.getLastKnownLocation(provider) }.getOrNull() }
                .firstOrNull { now - it.time <= maximumAge }
                ?.let {
                    completion.invoke(locationResult(it))
                    return
                }
        }

        synchronized(lock) {
            if (pendingRequests.containsKey(activity)) {
                completion.invoke(error("LOCATION_REQUEST_IN_PROGRESS", "当前 Activity 已有定位请求未完成"))
                return
            }
        }

        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                finish(activity, locationResult(location))
            }

            override fun onProviderEnabled(provider: String) = Unit

            override fun onProviderDisabled(provider: String) = Unit

            @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
        }
        val timeoutMs = options.optLong("timeout", DEFAULT_TIMEOUT_MS)
            .takeIf { it > 0L }
            ?.coerceAtMost(MAX_TIMEOUT_MS)
            ?: DEFAULT_TIMEOUT_MS
        val request = PendingRequest(manager, listener, completion)

        synchronized(lock) {
            if (pendingRequests.containsKey(activity)) {
                completion.invoke(error("LOCATION_REQUEST_IN_PROGRESS", "当前 Activity 已有定位请求未完成"))
                return
            }
            pendingRequests[activity] = request
        }

        try {
            var requestedCount = 0
            providers.forEach { provider ->
                runCatching {
                    manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
                    requestedCount += 1
                }
            }
            if (requestedCount == 0) {
                synchronized(lock) { pendingRequests.remove(activity) }
                request.cancel()
                completion.invoke(error("LOCATION_REQUEST_FAILED", "无法向 Android LocationManager 注册定位回调"))
                return
            }
            val timeoutTask = Runnable {
                finish(
                    activity,
                    errorWithDetails(
                        "NO_LOCATION_FIX",
                        "Android LocationManager 在超时时间内没有返回位置",
                        JSONObject().put("providers", JSONArray(providers)).put("timeout", timeoutMs),
                    ),
                )
            }
            request.timeout = timeoutTask
            mainHandler.postDelayed(timeoutTask, timeoutMs)
        } catch (error: SecurityException) {
            synchronized(lock) { pendingRequests.remove(activity) }
            request.cancel()
            completion.invoke(error("PERMISSION_DENIED", error.message ?: "定位权限不可用"))
        } catch (error: RuntimeException) {
            synchronized(lock) { pendingRequests.remove(activity) }
            request.cancel()
            completion.invoke(error("LOCATION_REQUEST_FAILED", error.message ?: "无法发起定位请求"))
        }
    }

    private fun finish(activity: Activity, result: JSONObject) {
        val request = synchronized(lock) {
            pendingRequests.remove(activity)
        } ?: return
        request.cancel()
        request.completion.invoke(result)
    }

    private fun enabledProviders(context: Context, manager: LocationManager, highAccuracy: Boolean): List<String> {
        val result = mutableListOf<String>()
        val fine = hasLocationPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
        if (highAccuracy && fine && isEnabled(manager, LocationManager.GPS_PROVIDER)) {
            result += LocationManager.GPS_PROVIDER
        }
        if (isEnabled(manager, LocationManager.NETWORK_PROVIDER)) {
            result += LocationManager.NETWORK_PROVIDER
        }
        if (!highAccuracy && fine && isEnabled(manager, LocationManager.GPS_PROVIDER)) {
            result += LocationManager.GPS_PROVIDER
        }
        return result.distinct()
    }

    private fun isEnabled(manager: LocationManager, provider: String): Boolean =
        runCatching { manager.isProviderEnabled(provider) }.getOrDefault(false)

    private fun hasLocationPermission(activity: Activity): Boolean =
        hasLocationPermission(activity, Manifest.permission.ACCESS_FINE_LOCATION) ||
            hasLocationPermission(activity, Manifest.permission.ACCESS_COARSE_LOCATION)

    private fun hasLocationPermission(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun locationResult(location: Location): JSONObject = JSONObject()
        .put(
            "coords",
            JSONObject()
                .put("latitude", location.latitude)
                .put("longitude", location.longitude)
                .put("accuracy", location.accuracy.toDouble())
                .put("altitude", if (location.hasAltitude()) location.altitude else JSONObject.NULL)
                .put("altitudeAccuracy", JSONObject.NULL)
                .put("heading", if (location.hasBearing()) location.bearing.toDouble() else JSONObject.NULL)
                .put("speed", if (location.hasSpeed()) location.speed.toDouble() else JSONObject.NULL),
        )
        .put("timestamp", location.time)

    private class PendingRequest(
        private val manager: LocationManager,
        private val listener: LocationListener,
        val completion: CompletionOnce,
    ) {
        var timeout: Runnable? = null

        fun cancel() {
            timeout?.let(mainHandler::removeCallbacks)
            timeout = null
            runCatching { manager.removeUpdates(listener) }
        }
    }

    private class CompletionOnce(private val callback: (JSONObject) -> Unit) {
        private val finished = AtomicBoolean(false)

        fun invoke(result: JSONObject) {
            if (finished.compareAndSet(false, true)) callback(result)
        }
    }

    private fun error(code: String, message: String): JSONObject = JSONObject()
        .put("error", JSONObject().put("code", code).put("message", message))

    private fun errorWithDetails(code: String, message: String, details: JSONObject): JSONObject =
        error(code, message).put("details", details)
}
