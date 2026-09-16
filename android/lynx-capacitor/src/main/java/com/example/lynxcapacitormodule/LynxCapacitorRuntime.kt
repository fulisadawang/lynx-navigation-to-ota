package com.example.lynxcapacitormodule

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.lynx.react.bridge.Callback
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
import org.json.JSONObject

/**
 * 当前 worktree 自有的原生能力运行时。
 *
 * 这里不创建 Capacitor Bridge，也不注册 Capacitor Plugin。页面传入的
 * pluginId/methodName/options 由 NativeCapabilityDispatcher 直接映射到 Android API。
 */
object LynxCapacitorRuntime : Application.ActivityLifecycleCallbacks {
    private const val TAG = "LynxNativeModule"
    private const val MODULE_ERROR = "MODULE_UNAVAILABLE"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val currentActivity = AtomicReference<Activity?>(null)
    @Volatile private var eventSender: ((String) -> Unit)? = null
    private var installed = false

    @Synchronized
    fun install(app: Application) {
        if (installed) return
        app.registerActivityLifecycleCallbacks(this)
        installed = true
    }

    fun handleCall(payload: String, callback: Callback) {
        val request = runCatching { JSONObject(payload) }.getOrElse { error ->
            callback.invoke(
                errorEnvelope(
                    callbackId = "-1",
                    pluginId = "",
                    methodName = "",
                    message = "Invalid bridge payload: ${error.message}",
                    code = "INVALID_PAYLOAD",
                ).toString(),
            )
            return
        }
        val pluginValue = request.opt("pluginId")
        val methodValue = request.opt("methodName")
        val pluginId = (pluginValue as? String)?.trim().orEmpty()
        val methodName = (methodValue as? String)?.trim().orEmpty()
        val invalidIdentityType = (pluginValue != null && pluginValue !== JSONObject.NULL && pluginValue !is String) ||
            (methodValue != null && methodValue !== JSONObject.NULL && methodValue !is String)
        val callbackValue = request.opt("callbackId")
        val callbackId = when {
            !request.has("callbackId") || request.isNull("callbackId") -> "-1"
            callbackValue is String && callbackValue.trim().isNotEmpty() -> callbackValue.trim()
            else -> {
                callback.invoke(
                    errorEnvelope(
                        callbackId = "-1",
                        pluginId = pluginId,
                        methodName = methodName,
                        message = "callbackId 必须是非空字符串，缺省或 null 才使用 -1",
                        code = "INVALID_ARGUMENT",
                    ).toString(),
                )
                return
            }
        }
        if (invalidIdentityType || pluginId.isEmpty() || methodName.isEmpty()) {
            callback.invoke(
                errorEnvelope(
                    callbackId = callbackId,
                    pluginId = pluginId,
                    methodName = methodName,
                    message = "pluginId 和 methodName 必须是非空字符串",
                    code = "INVALID_ARGUMENT",
                ).toString(),
            )
            return
        }
        val options = when {
            !request.has("options") || request.isNull("options") -> JSONObject()
            request.opt("options") is JSONObject -> request.getJSONObject("options")
            else -> {
                callback.invoke(
                    errorEnvelope(
                        callbackId = callbackId,
                        pluginId = pluginId,
                        methodName = methodName,
                        message = "options 必须是 JSON 对象",
                        code = "INVALID_ARGUMENT",
                    ).toString(),
                )
                return
            }
        }
        // 在读取 Activity 前先执行公共目录闸门，保证无宿主上下文时未知调用也不会伪装成可用能力。
        val spec = NativeCapabilityCatalog.find(pluginId)
        if (spec == null) {
            callback.invoke(
                errorEnvelope(
                    callbackId = callbackId,
                    pluginId = pluginId,
                    methodName = methodName,
                    message = "Unknown native capability: $pluginId",
                    code = "UNIMPLEMENTED",
                ).toString(),
            )
            return
        }
        if (methodName !in spec.methods) {
            callback.invoke(
                errorEnvelope(
                    callbackId = callbackId,
                    pluginId = pluginId,
                    methodName = methodName,
                    message = "Method $methodName is not registered on $pluginId",
                    code = "UNIMPLEMENTED",
                ).toString(),
            )
            return
        }
        if (methodName !in spec.implementedMethods) {
            callback.invoke(
                errorEnvelope(
                    callbackId = callbackId,
                    pluginId = pluginId,
                    methodName = methodName,
                    message = "$pluginId.$methodName 尚未接入当前 Android Module",
                    code = "UNSUPPORTED",
                ).toString(),
            )
            return
        }
        val activity = currentActivity.get()
        Log.i(TAG, "HANDLE_CALL $pluginId.$methodName activity=${activity?.javaClass?.name}")
        if (activity == null) {
            callback.invoke(
                errorEnvelope(
                    callbackId = callbackId,
                    pluginId = pluginId,
                    methodName = methodName,
                    message = "No Android Activity is available",
                    code = MODULE_ERROR,
                ).toString(),
            )
            return
        }

        if (methodName == "requestPermissions") {
            mainHandler.post {
                val claimed = NativePermissionCoordinator.request(
                    activity,
                    pluginId,
                    methodName,
                    options,
                ) { result ->
                    deliver(callback, callbackId, pluginId, methodName, result)
                }
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (pluginId == "Dialog" || pluginId == "ActionSheet") {
            mainHandler.post {
                val claimed = NativeInteractiveCapabilities.dispatch(
                    activity,
                    pluginId,
                    methodName,
                    options,
                ) { result ->
                    deliver(callback, callbackId, pluginId, methodName, result)
                }
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (pluginId == "Audio") {
            mainHandler.post {
                val claimed = NativeAudioCapabilities.dispatch(
                    activity,
                    methodName,
                    options,
                ) { result ->
                    deliver(callback, callbackId, pluginId, methodName, result)
                }
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (pluginId == "FileTransfer") {
            mainHandler.post {
                val claimed = NativeFileTransferCapabilities.dispatch(
                    activity,
                    methodName,
                    options,
                    complete = { result ->
                        deliver(callback, callbackId, pluginId, methodName, result)
                    },
                    eventSender = eventSender,
                )
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (pluginId == "LocalNotifications" && methodName !in setOf("checkPermissions", "requestPermissions")) {
            mainHandler.post {
                val claimed = NativeLocalNotificationCapabilities.dispatch(
                    activity,
                    methodName,
                    options,
                ) { result ->
                    deliver(callback, callbackId, pluginId, methodName, result)
                }
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (pluginId == "Camera" && methodName in setOf("getPhoto", "pickImages", "chooseFromGallery", "takePhoto")) {
            mainHandler.post {
                val claimed = NativeCameraCaptureCapabilities.dispatch(
                    activity,
                    methodName,
                    options,
                ) { result ->
                    deliver(callback, callbackId, pluginId, methodName, result)
                }
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (pluginId == "Camera" && methodName in setOf("recordVideo", "playVideo")) {
            mainHandler.post {
                val claimed = NativeVideoCaptureCapabilities.dispatch(
                    activity,
                    methodName,
                    options,
                ) { result ->
                    deliver(callback, callbackId, pluginId, methodName, result)
                }
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (pluginId == "Geolocation" && methodName == "getCurrentPosition") {
            mainHandler.post {
                val claimed = NativeGeolocationCapabilities.dispatch(
                    activity,
                    methodName,
                    options,
                ) { result ->
                    deliver(callback, callbackId, pluginId, methodName, result)
                }
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (pluginId == "CapacitorBarcodeScanner" && methodName == "scanBarcode") {
            mainHandler.post {
                val claimed = NativeBarcodeCapabilities.dispatch(
                    activity,
                    methodName,
                    options,
                ) { result ->
                    deliver(callback, callbackId, pluginId, methodName, result)
                }
                if (!claimed) {
                    deliver(
                        callback,
                        callbackId,
                        pluginId,
                        methodName,
                        NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                    )
                }
            }
            return
        }

        if (NativeCapabilityDispatcher.requiresBackground(pluginId, methodName)) {
            // 阻塞网络能力不占用 Lynx/Activity 主线程；结果统一切回主线程交付 callback。
            Thread({
                val dispatchResult = NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options)
                mainHandler.post {
                    deliver(callback, callbackId, pluginId, methodName, dispatchResult)
                }
            }, "lynx-native-$pluginId-$methodName").apply {
                isDaemon = true
                start()
            }
        } else {
            // Android 的 Window/UI/Provider API 和普通 Lynx callback 在主线程串行化。
            mainHandler.post {
                deliver(
                    callback,
                    callbackId,
                    pluginId,
                    methodName,
                    NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options),
                )
            }
        }
    }

    private fun deliver(
        callback: Callback,
        callbackId: String,
        pluginId: String,
        methodName: String,
        dispatchResult: JSONObject,
    ) {
        val retained = dispatchResult.optBoolean("save", false)
        val result = if (dispatchResult.has("error")) {
            dispatchResult.put("success", false).apply {
                optJSONObject("error")?.let { error ->
                    if (!error.has("reasonCode")) {
                        error.put("reasonCode", LynxCapabilitySemantics.errorReasonCode(error.optString("code")))
                    }
                }
            }
        } else if (dispatchResult.optBoolean("success", false)) {
            dispatchResult
        } else {
            val data = JSONObject(dispatchResult.toString()).apply { remove("save") }
            JSONObject().put("success", true).put("data", data)
        }
        val envelope = result.put("callbackId", callbackId)
            .put("pluginId", pluginId)
            .put("methodName", methodName)
            .put("save", retained)
        Log.i(TAG, "LNX_RESULT $pluginId.$methodName success=${envelope.optBoolean("success")} save=$retained")
        callback.invoke(envelope.toString())
    }

    fun setEventSender(context: Context, sender: (String) -> Unit) {
        eventSender = sender
        NativeLocalNotificationCapabilities.setEventSender(context, sender)
        currentActivity.get()?.let { activity ->
            NativeMotionCapabilities.install(activity) { eventSender?.invoke(it) }
        }
    }

    fun clearEventSender(sender: (String) -> Unit) {
        if (eventSender === sender) {
            eventSender = null
            NativeLocalNotificationCapabilities.clearEventSender(sender)
        }
    }

    fun pluginHeaders(): String = JSONArray().apply {
        NativeCapabilityCatalog.specs.forEach { spec ->
            put(JSONObject().apply {
                put("name", spec.id)
                put("methods", JSONArray().apply {
                    spec.methods.forEach { method ->
                        put(JSONObject().apply {
                            put("name", method)
                            put("rtype", "promise")
                        })
                    }
                })
            })
        }
    }.toString()

    fun capabilityStatus(): String = JSONArray().apply {
        NativeCapabilityCatalog.specs.forEach { spec ->
            put(JSONObject().apply {
                put("name", spec.id)
                put("methods", JSONArray(spec.methods))
                put("implementedMethods", JSONArray(spec.implementedMethods))
                put("state", spec.state)
                put("contractVersion", LynxCapabilitySemantics.CONTRACT_VERSION)
                put("semanticState", spec.semanticState)
                put("reasonCode", spec.reasonCode)
                put("reason", spec.reason)
                put("methodStatus", spec.methodStatus())
                put("verification", LynxCapabilitySemantics.verification())
                put("platform", "android")
            })
        }
    }.toString()

    fun getPlatform(): String = "android"

    fun onNewIntent(intent: Intent) {
        currentActivity.get()?.intent = intent
        currentActivity.get()?.let { NativeLocalNotificationCapabilities.onNotificationAction(it, intent) }
    }

    fun onNotificationAction(context: Context, intent: Intent) {
        NativeLocalNotificationCapabilities.onNotificationAction(context, intent)
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        Log.i(TAG, "PERMISSION_FORWARD requestCode=$requestCode permissions=${permissions.contentToString()}")
        return NativePermissionCoordinator.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean = NativeCameraCaptureCapabilities.onActivityResult(requestCode, resultCode, data) ||
        NativeVideoCaptureCapabilities.onActivityResult(requestCode, resultCode, data) ||
        NativeBarcodeCapabilities.onActivityResult(requestCode, resultCode, data)

    @Synchronized
    fun attach(activity: Activity) {
        currentActivity.set(activity)
        Log.i(TAG, "ATTACH_ACTIVITY ${activity.javaClass.name}")
        NativeMotionCapabilities.install(activity) { eventSender?.invoke(it) }
    }

    override fun onActivityPreCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        attachIfNoActiveActivity(activity)
    }

    override fun onActivityStarted(activity: Activity) {
        attachIfNoActiveActivity(activity)
    }

    override fun onActivityResumed(activity: Activity) {
        attachIfNoActiveActivity(activity)
        if (currentActivity.get() === activity) NativeMotionCapabilities.start(activity)
    }

    override fun onActivityPaused(activity: Activity) {
        if (currentActivity.get() === activity) NativeMotionCapabilities.stop(activity)
    }

    override fun onActivityStopped(@Suppress("UNUSED_PARAMETER") activity: Activity) = Unit

    override fun onActivitySaveInstanceState(
        @Suppress("UNUSED_PARAMETER") activity: Activity,
        @Suppress("UNUSED_PARAMETER") outState: Bundle,
    ) = Unit

    override fun onActivityDestroyed(activity: Activity) {
        NativePermissionCoordinator.release(activity)
        NativeCameraCaptureCapabilities.release(activity)
        NativeVideoCaptureCapabilities.release(activity)
        NativeBarcodeCapabilities.release(activity)
        NativeSystemCapabilities.release(activity)
        NativeToastCapabilities.release(activity)
        NativeFileTransferCapabilities.release(activity)
        NativeAudioCapabilities.release(activity)
        NativeGeolocationCapabilities.release(activity)
        NativeMotionCapabilities.detach(activity)
        if (currentActivity.get() === activity) currentActivity.set(null)
    }

    /**
     * Application 生命周期回调的顺序可能让启动页在 Lynx 容器之后再次收到 onResume；
     * 只有显式 attach 的宿主或当前没有有效宿主时，才允许生命周期观察回调更新 Activity。
     */
    @Synchronized
    private fun attachIfNoActiveActivity(activity: Activity) {
        val active = currentActivity.get()
        if (active == null || active.isFinishing || active.isDestroyed || active === activity) {
            attach(activity)
        }
    }

    private fun errorEnvelope(
        callbackId: String,
        pluginId: String,
        methodName: String,
        message: String,
        code: String,
    ): JSONObject = JSONObject()
        .put("callbackId", callbackId)
        .put("pluginId", pluginId)
        .put("methodName", methodName)
        .put("success", false)
        .put(
            "error",
            JSONObject()
                .put("code", code)
                .put("reasonCode", LynxCapabilitySemantics.errorReasonCode(code))
                .put("message", message),
        )
        .put("save", false)
}
