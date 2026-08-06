package com.example.lynxshell.routing

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import com.example.lynxshell.R
import com.example.lynxshell.container.LynxShellActivity
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.transition.LynxTransitionIntent
import com.example.lynxshell.transition.LynxTransitionRuntime
import com.example.lynxshell.transition.LynxSnapshotStore
import com.example.lynxshell.transition.LynxTransitionSpec
import com.example.lynxshell.util.JsonObjectCodec
import java.lang.ref.WeakReference
import java.util.UUID
import kotlin.math.min
import org.json.JSONObject

/** 一次原生导航操作的稳定结果；`data` 用于返回栈状态、entry 标识或页面结果。 */
data class LynxNavigationResult(
    val code: Int,
    val message: String,
    val affectedCount: Int = 0,
    val data: Map<String, Any> = emptyMap(),
) {
    val isSuccess: Boolean get() = code == 0
}

/** `open` 的页面复用策略，名称与 TypeScript/iOS 契约完全一致。 */
enum class LynxLaunchMode(val wireName: String) {
    PUSH("push"),
    SINGLE_TOP("singleTop"),
    CLEAR_TOP("clearTop"),
    SINGLE_TASK("singleTask");

    companion object {
        fun fromWireName(value: String): LynxLaunchMode =
            entries.firstOrNull { it.wireName.equals(value, ignoreCase = true) }
                ?: throw IllegalArgumentException(
                    "launchMode 只支持 push、singleTop、clearTop、singleTask",
                )
    }
}

/**
 * 一次导航命令的通用选项。
 *
 * 这些字段由 Native Module 从 `optionsJSON` 解析；页面展示参数仍由
 * [LynxRouteParser] 转换为 [LynxPageRequest]。两类参数共用一个 JSON，但职责分离。
 */
data class LynxNavigationOptions(
    val launchMode: LynxLaunchMode = LynxLaunchMode.PUSH,
    val animated: Boolean = true,
    val deduplicate: Boolean = true,
    val deduplicateWindowMs: Long = DEFAULT_DEDUPLICATE_WINDOW_MS,
    val resultJson: String? = null,
    val transitionSpec: LynxTransitionSpec = LynxTransitionSpec(),
    val preparedRouteToken: String? = null,
) {
    companion object {
        private const val DEFAULT_DEDUPLICATE_WINDOW_MS = 350L
        private const val MAX_DEDUPLICATE_WINDOW_MS = 5_000L

        fun fromJson(optionsJson: String): LynxNavigationOptions {
            val values = if (optionsJson.isBlank()) JSONObject() else JSONObject(optionsJson)
            val window = values.optLong(
                "deduplicateWindowMs",
                DEFAULT_DEDUPLICATE_WINDOW_MS,
            )
            require(window in 0..MAX_DEDUPLICATE_WINDOW_MS) {
                "deduplicateWindowMs 必须在 0..$MAX_DEDUPLICATE_WINDOW_MS 之间"
            }
            val animated = values.optBoolean("animated", true)
            return LynxNavigationOptions(
                launchMode = LynxLaunchMode.fromWireName(
                    values.optString("launchMode", LynxLaunchMode.PUSH.wireName),
                ),
                animated = animated,
                deduplicate = values.optBoolean("deduplicate", true),
                deduplicateWindowMs = window,
                resultJson = values.optionalObjectJson("result"),
                transitionSpec = LynxTransitionSpec.fromOptions(values, animated),
                preparedRouteToken = values.optString("preparedRouteToken")
                    .trim()
                    .takeIf { it.isNotEmpty() },
            )
        }

        fun withResult(resultJson: String): LynxNavigationOptions =
            LynxNavigationOptions(
                resultJson = JsonObjectCodec.requireObject(
                    resultJson,
                    "navigation result",
                ).toString(),
            )

        private fun JSONObject.optionalObjectJson(key: String): String? {
            if (!has(key) || isNull(key)) return null
            return when (val value = get(key)) {
                is JSONObject -> value.toString()
                is String -> JsonObjectCodec.requireObject(value, key).toString()
                else -> throw IllegalArgumentException("$key 必须是 JSON Object 或其字符串形式")
            }
        }
    }
}

/**
 * 业务 App 的主页接入点。
 *
 * 壳工程不知道真实 TabBar Activity，因此由宿主在 Application 启动时注入。返回 true
 * 表示主页跳转已经提交；LynxNavigator 随后只关闭当前 Lynx session。
 */
fun interface AppHomeHandler {
    fun openHome(activity: Activity, optionsJson: String): Boolean
}

/**
 * 混合原生/Lynx 栈的可选退出接入点。
 *
 * 默认 `closeAll` 只结束注册在当前 session 的 Lynx Activity，适用于连续的 Lynx 页面。
 * 如果业务允许在同一 session 中插入原生 Activity，可注入 Handler，用业务 Router 精确
 * 返回最初的宿主锚点。Handler 返回 false 时，本次关闭失败且不会批量 finish。
 */
