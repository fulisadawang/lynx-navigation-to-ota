package com.example.lynxmap

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import com.amap.api.location.AMapLocation
import com.amap.api.location.AMapLocationClient
import com.amap.api.location.AMapLocationClientOption
import com.amap.api.location.AMapLocationListener
import com.lynx.jsbridge.LynxMethod
import com.lynx.jsbridge.LynxModule
import com.lynx.jsbridge.Arguments
import com.lynx.react.bridge.Callback
import com.lynx.react.bridge.JavaOnlyArray
import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.tasm.behavior.LynxContext
import org.json.JSONObject
import java.util.HashMap
import java.util.concurrent.atomic.AtomicLong

/** AMapLocationClient 的 Lynx 服务边界；所有回调都回到宿主 LynxView 的主线程。 */
class LynxMapLocationModule(context: Context) : LynxModule(context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var client: AMapLocationClient? = null
    private var pending: ((JavaOnlyMap) -> Unit)? = null
    private var continuous = false
    private var destroyed = false
    private val generation = AtomicLong(0)

    @LynxMethod
    fun getCurrentLocation(optionsJSON: String?, callback: Callback) {
        mainHandler.post {
            if (!ensureUsable(callback)) return@post
            val options = parseOptions(optionsJSON, callback) ?: return@post
            if (!ensurePermission(callback)) return@post
            runCatching {
                val locationClient = configuredClient(options)
                pending?.invoke(LynxMapResult.error(1207, "定位请求已取消"))
                pending = { value -> callback.invoke(value) }
                val requestGeneration = generation.incrementAndGet()
                locationClient.setLocationOption(options)
                locationClient.setLocationListener { location ->
                    mainHandler.post {
                        if (destroyed || requestGeneration != generation.get()) return@post
                        if (location == null || location.errorCode != 0) {
                            finishPending(LynxMapResult.error(
                                if (location == null) 1205 else 1206,
                                location?.errorInfo ?: "高德定位失败",
                            ))
                            return@post
                        }
                        if (!continuous) locationClient.stopLocation()
                        finishPending(LynxMapResult.success("定位成功", locationData(location)))
                        if (continuous) emit("lynxMapLocation", locationData(location))
                    }
                }
                locationClient.startLocation()
            }.onFailure { error ->
                finishPending(LynxMapResult.error(1206, error.message ?: "高德定位初始化失败"))
            }
        }
    }

    @LynxMethod
    fun startLocation(optionsJSON: String?, callback: Callback) {
        mainHandler.post {
            if (!ensureUsable(callback)) return@post
            val options = parseOptions(optionsJSON, callback) ?: return@post
            if (!ensurePermission(callback)) return@post
            runCatching {
                val locationClient = configuredClient(options)
                continuous = true
                locationClient.setLocationOption(options)
                locationClient.setLocationListener { location ->
                    if (destroyed || !continuous) return@setLocationListener
                    mainHandler.post {
                        if (destroyed || !continuous) return@post
                        if (location == null || location.errorCode != 0) {
                            emit(
                                "lynxMapLocationError",
                                mapOf(
                                    "code" to "LOCATION_PROVIDER_ERROR",
                                    "message" to (location?.errorInfo ?: "连续定位失败"),
                                    "providerCode" to (location?.errorCode ?: -1),
                                ),
                            )
                        } else {
                            emit("lynxMapLocation", locationData(location))
                        }
                    }
                }
                locationClient.startLocation()
                callback.invoke(LynxMapResult.success("连续定位已启动", mapOf("status" to "running")))
            }.onFailure { error ->
                callback.invoke(LynxMapResult.error(1206, error.message ?: "高德定位初始化失败"))
            }
        }
    }

    @LynxMethod
    fun stopLocation(callback: Callback) {
        mainHandler.post {
            if (destroyed) {
                callback.invoke(LynxMapResult.error(1207, "定位服务实例已销毁"))
                return@post
            }
            continuous = false
            generation.incrementAndGet()
            client?.stopLocation()
            finishPending(LynxMapResult.error(1207, "定位请求已取消"))
            callback.invoke(LynxMapResult.success("定位已停止", mapOf("status" to "stopped")))
        }
    }

    @LynxMethod
    fun getAuthorizationStatus(callback: Callback) {
        mainHandler.post {
            val context = hostContext()
            val fine = hasPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = hasPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
            val activity = context.findActivity()
            val status = when {
                fine || coarse -> "authorizedWhenInUse"
                activity?.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION) == true -> "denied"
                else -> "notDetermined"
            }
            val accuracy = if (fine) "full" else if (coarse) "reduced" else "unknown"
            val servicesEnabled = (context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)
                ?.let { manager ->
                    runCatching {
                        manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
                    }.getOrDefault(false)
                } ?: false
            callback.invoke(
                LynxMapResult.success(
                    "定位权限状态已获取",
                    mapOf("status" to status, "accuracy" to accuracy, "servicesEnabled" to servicesEnabled),
                ),
            )
        }
    }

    override fun destroy() {
        mainHandler.post {
            destroyed = true
            continuous = false
            generation.incrementAndGet()
            client?.stopLocation()
            client?.unRegisterLocationListener(locationListener)
            client?.onDestroy()
            client = null
            finishPending(LynxMapResult.error(1207, "定位请求已取消"))
        }
        super.destroy()
    }

    private var locationListener: AMapLocationListener? = null

    private fun configuredClient(options: AMapLocationClientOption): AMapLocationClient {
        val value = client ?: AMapLocationClient(hostContext()).also { client = it }
        value.setLocationOption(options)
        return value
    }

    private fun parseOptions(optionsJSON: String?, callback: Callback): AMapLocationClientOption? {
        val json = optionsJSON?.trim().orEmpty()
        val objectValue = runCatching { if (json.isEmpty()) JSONObject() else JSONObject(json) }.getOrElse {
            callback.invoke(LynxMapResult.error(1201, "定位 options 必须是 JSON Object"))
            return null
        }
        val locationTimeout = objectValue.optInt("locationTimeout", 8)
        val reGeocodeTimeout = objectValue.optInt("reGeocodeTimeout", 5)
        val desiredAccuracy = objectValue.optDouble("desiredAccuracy", 100.0)
        val distanceFilter = objectValue.optDouble("distanceFilter", -1.0)
        if (locationTimeout !in 2..60 || reGeocodeTimeout !in 2..60 ||
            !desiredAccuracy.isFinite() || desiredAccuracy < 1 || desiredAccuracy > 10_000 ||
            (!distanceFilter.isFinite() || (distanceFilter != -1.0 && (distanceFilter < 0 || distanceFilter > 10_000)))) {
            callback.invoke(LynxMapResult.error(1201, "定位 options 超出允许范围"))
            return null
        }
        return AMapLocationClientOption().apply {
            isOnceLocation = true
            isOnceLocationLatest = true
            isNeedAddress = objectValue.optBoolean("withReGeocode", false)
            httpTimeOut = locationTimeout * 1000L
            interval = (distanceFilter.takeIf { it >= 0 } ?: 1000.0).toLong().coerceAtLeast(500L)
            locationMode = AMapLocationClientOption.AMapLocationMode.Hight_Accuracy
        }
    }

    private fun ensureUsable(callback: Callback): Boolean {
        if (destroyed) {
            callback.invoke(LynxMapResult.error(1207, "定位服务实例已销毁"))
            return false
        }
        if (!LynxMapRuntime.isConfigured()) {
            callback.invoke(LynxMapResult.error(1202, "高德定位隐私配置未完成"))
            return false
        }
        return true
    }

    private fun ensurePermission(callback: Callback): Boolean {
        val context = hostContext()
        if (hasPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
            hasPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)) return true
        context.findActivity()?.requestPermissions(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            LOCATION_PERMISSION_REQUEST_CODE,
        )
        callback.invoke(LynxMapResult.error(1204, "应用没有定位权限，请允许后重试"))
        return false
    }

    private fun finishPending(result: JavaOnlyMap) {
        val completion = pending ?: return
        pending = null
        completion(result)
    }

    private fun locationData(location: AMapLocation): Map<String, Any> = buildMap {
        put("latitude", location.latitude)
        put("longitude", location.longitude)
        put("timestamp", location.time)
        if (location.accuracy >= 0f) put("accuracy", location.accuracy)
        if (location.altitude.isFinite()) put("altitude", location.altitude)
        if (location.speed >= 0f) put("speed", location.speed)
        if (location.bearing >= 0f) put("course", location.bearing)
        if (!location.address.isNullOrBlank()) put("reGeocode", mapOf("formattedAddress" to location.address))
    }

    private fun emit(name: String, payload: Map<String, Any>) {
        val view = (mContext as? LynxContext)?.lynxView ?: return
        val values = HashMap(payload)
        view.sendGlobalEvent(name, JavaOnlyArray.of(Arguments.makeNativeMap(values)))
    }

    private fun hostContext(): Context {
        val lynxContext = mContext as? LynxContext
        return lynxContext?.context ?: mContext
    }

    private fun Context.findActivity(): Activity? {
        var current: Context? = this
        while (current is ContextWrapper) {
            if (current is Activity) return current
            current = current.baseContext
        }
        return current as? Activity
    }

    private fun hasPermission(context: Context, permission: String): Boolean =
        android.os.Build.VERSION.SDK_INT < 23 ||
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val LOCATION_PERMISSION_REQUEST_CODE = 17431
    }
}
