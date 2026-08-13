package com.example.lynxshell.telemetry

import java.util.UUID

/**
 * Native 监控事件的 Wire Schema 版本。
 *
 * 这是事件格式版本，不是 Router/OTA SDK 版本。三端在 Alpha 阶段必须保持这个值一致。
 */
const val TELEMETRY_WIRE_SCHEMA_VERSION = "3.0.0"

/** Bundle 来源的低基数枚举；不能把本机绝对路径写入 Telemetry。 */
enum class TelemetryBundleSource(val wireName: String) {
    OTA("ota"),
    DIRECT_HTTPS("direct_https"),
    ASSETS("assets"),
    LOCAL_FILE("local_file"),
}

enum class TelemetryRuntimeKind(val wireName: String) {
    LYNX_VIEW("lynx_view"),
    BACKGROUND_RUNTIME("background_runtime"),
}

enum class TelemetryCategory(val wireName: String) {
    ROUTER("router"),
    NAVIGATION("navigation"),
    PAGE("page"),
    APP("app"),
    TRANSITION("transition"),
    EXPOSURE("exposure"),
    OTA("ota"),
    DIAGNOSTIC("diagnostic"),
    TELEMETRY("telemetry"),
}

enum class PageLifecycleState(val wireName: String) {
    ALLOCATED("allocated"),
    REGISTERED("registered"),
    VISIBLE("visible"),
    HIDDEN("hidden"),
    DESTROYED("destroyed"),
}

enum class AppLifecycleState(val wireName: String) {
    FOREGROUND("foreground"),
    BACKGROUND("background"),
}

enum class RenderAttemptState(val wireName: String) {
    UNUSABLE("unusable"),
    USABLE("usable"),
}

enum class TransitionTerminal(val wireName: String) {
    COMPLETED("completed"),
    DEGRADED("degraded"),
    CANCELLED("cancelled"),
    FAILED("failed"),
    NOT_APPLICABLE("notApplicable"),
}

enum class NavigationAdmission(val wireName: String) {
    REQUESTED("requested"),
    ACCEPTED("accepted"),
    REJECTED("rejected"),
}

/**
 * 页面访问的 Native 身份。只有 Native 生成这些 ID；Lynx 页面提交同名字段时会被忽略。
 * pageViewId 可以为空，适用于尚未创建页面实例的 navigation_rejected。
 */
data class TelemetryIdentity(
    val navigationId: String = newTelemetryId(),
    val navigationSessionId: String? = null,
    val entryId: String? = null,
    val pageViewId: String? = null,
    val renderAttemptId: String? = null,
    val activationId: String? = null,
    val transactionId: String? = null,
) {
    companion object {
        fun forPage(
            entryId: String,
            navigationId: String = newTelemetryId(),
            navigationSessionId: String? = null,
            pageViewId: String = newTelemetryId(),
            transactionId: String? = null,
        ): TelemetryIdentity = TelemetryIdentity(
            navigationId = navigationId,
            navigationSessionId = navigationSessionId,
            entryId = entryId,
            pageViewId = pageViewId,
            transactionId = transactionId,
        )
    }
}

/** prepare() 前冻结的候选 Bundle 信息，用于解释缺包、下载、校验和取消。 */
data class AttemptedBundleSnapshot(
    val bundleSource: TelemetryBundleSource,
    val lynxAppId: String? = null,
    val bundleName: String,
    val telemetryRouteKey: String,
    val otaOperationId: String? = null,
    val candidateReleaseId: String? = null,
    val expectedSha256: String? = null,
    val prepareStartedAtUnixMs: Long,
    val attemptGeneration: Long,
)

/** prepare 成功且本地 SHA 校验完成后冻结的 Bundle 信息。 */
data class ResolvedBundleSnapshot(
    val bundleSource: TelemetryBundleSource,
    val lynxAppId: String? = null,
    val bundleName: String,
    val telemetryRouteKey: String,
    val releaseId: String? = null,
    val bundleSha256: String? = null,
    val engineVersion: String? = null,
    val localGeneration: String? = null,
    val rollbackFromReleaseId: String? = null,
    val resolvedAtUnixMs: Long,
    /** 仅进程内加载使用，永远不会出现在 TelemetryEvent 或 Debug 输出。 */
    val internalLocalPath: String? = null,
)

/** 仅允许安全的低基数字段进入 Event；URL、绝对路径和原始错误不会从这里导出。 */
data class TelemetryBundleSnapshotWire(
    val kind: String,
    val bundleSource: String,
    val lynxAppId: String?,
    val bundleName: String,
    val telemetryRouteKey: String,
    val otaOperationId: String?,
    val releaseId: String?,
    val sha256: String?,
    val prepareStartedAtUnixMs: Long? = null,
    val attemptGeneration: Long? = null,
    val engineVersion: String? = null,
    val localGeneration: String? = null,
    val rollbackFromReleaseId: String? = null,
    val resolvedAtUnixMs: Long? = null,
) {
    /** 旧平台适配器使用 source 命名时仍能读取统一字段。 */
    val source: String
        get() = bundleSource
)

