package com.example.lynxshell.monitoring

import android.app.Activity
import android.app.Application
import android.os.Build
import android.os.Bundle
// LYNX_DEBUG_TOOL_BEGIN
import com.example.lynxshell.debug.LynxDebugBridge
// LYNX_DEBUG_TOOL_END
import com.example.lynxshell.BuildConfig
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException

data class HostContext(
    val hostAppId: String, val hostBuild: String, val runtimeVersion: String, val processSessionId: String,
    val platform: String = "android",
)
class ProviderCapabilities(
    supportedEvents: Set<EventType>,
    val perEventBundleContext: Boolean,
    val rawJsFrames: Boolean,
    val sdkOwnsRetry: Boolean,
    val flushSupported: Boolean,
    val samplingOwner: String = "core",
    val platform: String = "android",
) { val supportedEvents: Set<EventType> = java.util.Collections.unmodifiableSet(HashSet(supportedEvents)) }

data class InitResult(val state: String, val reason: String? = null)
enum class HandoffResult { ACCEPTED_BY_SDK, RECORDED_LOCALLY, UNSUPPORTED, NOT_READY, INVALID_EVENT, PROVIDER_ERROR }
enum class FlushResult { COMPLETED_SDK_FLUSH, UNSUPPORTED, TIMED_OUT, FAILED }

interface RuntimeProvider {
    val id: String
    val capabilities: ProviderCapabilities
    fun initialize(context: HostContext): CompletionStage<InitResult>
    fun record(event: MonitorEvent): HandoffResult
    fun flush(timeoutMs: Long): CompletionStage<FlushResult> = CompletableFuture.completedFuture(FlushResult.UNSUPPORTED)
    fun dispose()
}

data class MonitorConfig(
    val enabled: Boolean = true,
    val provider: RuntimeProvider? = null,
    val performanceSampleRate: Double = 1.0,
    val textPolicy: MonitorTextPolicy = MonitorTextPolicy(),
    val scriptPositionFormats: ScriptPositionFormats = ScriptPositionFormats(),
)
data class InstallResult(val state: String, val reason: String? = null)
data class MonitorDiagnostics(val state: String, val reason: String?, val queuedEvents: Int, val queuedBytes: Int, val counters: Map<String, Long>)

/** 本地验收适配器只保存有界内存，不代表上传完成；导出由宿主主动在后台执行。 */
class DiagnosticProvider : RuntimeProvider {
    override val id = "local_diagnostic"
    override val capabilities = ProviderCapabilities(EventType.values().toSet(), true, true, false, false)
    private val events = ArrayDeque<Pair<MonitorEvent, Int>>()
    private var bytes = 0
    private var discarded = 0L
    override fun initialize(context: HostContext): CompletionStage<InitResult> = CompletableFuture.completedFuture(InitResult("ready"))
    @Synchronized override fun record(event: MonitorEvent): HandoffResult {
        val size = event.wireBytes()
        if (size > MAX_EVENT_BYTES) return HandoffResult.INVALID_EVENT
        while (events.size >= MAX_QUEUE_EVENTS || bytes + size > MAX_QUEUE_BYTES) {
            bytes -= events.removeFirst().second
            discarded++
        }
        events.addLast(event to size)
        bytes += size
        return HandoffResult.RECORDED_LOCALLY
    }
    @Synchronized fun snapshot(): List<MonitorEvent> = frozen(events.map { it.first })
    @Synchronized fun discardedCount(): Long = discarded
    @Synchronized override fun dispose() { events.clear(); bytes = 0 }
}

internal const val MAX_EVENT_BYTES = 32 * 1024
internal const val MAX_QUEUE_BYTES = 512 * 1024
internal const val MAX_QUEUE_EVENTS = 128

/** 一个进程只有一个交付所有者；队列和监听绑定都不持有页面、View 或 OTA lease。 */
object LynxMonitor {
    private var runtime: MonitorRuntime? = null
    private var installedConfig: MonitorConfig? = null
    private var installState = InstallResult("disabled")

    @Synchronized fun install(application: Application, config: MonitorConfig): InstallResult {
        if (installedConfig != null) {
            return if (installedConfig == config) installState else InstallResult("rejected", "already_initialized")
        }
        if (!config.enabled) return InstallResult("disabled").also { installState = it }
        val provider = config.provider ?: return InstallResult("not_configured").also { installState = it }
        val rate = config.performanceSampleRate
        if (!rate.isFinite() || rate !in 0.0..1.0) return InstallResult("rejected", "invalid_sample_rate")
        val caps = provider.capabilities
        if (caps.platform != "android" || caps.samplingOwner !in setOf("core", "provider")) return InstallResult("rejected", "invalid_capabilities")
        if (!caps.perEventBundleContext || !caps.rawJsFrames ||
            !caps.supportedEvents.containsAll(setOf(EventType.PERFORMANCE, EventType.JS_ERROR))) {
            return InstallResult("rejected", "incompatible_provider")
        }
        if (caps.samplingOwner == "provider" && rate != 1.0) return InstallResult("rejected", "sampling_conflict")
        val info = application.packageManager.getPackageInfo(application.packageName, 0)
        val build = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toString() else @Suppress("DEPRECATION") info.versionCode.toString()
        val context = HostContext(application.packageName, build, BuildConfig.LYNX_RUNTIME_VERSION, UUID.randomUUID().toString())
        val next = MonitorRuntime(context, config)
        runtime = next
        installedConfig = config
        installState = InstallResult("initializing")
        next.observeApplication(application)
        next.start()
        return installState
    }