fun interface SessionExitHandler {
    fun returnToAnchor(activity: Activity, sessionID: String): Boolean
}

/**
 * 宿主统一导航入口，业务层与 Native Module 都调用这里。
 *
 * 每个 Lynx 页面对应一个 Activity。`sessionID` 隔离一批连续的 Lynx 页面，
 * `entryID` 唯一标识某个实例，`order` 在 Activity 重建后仍保持原顺序。任何批量操作
 * 都不会调用 `finishAffinity()`，也不会误清整个 Android task。
 */
object LynxNavigator {
    private const val EXTRA_SESSION_ID = "lynx_shell.navigation_session_id"
    private const val EXTRA_ENTRY_ID = "lynx_shell.navigation_entry_id"
    private const val EXTRA_PARENT_ENTRY_ID = "lynx_shell.navigation_parent_entry_id"
    private const val EXTRA_ENTRY_ORDER = "lynx_shell.navigation_entry_order"
    private const val EXTRA_HAS_HOST_ANCHOR = "lynx_shell.has_host_anchor"

    @Volatile
    private var appHomeHandler: AppHomeHandler? = null

    @Volatile
    private var sessionExitHandler: SessionExitHandler? = null

    private val operationLock = Any()
    private var lastOperationKey = ""
    private var busyUntilMs = Long.MIN_VALUE

    /** 安装业务 App 的“回主 Tab”实现；后续安装会替换旧实现。 */
    fun installAppHomeHandler(handler: AppHomeHandler) {
        appHomeHandler = handler
    }

    /** 安装混合原生栈的 session 退出实现；纯 Lynx 连续栈无需安装。 */
    fun installSessionExitHandler(handler: SessionExitHandler?) {
        sessionExitHandler = handler
    }

    /**
     * 打开一个 Lynx 页面。
     *
     * - push：始终新增；
     * - singleTop：栈顶同 routeKey 时原位刷新；
     * - clearTop：回到已有目标并保留其旧参数；
     * - singleTask：回到已有目标并使用新参数刷新。
     */
    fun open(
        context: Context,
        request: LynxPageRequest,
        options: LynxNavigationOptions = LynxNavigationOptions(),
    ): LynxNavigationResult {
        val sourceActivity = context.findActivity()
        val sourceEntry = sourceActivity?.let(LynxNavigationRegistry::entryFor)
        val operationScope = sourceEntry?.sessionID
            ?: "host:${System.identityHashCode(sourceActivity ?: context.applicationContext)}"
        val routeKey = request.resolvedRouteKey()
        if (options.transitionSpec.explicitlyRequested && LynxTransitionRuntime.hasActiveTransaction()) {
            return failure(1006, "上一笔导航或转场事务仍在进行中")
        }
        rejectRepeatedOperation(
            key = "open:$operationScope:${options.launchMode.wireName}:$routeKey",
            options = options,
        )?.let { return it }

        if (sourceEntry != null) {
            val entries = LynxNavigationRegistry.entriesForSession(sourceEntry.sessionID)
                .filter { it.order <= sourceEntry.order }
            val target = entries.lastOrNull { it.routeKey == routeKey }
            when (options.launchMode) {
                LynxLaunchMode.PUSH -> Unit

                LynxLaunchMode.SINGLE_TOP -> {
                    if (sourceEntry.routeKey == routeKey) {
                        val activity = sourceEntry.activity.get()
                            ?: return failure(1002, "栈顶 Lynx Activity 已不可用")
                        activity.replaceRequest(request)
                        LynxNavigationRegistry.updateRoute(activity, routeKey)
                        return success(
                            message = "singleTop 已刷新栈顶页面",
                            affectedCount = 1,
                            data = entryData(sourceEntry, options.launchMode),
                        )
                    }
                }

                LynxLaunchMode.CLEAR_TOP -> {
                    if (target != null) {
                        val closing = entries.filter { it.order > target.order }
                            .sortedByDescending { it.order }
                        val accepted = finishEntriesWithTransition(
                            context = sourceActivity,
                            entries = closing,
                            options = options,
                            useStoredTransition = closing.size == 1,
                        ) {}
                        if (!accepted) {
                            return failure(1006, "上一笔导航或转场事务仍在进行中")
                        }
                        return success(
                            message = "clearTop 已回到 $routeKey",
                            affectedCount = closing.size,
                            data = entryData(target, options.launchMode),
                        )
                    }
                }

                LynxLaunchMode.SINGLE_TASK -> {
                    if (target != null) {
                        val targetActivity = target.activity.get()
                            ?: return failure(1002, "singleTask 目标 Activity 已不可用")
                        val closing = entries.filter { it.order > target.order }
                            .sortedByDescending { it.order }
                        val accepted = finishEntriesWithTransition(
                            context = sourceActivity,
                            entries = closing,
                            options = options,
                            useStoredTransition = closing.size == 1,
                        ) {
                            targetActivity.replaceRequest(request)
                            LynxNavigationRegistry.updateRoute(targetActivity, routeKey)
                        }
                        if (!accepted) {
                            return failure(1006, "上一笔导航或转场事务仍在进行中")
                        }
                        return success(
                            message = "singleTask 已复用并刷新 $routeKey",
                            affectedCount = closing.size + 1,
                            data = entryData(target.copy(routeKey = routeKey), options.launchMode),
                        )
                    }
                }
            }
        }

        val sessionID = sourceEntry?.sessionID ?: UUID.randomUUID().toString()
        val hasHostAnchor = sourceEntry?.hasHostAnchor
            ?: (sourceActivity != null && sourceActivity !is LynxShellActivity)
        return launch(
            context = context,
            request = request,
            sessionID = sessionID,
            hasHostAnchor = hasHostAnchor,
            parentEntryID = sourceEntry?.entryID,
            options = options,
        )
    }

