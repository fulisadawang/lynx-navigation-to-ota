package com.example.lynxshell.sample

import android.app.Activity
import android.content.Intent
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import com.example.lynxshell.LynxShell
import com.lynx.tasm.LynxView
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.lynx.tasm.behavior.ui.text.IUIText
import com.ota.android.sdk.OtaJson
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/** 真实首页按钮、原生路由及返回生命周期；不替换 Runtime 或合成首帧。 */
class ManualPageEngineReuseTest : InstrumentationTestCase() {
    fun testManualHomeRoutesReuseOneEngineThenReleaseBeforeThirdPage() {
        val ctx = instrumentation.targetContext
        assertEquals("com.hugboga.custom.otae2e", ctx.packageName)
        val home = instrumentation.startActivitySync(Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        val rows = mutableListOf<Map<String, Any?>>()
        val output = File(ctx.filesDir, "manual-engine-page-results").also { it.mkdirs() }
        fun persist() = File(output, "results.json").writeText(OtaJson.stringify(rows))
        var page: Activity? = null
        var first: Any? = null
        var firstPtr = 0L
        try {
            waitUntil("首页按钮启用") { mainValue { button(home).isEnabled } }
            main { LynxShell.onTrimMemory(10) }
            repeat(3) { index ->
                val monitor = instrumentation.addMonitor("com.example.lynxshell.container.LynxShellActivity", null, false)
                try {
                    main { assertTrue(button(home).performClick()) }
                    page = requireNotNull(instrumentation.waitForMonitorWithTimeout(monitor, 30_000))
                } finally { instrumentation.removeMonitor(monitor) }
                val activity = requireNotNull(page)
                var current: LynxView? = null
                waitUntil("真实原生Page的READY与健康帧") {
                    mainValue {
                        current = field(activity, "lynxView") as? LynxView
                        val view = current ?: return@mainValue false
                        val nodes = tree(view.lynxUIRoot).filter { it.idSelector == "bundle-bench-ready" }
                        (nodes.singleOrNull() as? IUIText)?.textLayout?.text?.toString() ==
                            "bundle-bench:small:payload=0:checksum=0:scripts=0" &&
                            ((field(activity, "firstScreenReadyGeneration") as? Number)?.toLong() ?: 0L) > 0
                    }
                }
                val view = requireNotNull(current)
                val engine = mainValue { requireNotNull(field(requireNotNull(field(view, "mLynxTemplateRender")), "mLynxEngineRef")) }
                val ptr = pointer(engine)
                assertTrue(ptr != 0L)
                if (index == 0) { first = engine; firstPtr = ptr }
                if (index == 1) { assertSame(first, engine); assertEquals(firstPtr, ptr) }
                if (index == 2) assertNotSame("第三次必须新Engine", first, engine)
                rows += mapOf("open" to index + 1, "realActivityClass" to activity.javaClass.name,
                    "engineIdentity" to System.identityHashCode(engine), "enginePtr" to ptr,
                    "sameAsFirst" to (engine === first), "currentRootReady" to true, "actualContainerHealthy" to true)
                persist()
                instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
                waitUntil("真实Back完成Activity销毁") { activity.isDestroyed }
                if (index == 0) assertEquals("退出A仍可供一次真实复用", firstPtr, pointer(engine))
                if (index == 1) assertEquals("退出B必须释放该Engine", 0L, pointer(engine))
                page = null
            }
        } finally {
            main { page?.finish(); home.finish(); LynxShell.onTrimMemory(10) }
            persist()
        }
    }
    private fun pointer(engine: Any): Long = engine.javaClass.getMethod("getNativePtr").invoke(engine) as Long
    private fun button(home: Activity): Button {
        fun children(view: View): List<View> = listOf(view) + if (view is ViewGroup)
            (0 until view.childCount).flatMap { children(view.getChildAt(it)) } else emptyList()
        return children(home.window.decorView).filterIsInstance<Button>().single { it.text.toString() == "小包 · 88 KB" }
    }
    private fun tree(ui: LynxBaseUI?): List<LynxBaseUI> = if (ui == null) emptyList() else listOf(ui) + ui.children.flatMap(::tree)
    private fun field(target: Any, name: String): Any? {
        var type: Class<*>? = target.javaClass
        while (type != null) {
            type.declaredFields.firstOrNull { it.name == name }?.let { return it.also { it.isAccessible = true }.get(target) }
            type = type.superclass
        }
        error(name)
    }
    private fun waitUntil(label: String, predicate: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < end) { if (predicate()) return; SystemClock.sleep(30) }
        fail(label)
    }
    private fun main(action: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync { try { action() } catch (error: Throwable) { failure.set(error) } }
        failure.get()?.let { throw it }
    }
    private fun <T> mainValue(action: () -> T): T {
        val result = AtomicReference<T>()
        main { result.set(action()) }
        return result.get()
    }
}