    @Synchronized fun diagnostics(): MonitorDiagnostics = runtime?.diagnostics()
        ?: MonitorDiagnostics(installState.state, installState.reason, 0, 0, emptyMap())

    fun flush(timeoutMs: Long = 1_000): CompletionStage<FlushResult> = synchronized(this) { runtime }?.flush(timeoutMs)
        ?: CompletableFuture.completedFuture(FlushResult.UNSUPPORTED)

    /** 关闭后不能由迟到初始化结果复活；不同 Provider 需要新进程。 */
    fun dispose() { synchronized(this) { runtime }?.dispose() }

    internal fun reserve(kind: ContainerKind, loadKind: LoadKind, bundle: BundleIdentity, visibility: Visibility): LynxViewMonitor? =
        synchronized(this) { runtime }?.reserve(kind, loadKind, bundle, visibility)
}

internal class MonitorRuntime(val host: HostContext, val config: MonitorConfig) {
    internal val initialization = CompletableFuture<InitResult>()
    private val provider = requireNotNull(config.provider)
    private val lock = Any()
    private class QueuedObservation(val type: EventType, val bytes: Int, val inputLimit: Int = MAX_EVENT_BYTES,
        val materialize: () -> MonitorEvent)
    private val queue = ArrayDeque<QueuedObservation>()
    private var queuedBytes = 0
    private var drainScheduled = false
    private var state = "initializing"
    private var reason: String? = null
    private val counters = LinkedHashMap<String, Long>()
    private val bindings = HashSet<LynxViewMonitor>()
    private var application: Application? = null
    private var lifecycle: Application.ActivityLifecycleCallbacks? = null
    private var appBackground = false
    private var providerDisposeScheduled = false
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "lynx-monitor-provider").apply { isDaemon = true } }
    private val timer = Executors.newSingleThreadScheduledExecutor { Thread(it, "lynx-monitor-budget").apply { isDaemon = true } }

    fun start() {
        val timeout = timer.schedule({ fail("initialization_timeout") }, 10, TimeUnit.SECONDS)
        worker.execute {
            try {
                provider.initialize(host).whenComplete { result, failure ->
                    timeout.cancel(false)
                    if (failure != null || result?.state != "ready") fail("initialization_failed")
                    else synchronized(lock) {
                        if (state == "initializing") { state = "ready"; scheduleDrain(); initialization.complete(InitResult("ready")) }
                    }
                }
            } catch (_: Exception) { timeout.cancel(false); fail("initialization_failed") }
        }
    }

    fun reserve(kind: ContainerKind, loadKind: LoadKind, bundle: BundleIdentity, visibility: Visibility): LynxViewMonitor? {
        val binding = synchronized(lock) {
            if (state !in setOf("initializing", "ready")) return null
            LynxViewMonitor(this, kind, loadKind, bundle, visibility, appBackground).also { bindings.add(it) }
        }
        binding.started()
        return binding
    }

    fun detach(binding: LynxViewMonitor) { synchronized(lock) { bindings.remove(binding) } }
    fun count(code: String, count: Long = 1) { synchronized(lock) { counters[code] = (counters[code] ?: 0) + count } }
    fun performanceSampling(viewId: String): Sampling? {
        if (provider.capabilities.samplingOwner == "provider") return Sampling("provider", null)
        val rate = config.performanceSampleRate
        if (rate == 0.0 || (viewId.hashCode().toLong() and 0xffffffffL).toDouble() / 4294967296.0 >= rate) return null
        return Sampling("core", rate)
    }

    fun enqueue(event: MonitorEvent) {
        enqueue(QueuedObservation(event.eventType, event.wireBytes()) { event })
    }

    fun enqueueError(envelope: MonitorEvent, captured: CapturedJsError, phase: String) {
        val size = envelope.wireBytes() + utf8Bytes(captured.summary) + utf8Bytes(captured.encoded)
        // SDK wrapper 与最终事件不是同一预算；保留完整 JSON，避免截断后丢失尾部堆栈与调试 key。
        enqueue(QueuedObservation(EventType.JS_ERROR, size, MAX_QUEUE_BYTES) {
            envelope.projected(MonitorProjection.error(captured, config.textPolicy, phase, config.scriptPositionFormats))
        })
    }

    private fun enqueue(item: QueuedObservation) {
        synchronized(lock) {
            if (state !in setOf("ready", "initializing")) { count("discarded_closed"); return }
            if (item.bytes > item.inputLimit) { count("oversize.${item.type.wire}"); return }
            while (queue.size >= MAX_QUEUE_EVENTS || queuedBytes + item.bytes > MAX_QUEUE_BYTES) {
                val candidate = queue.firstOrNull { it.type == EventType.PERFORMANCE || it.type == EventType.RESOURCE }
                    ?: queue.first()
                queue.remove(candidate)
                queuedBytes -= candidate.bytes
                count("dropped.${candidate.type.wire}")
            }
            queue.addLast(item)
            queuedBytes += item.bytes
            scheduleDrain()
        }
    }

    private fun scheduleDrain() {
        if (state != "ready" || drainScheduled) return
        drainScheduled = true
        worker.execute(::drain)
    }

    private fun drain() {
        while (true) {
            val item = synchronized(lock) {
                if (state != "ready" || queue.isEmpty()) { drainScheduled = false; return }
                queue.removeFirst().also { queuedBytes -= it.bytes }
            }
            val event = try { item.materialize() } catch (_: Exception) { count("projection_error"); continue }
            if (event.wireBytes() > MAX_EVENT_BYTES) { count("oversize.${event.eventType.wire}"); continue }
            // LYNX_DEBUG_TOOL_BEGIN
            LynxDebugBridge.record(event)
            // LYNX_DEBUG_TOOL_END
            val result = try {
                if (event.eventType !in provider.capabilities.supportedEvents) HandoffResult.UNSUPPORTED else provider.record(event)
            } catch (_: Exception) { HandoffResult.PROVIDER_ERROR }
            count("handoff.${result.name.lowercase()}")
        }
    }

    private fun fail(code: String) {
        val current = synchronized(lock) {
            if (state != "initializing") return
            state = "failed"; reason = code
            count("discarded_initialization", queue.size.toLong())
            queue.clear(); queuedBytes = 0
            bindings.toList().also { bindings.clear() }
        }
        current.forEach { it.disable() }
        initialization.complete(InitResult("failed", code))
        disposeProviderOnce()
    }

    fun diagnostics(): MonitorDiagnostics = synchronized(lock) { MonitorDiagnostics(state, reason, queue.size, queuedBytes, frozen(counters)) }

    fun flush(timeoutMs: Long): CompletionStage<FlushResult> {
        if (!provider.capabilities.flushSupported) return CompletableFuture.completedFuture(FlushResult.UNSUPPORTED)
        if (synchronized(lock) { state } == "disposed") return CompletableFuture.completedFuture(FlushResult.FAILED)
        val answer = CompletableFuture<FlushResult>()
        if (timeoutMs <= 0) { answer.complete(FlushResult.TIMED_OUT); return answer }
        val timeout = try { timer.schedule({ answer.complete(FlushResult.TIMED_OUT) }, timeoutMs, TimeUnit.MILLISECONDS) }
        catch (_: RejectedExecutionException) { answer.complete(FlushResult.FAILED); return answer }
        worker.execute {
            if (synchronized(lock) { state } != "ready") answer.complete(FlushResult.FAILED)
            else try {
                provider.flush(timeoutMs).whenComplete { value, failure ->
                    answer.complete(if (failure == null) value ?: FlushResult.FAILED else FlushResult.FAILED)
                }
            } catch (_: Exception) { answer.complete(FlushResult.FAILED) }
        }
        answer.whenComplete { _, _ -> timeout.cancel(false) }
        return answer
    }

    fun observeApplication(app: Application) {
        val callback = object : Application.ActivityLifecycleCallbacks {
            private var started = 0
            override fun onActivityStarted(activity: Activity) { if (started++ == 0) applicationVisibility(false) }
            override fun onActivityStopped(activity: Activity) {
                started = (started - 1).coerceAtLeast(0)
                if (started == 0 && !activity.isChangingConfigurations) applicationVisibility(true)
            }
            override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        }
        application = app; lifecycle = callback
        app.registerActivityLifecycleCallbacks(callback)
    }

    private fun applicationVisibility(background: Boolean) {
        val current = synchronized(lock) { appBackground = background; bindings.toList() }
        current.forEach { it.applicationVisibility(background) }
    }

    fun dispose() {
        val current = synchronized(lock) {
            if (state == "disposed") return
            state = "disposed"
            count("discarded_dispose", queue.size.toLong())
            queue.clear(); queuedBytes = 0
            bindings.toList().also { bindings.clear() }
        }
        current.forEach { it.disable() }
        initialization.complete(InitResult("failed", "disposed"))
        lifecycle?.let { application?.unregisterActivityLifecycleCallbacks(it) }
        application = null; lifecycle = null
        disposeProviderOnce()
        timer.shutdownNow()
    }

    private fun disposeProviderOnce() {
        synchronized(lock) {
            if (providerDisposeScheduled) return
            providerDisposeScheduled = true
        }
        worker.execute { try { provider.dispose() } catch (_: Exception) { count("dispose_error") } }
    }
}