    /** 保留旧契约：关闭当前容器；与 `back(delta)` 不同，session 首页也允许关闭。 */
    fun close(context: Context): LynxNavigationResult {
        val activity = context.findActivity() as? LynxShellActivity
            ?: return failure(1002, "当前 LynxContext 没有关联可关闭的 Activity")
        val current = LynxNavigationRegistry.entryFor(activity)
            ?: return failure(1002, "当前页面不在 Lynx 导航会话中")
        val options = LynxNavigationOptions()
        rejectRepeatedOperation("close:${current.entryID}", options)?.let { return it }
        val accepted = finishEntriesWithTransition(
            context = activity,
            entries = listOf(current),
            options = options,
            useStoredTransition = true,
        ) {}
        if (!accepted) return failure(1006, "上一笔导航或转场事务仍在进行中")
        return success("当前页面已关闭", 1)
    }

    /**
     * 在当前 Lynx session 内回退 delta 页。
     *
     * delta 超过可回退数量时收敛到 session 首页，不会越过宿主锚点。若 options 带
     * `result`，结果绑定到最终目标 entry，供其一次性消费。
     */
    fun back(
        context: Context,
        delta: Int,
        options: LynxNavigationOptions = LynxNavigationOptions(),
    ): LynxNavigationResult {
        if (delta <= 0) return failure(1001, "delta 必须大于 0")
        val activity = context.findActivity()
            ?: return failure(1002, "当前 LynxContext 没有关联 Activity")
        val current = LynxNavigationRegistry.entryFor(activity)
            ?: return failure(1002, "当前页面不在 Lynx 导航会话中")
        rejectRepeatedOperation("back:${current.entryID}:$delta", options)?.let { return it }

        val entries = LynxNavigationRegistry.entriesForSession(current.sessionID)
            .filter { it.order <= current.order }
        val currentIndex = entries.indexOfLast { it.entryID == current.entryID }
        if (currentIndex <= 0) return failure(1005, "当前已是 Lynx session 首页")
        val actualDelta = min(delta, currentIndex)
        val target = entries[currentIndex - actualDelta]
        val closing = entries.subList(currentIndex - actualDelta + 1, currentIndex + 1)
            .sortedByDescending { it.order }
        val accepted = finishEntriesWithTransition(
            context = activity,
            entries = closing,
            options = options,
            useStoredTransition = closing.size == 1,
        ) {
            options.resultJson?.let { payload ->
                AndroidNavigationResultStore.put(
                    context = activity,
                    targetEntryID = target.entryID,
                    payloadJson = payload,
                    source = current,
                )
            }
        }
        if (!accepted) return failure(1006, "上一笔导航或转场事务仍在进行中")
        return success(
            message = "已回退 $actualDelta 页",
            affectedCount = closing.size,
            data = hashMapOf(
                "requestedDelta" to delta,
                "actualDelta" to actualDelta,
                "targetRouteKey" to target.routeKey,
                "targetEntryID" to target.entryID,
            ),
        )
    }