fun AttemptedBundleSnapshot.toWireSnapshot(): TelemetryBundleSnapshotWire =
    TelemetryBundleSnapshotWire(
        kind = "attempted",
        bundleSource = bundleSource.wireName,
        lynxAppId = lynxAppId,
        bundleName = bundleName,
        telemetryRouteKey = telemetryRouteKey,
        otaOperationId = otaOperationId,
        releaseId = candidateReleaseId,
        sha256 = expectedSha256,
        prepareStartedAtUnixMs = prepareStartedAtUnixMs,
        attemptGeneration = attemptGeneration,
    )

fun ResolvedBundleSnapshot.toWireSnapshot(): TelemetryBundleSnapshotWire =
    TelemetryBundleSnapshotWire(
        kind = "resolved",
        bundleSource = bundleSource.wireName,
        lynxAppId = lynxAppId,
        bundleName = bundleName,
        telemetryRouteKey = telemetryRouteKey,
        otaOperationId = null,
        releaseId = releaseId,
        sha256 = bundleSha256,
        engineVersion = engineVersion,
        localGeneration = localGeneration,
        rollbackFromReleaseId = rollbackFromReleaseId,
        resolvedAtUnixMs = resolvedAtUnixMs,
    )

/** 采样信息必须随事件携带；同一个 pageView 的页面、曝光和点击共用一个 cohort。 */
data class SamplingDecision(
    val sampleRate: Double,
    val samplingGroup: String,
    val samplingRuleVersion: String,
    val sampled: Boolean,
    val inclusionProbability: Double,
)

/** 宿主侧的低基数上下文。不得放入账号、URL query、原始 params 或绝对路径。 */
data class TelemetryHostContext(
    val runtimeKind: TelemetryRuntimeKind = TelemetryRuntimeKind.LYNX_VIEW,
    val runtimeInstanceId: String = newTelemetryId(),
    val telemetryRouteKey: String = "unknown",
    val hostMode: String = "activity",
    val platform: String = "android",
    val hostApp: String = "unknown",
    val appVersion: String = "unknown",
    val buildNumber: String = "unknown",
    val lynxSdkVersion: String = "unknown",
    val engineVersion: String = "unknown",
)

data class TelemetryLifecycleSnapshot(
    val pageState: PageLifecycleState,
    val appState: AppLifecycleState,
    val attemptState: RenderAttemptState,
    val activeEligible: Boolean,
    val reason: String? = null,
)

data class TelemetryNavigationSnapshot(
    val state: NavigationAdmission,
    val rejectionCode: String? = null,
)

data class TelemetryTransitionSnapshot(
    val state: String = "waitingTarget",
    val terminal: TransitionTerminal? = null,
    val durationMs: Long? = null,
)

data class TelemetryPrivacySnapshot(
    val consentState: String = "unknown",
    val subjectRefPresent: Boolean = false,
    val optOut: Boolean = false,
)

/**
 * 旁路事件模型。toWireMap() 只导出 Wire Schema 允许字段，尤其不会导出 Resolved Snapshot 的本地路径。
 */
