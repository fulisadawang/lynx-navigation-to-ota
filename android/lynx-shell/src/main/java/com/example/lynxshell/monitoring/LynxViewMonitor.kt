package com.example.lynxshell.monitoring

import android.os.Handler
import android.os.Looper
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.ota.PreparedActivityBundle
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.LynxViewClientV2
import com.lynx.tasm.performance.performanceobserver.LoadBundleEntry
import com.lynx.tasm.performance.performanceobserver.PerformanceEntry
import com.lynx.tasm.performance.performanceobserver.ReloadBundleEntry
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.UUID

internal object BundleIdentities {
    fun attempted(request: LynxPageRequest): BundleIdentity = attempted(request.bundleUrl, request.lynxAppId, request.bundleName)
    fun attempted(url: String, appId: String?, bundleName: String?): BundleIdentity = BundleIdentity(
        source = if (appId != null && bundleName != null) "ota" else if (LynxPageRequest.isRemoteBundleUrl(url)) "direct_https" else "direct_asset",
        lynxAppId = appId?.takeIf(String::isNotBlank)?.let { utf8Prefix(it, 256) },
        // 只提取不含 query/fragment 的逻辑末级文件名，不把原始 URL 放进事件。
        bundleName = (bundleName ?: url.substringBefore('?').substringBefore('#').substringAfterLast('/'))
            .takeIf(String::isNotBlank)?.let { utf8Prefix(it, 256) },
    )

    fun prepared(value: PreparedActivityBundle): BundleIdentity {
        val hash = value.sha256?.removePrefix("sha256:")?.lowercase()?.takeIf { SHA.matches(it) }
        return BundleIdentity(
            source = if (value.source == "embedded_baseline") "embedded" else "ota",
            lynxAppId = utf8Prefix(value.lynxAppId, 256), bundleName = utf8Prefix(value.bundleName, 256),
            releaseId = value.releaseId?.takeIf(String::isNotBlank)?.let { utf8Prefix(it, 256) },
            releaseSequence = value.releaseSequence?.takeIf { SEQUENCE.matches(it) },
            sha256 = hash, identityStatus = if (hash != null) "verified" else "unavailable",
            missingReason = if (hash != null) null else "verified_hash_unavailable",
        )
    }
    private val SHA = Regex("[0-9a-f]{64}")
    private val SEQUENCE = Regex("0|[1-9][0-9]*")
}