    /**
     * 把当前 session 收敛到已存在的 routeKey。
     *
     * 例如 A-B-C-D-E 调用 popTo("A") 后，只 finish B/C/D/E；找不到 A 时明确失败，
     * 不会退化为重新打开 A。
     */
    fun popTo(
        context: Context,
        routeKey: String,
        options: LynxNavigationOptions = LynxNavigationOptions(),
    ): LynxNavigationResult {
        val activity = context.findActivity()
            ?: return failure(1002, "当前 LynxContext 没有关联 Activity")
        val current = LynxNavigationRegistry.entryFor(activity)
            ?: return failure(1002, "当前页面不在 Lynx 导航会话中")
        val normalizedKey = routeKey.trim()
        if (normalizedKey.isEmpty()) return failure(1001, "routeKey 不能为空")
        rejectRepeatedOperation(
            "popTo:${current.sessionID}:$normalizedKey",
            options,
        )?.let { return it }

        val entries = LynxNavigationRegistry.entriesForSession(current.sessionID)
            .filter { it.order <= current.order }
        val target = entries.lastOrNull { it.routeKey == normalizedKey }
            ?: return failure(1003, "当前 Lynx 会话中不存在 routeKey=$normalizedKey")
        val closing = entries.filter { it.order > target.order }.sortedByDescending { it.order }
        if (closing.isNotEmpty()) {
            val accepted = finishEntriesWithTransition(
                context = activity,
                entries = closing,
                options = options,
                useStoredTransition = closing.size == 1,
            ) {
                options.resultJson?.let { payload ->
                    AndroidNavigationResultStore.put(
                        context = activity,
                        targetEntryID = target.entryID,
                        payloadJson = payload,
                        source = current,
                    )
                }
            }
            if (!accepted) return failure(1006, "上一笔导航或转场事务仍在进行中")
        }
        return success(
            "已回退到 $normalizedKey",
            closing.size,
            hashMapOf("targetEntryID" to target.entryID, "targetRouteKey" to target.routeKey),
        )
    }

    /**
     * 关闭当前 Lynx session 并返回进入前的宿主页。
     *
     * 连续 Lynx Activity 栈可直接工作；若 session 中混入业务原生 Activity，宿主应安装
     * [SessionExitHandler]，用自己的 Router 精确返回原锚点。
     */
    fun closeAll(
        context: Context,
        options: LynxNavigationOptions = LynxNavigationOptions(),
    ): LynxNavigationResult {
        val activity = context.findActivity()
            ?: return failure(1002, "当前 LynxContext 没有关联 Activity")
        val current = LynxNavigationRegistry.entryFor(activity)
            ?: return failure(1002, "当前页面不在 Lynx 导航会话中")
        if (!current.hasHostAnchor) {
            return failure(1005, "当前 Lynx session 前没有可识别的宿主页锚点")
        }
        rejectRepeatedOperation("closeAll:${current.sessionID}", options)?.let { return it }
        val closing = LynxNavigationRegistry.entriesForSession(current.sessionID)
            .sortedByDescending { it.order }
        if (closing.isEmpty()) return failure(1002, "当前 Lynx 会话为空")

        val accepted = finishEntriesWithTransition(
            context = activity,
            entries = closing,
            options = options,
            useStoredTransition = closing.size == 1,
        ) {
            // 混合栈 Router 必须等唯一一段 POP 动画结束后再提交；提前跳宿主页会让
            // 当前 Activity onPause，从而看不到内容层转场。
            sessionExitHandler?.let { handler ->
                val returned = runCatching {
                    suppressOpenAnimation(activity)
                    handler.returnToAnchor(activity, current.sessionID)
                }.getOrElse {
                    throw IllegalStateException("session_exit_handler_failed", it)
                }
                suppressOpenAnimation(activity)
                check(returned) { "session_exit_handler_rejected" }
            }
        }
        if (!accepted) return failure(1006, "上一笔导航或转场事务仍在进行中")
        return success("已关闭全部 Lynx 页面并返回进入前的宿主页", closing.size)
    }

    /**
     * 返回应用主页/TabBar。
     *
     * 真实业务主页由 [AppHomeHandler] 决定；handler 成功后，再清理当前 Lynx session。
     */
    fun reLaunch(
        context: Context,
        optionsJson: String,
        options: LynxNavigationOptions = LynxNavigationOptions.fromJson(optionsJson),
    ): LynxNavigationResult {
        val activity = context.findActivity()
            ?: return failure(1002, "当前 LynxContext 没有关联 Activity")
        val current = LynxNavigationRegistry.entryFor(activity)
            ?: return failure(1002, "当前页面不在 Lynx 导航会话中")
        rejectRepeatedOperation("reLaunch:${current.sessionID}", options)?.let { return it }
        val handler = appHomeHandler
            ?: return failure(1004, "宿主尚未安装 AppHomeHandler")
        val closing = LynxNavigationRegistry.entriesForSession(current.sessionID)
            .sortedByDescending { it.order }
        val accepted = finishEntriesWithTransition(
            context = activity,
            entries = closing,
            options = options,
            useStoredTransition = closing.size == 1,
        ) {
            val opened = runCatching {
                // 先完成 coordinator 的内容层 POP，再提交主页 Router；前后都压制
                // Window open，避免主页跳转重新叠一层平台动画。
                suppressOpenAnimation(activity)
                handler.openHome(activity, optionsJson)
            }.getOrElse {
                throw IllegalStateException("app_home_handler_failed", it)
            }
            suppressOpenAnimation(activity)
            check(opened) { "app_home_handler_rejected" }
        }
        if (!accepted) return failure(1006, "上一笔导航或转场事务仍在进行中")
        return success("已返回应用主页", closing.size)
    }

