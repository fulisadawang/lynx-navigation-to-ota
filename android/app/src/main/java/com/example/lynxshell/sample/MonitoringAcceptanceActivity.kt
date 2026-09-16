package com.example.lynxshell.sample

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.monitoring.JsErrorPayload
import com.example.lynxshell.monitoring.LifecyclePayload
import com.example.lynxshell.monitoring.LoadPayload
import com.example.lynxshell.monitoring.LynxMonitor
import com.example.lynxshell.monitoring.MonitorEvent
import com.example.lynxshell.monitoring.PerformancePayload
import com.example.lynxshell.monitoring.ResourcePayload
import com.example.lynxshell.ota.EmbeddedBundleRegistry
import com.google.android.material.button.MaterialButton

/**
 * Debug Sample 的 Android G1 本地监控验收页。
 *
 * 页面只读取 DiagnosticProvider 的内存快照，并把经过限制的摘要写入 logcat，
 * 方便把真实 Page、Native Tab 和 Lynx 回调证据带入测试报告。
 */
class MonitoringAcceptanceActivity : AppCompatActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var statusView: TextView
    private lateinit var eventsView: TextView
    private val refreshTask = object : Runnable {
        override fun run() {
            renderSnapshot()
            handler.postDelayed(this, 500L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Lynx 监控 G1 验收"

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }
        val scroll = ScrollView(this).apply {
            addView(root)
        }

        root.addView(TextView(this).apply {
            text = "Android LynxView 监控 G1 验收"
            textSize = 22f
            setTextColor(0xff111111.toInt())
        })
        root.addView(TextView(this).apply {
            text = "本页只使用本地 DiagnosticProvider。它实时采集并保存有界快照，不会联网，也不代表 ARMS、Bugly 或后台已收到。"
            textSize = 14f
            setPadding(0, dp(8), 0, dp(8))
        })
        statusView = TextView(this).apply {
            textSize = 13f
            setTextIsSelectable(true)
            contentDescription = "lynx-monitor-status"
        }
        root.addView(statusView, matchWrap())

        root.addView(button("打开 Page 验收", "lynx-monitor-open-page") {
            openPage()
        })
        root.addView(button("打开 Native Tab 验收", "lynx-monitor-open-tabs") {
            startActivity(Intent(this, NativeTabDemoActivity::class.java))
        })
        root.addView(button("打开资源/错误事件 Page", "lynx-monitor-open-resource-page") {
            openDirectBundle("assets://bundles/video-demo.lynx.bundle", "监控资源事件验收")
        })
        root.addView(button("把当前快照写入 logcat", "lynx-monitor-log-snapshot") {
            logSnapshot()
            Toast.makeText(this, "快照摘要已写入 logcat", Toast.LENGTH_SHORT).show()
        })
        root.addView(button("刷新当前快照", "lynx-monitor-refresh") {
            renderSnapshot()
        })

        root.addView(TextView(this).apply {
            text = "事件快照（最新 80 条）"
            textSize = 18f
            setPadding(0, dp(16), 0, dp(8))
        })
        eventsView = TextView(this).apply {
            textSize = 11f
            setTextIsSelectable(true)
            typeface = android.graphics.Typeface.MONOSPACE
            contentDescription = "lynx-monitor-events"
        }
        root.addView(eventsView, matchWrap())
        setContentView(scroll)
        renderSnapshot()
    }

    override fun onResume() {
        super.onResume()
        handler.removeCallbacks(refreshTask)
        handler.post(refreshTask)
    }

    override fun onPause() {
        handler.removeCallbacks(refreshTask)
        super.onPause()
    }

    private fun openPage() {
        // home.lynx.bundle 同时存在于两个 Demo App ID，需用 home+main 的组合唯一解析 10000001。
        openBundle("home.lynx.bundle", "监控 Page 验收", setOf("home.lynx.bundle", "main.lynx.bundle"))
    }

    /** 复用内置 Bundle Manifest 打开测试页，不绕过 LynxRouter 的身份解析。 */
    private fun openBundle(bundleName: String, title: String, identityBundleNames: Set<String> = setOf(bundleName)) {
        runCatching {
            val appId = EmbeddedBundleRegistry(this).uniqueAppIdForBundles(identityBundleNames)
                ?: error("内置 Manifest 中没有唯一的 OTA Demo appId")
            LynxRouter.open(
                this,
                lynxAppId = appId,
                bundleName = bundleName,
                params = mapOf("source" to "android-monitoring-acceptance-page", "acceptance" to true),
                options = mapOf("title" to title, "fullscreen" to false, "showToolbar" to true),
            )
        }.onFailure {
            Toast.makeText(this, it.message ?: "Bundle 打开失败", Toast.LENGTH_LONG).show()
        }
    }

    /** Playground 资源 Bundle 不在 OTA Manifest 中时，使用受支持的本地 assets 地址。 */
    private fun openDirectBundle(bundleUrl: String, title: String) {
        runCatching {
            LynxRouter.open(
                this,
                bundle = bundleUrl,
                params = mapOf("source" to "android-monitoring-acceptance-direct", "acceptance" to true),
                options = mapOf("title" to title, "fullscreen" to false, "showToolbar" to true),
            )
        }.onFailure {
            Toast.makeText(this, it.message ?: "Bundle 打开失败", Toast.LENGTH_LONG).show()
        }
    }

    private fun renderSnapshot() {
        val provider = LynxShellSampleApplication.diagnosticProvider
        if (provider == null) {
            statusView.text = "Provider 未安装：请使用 Debug APK；当前没有可读取的本地快照。"
            eventsView.text = "(empty)"
            return
        }
        val diagnostics = LynxMonitor.diagnostics()
        val events = provider.snapshot()
        val nextStatus = buildString {
            append("Provider=local_diagnostic · monitorState=${diagnostics.state}")
            diagnostics.reason?.let { append(" · reason=$it") }
            append("\nqueue=${diagnostics.queuedEvents}/${diagnostics.queuedBytes} bytes · localEvents=${events.size}")
            append(" · discardedLocal=${provider.discardedCount()}")
            if (diagnostics.counters.isNotEmpty()) append("\ncounters=${diagnostics.counters}")
        }
        val nextEvents = events.takeLast(80).mapIndexed { index, event -> formatEvent(events.size - 80.coerceAtMost(events.size) + index, event) }
            .joinToString("\n")
            .ifBlank { "(还没有事件；先打开 Page 或 Native Tab)" }
        // 快照没有变化时不重复触发无障碍事件，避免验收工具一直等待窗口空闲。
        if (statusView.text.toString() != nextStatus) statusView.text = nextStatus
        if (eventsView.text.toString() != nextEvents) eventsView.text = nextEvents
    }

    private fun formatEvent(index: Int, event: MonitorEvent): String = buildString {
        append("[$index] ${event.eventType.wire} kind=${event.containerKind.wire} ")
        append("view=${event.viewId?.take(8) ?: "none"} load=${event.loadId?.take(8) ?: "none"}")
        append(" visibility=${event.visibility.wire} quality=${event.quality.association}")
        event.bundle?.let { bundle ->
            append(" bundle=${bundle.bundleName ?: "none"}")
            append(" release=${bundle.releaseId ?: "none"}")
            append(" sha=${bundle.sha256?.take(12) ?: "none"}")
        }
        append(" payload=${payloadSummary(event)}")
    }

    private fun payloadSummary(event: MonitorEvent): String = when (val payload = event.payload) {
        is LifecyclePayload -> payload.state
        is LoadPayload -> "${payload.phase}${payload.reasonCode?.let { ":$it" } ?: ""}"
        is PerformancePayload -> payload.metrics.joinToString(",") { "${it.name}=${it.value}" }
            .ifBlank { "${payload.entryType}:${payload.entryName}" }
        is ResourcePayload -> "${payload.resourceType}:${payload.outcome}"
        is JsErrorPayload -> "${payload.level} frames=${payload.frames.size} phase=${payload.phase}"
        else -> event.eventType.wire
    }

    private fun logSnapshot() {
        val provider = LynxShellSampleApplication.diagnosticProvider ?: return
        val diagnostics = LynxMonitor.diagnostics()
        Log.i("LynxMonitorAcceptance", "diagnostics=$diagnostics")
        provider.snapshot().takeLast(80).forEachIndexed { index, event ->
            // logcat 只写标准化摘要，避免把错误堆栈或业务文本扩大到宿主日志范围。
            Log.i("LynxMonitorAcceptance", "event[$index]=${formatEvent(index, event)}")
        }
    }

    private fun button(label: String, id: String, action: () -> Unit): MaterialButton = MaterialButton(this).apply {
        text = label
        contentDescription = id
        setOnClickListener { action() }
    }

    private fun matchWrap() = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
