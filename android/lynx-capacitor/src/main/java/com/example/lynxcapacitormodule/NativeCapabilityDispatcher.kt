package com.example.lynxcapacitormodule

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import androidx.core.content.ContextCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.io.File
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** 把自有 Module 协议映射到 Android framework；不依赖 Capacitor runtime/plugin。 */
object NativeCapabilityDispatcher {
    fun requiresBackground(pluginId: String, methodName: String): Boolean =
        (pluginId == "CapacitorHttp" && methodName in setOf("request", "get", "post")) ||
            (pluginId == "CapacitorSQLite" && methodName !in setOf("echo", "isAvailable"))

    fun dispatch(activity: Activity, pluginId: String, methodName: String, options: JSONObject): JSONObject {
        if (methodName == "checkPermissions") {
            NativePermissionCoordinator.check(activity, pluginId, options)?.let { return it }
        }
        NativeMediaCapabilities.dispatch(activity, pluginId, methodName, options)?.let { return it }
        NativeProviderCapabilities.dispatch(activity, pluginId, methodName, options)?.let { return it }
        NativeHapticsCapabilities.dispatch(activity, pluginId, methodName, options)?.let { return it }
        NativeToastCapabilities.dispatch(activity, pluginId, methodName, options)?.let { return it }
        NativeSystemCapabilities.dispatch(activity, pluginId, methodName, options)?.let { return it }
        NativeDatabaseCapabilities.dispatch(activity, pluginId, methodName, options)?.let { return it }
        if (pluginId == "Motion") {
            NativeMotionCapabilities.dispatch(activity, methodName, options)?.let { return it }
        }

        val spec = NativeCapabilityCatalog.find(pluginId)
            ?: return failure("UNIMPLEMENTED", "Unknown native capability: $pluginId")
        if (methodName !in spec.implementedMethods) {
            return failure("UNSUPPORTED", "$pluginId.$methodName 尚未接入当前 Android Module")
        }

        return runCatching {
            when (pluginId) {
                "Device" -> device(activity, methodName)
                "App" -> app(activity, methodName)
                "AppLauncher" -> appLauncher(activity, methodName, options)
                "Preferences" -> preferences(activity, methodName, options)
                "Share" -> share(activity, methodName)
                "Clipboard" -> clipboard(activity, methodName, options)
                "Filesystem" -> filesystem(activity, methodName, options)
                "Camera" -> permissions(activity, Manifest.permission.CAMERA, "camera")
                "Geolocation" -> geolocationPermissions(activity)
                "Network" -> network(activity)
                "StatusBar" -> statusBar(activity, methodName, options)
                "SystemBars" -> systemBars(activity, options)
                "ScreenOrientation" -> screenOrientation(activity)
                "ScreenReader" -> screenReader(activity)
                "TextZoom" -> textZoom(activity)
                "Keyboard" -> keyboard(activity, methodName)
                "SplashScreen" -> JSONObject().put("hidden", methodName == "hide")
                "PrivacyScreen" -> privacyScreen(activity, methodName)
                "KeepAwake" -> keepAwake(activity, methodName)
                "SafeArea" -> safeArea(activity, methodName, options)
                "LocalNotifications", "PushNotifications" -> notificationPermissions(activity)
                "CapacitorSQLite" -> sqlite(methodName, options)
                else -> failure("UNSUPPORTED", "$pluginId.$methodName 尚未接入当前 Android Module")
            }
        }.getOrElse { error ->
            failure("NATIVE_ERROR", error.message ?: "Android native call failed")
        }
    }