    /**
     * 用新请求原位替换当前 Lynx 页面。
     *
     * entryID、sessionID、order 和返回目标保持不变，因此 A-B-C redirect(A) 的结果为
     * A-B-A，同时不会经历“先 start 新 Activity 再 finish 旧 Activity”的竞态窗口。
     */
    fun redirect(
        context: Context,
        request: LynxPageRequest,
        options: LynxNavigationOptions = LynxNavigationOptions(),
    ): LynxNavigationResult {
        val activity = context.findActivity() as? LynxShellActivity
            ?: return failure(1002, "redirect 只能从 Lynx 页面发起")
        val current = LynxNavigationRegistry.entryFor(activity)
            ?: return failure(1002, "当前页面不在 Lynx 导航会话中")
        rejectRepeatedOperation(
            "redirect:${current.entryID}:${request.resolvedRouteKey()}",
            options,
        )?.let { return it }
        activity.replaceRequest(request)
        LynxNavigationRegistry.updateRoute(activity, request.resolvedRouteKey())
        return success(
            "当前页面已重定向为 ${request.resolvedRouteKey()}",
            1,
            hashMapOf("entryID" to current.entryID, "routeKey" to request.resolvedRouteKey()),
        )
    }

    /** 返回当前 session 的可序列化栈状态；查询本身不会触发防重复或修改页面。 */
    fun getNavigationState(context: Context): LynxNavigationResult {
        val activity = context.findActivity()
            ?: return failure(1002, "当前 LynxContext 没有关联 Activity")
        val current = LynxNavigationRegistry.entryFor(activity)
            ?: return failure(1002, "当前页面不在 Lynx 导航会话中")
        val entries = LynxNavigationRegistry.entriesForSession(current.sessionID)
            .filter { it.order <= current.order }
        val currentIndex = entries.indexOfLast { it.entryID == current.entryID }
        if (currentIndex < 0) return failure(1002, "当前 entry 不在 session 栈中")

        val stack = ArrayList<HashMap<String, Any>>(entries.size)
        entries.forEachIndexed { index, entry ->
            stack += hashMapOf(
                "entryID" to entry.entryID,
                "routeKey" to entry.routeKey,
                "index" to index,
            )
        }
        val currentData = stack[currentIndex]
        return success(
            message = "导航状态读取成功",
            data = hashMapOf(
                "sessionID" to current.sessionID,
                "current" to currentData,
                "stack" to stack,
                "depth" to entries.size,
                "canGoBack" to (currentIndex > 0),
                "hasHostAnchor" to current.hasHostAnchor,
            ),
        )
    }

    /** 关闭当前页，并把一个 JSON Object 返回给它下面的 Lynx entry。 */
    fun closeWithResult(context: Context, resultJson: String): LynxNavigationResult =
        back(
            context = context,
            delta = 1,
            options = LynxNavigationOptions.withResult(resultJson),
        )

    /**
     * 一次性消费发给当前 entry 的页面结果。
     *
     * 没有结果不是错误，返回 `hasResult=false`；成功读取后原生存储立即删除该结果。
     */
    fun consumeNavigationResult(context: Context): LynxNavigationResult {
        val activity = context.findActivity()
            ?: return failure(1002, "当前 LynxContext 没有关联 Activity")
        val current = LynxNavigationRegistry.entryFor(activity)
            ?: return failure(1002, "当前页面不在 Lynx 导航会话中")
        val value = AndroidNavigationResultStore.consume(activity, current.entryID)
            ?: return success(
                message = "当前页面没有待消费结果",
                data = hashMapOf("hasResult" to false),
            )
        value["hasResult"] = true
        return success("页面结果读取成功", data = value)
    }

    /**
     * Activity 完成路由解析后登记。
     *
     * `entryID/order` 已写入 Intent 时原样复用，因此系统重建 Activity 后注册顺序变化
     * 也不会改变原栈顺序；直接深链进入则创建独立 session 和根 entry。
     */
    internal fun register(activity: LynxShellActivity, request: LynxPageRequest) {
        val sessionID = activity.intent.getStringExtra(EXTRA_SESSION_ID)
            ?.takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString()
        val entryID = activity.intent.getStringExtra(EXTRA_ENTRY_ID)
            ?.takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString()
        val parentEntryID = activity.intent.getStringExtra(EXTRA_PARENT_ENTRY_ID)
            ?.takeIf { it.isNotBlank() }
        val order = if (activity.intent.hasExtra(EXTRA_ENTRY_ORDER)) {
            activity.intent.getLongExtra(EXTRA_ENTRY_ORDER, 0L)
        } else {
            LynxNavigationRegistry.nextOrderForSession(sessionID)
        }
        val hasHostAnchor = activity.intent.getBooleanExtra(EXTRA_HAS_HOST_ANCHOR, false)
        activity.intent
            .putExtra(EXTRA_SESSION_ID, sessionID)
            .putExtra(EXTRA_ENTRY_ID, entryID)
            .putExtra(EXTRA_ENTRY_ORDER, order)
        parentEntryID?.let { activity.intent.putExtra(EXTRA_PARENT_ENTRY_ID, it) }
        LynxNavigationRegistry.register(
            activity = activity,
            sessionID = sessionID,
            entryID = entryID,
            parentEntryID = parentEntryID,
            routeKey = request.resolvedRouteKey(),
            hasHostAnchor = hasHostAnchor,
            order = order,
        )
    }