data class TelemetryEvent(
    val eventId: String = newTelemetryEventId(),
    val eventName: String,
    val category: TelemetryCategory,
    val source: String = "native",
    val occurredAtUnixMs: Long,
    val monotonicOffsetMs: Long,
    val sequenceNo: Long,
    val identity: TelemetryIdentity,
    val host: TelemetryHostContext,
    val attemptedBundle: TelemetryBundleSnapshotWire? = null,
    val resolvedBundle: TelemetryBundleSnapshotWire? = null,
    val sampling: SamplingDecision,
    val lifecycle: TelemetryLifecycleSnapshot? = null,
    val navigationAdmission: TelemetryNavigationSnapshot? = null,
    val transition: TelemetryTransitionSnapshot? = null,
    val privacy: TelemetryPrivacySnapshot = TelemetryPrivacySnapshot(),
    val analysisEligible: Boolean = true,
    val samplingReason: String = if (sampling.sampled) "stable_cohort" else "not_sampled",
    val deliveryOwner: String = "internal",
    val otaOperationId: String? = null,
    val runtimeGeneration: Long? = null,
    val attributes: Map<String, String> = emptyMap(),
) {
    /** 给 Debug Sink 和后续上传适配器使用的平面 Wire 结构。 */
    fun toWireMap(): Map<String, Any?> {
        val wire = linkedMapOf<String, Any?>(
        "schemaVersion" to TELEMETRY_WIRE_SCHEMA_VERSION,
        "eventId" to eventId,
        "eventName" to eventName,
        "category" to category.wireName,
        "source" to source,
        "occurredAtUnixMs" to occurredAtUnixMs,
        "monotonicOffsetMs" to monotonicOffsetMs,
        "sequenceNo" to sequenceNo,
        "navigationId" to identity.navigationId,
        "navigationSessionId" to identity.navigationSessionId,
        "pageViewId" to identity.pageViewId,
        "entryId" to identity.entryId,
        "renderAttemptId" to identity.renderAttemptId,
        "activationId" to identity.activationId,
        "transactionId" to identity.transactionId,
        "runtimeKind" to host.runtimeKind.wireName,
        "runtimeInstanceId" to host.runtimeInstanceId,
        "telemetryRouteKey" to host.telemetryRouteKey,
        "hostMode" to host.hostMode,
        "platform" to host.platform,
        "hostApp" to host.hostApp,
        "appVersion" to host.appVersion,
        "buildNumber" to host.buildNumber,
        "lynxSdkVersion" to host.lynxSdkVersion,
        "engineVersion" to host.engineVersion,
        "runtimeGeneration" to runtimeGeneration,
        "otaOperationId" to otaOperationId,
        "attemptedBundleSnapshot" to attemptedBundle?.toWireMap(),
        "resolvedBundleSnapshot" to resolvedBundle?.toWireMap(),
        "lifecycle" to lifecycle?.toWireMap(),
        "navigationAdmission" to navigationAdmission?.toWireMap(),
        "transition" to transition?.toWireMap(),
        "sampleRate" to sampling.sampleRate,
        "samplingGroup" to sampling.samplingGroup,
        "samplingRuleVersion" to sampling.samplingRuleVersion,
        "inclusionProbability" to sampling.inclusionProbability,
        "analysisEligible" to analysisEligible,
        "samplingReason" to samplingReason,
        "deliveryOwner" to deliveryOwner,
        "privacy" to privacy.toWireMap(),
            "attributes" to attributes,
        )
        // JSON Schema 的可选对象不能以 null 形式发送；省略而不是写入 null，避免服务端拒绝整条事件。
        return wire.filterValues { it != null }
    }
}

private fun TelemetryBundleSnapshotWire.toWireMap(): Map<String, Any?> {
    val common = linkedMapOf<String, Any?>(
        "kind" to kind,
        "bundleSource" to bundleSource,
        "lynxAppId" to lynxAppId,
        "bundleName" to bundleName,
        "telemetryRouteKey" to telemetryRouteKey,
    )
    if (kind == "attempted") {
        common["otaOperationId"] = otaOperationId
        common["candidateReleaseId"] = releaseId
        common["expectedSha256"] = sha256
        common["prepareStartedAtUnixMs"] = prepareStartedAtUnixMs
        common["attemptGeneration"] = attemptGeneration
    } else {
        common["releaseId"] = releaseId
        common["bundleSha256"] = sha256
        common["engineVersion"] = engineVersion
        common["localGeneration"] = localGeneration
        common["rollbackFromReleaseId"] = rollbackFromReleaseId
        common["resolvedAtUnixMs"] = resolvedAtUnixMs
    }
    return common
}

private fun TelemetryLifecycleSnapshot.toWireMap(): Map<String, Any?> = linkedMapOf(
    "pageState" to pageState.wireName,
    "appState" to appState.wireName,
    "attemptState" to attemptState.wireName,
    "activeEligible" to activeEligible,
    "reason" to reason,
)

private fun TelemetryNavigationSnapshot.toWireMap(): Map<String, Any?> = linkedMapOf(
    "state" to state.wireName,
    "rejectionCode" to rejectionCode,
)

private fun TelemetryTransitionSnapshot.toWireMap(): Map<String, Any?> = linkedMapOf(
    "state" to state,
    "terminal" to terminal?.wireName,
    "durationMs" to durationMs,
)

private fun TelemetryPrivacySnapshot.toWireMap(): Map<String, Any?> = linkedMapOf(
    "consentState" to consentState,
    "subjectRefPresent" to subjectRefPresent,
    "optOut" to optOut,
)

/** 确定性 ID 生成器，后续可以在单测中注入固定实现。 */
fun newTelemetryId(): String = UUID.randomUUID().toString()

/** Wire Schema 要求事件 ID 具备 evt_ 前缀；页面身份仍使用普通 Native ID。 */
fun newTelemetryEventId(): String = "evt_${newTelemetryId()}"