/** 一次物理 View 的监听门；事件在锁内冻结，关门后不能借新 generation 重新归属。 */
class LynxViewMonitor internal constructor(
    private val runtime: MonitorRuntime,
    private val kind: ContainerKind,
    private val loadKind: LoadKind,
    private var bundle: BundleIdentity,
    private var pageVisibility: Visibility,
    private var appBackground: Boolean,
) {
    val viewId: String = UUID.randomUUID().toString()
    val loadId: String = UUID.randomUUID().toString()
    private val startedAt = System.nanoTime()
    private var prepareStartedAt = startedAt
    private var byteReadStarted = false
    private var nativeInstanceId: String? = null
    private var view = WeakReference<LynxView>(null)
    private var closed = false
    private var created = false
    private var resolved = false
    private var terminal = false
    private var firstContent = false
    private var loaded = false
    private var ambiguous = false
    private var pageStarts = 0
    private val primaryMetrics = HashSet<String>()

    private val lifecycleClient = object : LynxViewClient() {
        override fun onLoadSuccess() { loaded() }
        override fun onFirstScreen() { firstContent() }
        override fun onReceivedError(error: LynxError) { receivedError(error) }
        @Suppress("OVERRIDE_DEPRECATION")
        override fun onLoadFailed(message: String) { failed("sdk_load_failed") }
    }
    private val performanceClient = object : LynxViewClientV2() {
        override fun onPageStarted(view: LynxView?, info: LynxPipelineInfo) { pageStarted(info.isFromReload) }
        override fun onPerformanceEvent(entry: PerformanceEntry) { performance(entry) }
        override fun onResourceLoaded(info: LynxResourceLoadInfo) { resource(info) }
    }

    @Synchronized internal fun started() { emit(LoadPayload("started")) }

    /** 调用者在 build 之前计时；实例注册必须早于第一次 render。 */
    @Synchronized internal fun attach(value: LynxView, creationStartNanos: Long) {
        if (!open()) return
        nativeInstanceId = value.lynxViewId.toString()
        view = WeakReference(value)
        try {
            value.addLynxViewClient(lifecycleClient)
            value.addLynxViewClientV2(performanceClient)
        } catch (_: Exception) {
            runtime.count("listener_install_failed")
            disable()
            runtime.detach(this)
            return
        }
        created = true
        emit(LifecyclePayload("created", elapsed(creationStartNanos)))
        // 创建前只记录目标可见状态；真实 View 建立后再发首个 visible/hidden/background。
        val currentVisibility = visibility()
        if (currentVisibility != Visibility.UNKNOWN) emit(LifecyclePayload(currentVisibility.wire))
    }

    @Synchronized internal fun createFailed() {
        if (!open()) return
        emit(LifecyclePayload("create_failed"))
        failed("view_create_failed")
    }

    @Synchronized internal fun resolvePrepared(value: PreparedActivityBundle) {
        if (!open() || resolved) return
        bundle = BundleIdentities.prepared(value)
        // 缺哈希时等待实际 Provider 读取字节；不会把预期版本当作已校验内容。
        if (bundle.sha256 != null) resolve()
    }

    /** Provider 的 IO 线程在本次真实字节交付 Lynx 前调用，直连 Bundle 只计算一次。 */
    internal fun bytesResolved(bytes: ByteArray) {
        val needsHash = synchronized(this) { !closed && !resolved }
        if (!needsHash) return
        val hash = try { MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) } }
        catch (_: Exception) { runtime.count("hash_failed"); return }
        synchronized(this) {
            if (!open() || resolved) return
            bundle = bundle.copy(sha256 = hash, identityStatus = "computed", missingReason = null)
            resolve()
        }
    }

    @Synchronized internal fun byteReadStarted() {
        if (!closed && !byteReadStarted && !resolved) {
            byteReadStarted = true
            if (bundle.source == "direct_https" || bundle.source == "direct_asset") prepareStartedAt = System.nanoTime()
        }
    }

    private fun resolve() {
        resolved = true
        emit(LoadPayload("resolved", durationMs = elapsed(prepareStartedAt)))
    }

    @Synchronized fun visibility(value: Visibility) {
        if (closed || value == pageVisibility) return
        pageVisibility = value
        if (created && visibility() != Visibility.UNKNOWN) emit(LifecyclePayload(visibility().wire))
    }

    @Synchronized internal fun applicationVisibility(background: Boolean) {
        if (closed || background == appBackground) return
        appBackground = background
        if (created && visibility() != Visibility.UNKNOWN) emit(LifecyclePayload(visibility().wire))
    }

    @Synchronized internal fun failed(reason: String) {
        if (closed || terminal || ambiguous) return
        terminal = true
        emit(LoadPayload("failed", reason, elapsed(startedAt)))
    }

    @Synchronized private fun loaded() {
        if (!open() || loaded || terminal || ambiguous) return
        loaded = true
        emit(LoadPayload("loaded_unconfirmed"))
    }

    @Synchronized internal fun firstContent() {
        if (!open() || terminal || ambiguous) return
        firstContent = true; terminal = true
        emit(LoadPayload("first_content", durationMs = elapsed(startedAt)))
    }

    @Synchronized internal fun pageStarted(reload: Boolean) {
        if (!open()) return
        pageStarts++
        if (reload || pageStarts > 1) {
            if (!terminal && !ambiguous) emit(LoadPayload("incomplete", "untracked_same_view_load"))
            ambiguous = true
            runtime.count("ambiguous_load")
        }
    }

    @Synchronized internal fun performance(entry: PerformanceEntry) {
        if (!open()) return
        if (entry is ReloadBundleEntry) ambiguous = true
        val projection = try { MonitorProjection.performance(entry) } catch (_: Exception) {
            runtime.count("performance_projection_error"); null
        } ?: run { runtime.count("unsupported_performance_entry"); return }
        val payload = projection.payload
        // 首次内容是一条基础事实，不受性能采样影响；SDK 原始时间不替换原生计时。
        if (!ambiguous && entry is LoadBundleEntry && payload.metrics.any { it.name == "lynx_fcp_ms" }) firstContent()
        val sampling = runtime.performanceSampling(viewId) ?: run { runtime.count("performance_sampled_out"); return }
        val metrics = payload.metrics.filter { metric ->
            if (!ambiguous && metric.name in setOf("lynx_fcp_ms", "prepare_to_fcp_ms", "open_to_fcp_ms")) primaryMetrics.add(metric.name) else true
        }
        emit(PerformancePayload(payload.entryType, payload.entryName, payload.identifier, metrics, payload.timing),
            projection.missing, projection.invalid, projection.truncated, sampling)
    }

    @Synchronized private fun receivedError(error: LynxError) {
        if (!open()) return
        val captured = try { MonitorProjection.captureError(error) }
        catch (_: Exception) { runtime.count("error_projection_error"); null }
        if (captured != null) {
            val phase = if (ambiguous) "unknown" else if (firstContent) "running" else "loading"
            val envelope = event(JsErrorPayload(captured.errorCode, captured.subCode, captured.level, captured.realm,
                "", null, emptyList(), phase = phase))
            runtime.enqueueError(envelope, captured, phase)
        }
        else runtime.count("non_js_error")
        if (error.isFatal && !firstContent) failed("fatal_runtime_error")
    }

    @Synchronized private fun resource(info: LynxViewClientV2.LynxResourceLoadInfo) {
        if (!open()) return
        emit(ResourcePayload(utf8Prefix(info.resourceType.name, 128), if (info.errCode == 0) "success" else "failed",
            errorCode = info.errCode.takeIf { it != 0 }?.toString()), missing = listOf("resource.durationMs", "resource.resourceKey"))
    }

    /** 必须在取消 prepare、摘监听和销毁 View 之前调用；已入队事件不受实例销毁影响。 */
    @Synchronized fun close(reason: String = "cancelled") {
        if (closed) return
        if (!terminal && !ambiguous) emit(LoadPayload(if (reason == "cancelled") "cancelled" else "incomplete", reason))
        if (created) emit(LifecyclePayload("destroyed"))
        closed = true
        removeListeners()
        runtime.detach(this)
    }

    @Synchronized internal fun disable() {
        if (closed) return
        closed = true
        removeListeners()
    }

    private fun removeListeners() {
        val target = view.get()
        view.clear()
        if (target != null) {
            val remove = Runnable {
                try { target.removeLynxViewClient(lifecycleClient); target.removeLynxViewClientV2(performanceClient) }
                catch (_: Exception) { runtime.count("listener_remove_failed") }
            }
            if (Looper.myLooper() == Looper.getMainLooper()) remove.run() else Handler(Looper.getMainLooper()).post(remove)
        }
    }

    private fun open(): Boolean = if (closed) { runtime.count("callback_after_close"); false } else true
    private fun visibility(): Visibility = if (appBackground) Visibility.BACKGROUND else pageVisibility
    private fun elapsed(start: Long): Double = (System.nanoTime() - start).coerceAtLeast(0) / 1_000_000.0

    private fun emit(payload: MonitorPayload, missing: List<String> = emptyList(), invalid: List<String> = emptyList(),
        truncated: List<String> = emptyList(), sampling: Sampling = Sampling("none", 1.0)) {
        runtime.enqueue(event(payload, missing, invalid, truncated, sampling))
    }

    private fun event(payload: MonitorPayload, missing: List<String> = emptyList(), invalid: List<String> = emptyList(),
        truncated: List<String> = emptyList(), sampling: Sampling = Sampling("none", 1.0)): MonitorEvent =
        MonitorEvent(UUID.randomUUID().toString(), runtime.host.processSessionId, System.currentTimeMillis(),
            runtime.host.runtimeVersion, runtime.host.hostBuild, viewId, nativeInstanceId, kind,
            if (ambiguous) null else loadId, if (ambiguous) null else loadKind, if (ambiguous) null else bundle,
            visibility(), EventQuality(if (ambiguous) "exact_view" else "exact_load", missingFields =
                missing + if (ambiguous) listOf("ambiguous_load") else if (bundle.sha256 == null) listOf("bundle.sha256") else emptyList(),
                invalidFields = invalid, truncatedFields = truncated), sampling, payload)
}