    /**
     * 暴露给页面消息中心和 GlobalProps 工厂的只读身份。
     *
     * Activity 仍是栈的唯一宿主；这里仅返回 entry/session 元数据，不把 Registry 的
     * 内部可变对象泄漏到 Bridge 层。
     */
    internal fun routerPageIdentity(activity: LynxShellActivity): LynxRouterPageIdentity? =
        LynxNavigationRegistry.entryFor(activity)?.let { entry ->
            LynxRouterPageIdentity(
                sessionID = entry.sessionID,
                entryID = entry.entryID,
                routeKey = entry.routeKey,
            )
        }

    internal fun unregister(activity: LynxShellActivity) {
        // 系统 Back/Toolbar 直接 finish 不一定经过 Navigator.close；仅在真正 finishing 时
        // 清理发给该 entry 的未消费结果。配置变更/进程恢复时 isFinishing=false，结果保留。
        if (activity.isFinishing) {
            activity.intent.getStringExtra(EXTRA_ENTRY_ID)
                ?.takeIf { it.isNotBlank() }
                ?.let { AndroidNavigationResultStore.remove(activity, it) }
        }
        LynxNavigationRegistry.unregister(activity)
    }

    /** Toolbar/系统返回的最终提交点；交互 cancel 不会调用到这里。 */
    fun commitSystemBack(activity: LynxShellActivity) {
        LynxNavigationRegistry.entryFor(activity)?.let { entry ->
            AndroidNavigationResultStore.remove(activity, entry.entryID)
        }
        finishActivity(activity, animated = false)
    }

    private fun launch(
        context: Context,
        request: LynxPageRequest,
        sessionID: String,
        hasHostAnchor: Boolean,
        parentEntryID: String?,
        options: LynxNavigationOptions,
    ): LynxNavigationResult {
        val entryID = UUID.randomUUID().toString()
        val order = LynxNavigationRegistry.nextOrderForSession(sessionID)
        return runCatching {
            val intent = request.writeTo(Intent(context, LynxShellActivity::class.java))
                .putExtra(EXTRA_SESSION_ID, sessionID)
                .putExtra(EXTRA_ENTRY_ID, entryID)
                .putExtra(EXTRA_ENTRY_ORDER, order)
                .putExtra(EXTRA_HAS_HOST_ANCHOR, hasHostAnchor)
            parentEntryID?.let { intent.putExtra(EXTRA_PARENT_ENTRY_ID, it) }
            options.preparedRouteToken?.let {
                intent.putExtra(LynxTransitionIntent.EXTRA_PREPARED_ROUTE_TOKEN, it)
            }
            val acceptance = if (options.transitionSpec.explicitlyRequested) {
                LynxTransitionRuntime.launch(
                    context = context,
                    // 基础/preset 可以从任意宿主 Activity 冻结上一页；只有 selector
                    // 解析需要 LynxShellActivity，Runtime 会在该分支做类型校验。
                    sourceActivity = context.findActivity(),
                    request = request,
                    options = options,
                    intent = intent,
                    sourceEntryID = parentEntryID,
                    targetEntryID = entryID,
                ).getOrThrow()
            } else {
                if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (!options.animated) intent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                context.startActivity(intent)
                if (!options.animated) {
                    @Suppress("DEPRECATION")
                    context.findActivity()?.overridePendingTransition(0, 0)
                }
                null
            }
            success(
                message = "页面打开事务已提交",
                data = hashMapOf<String, Any>(
                    "entryID" to entryID,
                    "routeKey" to request.resolvedRouteKey(),
                    "launchMode" to options.launchMode.wireName,
                ).apply {
                    acceptance?.toMap()?.let(::putAll)
                },
            )
        }.getOrElse { failure(1500, it.message ?: "原生导航异常") }
    }

