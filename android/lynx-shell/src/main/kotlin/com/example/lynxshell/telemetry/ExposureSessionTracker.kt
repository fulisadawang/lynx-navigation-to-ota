package com.example.lynxshell.telemetry

/** 曝光结束原因；Native 生命周期封口使用这些固定低基数值。 */
enum class ExposureEndReason(val wireName: String) {
    RATIO_DROP("ratio_drop"),
    COVERED("covered"),
    BACKGROUND("background"),
    DESTROYED("destroyed"),
    RELOAD("reload"),
    ITEM_RECYCLED("item_recycled"),
}

data class ExposureQualified(
    val exposureKey: String,
    val contentId: String,
    val exposureSessionId: String,
    val position: Int?,
    val occurrence: Int,
    val visibleRatioThreshold: Double,
    val maxVisibleRatio: Double,
    val minDurationMs: Long,
    val ruleVersion: String,
)

data class ExposureEnded(
    val qualified: ExposureQualified,
    val durationMs: Long,
    val endReason: ExposureEndReason,
)

/**
 * 单个元素的 Native 曝光状态机。
 *
 * JS 只提供比例和 begin/end 意图；计时、occurrence、sessionId 和 reportOnce 都由 Native 持有。
 * resumeObserver() 会丢弃旧区间并提升 generation，不会合成一条曝光事件。
 */
class ExposureSessionTracker(
    private val exposureKey: String,
    private val contentId: String,
    private val position: Int? = null,
    private val reportOnce: Boolean = true,
    private val idFactory: () -> String = ::newTelemetryId,
) {
    private data class Active(
        val sessionId: String,
        val occurrence: Int,
        val threshold: Double,
        val minDurationMs: Long,
        val ruleVersion: String,
        val startedAtMonotonicMs: Long,
        var maxRatio: Double,
        var qualified: ExposureQualified? = null,
    )

    private var observerGeneration = 0L
    private var occurrence = 0
    private var active: Active? = null
    private var qualifiedOnce = false

    fun observerGeneration(): Long = observerGeneration

    fun isActive(): Boolean = active != null

    fun isQualified(): Boolean = active?.qualified != null

    /** 只有当前 Observer generation 可以 begin；旧回调直接拒绝。 */
    fun begin(
        callbackGeneration: Long,
        initialRatio: Double,
        threshold: Double,
        minDurationMs: Long,
        ruleVersion: String,
        nowMonotonicMs: Long,
    ): Boolean {
        if (callbackGeneration != observerGeneration || active != null) return false
        if (reportOnce && qualifiedOnce) return false
        val safeThreshold = threshold.coerceIn(0.0, 1.0)
        val safeRatio = initialRatio.coerceIn(0.0, 1.0)
        val safeDuration = minDurationMs.coerceAtLeast(0L)
        if (safeRatio < safeThreshold) return false
        occurrence += 1
        active = Active(
            sessionId = idFactory(),
            occurrence = occurrence,
            threshold = safeThreshold,
            minDurationMs = safeDuration,
            ruleVersion = ruleVersion.take(64),
            startedAtMonotonicMs = nowMonotonicMs,
            maxRatio = safeRatio,
        )
        return true
    }

    /** 达到 deadline 时生成唯一 qualified；未达到 minDuration 不产生曝光分子。 */
    fun qualifyIfDue(nowMonotonicMs: Long): ExposureQualified? {
        val current = active ?: return null
        current.maxRatio = current.maxRatio.coerceIn(0.0, 1.0)
        if (current.qualified != null) return current.qualified
        val elapsed = nowMonotonicMs - current.startedAtMonotonicMs
        if (elapsed < current.minDurationMs) return null
        return ExposureQualified(
            exposureKey = exposureKey,
            contentId = contentId,
            exposureSessionId = current.sessionId,
            position = position,
            occurrence = current.occurrence,
            visibleRatioThreshold = current.threshold,
            maxVisibleRatio = current.maxRatio,
            minDurationMs = current.minDurationMs,
            ruleVersion = current.ruleVersion,
        ).also {
            current.qualified = it
            qualifiedOnce = true
        }
    }

    fun updateRatio(ratio: Double) {
        active?.maxRatio = maxOf(active?.maxRatio ?: 0.0, ratio.coerceIn(0.0, 1.0))
    }

    /** 只有 qualified 区间才产生 ended；系统封口可早于 JS end。 */
    fun end(
        reason: ExposureEndReason,
        nowMonotonicMs: Long,
    ): ExposureEnded? {
        val current = active ?: return null
        val qualified = current.qualified
        active = null
        if (qualified == null) return null
        return ExposureEnded(
            qualified = qualified,
            durationMs = (nowMonotonicMs - current.startedAtMonotonicMs).coerceAtLeast(0L),
            endReason = reason,
        )
    }

    /**
     * covered/background 后必须重建 Observer；官方 resumeExposure 不保证重新发事件，不能在这里补曝光。
     */
    fun resumeObserver(): Long {
        observerGeneration += 1L
        active = null
        return observerGeneration
    }

    fun resetForReload(): Long {
        observerGeneration += 1L
        active = null
        occurrence = 0
        qualifiedOnce = false
        return observerGeneration
    }
}
