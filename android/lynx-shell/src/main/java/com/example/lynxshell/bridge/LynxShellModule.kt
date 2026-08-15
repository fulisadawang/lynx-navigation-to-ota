package com.example.lynxshell.bridge

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.example.lynxshell.LynxShell
import com.example.lynxshell.routing.LynxNavigationOptions
import com.example.lynxshell.routing.LynxNavigationResult
import com.example.lynxshell.routing.LynxNavigator
import com.example.lynxshell.routing.LynxRouteParser
import com.example.lynxshell.routing.findActivity
import com.example.lynxshell.transition.LynxTransitionRuntime
import com.example.lynxshell.transition.PreparedRouteStore
import com.example.lynxshell.ota.LynxOtaRuntime
import com.lynx.jsbridge.Arguments
import com.lynx.jsbridge.LynxMethod
import com.lynx.jsbridge.LynxModule
import com.lynx.react.bridge.Callback
import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.react.bridge.ReadableMap
import com.lynx.tasm.behavior.LynxContext

/**
 * 页面通过 `NativeModules.LynxShellModule` 调用的稳定宿主模块。
 *
 * 设计边界：
 * - 这里负责 Lynx 参数到 Kotlin 类型的转换、主线程切换和回调封装；
 * - 导航栈规则统一放在 [LynxNavigator]，媒体实现放在 [ShellMediaBridge]；
 * - 不接入 sparkling-method、spkPipe、autolink 或 codegen；
 * - 导航成功回调表示“原生事务已提交/执行”，不代表目标 Lynx Bundle 已完成首帧。
 *
 * Native 回调原始协议为 `code == 0` 成功；Playground wrapper 会再归一化为页面侧
 * `code == 1` 成功。业务页面若直接调用 NativeModules，应以本类原始协议为准。
 */
class LynxShellModule(context: Context) : LynxModule(context) {
    /** 所有 UIKit/Activity 等价操作都串行进入 Android 主线程。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 打开页面。
     *
     * `optionsJSON` 同时承载页面参数和导航参数，可包含 `routeKey`、`launchMode`、
     * `animated`、`backGestureEnabled`、`deduplicateWindowMs`、`keyboardBehavior` 等字段。
     */
    @LynxMethod
    fun open(url: String, optionsJSON: String, callback: Callback) {
        runCatching {
            LynxRouteParser.fromBridge(url, optionsJSON) to
                LynxNavigationOptions.fromJson(optionsJSON)
        }.onSuccess { (request, options) ->
            postResult(callback) { LynxNavigator.open(hostContext(), request, options) }
        }.onFailure { callback.invoke(result(1001, it.message ?: "页面参数不合法")) }
    }

    /**
     * 关闭当前容器。
     *
     * 与 `back(delta)` 不同，当前页是 session 首页时也允许关闭并返回宿主页。
     */
    @LynxMethod
    fun close(callback: Callback) {
        postResult(callback) { LynxNavigator.close(hostContext()) }
    }

    /**
     * 在当前 Lynx session 内回退 delta 页。
     *
     * `optionsJSON.result` 可携带 JSON Object 给目标页；超过可退深度时只退到 session
     * 首页，不会跨过宿主锚点。
     */
    @LynxMethod
    fun back(delta: Int, optionsJSON: String, callback: Callback) {
        runCatching { LynxNavigationOptions.fromJson(optionsJSON) }
            .onSuccess { options ->
                postResult(callback) { LynxNavigator.back(hostContext(), delta, options) }
            }
            .onFailure { callback.invoke(result(1001, it.message ?: "back options 不合法")) }
    }

    /** 保留兼容签名：使用默认动画回到当前 session 已存在的 routeKey。 */
    @LynxMethod
    fun popTo(routeKey: String, callback: Callback) {
        postResult(callback) { LynxNavigator.popTo(hostContext(), routeKey) }
    }

    /** `popTo` 的可配置版本，支持 animated、result 和防重复参数。 */
    @LynxMethod
    fun popToWithOptions(routeKey: String, optionsJSON: String, callback: Callback) {
        runCatching { LynxNavigationOptions.fromJson(optionsJSON) }
            .onSuccess { options ->
                postResult(callback) {
                    LynxNavigator.popTo(hostContext(), routeKey, options)
                }
            }
            .onFailure { callback.invoke(result(1001, it.message ?: "popTo options 不合法")) }
    }

