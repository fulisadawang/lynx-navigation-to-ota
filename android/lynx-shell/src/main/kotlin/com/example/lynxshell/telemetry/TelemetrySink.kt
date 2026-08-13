package com.example.lynxshell.telemetry

/**
 * 监控是旁路能力。Sink 失败不得向 Router、OTA 或 LynxView 抛异常。
 * Alpha 只提供内存 no-op/debug Sink，不实现网络上传或持久队列。
 */
fun interface TelemetrySink {
    fun emit(event: TelemetryEvent)
}

object NoOpTelemetrySink : TelemetrySink {
    override fun emit(event: TelemetryEvent) = Unit
}

/**
 * 可选的本地 Debug Sink。宿主决定如何记录日志，库本身不使用 Android Log，也不输出完整 URL、
 * params、异常堆栈或本机绝对路径。
 */
class DebugTelemetrySink(
    private val logger: (String) -> Unit = { message -> println(message) },
) : TelemetrySink {
    override fun emit(event: TelemetryEvent) {
        runCatching {
            logger(
                buildString {
                    append("[LynxTelemetry] ")
                    append(event.eventName)
                    append(" seq=")
                    append(event.sequenceNo)
                    append(" pageViewId=")
                    append(event.identity.pageViewId ?: "null")
                    append(" attempt=")
                    append(event.identity.renderAttemptId ?: "null")
                    append(" attrs=")
                    append(event.attributes)
                },
            )
        }
        // Debug 输出失败也必须 fail-open；不能让日志实现影响页面。
    }
}

data class SamplingPolicy(
    val sampleRate: Double = 1.0,
    val samplingGroup: String = "page_quality",
    val samplingRuleVersion: String = "v1",
    /** 仅供测试或宿主注入稳定的实验分桶函数；默认使用 pageViewId 的确定性 hash。 */
    val decisionOverride: ((String, Double) -> Boolean)? = null,
) {
    fun decide(cohortKey: String): SamplingDecision {
        val boundedRate = sampleRate.coerceIn(0.0, 1.0)
        val sampled = decisionOverride?.invoke(cohortKey, boundedRate)
            ?: deterministicSample(cohortKey, boundedRate)
        return SamplingDecision(
            sampleRate = boundedRate,
            samplingGroup = samplingGroup.take(64),
            samplingRuleVersion = samplingRuleVersion.take(64),
            sampled = sampled,
            inclusionProbability = boundedRate,
        )
    }

    private fun deterministicSample(key: String, rate: Double): Boolean {
        if (rate <= 0.0) return false
        if (rate >= 1.0) return true
        val normalized = (key.hashCode().toLong() and 0x7fffffffL) / 2_147_483_647.0
        return normalized < rate
    }
}

data class TelemetryConfig(
    val enabled: Boolean = true,
    val samplingPolicy: SamplingPolicy = SamplingPolicy(),
    /** 可按完整事件名或末级 feature 名关闭，例如 page_open、exposure、performance。 */
    val killSwitches: Set<String> = emptySet(),
    /** Alpha 只允许一个交付所有者；这里默认 internal，避免同时出现两条上传链。 */
    val deliveryOwner: String = "internal",
    val maxAttributes: Int = 10,
    val maxAttributeKeyLength: Int = 64,
    val maxAttributeValueLength: Int = 256,
) {
    fun isEventEnabled(eventName: String): Boolean {
        if (!enabled) return false
        val suffix = eventName.substringAfterLast('.')
        return eventName !in killSwitches && suffix !in killSwitches
    }
}
