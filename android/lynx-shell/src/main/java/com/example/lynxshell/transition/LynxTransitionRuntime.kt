package com.example.lynxshell.transition

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import androidx.core.view.WindowInsetsControllerCompat
import com.example.lynxshell.R
import com.example.lynxshell.container.LynxShellActivity
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.routing.LynxNavigationOptions
import com.lynx.react.bridge.JavaOnlyArray
import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.tasm.LynxView
import java.lang.ref.WeakReference
import java.util.LinkedHashMap
import java.util.UUID

data class LynxTransitionAcceptance(
    val transactionID: String,
    val requestedTransition: LynxTransitionStyle,
    val effectiveTransition: LynxTransitionStyle,
    val reason: String?,
) {
    fun toMap(): HashMap<String, Any> = hashMapOf<String, Any>(
        "transactionID" to transactionID,
        "requestedTransition" to requestedTransition.wireName,
        "effectiveTransition" to effectiveTransition.wireName,
        "direction" to LynxTransitionDirection.PUSH.wireName,
    ).apply {
        reason?.let { put("reason", it) }
    }
}

/**
 * 跨 Activity 的进程内事务中心。
 *
 * 重要边界：只要调用方显式提供 transition 或 routeType，本类就为 Intent 加
 * FLAG_ACTIVITY_NO_ANIMATION，并在 startActivity 前后压制 Window open 动画。所有可见
 * 动画都由目标 Activity 内的 [LynxTransitionCoordinator] 绘制；这里只冻结源页。
 */
object LynxTransitionRuntime {
    private const val MAX_RECORDS = 16

    private data class Record(
        var ticket: AndroidTransitionTicket,
        var state: LynxTransitionState,
        var coordinator: WeakReference<LynxTransitionCoordinator>? = null,
    )

    private val records = LinkedHashMap<String, Record>(20, 0.75f, true)
    private var latestTransactionID: String? = null

    fun launch(
        context: Context,
        sourceActivity: Activity?,
        request: LynxPageRequest,
        options: LynxNavigationOptions,
        intent: Intent,
        sourceEntryID: String?,
        targetEntryID: String,
    ): Result<LynxTransitionAcceptance> {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            "原生转场必须在 Android 主线程发起"
        }
        val spec = options.transitionSpec
        check(spec.explicitlyRequested) {
            "LynxTransitionRuntime 只接收显式 transition/routeType"
        }
        val motion = LynxMotionPolicy.resolve(
            context = context,
            requested = spec.style,
            durationMs = spec.durationMs,
            // heroSheet 是透明宿主模式：原生不移动 liveContent，动画完全由 Lynx 页面负责。
            animated = options.animated && spec.routePreset != LynxRoutePreset.HERO_SHEET,
        )
        val resolvedSpec = spec.copy(
            durationMs = motion.durationMs,
            reverseDurationMs = if (motion.style == LynxTransitionStyle.NONE) {
                0L
            } else {
                spec.reverseDurationMs
            },
        )
        // LynxShellActivity 可释放 LynxView、保留 Activity 身份并在返回时重建。宿主原生
        // Activity 没有统一重建协议，只能明确报告边界，不能擅自销毁业务页面。
        val initialReason = motion.reason ?: if (
            !resolvedSpec.routeConfig.maintainState &&
            sourceActivity !is LynxShellActivity
        ) {
            "maintain_state_false_host_activity_not_releasable"
        } else {
            null
        }
        val transactionID = UUID.randomUUID().toString()
        val ticket = AndroidTransitionTicket(
            transactionID = transactionID,
            requestedTransition = spec.style,
            effectiveTransition = motion.style,
            fallbackTransition = spec.fallbackStyle,
            routeKey = request.resolvedRouteKey(),
            sourceEntryID = sourceEntryID,
            targetEntryID = targetEntryID,
            spec = resolvedSpec,
            sourceLightStatusBars = sourceActivity?.let {
                WindowInsetsControllerCompat(
                    it.window,
                    it.window.decorView,
                ).isAppearanceLightStatusBars
            },
            reason = initialReason,
        )
        register(ticket)
        options.preparedRouteToken?.let {
            intent.putExtra(LynxTransitionIntent.EXTRA_PREPARED_ROUTE_TOKEN, it)
        }
        val acceptance = LynxTransitionAcceptance(
            transactionID = transactionID,
            requestedTransition = spec.style,
            effectiveTransition = motion.style,
            reason = initialReason,
        )