    private fun rejectRepeatedOperation(
        key: String,
        options: LynxNavigationOptions,
    ): LynxNavigationResult? {
        if (!options.deduplicate || options.deduplicateWindowMs == 0L) return null
        val now = SystemClock.elapsedRealtime()
        synchronized(operationLock) {
            if (now < busyUntilMs) {
                val message = if (lastOperationKey == key) {
                    "重复导航已抑制"
                } else {
                    "上一笔导航事务仍在进行中"
                }
                return failure(1006, message)
            }
            lastOperationKey = key
            busyUntilMs = now + if (options.animated) {
                options.deduplicateWindowMs
            } else {
                min(options.deduplicateWindowMs, 80L)
            }
        }
        return null
    }

    private fun finishEntries(
        context: Context,
        entries: List<LynxNavigationEntry>,
        animated: Boolean,
    ) {
        entries.forEach { entry ->
            AndroidNavigationResultStore.remove(context, entry.entryID)
            entry.activity.get()?.let { activity ->
                if (!activity.isFinishing && !activity.isDestroyed) {
                    finishActivity(activity, animated)
                }
            }
        }
    }

    private fun finishEntriesWithTransition(
        context: Context,
        entries: List<LynxNavigationEntry>,
        options: LynxNavigationOptions,
        useStoredTransition: Boolean,
        beforeCommit: () -> Unit,
    ): Boolean {
        if (entries.isEmpty()) {
            beforeCommit()
            return true
        }
        val currentActivity = context.findActivity() as? LynxShellActivity
        val includesCurrent = currentActivity != null &&
            entries.any { it.activity.get() === currentActivity }
        if (!includesCurrent) {
            // NativeModules 发起的批量路由如果丢失当前 coordinator，宁可明确失败，也不能
            // 回落到多个 Activity 的系统 close animation。
            return false
        }
        val currentEntry = LynxNavigationRegistry.entryFor(requireNotNull(currentActivity))
        val batchSnapshotTicket = if (entries.size > 1) {
            // entries 按 pop 顺序传入；order 最小的被关闭页，其入场 source 就是最终目标页。
            LynxTransitionRuntime.ticketForTargetEntry(
                entries.minByOrNull(LynxNavigationEntry::order)?.entryID,
            )
        } else {
            null
        }
        val hasBatchTargetSnapshot = batchSnapshotTicket
            ?.sourceWindowSnapshotToken
            ?.let(LynxSnapshotStore::get) != null
        val batchSnapshotReason = if (entries.size > 1 && !hasBatchTargetSnapshot) {
            "batch_target_snapshot_unavailable"
        } else {
            null
        }
        return requireNotNull(currentActivity).requestNavigationBack(
            animated = options.animated,
            useStoredTransition = useStoredTransition || hasBatchTargetSnapshot,
            // 未显式传 transition/routeType 时延续当前页存储的 POP；显式参数则冻结为
            // 本次独立 transaction，绝不能被旧 push ticket 覆盖。
            transitionSpecOverride = options.transitionSpec.takeIf {
                it.explicitlyRequested
            },
            snapshotTicket = batchSnapshotTicket,
            forceTransaction = true,
            routeKey = currentEntry?.routeKey,
            transactionReason = batchSnapshotReason,
        ) {
            beforeCommit()
            // coordinator 已经完成唯一一段视觉动画；批量 finish 全部静默提交。
            finishEntries(context, entries, animated = false)
        }
    }

    @Suppress("DEPRECATION")
    private fun finishActivity(activity: Activity, animated: Boolean) {
        if (!animated) {
            suppressCloseAnimation(activity)
        }
        activity.finish()
        if (!animated) {
            // 部分 OEM 在 finish 时重新读取 Window animation，再压一次确保不会叠加系统返回。
            suppressCloseAnimation(activity)
        }
    }

    @Suppress("DEPRECATION")
    private fun suppressCloseAnimation(activity: Activity) {
        if (Build.VERSION.SDK_INT >= 34) {
            activity.overrideActivityTransition(
                Activity.OVERRIDE_TRANSITION_CLOSE,
                R.anim.lynx_no_animation,
                R.anim.lynx_no_animation,
            )
        }
        activity.overridePendingTransition(0, 0)
    }

    @Suppress("DEPRECATION")
    private fun suppressOpenAnimation(activity: Activity) {
        if (Build.VERSION.SDK_INT >= 34) {
            activity.overrideActivityTransition(
                Activity.OVERRIDE_TRANSITION_OPEN,
                R.anim.lynx_no_animation,
                R.anim.lynx_no_animation,
            )
        }
        activity.overridePendingTransition(0, 0)
    }

    private fun entryData(
        entry: LynxNavigationEntry,
        launchMode: LynxLaunchMode,
    ): HashMap<String, Any> = hashMapOf(
        "entryID" to entry.entryID,
        "routeKey" to entry.routeKey,
        "launchMode" to launchMode.wireName,
    )