    /** 保留兼容签名：关闭当前 session 的全部 Lynx 页面并返回进入前宿主页。 */
    @LynxMethod
    fun closeAll(callback: Callback) {
        postResult(callback) { LynxNavigator.closeAll(hostContext()) }
    }

    /** `closeAll` 的可配置版本，主要用于控制动画和重复操作窗口。 */
    @LynxMethod
    fun closeAllWithOptions(optionsJSON: String, callback: Callback) {
        runCatching { LynxNavigationOptions.fromJson(optionsJSON) }
            .onSuccess { options ->
                postResult(callback) { LynxNavigator.closeAll(hostContext(), options) }
            }
            .onFailure { callback.invoke(result(1001, it.message ?: "closeAll options 不合法")) }
    }

    /**
     * 关闭当前 Lynx session，并由业务宿主注入的 AppHomeHandler 回到主 Tab。
     *
     * 通用壳不会猜测业务 TabBar Activity；未安装 Handler 时明确返回 1004。
     */
    @LynxMethod
    fun reLaunch(optionsJSON: String, callback: Callback) {
        runCatching { LynxNavigationOptions.fromJson(optionsJSON) }
            .onSuccess { options ->
                postResult(callback) {
                    LynxNavigator.reLaunch(hostContext(), optionsJSON, options)
                }
            }
            .onFailure { callback.invoke(result(1001, it.message ?: "reLaunch options 不合法")) }
    }

    /**
     * 用新请求原位替换当前 entry。
     *
     * sessionID/entryID/order 保持不变，页面参数和 Bundle 会重新加载。
     */
    @LynxMethod
    fun redirect(url: String, optionsJSON: String, callback: Callback) {
        runCatching {
            LynxRouteParser.fromBridge(url, optionsJSON) to
                LynxNavigationOptions.fromJson(optionsJSON)
        }.onSuccess { (request, options) ->
            postResult(callback) {
                LynxNavigator.redirect(hostContext(), request, options)
            }
        }.onFailure { callback.invoke(result(1001, it.message ?: "页面参数不合法")) }
    }

    /** 查询当前 session 的 route、stack、depth、canGoBack 和宿主锚点状态。 */
    @LynxMethod
    fun getNavigationState(callback: Callback) {
        postResult(callback) { LynxNavigator.getNavigationState(hostContext()) }
    }

    /**
     * 关闭当前页并向下一个 Lynx entry 返回 JSON Object。
     *
     * 页面结果按目标 entryID 持久化，不依赖会随页面销毁失效的 JS callback 闭包。
     */
    @LynxMethod
    fun closeWithResult(resultJSON: String, callback: Callback) {
        runCatching {
            // Navigator 会再次解析；这里提前校验，确保参数错误稳定返回 1001。
            LynxNavigationOptions.withResult(resultJSON)
        }.onSuccess {
            postResult(callback) {
                LynxNavigator.closeWithResult(hostContext(), resultJSON)
            }
        }.onFailure {
            callback.invoke(result(1001, it.message ?: "resultJSON 必须是 JSON Object"))
        }
    }

    /** 一次性读取发给当前 entry 的页面结果；没有结果时成功返回 hasResult=false。 */
    @LynxMethod
    fun consumeNavigationResult(callback: Callback) {
        postResult(callback) { LynxNavigator.consumeNavigationResult(hostContext()) }
    }

    /** 页面向宿主发送同步消息；处理器返回值会通过同一 callback 回到 Lynx。 */
    @LynxMethod
    fun emitToNative(eventName: String, payload: ReadableMap?, callback: Callback) {
        val activity = hostContext().findActivity()
        if (activity == null) {
            callback.invoke(result(1002, "当前 LynxContext 没有关联 Activity"))
            return
        }
        val reply = ShellMessageHub.dispatchFromActivity(
            activity = activity,
            eventName = eventName,
            payload = payloadMap(payload),
        )
        callback.invoke(
            nativeMap(
                hashMapOf(
                    "code" to if (reply.accepted) 0 else 1,
                    "message" to reply.message,
                    "data" to payloadMap(reply.data),
                ),
            ),
        )
    }