        // allowEnterRouteSnapshotting 是硬边界：false 时即使页面非 opaque 或
        // maintainState=false 也不能暗中截图。需要 source route 的 renderer 会带明确
        // reason 降级，主 route 自身仍可继续播放内容层动画。
        val requiresSourceSnapshot =
            motion.style == LynxTransitionStyle.SHARED_ELEMENT ||
                motion.style == LynxTransitionStyle.OPEN_CONTAINER ||
                resolvedSpec.routePreset != null ||
                !resolvedSpec.routeConfig.opaque ||
                !resolvedSpec.routeConfig.maintainState
        val shouldSnapshot = (motion.style != LynxTransitionStyle.NONE || requiresSourceSnapshot) &&
            resolvedSpec.routeConfig.allowEnterRouteSnapshotting
        if (!shouldSnapshot) {
            if (motion.style != LynxTransitionStyle.NONE && requiresSourceSnapshot) {
                return launchWithoutSnapshot(
                    context,
                    sourceActivity,
                    intent,
                    ticket,
                    acceptance,
                    "enter_route_snapshotting_disabled",
                )
            }
            return launchPrepared(
                context = context,
                sourceActivity = sourceActivity,
                intent = intent,
                ticket = ticket,
                acceptance = acceptance,
            )
        }
        if (sourceActivity == null) {
            return launchWithoutSnapshot(
                context,
                null,
                intent,
                ticket,
                acceptance,
                "source_activity_missing",
            )
        }

        val requiredElements = resolveRequiredSourceElements(
            sourceActivity = sourceActivity,
            ticket = ticket,
        )
        if (requiredElements.isFailure) {
            return launchWithoutSnapshot(
                context,
                sourceActivity,
                intent,
                ticket,
                acceptance,
                requiredElements.exceptionOrNull()?.message ?: "source_selector_missing",
            )
        }