    private fun device(context: Context, method: String): JSONObject = when (method) {
        "getInfo" -> JSONObject()
            .put("model", Build.MODEL)
            .put("platform", "android")
            .put("operatingSystem", "android")
            .put("osVersion", Build.VERSION.RELEASE ?: "unknown")
            .put("manufacturer", Build.MANUFACTURER)
            .put("isVirtual", isVirtualDevice())
            .put("webViewVersion", JSONObject.NULL)
        "getId" -> JSONObject().put(
            "identifier",
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: "unknown",
        )
        "getBatteryInfo" -> {
            val manager = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            val level = manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            JSONObject()
                .put("batteryLevel", if (level in 0..100) level / 100.0 else JSONObject.NULL)
                .put("isCharging", if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) manager.isCharging else JSONObject.NULL)
        }
        "getLanguageCode" -> JSONObject().put("value", Locale.getDefault().language)
        "getLanguageTag" -> JSONObject().put("value", Locale.getDefault().toLanguageTag())
        else -> failure("UNSUPPORTED", "Device.$method 尚未接入当前 Android Module")
    }

    private fun app(activity: Activity, method: String): JSONObject = when (method) {
        "getInfo" -> {
            val packageInfo = activity.packageManager.getPackageInfo(activity.packageName, 0)
            JSONObject()
                .put("name", activity.applicationInfo.loadLabel(activity.packageManager).toString())
                .put("id", activity.packageName)
                .put("version", packageInfo.versionName ?: "")
                .put("build", if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) packageInfo.longVersionCode else packageInfo.versionCode.toLong())
        }
        "getState" -> JSONObject().put("isActive", !activity.isFinishing && !activity.isDestroyed)
        "getLaunchUrl" -> JSONObject().put("url", activity.intent?.dataString ?: JSONObject.NULL)
        else -> failure("UNSUPPORTED", "App.$method 尚未接入当前 Android Module")
    }

    private fun appLauncher(activity: Activity, method: String, options: JSONObject): JSONObject {
        val url = options.optString("url").trim()
        if (url.isEmpty()) return failure("INVALID_ARGUMENT", "url 不能为空")
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        return when (method) {
            "canOpenUrl" -> JSONObject().put("value", intent.resolveActivity(activity.packageManager) != null)
            "openUrl" -> {
                activity.startActivity(intent)
                JSONObject().put("opened", true)
            }
            else -> failure("UNSUPPORTED", "AppLauncher.$method 尚未接入当前 Android Module")
        }
    }

    private fun preferences(context: Context, method: String, options: JSONObject): JSONObject {
        val prefs = context.getSharedPreferences("lynx-native-capabilities", Context.MODE_PRIVATE)
        val key = options.optString("key")
        if (key.isEmpty() && method != "keys") return failure("INVALID_ARGUMENT", "key 不能为空")
        return when (method) {
            "set" -> {
                prefs.edit().putString(key, options.optString("value")).apply()
                JSONObject().put("saved", true)
            }
            "get" -> JSONObject().put("value", if (prefs.contains(key)) prefs.getString(key, null) else JSONObject.NULL)
            "keys" -> JSONObject().put("keys", JSONArray(prefs.all.keys.toList()))
            "remove" -> {
                prefs.edit().remove(key).apply()
                JSONObject().put("removed", true)
            }
            else -> failure("UNSUPPORTED", "Preferences.$method 尚未接入当前 Android Module")
        }
    }

    private fun share(activity: Activity, method: String): JSONObject = when (method) {
        "canShare" -> JSONObject().put(
            "value",
            Intent(Intent.ACTION_SEND).apply { type = "text/plain" }.resolveActivity(activity.packageManager) != null,
        )
        else -> failure("UNSUPPORTED", "Share.$method 尚未接入当前 Android Module")
    }

    private fun clipboard(activity: Activity, method: String, options: JSONObject): JSONObject {
        val manager = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        return when (method) {
            "write" -> {
                val value = options.optString("string", options.optString("text", ""))
                manager.setPrimaryClip(ClipData.newPlainText("lynx", value))
                JSONObject().put("written", true)
            }
            "read" -> {
                val clip = manager.primaryClip
                val value = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).coerceToText(activity).toString() else ""
                JSONObject().put("type", "text").put("value", value)
            }
            else -> failure("UNSUPPORTED", "Clipboard.$method 尚未接入当前 Android Module")
        }
    }

    private fun filesystem(activity: Activity, method: String, options: JSONObject): JSONObject {
        val root = activity.cacheDir.canonicalFile
        val relativePath = options.optString("path").trim().removePrefix("/")
        val target = File(root, relativePath).canonicalFile
        if (!target.path.startsWith(root.path)) return failure("INVALID_ARGUMENT", "path 越界")
        return when (method) {
            "writeFile" -> {
                target.parentFile?.mkdirs()
                target.writeText(options.optString("data"))
                JSONObject().put("uri", target.toURI().toString())
            }
            "readFile" -> JSONObject().put("data", target.readText())
            "readdir" -> JSONObject().put("files", filesJson(target))
            "stat" -> if (target.exists()) fileSummary(target) else failure("NOT_FOUND", "文件不存在: $relativePath")
            "mkdir" -> JSONObject().put("created", target.mkdirs() || target.isDirectory)
            "getUri" -> JSONObject().put("uri", target.toURI().toString())
            else -> failure("UNSUPPORTED", "Filesystem.$method 尚未接入当前 Android Module")
        }
    }

    private fun filesJson(directory: File): JSONArray {
        val result = JSONArray()
        if (directory.isDirectory) directory.listFiles()?.forEach { result.put(fileSummary(it)) }
        return result
    }

    private fun fileSummary(file: File): JSONObject = JSONObject()
        .put("name", file.name)
        .put("type", if (file.isDirectory) "directory" else "file")
        .put("size", if (file.isFile) file.length() else 0)
        .put("uri", file.toURI().toString())

    private fun permissions(activity: Activity, permission: String, key: String): JSONObject = JSONObject()
        .put(key, permissionState(activity, permission))

    private fun geolocationPermissions(activity: Activity): JSONObject = JSONObject()
        .put("location", when {
            hasPermission(activity, Manifest.permission.ACCESS_FINE_LOCATION) -> "granted"
            hasPermission(activity, Manifest.permission.ACCESS_COARSE_LOCATION) -> "granted"
            else -> "denied"
        })

    private fun notificationPermissions(activity: Activity): JSONObject = JSONObject()
        .put("notifications", if (Build.VERSION.SDK_INT < 33 || hasPermission(activity, Manifest.permission.POST_NOTIFICATIONS)) "granted" else "denied")

    private fun network(activity: Activity): JSONObject {
        val manager = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val capabilities = manager.activeNetwork?.let(manager::getNetworkCapabilities)
        val type = when {
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "wifi"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "cellular"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "ethernet"
            capabilities != null -> "other"
            else -> "none"
        }
        return JSONObject().put("connected", capabilities != null).put("connectionType", type)
    }

    private fun statusBar(activity: Activity, method: String, options: JSONObject): JSONObject = when (method) {
        "getInfo" -> JSONObject()
            .put("visible", activity.window.decorView.systemUiVisibility and ViewFlags.FULLSCREEN == 0)
            .put("style", options.optString("style", "DEFAULT"))
        "setStyle" -> setBarsStyle(activity, options.optString("style", "DEFAULT"))
        "hide" -> {
            activity.window.decorView.systemUiVisibility = activity.window.decorView.systemUiVisibility or ViewFlags.FULLSCREEN
            JSONObject().put("visible", false)
        }
        "show" -> {
            activity.window.decorView.systemUiVisibility = activity.window.decorView.systemUiVisibility and ViewFlags.FULLSCREEN.inv()
            JSONObject().put("visible", true)
        }
        else -> failure("UNSUPPORTED", "StatusBar.$method 尚未接入当前 Android Module")
    }

    private fun systemBars(activity: Activity, options: JSONObject): JSONObject = setBarsStyle(activity, options.optString("style", "DEFAULT"))

    private fun setBarsStyle(activity: Activity, style: String): JSONObject {
        val normalized = style.uppercase(Locale.US)
        val light = normalized == "LIGHT"
        val controller = WindowInsetsControllerCompat(activity.window, activity.window.decorView)
        controller.isAppearanceLightStatusBars = light
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) controller.isAppearanceLightNavigationBars = light
        return JSONObject().put("style", normalized)
    }

    private fun screenOrientation(activity: Activity): JSONObject = JSONObject().put(
        "type",
        if (activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) "landscape" else "portrait",
    )

    private fun screenReader(activity: Activity): JSONObject {
        val manager = activity.getSystemService(Context.ACCESSIBILITY_SERVICE) as android.view.accessibility.AccessibilityManager
        return JSONObject().put("value", manager.isEnabled)
    }

    private fun textZoom(activity: Activity): JSONObject = JSONObject().put("value", activity.resources.configuration.fontScale.toDouble())

    private fun keyboard(activity: Activity, method: String): JSONObject = when (method) {
        "getResizeMode" -> {
            val mode = activity.window.attributes.softInputMode and WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST
            JSONObject().put("mode", when (mode) {
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE -> "resize"
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_PAN -> "pan"
                else -> "native"
            })
        }
        "hide" -> {
            val manager = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            manager.hideSoftInputFromWindow(activity.window.decorView.windowToken, 0)
            JSONObject().put("hidden", true)
        }
        else -> failure("UNSUPPORTED", "Keyboard.$method 尚未接入当前 Android Module")
    }

    private fun privacyScreen(activity: Activity, method: String): JSONObject = when (method) {
        "isEnabled" -> JSONObject().put("value", activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        "enable" -> {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            JSONObject().put("value", true)
        }
        "disable" -> {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            JSONObject().put("value", false)
        }
        else -> failure("UNSUPPORTED", "PrivacyScreen.$method 尚未接入当前 Android Module")
    }

    private fun keepAwake(activity: Activity, method: String): JSONObject = when (method) {
        "isSupported" -> JSONObject().put("value", true)
        "isKeptAwake" -> JSONObject().put("value", activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0)
        "keepAwake" -> {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            JSONObject().put("value", true)
        }
        "allowSleep" -> {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            JSONObject().put("value", false)
        }
        else -> failure("UNSUPPORTED", "KeepAwake.$method 尚未接入当前 Android Module")
    }

    private fun safeArea(activity: Activity, method: String, options: JSONObject): JSONObject = when (method) {
        "setSystemBarsStyle" -> setBarsStyle(activity, options.optString("style", "DEFAULT"))
        "hideSystemBars" -> statusBar(activity, "hide", options)
        "showSystemBars" -> statusBar(activity, "show", options)
        else -> failure("UNSUPPORTED", "SafeArea.$method 尚未接入当前 Android Module")
    }

    private fun sqlite(method: String, options: JSONObject): JSONObject = when (method) {
        "echo" -> JSONObject().put("value", options.optString("value"))
        "isAvailable" -> JSONObject().put("result", true)
        else -> failure("UNSUPPORTED", "CapacitorSQLite.$method 尚未接入当前 Android Module")
    }

    private fun permissionState(activity: Activity, permission: String): String = if (hasPermission(activity, permission)) "granted" else "denied"

    private fun hasPermission(activity: Activity, permission: String): Boolean =
        ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED

    private fun isVirtualDevice(): Boolean {
        val fingerprint = Build.FINGERPRINT.lowercase(Locale.US)
        val model = Build.MODEL.lowercase(Locale.US)
        return fingerprint.contains("generic") || fingerprint.contains("emulator") || model.contains("sdk") || model.contains("emulator")
    }

    private fun failure(code: String, message: String): JSONObject = JSONObject()
        .put("success", false)
        .put("error", JSONObject().put("code", code).put("message", message))

    private object ViewFlags {
        const val FULLSCREEN: Int = 0x00000004
    }
}