    /** 向进程内所有仍存活的 Lynx Activity 广播消息。 */
    @LynxMethod
    fun broadcast(eventName: String, payload: ReadableMap?, callback: Callback) {
        runCatching {
            ShellMessageHub.broadcast(eventName, payloadMap(payload))
        }.onSuccess { affectedCount ->
            callback.invoke(
                nativeMap(
                    hashMapOf(
                        "code" to 0,
                        "message" to "广播已发送",
                        "data" to hashMapOf("affectedCount" to affectedCount),
                    ),
                ),
            )
        }.onFailure {
            callback.invoke(result(1001, it.message ?: "广播发送失败"))
        }
    }

    /** 按 pageId 向另一个 Lynx Activity 定向发送消息。 */
    @LynxMethod
    fun sendToPage(
        targetPageId: String,
        eventName: String,
        payload: ReadableMap?,
        callback: Callback,
    ) {
        runCatching {
            ShellMessageHub.sendToPage(targetPageId, eventName, payloadMap(payload))
        }.onSuccess { sent ->
            callback.invoke(
                nativeMap(
                    hashMapOf(
                        "code" to if (sent) 0 else 1,
                        "message" to if (sent) "定向消息已发送" else "目标页面不存在或已经销毁",
                        "data" to hashMapOf("affectedCount" to if (sent) 1 else 0),
                    ),
                ),
            )
        }.onFailure {
            callback.invoke(result(1001, it.message ?: "定向消息发送失败"))
        }
    }

    /**
     * 预解析安全路由并预取 Bundle 字节。
     *
     * token 默认 30 秒过期、最多使用一次；这里只缓存 bytes，不创建 LynxView、
     * Activity 或 JS Runtime。预取失败不会污染后续普通 Provider 加载。
     */
    @LynxMethod
    fun prepareRoute(url: String, optionsJSON: String, callback: Callback) {
        val parsed = runCatching {
            LynxRouteParser.fromBridge(url, optionsJSON).also {
                // 同时校验 transition / routeType，避免 prepare 和 open 对同一参数结论不同。
                LynxNavigationOptions.fromJson(optionsJSON)
            }
        }
        parsed.onFailure {
            callback.invoke(result(1001, it.message ?: "prepareRoute 参数不合法"))
        }.onSuccess { request ->
            PreparedRouteStore.prepare(hostContext(), request) { prepared ->
                mainHandler.post {
                    prepared.onSuccess { route ->
                        callback.invoke(
                            result(
                                LynxNavigationResult(
                                    code = 0,
                                    message = "路由 Bundle 预取成功",
                                    data = hashMapOf(
                                        "token" to route.token,
                                        "routeKey" to route.routeKey,
                                        "sizeBytes" to route.sizeBytes,
                                        "expiresAt" to route.expiresAt,
                                    ),
                                ),
                            ),
                        )
                    }.onFailure { error ->
                        callback.invoke(
                            result(
                                LynxNavigationResult(
                                    code = 1500,
                                    message = error.message ?: "路由 Bundle 预取失败",
                                ),
                            ),
                        )
                    }
                }
            }
        }
    }

    /** 取消尚未消费的 prepared route；不存在、过期或已消费统一返回 1003。 */
    @LynxMethod
    fun cancelPreparedRoute(token: String, callback: Callback) {
        postResult(callback) {
            when {
                token.isBlank() -> LynxNavigationResult(1001, "prepared route token 不能为空")
                PreparedRouteStore.cancel(token) ->
                    LynxNavigationResult(0, "prepared route 已取消", affectedCount = 1)
                else -> LynxNavigationResult(1003, "prepared route 不存在、已过期或已消费")
            }
        }
    }

    /**
     * 页面通知异步 hero 内容已经稳定。
     *
     * 该信号只触发原生下一次 selector 解析，不接受坐标，也不参与逐帧 progress。
     */
    @LynxMethod
    fun markTransitionReady(transactionID: String, callback: Callback) {
        postResult(callback) {
            when {
                transactionID.isBlank() ->
                    LynxNavigationResult(1001, "transactionID 不能为空")
                LynxTransitionRuntime.markReady(transactionID) ->
                    LynxNavigationResult(0, "转场 ready 信号已接收")
                else -> LynxNavigationResult(1003, "转场事务不存在")
            }
        }
    }