        // tap 回调刚结束时来源节点仍可能保持按压/高亮态。下一原生绘制帧再 PixelCopy，
        // 让来源页先恢复稳定外观，避免目标 Activity 用“按下状态”快照造成开场闪烁。
        // NativeModules.open 的 callback 仍只表示事务已接受，不等待截图或动画完成。
        sourceActivity.window.decorView.postOnAnimation {
            LynxSnapshotter.captureWindow(sourceActivity) { result ->
                result.onSuccess { windowBitmap ->
                    val frozenElements = mutableListOf<AndroidSharedElementSnapshot>()
                    var elementFailure: String? = null
                    requiredElements.getOrThrow().forEach { required ->
                        if (elementFailure != null) return@forEach
                        val bitmap = LynxSnapshotter.cropWindowBitmap(
                            sourceActivity,
                            windowBitmap,
                            required.rectOnScreen,
                        )
                        val token = bitmap?.let(LynxSnapshotStore::put)
                        if (token == null) {
                            elementFailure = "snapshot_unavailable:${required.key}"
                        } else {
                            frozenElements += AndroidSharedElementSnapshot(
                                key = required.key,
                                rectOnScreen = Rect(required.rectOnScreen),
                                snapshotToken = token,
                            )
                        }
                    }
                    if (elementFailure != null) {
                        frozenElements.forEach { LynxSnapshotStore.remove(it.snapshotToken) }
                        launchWithoutSnapshot(
                            context,
                            sourceActivity,
                            intent,
                            ticket,
                            acceptance,
                            requireNotNull(elementFailure),
                        )
                        return@onSuccess
                    }
                    if (
                        !LynxSnapshotter.clearWindowRects(
                            sourceActivity,
                            windowBitmap,
                            requiredElements.getOrThrow().map { it.rectOnScreen },
                        )
                    ) {
                        frozenElements.forEach { LynxSnapshotStore.remove(it.snapshotToken) }
                        launchWithoutSnapshot(
                            context,
                            sourceActivity,
                            intent,
                            ticket,
                            acceptance,
                            "source_underlay_redaction_failed",
                        )
                        return@onSuccess
                    }
                    val windowToken = LynxSnapshotStore.put(windowBitmap)
                    if (windowToken == null) {
                        frozenElements.forEach { LynxSnapshotStore.remove(it.snapshotToken) }
                        launchWithoutSnapshot(
                            context,
                            sourceActivity,
                            intent,
                            ticket,
                            acceptance,
                            "snapshot_unavailable",
                        )
                        return@onSuccess
                    }
                    val lruEvictedRequiredSnapshot =
                        LynxSnapshotStore.get(windowToken) == null ||
                            frozenElements.any {
                                LynxSnapshotStore.get(it.snapshotToken) == null
                            }
                    if (lruEvictedRequiredSnapshot) {
                        LynxSnapshotStore.remove(windowToken)
                        frozenElements.forEach { LynxSnapshotStore.remove(it.snapshotToken) }
                        launchWithoutSnapshot(
                            context,
                            sourceActivity,
                            intent,
                            ticket,
                            acceptance,
                            "snapshot_budget_exceeded",
                        )
                        return@onSuccess
                    }

                    val first = frozenElements.firstOrNull()
                    val preparedTicket = ticket.copy(
                        sourceElements = frozenElements,
                        // 兼容旧 coordinator/进程内诊断字段。
                        sourceRectOnScreen = first?.let { Rect(it.rectOnScreen) },
                        sourceWindowSnapshotToken = windowToken,
                        sourceElementSnapshotToken = first?.snapshotToken,
                        sourceWindowWidth = windowBitmap.width,
                        sourceWindowHeight = windowBitmap.height,
                        sourceBackdropColor = LynxSnapshotter.sampleTopEdgeColor(windowBitmap),
                    )
                    replaceTicket(preparedTicket)
                    launchPrepared(
                        context,
                        sourceActivity,
                        intent,
                        preparedTicket,
                        acceptance,
                    )
                }.onFailure {
                    launchWithoutSnapshot(
                        context,
                        sourceActivity,
                        intent,
                        ticket,
                        acceptance,
                        "snapshot_unavailable",
                    )
                }
            }
        }
        return Result.success(acceptance)
    }

    @Synchronized
    fun hasActiveTransaction(): Boolean =
        records.values.any {
            it.state.status == LynxTransitionStatus.ACCEPTED ||
                it.state.status == LynxTransitionStatus.WAITING_TARGET ||
                it.state.status == LynxTransitionStatus.RUNNING ||
                it.state.status == LynxTransitionStatus.SETTLING
        }

    @Synchronized
    fun ticket(transactionID: String?): AndroidTransitionTicket? =
        transactionID?.let { records[it]?.ticket }

    /**
     * 批量 pop 要显示最终目标页，而不是只显示当前页下面的中间页。
     *
     * 例如 A-B-C-D-E -> A 时，最早被关闭的 B 事务保存的 source Window 正是 A。
     */
    @Synchronized
    fun ticketForTargetEntry(targetEntryID: String?): AndroidTransitionTicket? {
        if (targetEntryID.isNullOrBlank()) return null
        return records.values
            .map(Record::ticket)
            .lastOrNull { it.targetEntryID == targetEntryID }
    }

    /**
     * 为 back/popTo/clearTop/closeAll/reLaunch 冻结一次独立 POP 事务。
     *
     * invocationSpec 是本次 NativeModules 调用解析后的不可变配置；snapshotTicket 只提供
     * 最终目标页的冻结内容，不会覆盖调用方指定的 style/routeType/duration。
     */
    @Synchronized
    fun beginPopTransaction(
        context: Context,
        currentTicket: AndroidTransitionTicket?,
        snapshotTicket: AndroidTransitionTicket?,
        invocationSpec: LynxTransitionSpec,
        animated: Boolean,
        routeKey: String?,
        reasonOverride: String? = null,
    ): AndroidTransitionTicket {
        val motion = LynxMotionPolicy.resolve(
            context = context,
            requested = invocationSpec.style,
            durationMs = invocationSpec.reverseDurationMs,
            animated = animated && invocationSpec.routePreset != LynxRoutePreset.HERO_SHEET,
        )
        val source = snapshotTicket ?: currentTicket
        val resolvedSpec = invocationSpec.copy(
            reverseDurationMs = motion.durationMs,
        )
        val inheritedReason = currentTicket?.reason?.takeIf {
            motion.style != LynxTransitionStyle.NONE &&
                invocationSpec.style == currentTicket.effectiveTransition &&
                invocationSpec.routePreset == currentTicket.spec.routePreset
        }
        val ticket = AndroidTransitionTicket(
            transactionID = UUID.randomUUID().toString(),
            requestedTransition = invocationSpec.style,
            effectiveTransition = motion.style,
            fallbackTransition = invocationSpec.fallbackStyle,
            direction = LynxTransitionDirection.POP,
            routeKey = routeKey
                ?: currentTicket?.routeKey
                ?: source?.routeKey
                ?: "navigation-pop",
            sourceEntryID = source?.sourceEntryID,
            targetEntryID = currentTicket?.sourceEntryID
                ?: source?.sourceEntryID
                ?: "navigation-pop-target",
            spec = resolvedSpec,
            sourceElements = source?.sourceElements.orEmpty(),
            sourceRectOnScreen = source?.sourceRectOnScreen?.let(::Rect),
            sourceWindowSnapshotToken = source?.sourceWindowSnapshotToken,
            sourceElementSnapshotToken = source?.sourceElementSnapshotToken,
            sourceWindowWidth = source?.sourceWindowWidth ?: 0,
            sourceWindowHeight = source?.sourceWindowHeight ?: 0,
            sourceBackdropColor = source?.sourceBackdropColor,
            sourceLightStatusBars = source?.sourceLightStatusBars,
            reason = motion.reason ?: reasonOverride ?: inheritedReason,
        )
        register(ticket)
        return ticket
    }

    @Synchronized
    fun attachCoordinator(
        transactionID: String,
        coordinator: LynxTransitionCoordinator,
    ) {
        records[transactionID]?.coordinator = WeakReference(coordinator)
    }

    @Synchronized
    fun detachCoordinator(
        transactionID: String?,
        coordinator: LynxTransitionCoordinator,
    ) {
        if (transactionID == null) return
        val record = records[transactionID] ?: return
        if (record.coordinator?.get() === coordinator) record.coordinator = null
    }

    fun markReady(transactionID: String): Boolean {
        val coordinator = synchronized(this) {
            val record = records[transactionID] ?: return false
            record.coordinator?.get()
        }
        coordinator?.onBusinessReady()
        return true
    }

    @Synchronized
    fun state(transactionID: String?): LynxTransitionState? =
        transactionID?.let { records[it]?.state }

    @Synchronized
    fun stateFor(intent: Intent?): LynxTransitionState {
        val transactionID = intent?.let(LynxTransitionIntent::transactionID)
            ?: latestTransactionID
        val record = transactionID?.let(records::get)
        return record?.state
            ?: intent?.let(LynxTransitionIntent::diagnosticState)
            ?: LynxTransitionState()
    }

    @Synchronized
    fun update(
        transactionID: String,
        status: LynxTransitionStatus,
        direction: LynxTransitionDirection? = null,
        progress: Float? = null,
        effectiveTransition: LynxTransitionStyle? = null,
        reason: String? = null,
    ) {
        val record = records[transactionID] ?: return
        record.state = record.state.copy(
            status = status,
            direction = direction ?: record.state.direction,
            progress = progress?.coerceIn(0f, 1f) ?: record.state.progress,
            effectiveTransition = effectiveTransition ?: record.state.effectiveTransition,
            reason = reason ?: record.state.reason,
            updatedAt = System.currentTimeMillis(),
        )
        latestTransactionID = transactionID
    }

    @Synchronized
    fun release(transactionID: String?) {
        if (transactionID.isNullOrBlank()) return
        val record = records[transactionID] ?: return
        releaseTicketSnapshots(record.ticket)
        record.ticket = record.ticket.copy(
            sourceElements = emptyList(),
            sourceWindowSnapshotToken = null,
            sourceElementSnapshotToken = null,
        )
        record.coordinator = null
    }

    private data class RequiredSourceElement(
        val key: String,
        val rectOnScreen: Rect,
    )

    private fun resolveRequiredSourceElements(
        sourceActivity: Activity,
        ticket: AndroidTransitionTicket,
    ): Result<List<RequiredSourceElement>> = runCatching {
        val shellActivity = sourceActivity as? LynxShellActivity
        val descriptors = when (ticket.effectiveTransition) {
            LynxTransitionStyle.SHARED_ELEMENT ->
                ticket.spec.sharedElements.map { it.key to it.sourceSelector }
            LynxTransitionStyle.OPEN_CONTAINER ->
                listOf("__open_container__" to requireNotNull(ticket.spec.openContainer).sourceSelector)
            else -> emptyList()
        }
        if (descriptors.isEmpty()) return@runCatching emptyList()
        requireNotNull(shellActivity) { "source_selector_missing" }
        descriptors.map { (key, selector) ->
            val resolved = LynxElementResolver.resolve(
                shellActivity.currentLynxView(),
                selector,
            ) ?: throw IllegalArgumentException("source_selector_missing:$key")
            RequiredSourceElement(key, Rect(resolved.rectOnScreen))
        }
    }

    private fun launchWithoutSnapshot(
        context: Context,
        sourceActivity: Activity?,
        intent: Intent,
        original: AndroidTransitionTicket,
        acceptance: LynxTransitionAcceptance,
        reason: String,
    ): Result<LynxTransitionAcceptance> {
        // shared/open 没有源元素就改走调用方声明的内容层 fallback；基础/preset 仍可在目标
        // Activity 中完成自身 renderer，只是没有上一页快照作为 underlay。
        val shouldFallback = original.effectiveTransition in setOf(
            LynxTransitionStyle.SHARED_ELEMENT,
            LynxTransitionStyle.OPEN_CONTAINER,
        )
        val fallback = original.copy(
            effectiveTransition = if (shouldFallback) {
                original.fallbackTransition
            } else {
                original.effectiveTransition
            },
            reason = reason,
        )
        replaceTicket(fallback)
        return launchPrepared(
            context,
            sourceActivity,
            intent,
            fallback,
            acceptance.copy(
                effectiveTransition = fallback.effectiveTransition,
                reason = reason,
            ),
        )
    }

    private fun launchPrepared(
        context: Context,
        sourceActivity: Activity?,
        intent: Intent,
        ticket: AndroidTransitionTicket,
        acceptance: LynxTransitionAcceptance,
    ): Result<LynxTransitionAcceptance> {
        val releaseRequested = !ticket.spec.routeConfig.maintainState
        val sourceShell = sourceActivity as? LynxShellActivity
        val releasedSource = if (releaseRequested && sourceShell != null) {
            sourceShell.releaseContentForRouteSnapshot()
        } else {
            false
        }
        val preparedTicket = if (releaseRequested && sourceShell != null && !releasedSource) {
            ticket.copy(
                reason = ticket.reason ?: "maintain_state_false_source_release_failed",
            )
        } else {
            ticket
        }
        replaceTicket(preparedTicket)
        LynxTransitionIntent.write(intent, preparedTicket)
        return runCatching {
            startActivityWithoutWindowAnimation(context, sourceActivity, intent)
            update(
                transactionID = preparedTicket.transactionID,
                status = LynxTransitionStatus.WAITING_TARGET,
                effectiveTransition = preparedTicket.effectiveTransition,
                reason = preparedTicket.reason,
            )
            acceptance.copy(
                effectiveTransition = preparedTicket.effectiveTransition,
                reason = preparedTicket.reason,
            )
        }.onFailure { error ->
            if (releasedSource) sourceShell?.restoreContentReleasedForRouteSnapshot()
            update(
                preparedTicket.transactionID,
                LynxTransitionStatus.FAILED,
                reason = error.message ?: "page_destroyed",
            )
            // 目标 Activity 根本没有建立 coordinator 时，失败终态必须回送源 LynxView；
            // 否则页面只拿到 open 的 accepted callback，永远等不到 settled。
            dispatchTransitionSettled(
                lynxView = sourceShell?.currentLynxView(),
                transactionID = preparedTicket.transactionID,
                routeType = preparedTicket.spec.routeType,
            )
        }
    }

    private fun dispatchTransitionSettled(
        lynxView: LynxView?,
        transactionID: String,
        routeType: String?,
    ) {
        val payload = state(transactionID)?.toMap() ?: return
        routeType?.let { payload["routeType"] = it }
        runCatching {
            lynxView?.sendGlobalEvent(
                "onTransitionSettled",
                JavaOnlyArray.of(JavaOnlyMap.from(payload)),
            )
        }
    }

    @Synchronized
    private fun register(ticket: AndroidTransitionTicket) {
        while (records.size >= MAX_RECORDS) {
            val oldest = records.entries.firstOrNull() ?: break
            evict(oldest.key)
        }
        records[ticket.transactionID] = Record(
            ticket = ticket,
            state = LynxTransitionState(
                transactionID = ticket.transactionID,
                status = LynxTransitionStatus.ACCEPTED,
                requestedTransition = ticket.requestedTransition,
                effectiveTransition = ticket.effectiveTransition,
                direction = ticket.direction,
                reason = ticket.reason,
                routeKey = ticket.routeKey,
            ),
        )
        latestTransactionID = ticket.transactionID
    }

    @Synchronized
    private fun replaceTicket(ticket: AndroidTransitionTicket) {
        val record = records[ticket.transactionID] ?: return
        record.ticket = ticket
        record.state = record.state.copy(
            effectiveTransition = ticket.effectiveTransition,
            reason = ticket.reason,
            updatedAt = System.currentTimeMillis(),
        )
    }

    @Synchronized
    private fun evict(transactionID: String) {
        val ticket = records.remove(transactionID)?.ticket ?: return
        releaseTicketSnapshots(ticket)
        if (latestTransactionID == transactionID) latestTransactionID = records.keys.lastOrNull()
    }

    private fun releaseTicketSnapshots(ticket: AndroidTransitionTicket) {
        LynxSnapshotStore.remove(ticket.sourceWindowSnapshotToken)
        val tokens = buildSet {
            ticket.sourceElementSnapshotToken?.let(::add)
            ticket.sourceElements.forEach { add(it.snapshotToken) }
        }
        tokens.forEach(LynxSnapshotStore::remove)
    }

    /**
     * 显式转场的唯一启动通道。严禁调用平台自定义 Window animation API。
     *
     * Android 14 用 overrideActivityTransition，旧系统用 overridePendingTransition；目标
     * Activity 的 onCreate 还会再压一次，规避部分 OEM 在 launch 后重新读取 Window 样式。
     */
    @Suppress("DEPRECATION")
    private fun startActivityWithoutWindowAnimation(
        context: Context,
        sourceActivity: Activity?,
        intent: Intent,
    ) {
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        intent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
        suppressOpenAnimation(sourceActivity)
        context.startActivity(intent)
        suppressOpenAnimation(sourceActivity)
    }

    @Suppress("DEPRECATION")
    private fun suppressOpenAnimation(activity: Activity?) {
        activity ?: return
        if (Build.VERSION.SDK_INT >= 34) {
            activity.overrideActivityTransition(
                Activity.OVERRIDE_TRANSITION_OPEN,
                R.anim.lynx_no_animation,
                R.anim.lynx_no_animation,
            )
        }
        activity.overridePendingTransition(0, 0)
    }
}
