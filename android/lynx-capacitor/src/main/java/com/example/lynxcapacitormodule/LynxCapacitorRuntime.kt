package com.example.lynxcapacitormodule

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.lynx.react.bridge.Callback
import com.lynx.tasm.behavior.LynxContext
import java.lang.ref.WeakReference
import java.util.WeakHashMap
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
    private val mainHandler = Handler(Looper.getMainLooper())
    private val currentActivity = AtomicReference<Activity?>(null)
    // 生命周期在主线程更新，Bridge 只读快照；未销毁的 Activity 不能代表 App 仍在前台。
    private val resumedActivities = WeakHashMap<Activity, Unit>()
    @Volatile private var appActive = false
    @Volatile private var eventSender: ((String) -> Unit)? = null
    private class OwnerBinding(val scope: NativeOwnerScope, val activity: WeakReference<Activity?>) {
        @Volatile var rawSender: ((String) -> Unit)? = null
        val sender: (String) -> Unit = { json -> LynxCapacitorRuntime.onMain { if (scope.isActive) rawSender?.invoke(json) } }
    }
    private val owners = WeakHashMap<Context, OwnerBinding>()
    private val destroyedContexts = WeakHashMap<Context, Unit>()
    private val activeContext = NativeActiveContext<Context>()
    private var installed = false

    @Synchronized
    fun install(app: Application) {
        if (installed) return
        app.registerActivityLifecycleCallbacks(this)
        installed = true
    }

    fun handleCall(payload: String, callback: Callback, callerContext: Context? = null) {
        if (payload.length > NativePayloadBudget.REQUEST_BYTES ||
            payload.toByteArray(Charsets.UTF_8).size > NativePayloadBudget.REQUEST_BYTES) {
            invokeOnMain(callback, errorEnvelope("-1", "", "", "请求超过 1 MiB 限制", "PAYLOAD_TOO_LARGE").toString())
            return
        }
        val request = runCatching { JSONObject(payload) }.getOrElse { error ->
            invokeOnMain(callback,
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
                invokeOnMain(callback,
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
            invokeOnMain(callback,
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
                invokeOnMain(callback,
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
            invokeOnMain(callback,
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
            invokeOnMain(callback,
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
            invokeOnMain(callback,
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
        val binding = synchronized(this) { callerContext?.let { owners[it] } }
        val activity = if (callerContext == null) currentActivity.get() else activityForContext(callerContext)
        if (activity == null || binding == null || !binding.scope.isActive) {
            invokeOnMain(callback, errorEnvelope(callbackId, pluginId, methodName,
                "当前调用页面未安装或已销毁", "HOST_DESTROYED").toString())
            return
        }
        val owner = binding.scope
        val call = owner.call {
            onMain { invokeOnMain(callback, errorEnvelope(callbackId, pluginId, methodName,
                "调用页面已销毁", "HOST_DESTROYED").toString()) }
        }
        if (!owner.isActive) return
        val complete: (JSONObject) -> Unit = { result ->
            encodeResult(owner, call, callback, callbackId, pluginId, methodName, result)
        }
        val work = {
            NativeCallContext.withOwner(owner) {
                if (NativeHostRegistry.requiresHost(pluginId, methodName)) {
                    val provider = NativeHostRegistry.provider
                    if (provider == null || "$pluginId.$methodName" !in NativeHostRegistry.supportedMethods || callerContext == null) {
                        complete(nativeFailure("HOST_NOT_CONFIGURED", "当前容器未提供 $pluginId.$methodName"))
                    } else {
                        val host = provider.resolve(callerContext)
                        if (host == null) complete(nativeFailure("HOST_DESTROYED", "当前容器已失效或没有实际 LynxView"))
                        else {
                            owner.own(provider) { onMain { provider.release(callerContext) } }
                            host.call(pluginId, methodName, options, complete)
                        }
                    }
                } else {
                    val claimed = when {
                        methodName == "requestPermissions" -> NativePermissionCoordinator.request(activity, pluginId, methodName, options, complete)
                        pluginId in setOf("Dialog", "ActionSheet") -> NativeInteractiveCapabilities.dispatch(activity, pluginId, methodName, options, complete)
                        pluginId == "Audio" -> NativeAudioCapabilities.dispatch(activity, methodName, options, complete)
                        pluginId == "FileViewer" && methodName == "openDocumentFromLocalPath" -> {
                            NativeMediaCapabilities.openDocument(activity, options, complete)
                            true
                        }
                        pluginId == "FileTransfer" -> NativeFileTransferCapabilities.dispatch(activity, methodName, options, complete, binding.sender)
                        pluginId == "LocalNotifications" && methodName !in setOf("checkPermissions", "requestPermissions") ->
                            NativeLocalNotificationCapabilities.dispatch(activity, methodName, options, complete)
                        pluginId == "Camera" && methodName in setOf("getPhoto", "pickImages", "chooseFromGallery", "takePhoto") ->
                            NativeCameraCaptureCapabilities.dispatch(activity, methodName, options, complete)
                        pluginId == "Camera" && methodName in setOf("recordVideo", "playVideo") ->
                            NativeVideoCaptureCapabilities.dispatch(activity, methodName, options, complete)
                        pluginId == "Geolocation" && methodName == "getCurrentPosition" ->
                            NativeGeolocationCapabilities.dispatch(activity, methodName, options, complete)
                        pluginId == "CapacitorBarcodeScanner" && methodName == "scanBarcode" ->
                            NativeBarcodeCapabilities.dispatch(activity, methodName, options, complete)
                        else -> false
                    }
                    if (!claimed) {
                        if (pluginId == "Motion") NativeMotionCapabilities.install(activity, binding.sender)
                        complete(NativeCapabilityDispatcher.dispatch(activity, pluginId, methodName, options))
                    }
                }
            }
        }
        NativeExecutionPolicy.schedule(pluginId, methodName, owner, ::onMain,
            { complete(nativeFailure("BUSY", "原生执行队列已满")) }) {
            try { work() } catch (error: Exception) { complete(exceptionResult(error)) }
        }
    }

    private fun encodeResult(owner: NativeOwnerScope, call: NativeOwnerScope.Call, callback: Callback,
        callbackId: String, pluginId: String, methodName: String, raw: JSONObject) {
        if (!owner.isActive) return
        val encode = {
            val json = try {
                NativeCallContext.checkActive()
                val retained = raw.optBoolean("save", false)
                val envelope = when {
                    raw.has("error") -> raw.put("success", false).apply {
                        optJSONObject("error")?.let { error ->
                            if (!error.has("reasonCode")) error.put("reasonCode", LynxCapabilitySemantics.errorReasonCode(error.optString("code")))
                        }
                    }
                    raw.optBoolean("success", false) -> raw
                    else -> JSONObject().put("success", true).put("data", raw.apply { remove("save") })
                }.put("callbackId", callbackId).put("pluginId", pluginId).put("methodName", methodName).put("save", retained)
                val encoded = envelope.toString()
                NativePayloadBudget.check(encoded.toByteArray(Charsets.UTF_8).size.toLong(), NativePayloadBudget.RESULT_BYTES.toLong(), "RESULT_TOO_LARGE")
                encoded
            } catch (error: Exception) {
                errorEnvelope(callbackId, pluginId, methodName, error.message ?: "原生结果编码失败",
                    if (error is NativeBudgetExceeded) error.code else if (error is NativeCallCancelled) "HOST_DESTROYED" else "ENCODING_ERROR").toString()
            }
            onMain { call.complete { invokeOnMain(callback, json) } }
        }
        if (Looper.myLooper() != Looper.getMainLooper()) encode()
        else NativeIO.local.submit(owner, {
            onMain { call.complete { invokeOnMain(callback, errorEnvelope(callbackId, pluginId, methodName,
                "结果编码队列已满", "BUSY").toString()) } }
        }, encode)
    }

    fun setHostProvider(provider: LynxCapacitorHostProvider?) = NativeHostRegistry.install(provider)

    fun setEventSender(context: Context, sender: (String) -> Unit) {
        val binding = synchronized(this) {
            if (destroyedContexts.containsKey(context)) return
            val existing = owners[context]
            // Shell 先使用媒体时早建 owner；首次 Cap Module 只补事件出口，不取消已经启动的任务。
            if (existing != null && existing.rawSender == null && existing.scope.isActive) {
                existing.rawSender = sender
                existing
            } else {
                existing?.scope?.let(::endOwner)
                OwnerBinding(NativeOwnerScope(), WeakReference(activityForContext(context))).also {
                    it.rawSender = sender
                    owners[context] = it
                }
            }
        }
        if (synchronized(this) { activeContext.canActivate(context) }) onMain {
            val stillCurrent = synchronized(this) { owners[context] === binding && activeContext.canActivate(context) }
            if (binding.scope.isActive && stillCurrent) activate(context)
        }
    }

    /** Legacy facade 不加入四入口和能力目录；它与 Cap transport 共用 exact Context owner。 */
    fun handleLegacyMedia(context: Context, methodName: String, optionsJSON: String, complete: (JSONObject) -> Unit) {
        val activity = activityForContext(context)
        val binding = synchronized(this) {
            if (context !is LynxContext || activity == null || destroyedContexts.containsKey(context)) null
            else owners[context] ?: OwnerBinding(NativeOwnerScope(), WeakReference(activity)).also { owners[context] = it }
        }
        if (activity == null || binding == null || !binding.scope.isActive) {
            onMain { complete(NativeLegacyMediaCapabilities.failure("当前调用页面未安装或已销毁")) }
            return
        }
        if (methodName == "saveDataURL" && optionsJSON.length > NativeLegacyMediaCapabilities.MAX_DATA_URL_CHARS) {
            onMain { complete(NativeLegacyMediaCapabilities.failure("Data URL 超过 20 MiB 输入预算")) }
            return
        }
        val admission = if (methodName == "saveDataURL") NativeLegacyMediaCapabilities.admitDataUrl() else null
        if (methodName == "saveDataURL" && admission == null) {
            onMain { complete(NativeLegacyMediaCapabilities.failure("已有 Data URL 正在处理")) }
            return
        }
        val owner = binding.scope
        if (admission != null) owner.own(admission) { admission.release() }
        val call = owner.call {
            admission?.release()
            onMain { complete(NativeLegacyMediaCapabilities.failure("调用页面已销毁")) }
        }
        val reply: (JSONObject) -> Unit = { raw ->
            val finish: (JSONObject) -> Unit = { result -> onMain {
                val deliver = { call.complete {
                    if (methodName == "chooseMedia") NativeLegacyMediaCapabilities.finishSelection(raw, result.optInt("code", -1) == 0, owner)
                    admission?.let { owner.disown(it); it.release() }
                    complete(result)
                }; Unit }
                // 成功文件移交与调用终态共用 owner 锁，销毁不能夹在二者之间删除已交付文件。
                if (methodName == "chooseMedia") {
                    try { owner.commit(deliver) } catch (_: NativeCallCancelled) { /* owner 终态已负责失败回包。 */ }
                } else deliver()
            } }
            val encode = {
                val result = try {
                    NativeJsonBudget().account(raw)
                    raw
                } catch (error: Exception) {
                    NativeLegacyMediaCapabilities.failure(error.message ?: "原生媒体结果编码失败")
                }
                finish(result)
            }
            if (Looper.myLooper() == Looper.getMainLooper()) NativeIO.local.submit(owner,
                { finish(NativeLegacyMediaCapabilities.failure("结果执行队列已满")) }, encode)
            else NativeCallContext.withOwner(owner, encode)
        }
        NativeIO.local.submit(owner, { reply(NativeLegacyMediaCapabilities.failure("本地执行队列已满")) }) {
            try { NativeLegacyMediaCapabilities.dispatch(activity, methodName, optionsJSON, reply) }
            catch (error: Exception) { reply(NativeLegacyMediaCapabilities.failure(error.message ?: "原生媒体调用失败")) }
        }
    }

    /** SDK Module 和 Shell 实际 View 销毁共用此入口；旧 Module 不释放后续同 Context 的新代次。 */
    fun destroyForContext(context: Context, expectedSender: ((String) -> Unit)? = null) {
        val binding = synchronized(this) {
            val current = owners[context]
            if (expectedSender != null && current?.rawSender !== expectedSender) return
            destroyedContexts[context] = Unit
            owners.remove(context)
            activeContext.release(context)
            if (eventSender === current?.sender) eventSender = null
            current
        } ?: return
        endOwner(binding.scope)
        onMain {
            NativeMotionCapabilities.releaseForSender(binding.sender)
            NativeFileTransferCapabilities.releaseForSender(binding.sender)
            NativeLocalNotificationCapabilities.clearEventSender(binding.sender)
        }
    }

    fun clearEventSender(sender: (String) -> Unit) {
        val contexts = synchronized(this) { owners.entries.filter { it.value.rawSender === sender }.map { it.key } }
        contexts.forEach { destroyForContext(it, sender) }
    }

    /** Page/Tab 重新显示时恢复自己的事件出口，跨 owner 的结果始终保留原来的出口。 */
    fun activate(context: Context) {
        val activity = activityForContext(context) ?: return
        val sender = synchronized(this) {
            if (destroyedContexts.containsKey(context)) return
            activeContext.activate(context)
            owners[context]?.sender
        }
        eventSender?.let { previous -> if (previous !== sender) NativeLocalNotificationCapabilities.clearEventSender(previous) }
        eventSender = sender
        attach(activity)
        if (sender != null) {
            NativeLocalNotificationCapabilities.setEventSender(context, sender)
            NativeMotionCapabilities.install(activity, sender)
        }
    }

    private fun endOwner(owner: NativeOwnerScope) {
        owner.end().forEach { Log.e(TAG, "原生 owner 资源清理失败", it) }
    }
    private fun invokeOnMain(callback: Callback, json: String) = onMain { callback.invoke(json) }
    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action)
    }
    private fun nativeFailure(code: String, message: String): JSONObject = JSONObject().put("error", JSONObject().put("code", code).put("message", message))
    private fun exceptionResult(error: Exception): JSONObject = nativeFailure(
        if (error is NativeBudgetExceeded) error.code else if (error is NativeCallCancelled) "HOST_DESTROYED" else "NATIVE_ERROR",
        error.message ?: "Android 原生调用失败")

    private fun activityForContext(context: Context): Activity? {
        var current = context
        while (current !is Activity) {
            current = when (current) {
                is LynxContext -> current.getContext()
                is ContextWrapper -> current.baseContext
                else -> return null
            }
        }
        return current.takeUnless { it.isFinishing || it.isDestroyed }
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

    fun capabilityStatus(): String = NativeCapabilityStatusSnapshot.build()

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
        eventSender?.let { NativeMotionCapabilities.install(activity, it) }
    }

    override fun onActivityPreCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        attachIfNoActiveActivity(activity)
    }

    override fun onActivityStarted(activity: Activity) {
        attachIfNoActiveActivity(activity)
    }

    internal fun isAppActive(): Boolean = appActive

    override fun onActivityResumed(activity: Activity) {
        resumedActivities[activity] = Unit
        appActive = true
        attachIfNoActiveActivity(activity)
        if (currentActivity.get() === activity) NativeMotionCapabilities.start(activity)
    }

    override fun onActivityPaused(activity: Activity) {
        resumedActivities.remove(activity)
        appActive = resumedActivities.isNotEmpty()
        if (currentActivity.get() === activity) NativeMotionCapabilities.stop(activity)
    }

    override fun onActivityStopped(@Suppress("UNUSED_PARAMETER") activity: Activity) = Unit

    override fun onActivitySaveInstanceState(
        @Suppress("UNUSED_PARAMETER") activity: Activity,
        @Suppress("UNUSED_PARAMETER") outState: Bundle,
    ) = Unit

    override fun onActivityDestroyed(activity: Activity) {
        resumedActivities.remove(activity)
        appActive = resumedActivities.isNotEmpty()
        val contexts = synchronized(this) { owners.entries.filter { it.value.activity.get() === activity }.map { it.key } }
        contexts.forEach { destroyForContext(it) }
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