    /** 低频诊断当前原生事务；页面不得据此轮询并把 progress 再写回原生。 */
    @LynxMethod
    fun getTransitionState(callback: Callback) {
        postResult(callback) {
            val activity = hostContext().findActivity()
            LynxNavigationResult(
                code = 0,
                message = "转场状态读取成功",
                data = LynxTransitionRuntime.stateFor(activity?.intent).toMap(),
            )
        }
    }

    /** 写入壳工程隔离的 SharedPreferences；调用不阻塞等待磁盘落盘。 */
    @LynxMethod
    fun setStorageItem(key: String, value: String) {
        storage().edit().putString(key, value).apply()
    }

    /** 读取字符串；Key 不存在时返回空字符串，保持现有 Playground 契约。 */
    @LynxMethod
    fun getStorageItem(key: String, callback: Callback) {
        callback.invoke(storage().getString(key, "") ?: "")
    }

    /** 删除一个隔离存储 Key。 */
    @LynxMethod
    fun removeStorageItem(key: String) {
        storage().edit().remove(key).apply()
    }

    /** 清空 LynxShellModule 自己的存储空间，不影响 App 其他 SharedPreferences。 */
    @LynxMethod
    fun clearStorage() {
        storage().edit().clear().apply()
    }

    /**
     * 删除指定 appId 的全部 OTA Bundle。
     *
     * 这是磁盘清理 API，不会把目录改名成备份，也不会删除 APK 内置 Bundle；删除完成
     * 后页面下次打开会重新进入 OTA 下载/校验链路。回调 code=0 才表示真实删除成功。
     */
    @LynxMethod
    fun deleteOtaBundles(lynxAppId: String, callback: Callback) {
        if (lynxAppId.isBlank()) {
            callback.invoke(result(1001, "lynxAppId 不能为空"))
            return
        }
        val runtime = LynxShell.activityBundleRuntime()
        if (runtime !is LynxOtaRuntime) {
            callback.invoke(result(1004, "当前没有安装 Router OTA runtime"))
            return
        }
        runtime.deleteBundles(lynxAppId) { success, message ->
            callback.invoke(
                nativeMap(
                    hashMapOf(
                        "code" to if (success) 0 else 1500,
                        "message" to (message ?: if (success) "指定 appId 的 OTA Bundle 已删除" else "OTA Bundle 删除失败"),
                        "data" to hashMapOf(
                            "lynxAppId" to lynxAppId,
                            "deleted" to success,
                        ),
                    ),
                ),
            )
        }
    }

    /** 删除磁盘中的全部 appId OTA Bundle；APK 内置 Bundle 和 embedded 描述保留。 */
    @LynxMethod
    fun deleteAllOtaBundles(callback: Callback) {
        val runtime = LynxShell.activityBundleRuntime()
        if (runtime !is LynxOtaRuntime) {
            callback.invoke(result(1004, "当前没有安装 Router OTA runtime"))
            return
        }
        runtime.deleteAllBundles { success, message ->
            callback.invoke(
                nativeMap(
                    hashMapOf(
                        "code" to if (success) 0 else 1500,
                        "message" to (message ?: if (success) "全部 appId 的 OTA Bundle 已删除" else "OTA Bundle 删除失败"),
                        "data" to hashMapOf(
                            "scope" to "all",
                            "deleted" to success,
                        ),
                    ),
                ),
            )
        }
    }

    /** 返回不含设备标识的 App/系统基础信息。 */
    @LynxMethod
    fun getAppInfo(callback: Callback) {
        val context = hostContext()
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        callback.invoke(
            nativeMap(
                hashMapOf(
                    "platform" to "android",
                    "appVersion" to (packageInfo.versionName ?: ""),
                    "buildNumber" to if (Build.VERSION.SDK_INT >= 28) {
                        packageInfo.longVersionCode.toString()
                    } else {
                        @Suppress("DEPRECATION") packageInfo.versionCode.toString()
                    },
                    "systemVersion" to Build.VERSION.RELEASE,
                ),
            ),
        )
    }

    /** 调系统相册/相机选择媒体；权限和 Activity Result 生命周期由媒体桥处理。 */
    @LynxMethod
    fun chooseMedia(optionsJSON: String, callback: Callback) {
        ShellMediaBridge.chooseMedia(hostContext(), optionsJSON, callback)
    }

    /** 上传本地文件；与 uploadImage 共用受大小限制的网络实现。 */
    @LynxMethod
    fun uploadFile(optionsJSON: String, callback: Callback) {
        ShellMediaBridge.upload(optionsJSON, callback)
    }