    private fun success(
        message: String,
        affectedCount: Int = 0,
        data: Map<String, Any> = emptyMap(),
    ) = LynxNavigationResult(
        code = 0,
        message = message,
        affectedCount = affectedCount,
        data = data,
    )

    private fun failure(code: Int, message: String) =
        LynxNavigationResult(code = code, message = message)
}

/** 当前进程中仍存活的 Lynx Activity 弱引用注册项。 */
private data class LynxNavigationEntry(
    val activity: WeakReference<LynxShellActivity>,
    val sessionID: String,
    val entryID: String,
    val parentEntryID: String?,
    val routeKey: String,
    val hasHostAnchor: Boolean,
    val order: Long,
)

/** Native Page Stack 的跨层只读身份。 */
internal data class LynxRouterPageIdentity(
    val sessionID: String,
    val entryID: String,
    val routeKey: String,
)

/**
 * 进程内 Activity 注册表。
 *
 * Android 系统负责真正的 task 栈；这里仅维护当前进程可观察的 Lynx entry。显式
 * `order` 来自 Intent，可抵抗配置变更和进程恢复时 onCreate 回调顺序变化。
 */
private object LynxNavigationRegistry {
    private val entries = mutableListOf<LynxNavigationEntry>()

    @Synchronized
    fun register(
        activity: LynxShellActivity,
        sessionID: String,
        entryID: String,
        parentEntryID: String?,
        routeKey: String,
        hasHostAnchor: Boolean,
        order: Long,
    ) {
        cleanup()
        entries.removeAll { it.activity.get() === activity || it.entryID == entryID }
        entries += LynxNavigationEntry(
            activity = WeakReference(activity),
            sessionID = sessionID,
            entryID = entryID,
            parentEntryID = parentEntryID,
            routeKey = routeKey,
            hasHostAnchor = hasHostAnchor,
            order = order,
        )
    }

    @Synchronized
    fun updateRoute(activity: LynxShellActivity, routeKey: String) {
        cleanup()
        val index = entries.indexOfLast { it.activity.get() === activity }
        if (index >= 0) entries[index] = entries[index].copy(routeKey = routeKey)
    }

    @Synchronized
    fun unregister(activity: LynxShellActivity) {
        entries.removeAll { it.activity.get() == null || it.activity.get() === activity }
    }

    @Synchronized
    fun entryFor(activity: Activity): LynxNavigationEntry? {
        cleanup()
        return entries.lastOrNull { it.activity.get() === activity }
    }

    @Synchronized
    fun entriesForSession(sessionID: String): List<LynxNavigationEntry> {
        cleanup()
        return entries.filter { it.sessionID == sessionID }.sortedBy { it.order }
    }

    @Synchronized
    fun nextOrderForSession(sessionID: String): Long {
        cleanup()
        return (entries.filter { it.sessionID == sessionID }.maxOfOrNull { it.order } ?: -1L) + 1L
    }

    private fun cleanup() {
        entries.removeAll { entry ->
            val activity = entry.activity.get()
            activity == null || activity.isDestroyed || activity.isFinishing
        }
    }
}

/**
 * 页面返回结果的轻量持久层。
 *
 * 结果以目标 entryID 为 key 写入专用 SharedPreferences。这样目标 Activity 因系统回收
 * 后重建时仍能读取；读取采用 remove-before-return，确保同一结果最多消费一次。
 */
private object AndroidNavigationResultStore {
    private const val PREFERENCES_NAME = "lynx_shell_navigation_results"
    private const val KEY_PREFIX = "entry."

    fun put(
        context: Context,
        targetEntryID: String,
        payloadJson: String,
        source: LynxNavigationEntry,
    ) {
        val envelope = JSONObject()
            .put("result", JsonObjectCodec.requireObject(payloadJson, "navigation result"))
            .put("sourceEntryID", source.entryID)
            .put("sourceRouteKey", source.routeKey)
            .put("createdAt", System.currentTimeMillis())
        preferences(context).edit()
            .putString(KEY_PREFIX + targetEntryID, envelope.toString())
            .apply()
    }

    fun consume(context: Context, entryID: String): HashMap<String, Any>? {
        val key = KEY_PREFIX + entryID
        val preferences = preferences(context)
        val value = preferences.getString(key, null) ?: return null
        preferences.edit().remove(key).apply()
        return runCatching {
            JsonObjectCodec.objectToMap(JSONObject(value))
        }.getOrNull()
    }

    fun remove(context: Context, entryID: String) {
        preferences(context).edit().remove(KEY_PREFIX + entryID).apply()
    }

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
}

/** 从 LynxContext/ContextWrapper 安全追溯真实 Activity。 */
fun Context.findActivity(): Activity? {
    var cursor: Context? = this
    while (cursor is ContextWrapper) {
        if (cursor is Activity) return cursor
        val next = cursor.baseContext
        if (next === cursor) break
        cursor = next
    }
    return cursor as? Activity
}
