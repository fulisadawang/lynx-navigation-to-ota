package com.example.lynxshell.telemetry

import java.util.concurrent.atomic.AtomicLong

/** 可替换时钟，单测使用固定时间，生产使用系统墙钟和单调钟。 */
interface TelemetryClock {
    fun nowUnixMillis(): Long
    fun nowMonotonicMillis(): Long
}

object SystemTelemetryClock : TelemetryClock {
    override fun nowUnixMillis(): Long = System.currentTimeMillis()

    override fun nowMonotonicMillis(): Long = System.nanoTime() / 1_000_000L
}

/**
 * Android Activity-first 页面旁路监控协调器。
 *
 * 这个类只管理“观察事实”和内存中的事件，不改变 Router/OTA 的成功回调，也不执行网络上传。
 * 任意 Observer、Debug Sink 或输入异常都会 fail-open，绝不能阻塞 Lynx 首屏。
 */
class TelemetryCoordinator(
    private val pageIdentity: TelemetryIdentity,
    private val hostContext: TelemetryHostContext = TelemetryHostContext(),
    private val sink: TelemetrySink = NoOpTelemetrySink,
    private val config: TelemetryConfig = TelemetryConfig(),
    private val clock: TelemetryClock = SystemTelemetryClock,
    private val idFactory: () -> String = ::newTelemetryId,
) {
    private val sequence = AtomicLong(0L)
    private var generationCounter = 0L
    private var currentGeneration: Long? = null
    private var currentIdentity = pageIdentity
    private var currentAttempted: AttemptedBundleSnapshot? = null
    private var currentResolved: ResolvedBundleSnapshot? = null
    private var firstScreenEmitted = false
    private var navigationAdmission: NavigationAdmission? = null
    private var transitionTerminalEmitted = false
    private var transitionTerminal: TransitionTerminal? = null
    private var transitionDurationMs: Long? = null
    private var lifecycleReason: String? = null
    private var navigationRejectionCode: String? = null
    private var pageState = PageLifecycleState.ALLOCATED
    // Activity 创建通常发生在 App 已经前台；真正的后台状态由宿主显式回调覆盖。
    private var appState = AppLifecycleState.FOREGROUND
    private var attemptState = RenderAttemptState.UNUSABLE
    private var activeActivationId: String? = null
    private var exposureObserverGeneration = 0L
    private var samplingDecision: SamplingDecision? = null
    private val pageOpenKeys = mutableSetOf<String>()

    /** 最近一次 attempt 的 generation；没有开始渲染时为 null。 */
    fun currentGeneration(): Long? = currentGeneration

    fun currentPageState(): PageLifecycleState = pageState

    fun currentAppState(): AppLifecycleState = appState

    fun currentAttemptState(): RenderAttemptState = attemptState

    fun activeEligible(): Boolean =
        pageState == PageLifecycleState.VISIBLE &&
            appState == AppLifecycleState.FOREGROUND &&
            attemptState == RenderAttemptState.USABLE

    fun activeActivationId(): String? = activeActivationId

    fun currentAttemptedSnapshot(): AttemptedBundleSnapshot? = currentAttempted

    fun currentResolvedSnapshot(): ResolvedBundleSnapshot? = currentResolved

    /** navigation_requested 不创建 pageView；Router 仍可以据此统计调用量和拒绝率。 */
    fun onNavigationRequested(): Boolean = emit(
        eventName = "lynx.navigation.requested",
        category = TelemetryCategory.NAVIGATION,
        includePageIdentity = false,
        attributes = emptyMap(),
    )

    /** navigation_accepted 只表示宿主已受理，不等于首屏或转场完成。 */
    fun onNavigationAccepted(): Boolean {
        navigationAdmission = NavigationAdmission.ACCEPTED
        return emit(
            eventName = "lynx.navigation.accepted",
            category = TelemetryCategory.NAVIGATION,
            includePageIdentity = true,
            attributes = emptyMap(),
        )
    }

    /** 参数拒绝时不带 pageViewId/entryId，避免把未创建页面误算为 PV。 */
    fun onNavigationRejected(reasonCode: String): Boolean {
        navigationAdmission = NavigationAdmission.REJECTED
        val safeReason = sanitizeValue(reasonCode)
        navigationRejectionCode = safeReason
        return emit(
            eventName = "lynx.navigation.rejected",
            category = TelemetryCategory.NAVIGATION,
            includePageIdentity = false,
            attributes = mapOf("reasonCode" to safeReason),
        )
    }

    /**
     * 创建一次 load/reload/recovery attempt。调用时先冻结 Attempted Snapshot，随后才进入 prepare。
     * 旧 attempt 的回调只能通过 stale generation 诊断被丢弃。
     */
    fun beginRenderAttempt(snapshot: AttemptedBundleSnapshot): Long {
        endActivationIfNeeded("reload")
        generationCounter += 1L
        val generation = generationCounter
        currentGeneration = generation
        currentIdentity = pageIdentity.copy(
            renderAttemptId = idFactory(),
            activationId = null,
        )
        currentAttempted = snapshot.copy(attemptGeneration = generation)
        currentResolved = null
        firstScreenEmitted = false
        transitionTerminalEmitted = false
        transitionTerminal = null
        transitionDurationMs = null
        lifecycleReason = "reload"
        attemptState = RenderAttemptState.UNUSABLE
        pageState = if (pageState == PageLifecycleState.DESTROYED) {
            PageLifecycleState.ALLOCATED
        } else {
            PageLifecycleState.REGISTERED
        }
        emit(
            eventName = "lynx.page.load_started",
            category = TelemetryCategory.PAGE,
            includePageIdentity = true,
            attributes = mapOf("attemptGeneration" to generation.toString()),
        )
        return generation
    }

    /** prepare 成功后冻结 Resolved Snapshot，并把 attempt 置为可用。 */
    fun resolveBundle(generation: Long, snapshot: ResolvedBundleSnapshot): Boolean {
        if (!isCurrentGeneration(generation)) return false
        currentResolved = snapshot
        attemptState = RenderAttemptState.USABLE
        emit(
            eventName = "lynx.page.runtime_ready",
            category = TelemetryCategory.PAGE,
            includePageIdentity = true,
            attributes = mapOf("attemptGeneration" to generation.toString()),
        )
        reconcileActivation("attempt_usable")
        return true
    }

    /** prepare 失败只关联 Attempted Snapshot，不读取失败后的 current 伪造 Resolved Snapshot。 */
    fun failPrepare(generation: Long, reasonCode: String): Boolean {
        if (!isCurrentGeneration(generation)) return false
        attemptState = RenderAttemptState.UNUSABLE
        val safeReason = sanitizeValue(reasonCode)
        emit(
            eventName = "lynx.page.failed",
            category = TelemetryCategory.PAGE,
            includePageIdentity = true,
            attributes = mapOf(
                "failureStage" to "prepare",
                "reasonCode" to safeReason,
            ),
        )
        return true
    }

    /**
     * 只有当前 attempt 首次真实首屏才产生 page_open。重复 onFirstScreen 会被幂等丢弃。
     * page_open 与 sampled_page_view 共享一个采样决定。
     */
    fun onFirstScreen(generation: Long): Boolean {
        if (!isCurrentGeneration(generation)) return false
        if (attemptState != RenderAttemptState.USABLE || firstScreenEmitted) return false
        firstScreenEmitted = true
        pageState = PageLifecycleState.VISIBLE
        reconcileActivation("first_screen")

        val key = pageOpenKey()
        val isNewKey = pageOpenKeys.add(key)
        if (!isNewKey) return true
        emit(
            eventName = "lynx.page.first_screen",
            category = TelemetryCategory.PAGE,
            includePageIdentity = true,
            attributes = mapOf("renderBoundary" to "first_screen"),
        )
        emit(
            eventName = "ota.page_open",
            category = TelemetryCategory.OTA,
            includePageIdentity = true,
            attributes = mapOf("renderBoundary" to "first_screen"),
        )
        if (sampling().sampled) {
            emit(
                eventName = "sampled_page_view",
                category = TelemetryCategory.PAGE,
                includePageIdentity = true,
                attributes = mapOf("denominator" to "page_view"),
            )
        }
        return true
    }

    /** Page 状态与 App 状态正交，页面不自行猜测 App 前后台。 */
    fun onPageLifecycle(state: PageLifecycleState, reason: String = "native_callback"): Boolean {
        if (pageState == PageLifecycleState.DESTROYED && state != PageLifecycleState.DESTROYED) return false
        if (state == PageLifecycleState.DESTROYED) endActivationIfNeeded("destroyed")
        pageState = state
        lifecycleReason = canonicalLifecycleReason(reason)
        val accepted = emit(
            eventName = "lynx.page.visibility_changed",
            category = TelemetryCategory.PAGE,
            includePageIdentity = true,
            attributes = mapOf(
                "pageState" to state.wireName,
                "reason" to sanitizeValue(reason),
            ),
        )
        reconcileActivation(reason)
        if (state == PageLifecycleState.DESTROYED) {
            emit(
                eventName = "lynx.page.destroyed",
                category = TelemetryCategory.PAGE,
                includePageIdentity = true,
                attributes = emptyMap(),
            )
        }
        return accepted
    }

    fun onApplicationLifecycle(state: AppLifecycleState, reason: String = "native_callback"): Boolean {
        if (appState == state) return false
        if (state == AppLifecycleState.BACKGROUND) endActivationIfNeeded("background")
        appState = state
        lifecycleReason = if (state == AppLifecycleState.FOREGROUND) "appForeground" else "appBackground"
        val accepted = emit(
            eventName = "app.lifecycle.changed",
            category = TelemetryCategory.APP,
            includePageIdentity = true,
            attributes = mapOf(
                "appState" to state.wireName,
                "reason" to sanitizeValue(reason),
            ),
        )
        reconcileActivation(reason)
        return accepted
    }

    /** 转场终态只允许一次；navigation accepted 仍保留独立历史事实。 */
    fun onTransitionTerminal(terminal: TransitionTerminal, durationMs: Long? = null): Boolean {
        if (transitionTerminalEmitted) return false
        transitionTerminalEmitted = true
        transitionTerminal = terminal
        transitionDurationMs = durationMs?.takeIf { it >= 0L }
        val attrs = linkedMapOf("terminal" to terminal.wireName)
        durationMs?.takeIf { it >= 0L }?.let { attrs["durationMs"] = it.toString() }
        return emit(
            eventName = "lynx.transition.terminal",
            category = TelemetryCategory.TRANSITION,
            includePageIdentity = true,
            attributes = attrs,
        )
    }

    /**
     * covered/background 后只请求 JS 重建 Observer，不合成曝光事件；返回新的 Observer generation。
     */
    fun requestExposureResume(): Long {
        exposureObserverGeneration += 1L
        emit(
            eventName = "lynx.exposure.resume_requested",
            category = TelemetryCategory.EXPOSURE,
            includePageIdentity = true,
            attributes = mapOf("observerGeneration" to exposureObserverGeneration.toString()),
        )
        return exposureObserverGeneration
    }

    /** 旧 Observer 回调直接丢弃，不能覆盖新 generation。 */
    fun acceptExposureCallback(observerGeneration: Long): Boolean {
        if (observerGeneration == exposureObserverGeneration) return true
        emit(
            eventName = "telemetry.stale_callback_dropped",
            category = TelemetryCategory.TELEMETRY,
            includePageIdentity = true,
            attributes = mapOf(
                "callbackType" to "exposure",
                "callbackGeneration" to observerGeneration.toString(),
                "currentGeneration" to exposureObserverGeneration.toString(),
            ),
        )
        return false
    }

    /** 只用于页面层接入时判断回调是否仍属于当前 attempt。 */
    fun isCurrentGeneration(generation: Long): Boolean {
        val current = currentGeneration
        if (current == generation) return true
        emit(
            eventName = "telemetry.stale_callback_dropped",
            category = TelemetryCategory.TELEMETRY,
            includePageIdentity = false,
            attributes = mapOf(
                "callbackType" to "render_attempt",
                "callbackGeneration" to generation.toString(),
                "currentGeneration" to (current?.toString() ?: "none"),
            ),
        )
        return false
    }

    private fun reconcileActivation(reason: String) {
        val eligible = activeEligible()
        if (eligible && activeActivationId == null) {
            activeActivationId = idFactory()
            emit(
                eventName = "lynx.page.activation_started",
                category = TelemetryCategory.PAGE,
                includePageIdentity = true,
                activationOverride = activeActivationId,
                attributes = mapOf("reason" to sanitizeValue(reason)),
            )
        } else if (!eligible) {
            endActivationIfNeeded(reason)
        }
    }

    private fun endActivationIfNeeded(reason: String) {
        val ended = activeActivationId ?: return
        emit(
            eventName = "lynx.page.activation_ended",
            category = TelemetryCategory.PAGE,
            includePageIdentity = true,
            activationOverride = ended,
            attributes = mapOf("reason" to sanitizeValue(reason)),
        )
        activeActivationId = null
    }

    private fun emit(
        eventName: String,
        category: TelemetryCategory,
        includePageIdentity: Boolean,
        attributes: Map<String, String>,
        activationOverride: String? = activeActivationId,
    ): Boolean {
        if (!config.isEventEnabled(eventName)) return false
        val decision = sampling()
        // 错误/失败/竞态诊断不参与普通 PV 采样，但仍受 kill switch、限流和 Sink 边界约束。
        val diagnosticEvent = eventName in DIAGNOSTIC_EVENTS
        if (!decision.sampled && !diagnosticEvent) return false
        val identity = if (includePageIdentity) {
            currentIdentity.copy(activationId = activationOverride)
        } else {
            currentIdentity.copy(
                entryId = null,
                pageViewId = null,
                renderAttemptId = null,
                activationId = null,
                transactionId = null,
            )
        }
        val event = TelemetryEvent(
            eventName = eventName,
            category = category,
            occurredAtUnixMs = clock.nowUnixMillis(),
            monotonicOffsetMs = clock.nowMonotonicMillis(),
            sequenceNo = sequence.incrementAndGet(),
            identity = identity,
            host = hostContext,
            attemptedBundle = currentAttempted?.toWireSnapshot(),
            resolvedBundle = currentResolved?.toWireSnapshot(),
            sampling = decision,
            lifecycle = TelemetryLifecycleSnapshot(
                pageState = pageState,
                appState = appState,
                attemptState = attemptState,
                activeEligible = activeEligible(),
                reason = lifecycleReason,
            ),
            navigationAdmission = TelemetryNavigationSnapshot(
                state = navigationAdmission ?: NavigationAdmission.REQUESTED,
                rejectionCode = navigationRejectionCode,
            ),
            transition = TelemetryTransitionSnapshot(
                state = if (transitionTerminalEmitted) "terminal" else "waitingTarget",
                terminal = transitionTerminal,
                durationMs = transitionDurationMs,
            ),
            analysisEligible = !diagnosticEvent,
            samplingReason = if (diagnosticEvent) "forced_diagnostic" else if (decision.sampled) "stable_cohort" else "not_sampled",
            deliveryOwner = config.deliveryOwner,
            otaOperationId = currentAttempted?.otaOperationId,
            runtimeGeneration = currentGeneration,
            attributes = sanitizeAttributes(attributes),
        )
        return runCatching {
            sink.emit(event)
            true
        }.getOrDefault(false)
    }

    private fun sampling(): SamplingDecision {
        return samplingDecision ?: config.samplingPolicy.decide(
            pageIdentity.pageViewId ?: pageIdentity.entryId ?: pageIdentity.navigationId,
        ).also { samplingDecision = it }
    }

    private fun pageOpenKey(): String {
        val attempted = currentAttempted
        val resolved = currentResolved
        return listOf(
            pageIdentity.pageViewId,
            currentIdentity.renderAttemptId,
            resolved?.lynxAppId ?: attempted?.lynxAppId,
            resolved?.bundleName ?: attempted?.bundleName,
            resolved?.releaseId ?: attempted?.candidateReleaseId,
            resolved?.bundleSha256 ?: attempted?.expectedSha256,
        ).joinToString("|") { it ?: "" }
    }

    private fun sanitizeAttributes(attributes: Map<String, String>): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        attributes.entries.take(config.maxAttributes.coerceAtLeast(0)).forEach { (rawKey, rawValue) ->
            val key = rawKey.trim().take(config.maxAttributeKeyLength.coerceAtLeast(1))
            if (key.isEmpty() || !key.matches(ATTRIBUTE_KEY)) return@forEach
            result[key] = sanitizeValue(rawValue).take(config.maxAttributeValueLength.coerceAtLeast(1))
        }
        return result
    }

    private fun sanitizeValue(raw: String): String = raw
        .replace(Regex("https?://[^\\s]+", RegexOption.IGNORE_CASE), "[url]")
        .replace(Regex("/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+"), "[path]")
        .replace(Regex("\\s+"), " ")
        .trim()
        .take(config.maxAttributeValueLength.coerceAtLeast(1))

    private companion object {
        val ATTRIBUTE_KEY = Regex("^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$")
        val DIAGNOSTIC_EVENTS = setOf(
            "lynx.navigation.rejected",
            "lynx.page.failed",
            "telemetry.stale_callback_dropped",
        )
    }

    private fun canonicalLifecycleReason(raw: String): String? = when (raw) {
        "covered", "coveredByPage" -> "coveredByPage"
        "detached" -> "detached"
        "configurationChange" -> "configurationChange"
        "appForeground" -> "appForeground"
        "appBackground" -> "appBackground"
        "destroyed" -> "destroyed"
        "reload" -> "reload"
        else -> null
    }
}
