package com.example.lynxshell.telemetry

/**
 * Lynx Runtime 回调的 typed 边界。
 *
 * [待确认] 当前独立仓尚未锁定 Lynx 4.0.0 的实际 FirstScreen/Performance ABI，因此这里不直接继承
 * LynxViewClient，也不臆造回调签名。容器确认 SDK header 后，只需要把已有 callback 转译到此接口，
 * 不应把 SDK 类型泄漏到 Telemetry Coordinator。
 */
interface LynxTelemetryRuntimeAdapter {
    fun onRuntimeReady(generation: Long, resolved: ResolvedBundleSnapshot): Boolean

    fun onFirstScreen(generation: Long): Boolean

    fun onRuntimeFailure(generation: Long, reasonCode: String): Boolean
}

/** 将容器已确认的 Lynx 生命周期转发给本地 Coordinator；不改变原有渲染回调语义。 */
class CoordinatorLynxTelemetryAdapter(
    private val coordinator: TelemetryCoordinator,
) : LynxTelemetryRuntimeAdapter {
    override fun onRuntimeReady(generation: Long, resolved: ResolvedBundleSnapshot): Boolean =
        coordinator.resolveBundle(generation, resolved)

    override fun onFirstScreen(generation: Long): Boolean = coordinator.onFirstScreen(generation)

    override fun onRuntimeFailure(generation: Long, reasonCode: String): Boolean =
        coordinator.failPrepare(generation, reasonCode)
}