    /** 兼容 Playground 的图片上传方法名。 */
    @LynxMethod
    fun uploadImage(optionsJSON: String, callback: Callback) {
        ShellMediaBridge.upload(optionsJSON, callback)
    }

    /** 下载远程文件到 App 私有缓存目录。 */
    @LynxMethod
    fun downloadFile(optionsJSON: String, callback: Callback) {
        ShellMediaBridge.download(hostContext(), optionsJSON, callback)
    }

    /** 把 Data URL 解码到 App 私有缓存目录，不直接写公共相册。 */
    @LynxMethod
    fun saveDataURL(optionsJSON: String, callback: Callback) {
        ShellMediaBridge.saveDataUrl(hostContext(), optionsJSON, callback)
    }

    /**
     * 把返回 [LynxNavigationResult] 的操作串行投递到主线程，并统一处理意外异常。
     *
     * 参数解析错误在投递前返回 1001；平台调用中的意外异常统一返回 1500。
     */
    private fun postResult(callback: Callback, operation: () -> LynxNavigationResult) {
        mainHandler.post {
            val value = runCatching(operation)
                .getOrElse {
                    LynxNavigationResult(
                        code = 1500,
                        message = it.message ?: "原生 Module 调用异常",
                    )
                }
            callback.invoke(result(value))
        }
    }

    /**
     * 从 LynxContext 追溯真实 Activity。
     *
     * 媒体选择和页面跳转必须使用 Activity；只有确实找不到时才退回基础 Context，
     * 避免无意添加 FLAG_NEW_TASK 并拆分导航会话。
     */
    private fun hostContext(): Context {
        val lynxContext = mContext as? LynxContext
        val baseContext = lynxContext?.getContext() ?: mContext
        return mContext.findActivity() ?: baseContext.findActivity() ?: baseContext
    }

    /** Module 自己的隔离存储，不与页面结果或宿主业务存储共用文件。 */
    private fun storage() = hostContext().getSharedPreferences(STORAGE_NAME, Context.MODE_PRIVATE)

    /**
     * 把普通 Kotlin/Java Map 递归编码成 Lynx Bridge 能识别的 JavaOnlyMap。
     *
     * Callback.invoke 的参数会被放进 JavaOnlyArray；直接传 HashMap 会在真机抛出
     * `unsupported type ... HashMap contained in JavaOnlyArray`，最终让 JS 收到 null。
     * Arguments.makeNativeMap 会同时转换嵌套 Map/List，因此所有对象型回调必须走这里。
     */
    private fun nativeMap(value: HashMap<String, Any>): JavaOnlyMap =
        Arguments.makeNativeMap(value)

    /** 把 Lynx 传入的 JavaOnlyMap/HashMap 统一转换为可递归编码的 Map。 */
    /** Lynx 4.0 Bridge 只接受 ReadableMap，避免 Kotlin Any? 被反射成不支持的 Object。 */
    private fun payloadMap(value: ReadableMap?): Map<String, Any?> =
        value?.toHashMap()
            ?.filterKeys { it is String }
            ?.mapKeys { it.key.toString() }
            ?: emptyMap()

    /** 宿主回包已经是 Kotlin Map 时只清理 null，保持与 Lynx ReadableMap 入口一致。 */
    private fun payloadMap(value: Map<String, Any?>): Map<String, Any?> =
        value.filterValues { it != null }

    /** 构造不带 data 的统一错误/结果结构。 */
    private fun result(code: Int, message: String): JavaOnlyMap =
        nativeMap(hashMapOf("code" to code, "message" to message))

    /** 把导航 result 的扩展数据和 affectedCount 合并为页面可消费的 Lynx Map。 */
    private fun result(value: LynxNavigationResult): JavaOnlyMap {
        val data = hashMapOf<String, Any>("affectedCount" to value.affectedCount)
        data.putAll(value.data)
        return nativeMap(
            hashMapOf(
                "code" to value.code,
                "message" to value.message,
                "data" to data,
            ),
        )
    }

    companion object {
        /** Lynx Runtime 注册和 TypeScript `NativeModules` 访问使用的固定模块名。 */
        const val MODULE_NAME = "LynxShellModule"
        private const val STORAGE_NAME = "lynx_shell_storage"
    }
}
