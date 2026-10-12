package com.example.lynxshell.sample

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.test.InstrumentationTestRunner
import android.view.View
import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.FrameLayout
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.bridge.LynxRouterMessageReply
import com.example.lynxshell.bridge.LynxRouterPageInfo
import com.example.lynxshell.bridge.ShellMessageHub
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxEnv
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewBuilder
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateBundle
import com.lynx.tasm.TemplateData
import com.lynx.tasm.ThreadStrategyForRendering
import com.lynx.tasm.behavior.ui.text.FlattenUIText
import com.lynx.tasm.behavior.ui.text.IUIText
import com.lynx.tasm.behavior.ui.text.UIText
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.lynx.tasm.behavior.ui.text.AndroidText
import com.lynx.tasm.group.ILynxViewGroup
import com.lynx.tasm.group.LynxViewGroupBuilder
import com.ota.android.sdk.OtaJson
import java.io.File
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** 独立SDK Group cache=true诊断；不改变安全生产cache或冻结State验收。 */
class EngineReuseLifecycleDiagnosticTest : InstrumentationTestCase() {
    fun testSameOriginalEngineLifecycleWithRenderedTextAndMetadataSeparated() {
        val context = instrumentation.targetContext
        val ordering = (instrumentation as InstrumentationTestRunner).arguments.getString("ordering") ?: "normal"
        require(ordering in setOf("normal", "pre-reload"))
        assertEquals("仅隔离验收App", "com.hugboga.custom.otae2e", context.packageName)
        val input = File(context.filesDir, "engine-reuse-lifecycle-diagnostic")
        val metadata = OtaJson.asObject(OtaJson.parse(File(input, "fixture-metadata.json").readText()), "diagnostic")
        assertEquals("ENGINE_REUSE_DIAGNOSTIC_V1", metadata["fixture"])
        val artifact = OtaJson.asObject(metadata["bundle"], "bundle")
        assertEquals("EngineReuseLifecycleProbe.lynx.bundle", artifact["path"])
        val bytes = File(input, artifact["path"] as String).readBytes()
        assertEquals((artifact["size"] as Number).toInt(), bytes.size)
        assertEquals(artifact["sha256"], sha256(bytes))
        val launcher = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("lynx_shell.show_native_launcher", true),
        ) as MainActivity
        val frame = FrameLayout(launcher)
        onMain {
            launcher.setContentView(frame)
            // SDK解析模板依赖Native环境，先按真实宿主顺序触发Builder初始化。
            LynxViewBuilder()
        }
        assertTrue("解析真实模板前必须完成Lynx Native环境初始化", LynxEnv.inst().isNativeLibraryLoaded)
        val template = TemplateBundle.fromTemplate(bytes)
        assertTrue(template.errorMessage, template.isValid)
        val results = File(context.filesDir, "engine-reuse-lifecycle-diagnostic/results").also { assertTrue(it.isDirectory || it.mkdirs()) }
        val pages = ConcurrentHashMap<String, Page>()
        val rows = Collections.synchronizedList(mutableListOf<MutableMap<String, Any?>>())
        val fileLock = Any()
        fun persist() = synchronized(fileLock) {
            val copy = synchronized(rows) { rows.toList() }.map { row -> synchronized(row) { LinkedHashMap(row) } }
            File(results, "results.json").writeText(OtaJson.stringify(copy))
        }
        var group: ILynxViewGroup? = null
        onMain {
            val builder = LynxViewGroupBuilder().setContext(launcher.applicationContext)
                .setUrl("assets://diagnostic/EngineReuseLifecycleProbe.lynx.bundle")
                .setTemplateBundle(template).setEnableCacheEngine(true).setEnableSharedModule(false)
            builder.setThreadStrategyForRendering(ThreadStrategyForRendering.MOST_ON_TASM)
            group = builder.build()
            LynxRouter.setMessageHandler { message ->
                val page = pages[message.source.pageId]
                val accepted = page != null && !page.closed.get() &&
                    message.payload["fixture"] == "ENGINE_REUSE_DIAGNOSTIC_V1" &&
                    message.payload["pageId"] == page.id && message.payload["marker"] == page.marker
                page?.let {
                    it.events.add(Event(message.eventName, message.source.pageId, message.payload, accepted))
                    it.row["lastActualNativeEvent"] = mapOf("source" to message.source.pageId, "name" to message.eventName,
                        "payload" to message.payload, "accepted" to accepted)
                    persist()
                }
                record("Native actual name=${message.eventName} source=${message.source.pageId} accepted=$accepted payload=${OtaJson.stringify(message.payload)}")
                LynxRouterMessageReply(accepted, "诊断真实source与marker")
            }
        }
        fun open(marker: String, oldOnly: Boolean): Page {
            val id = "engine-lifecycle-${UUID.randomUUID()}"
            val row = Collections.synchronizedMap(linkedMapOf<String, Any?>("pageId" to id, "marker" to marker,
                "oldOnly" to oldOnly, "ordering" to ordering))
            val page = Page(id, marker, oldOnly, row)
            pages[id] = page
            rows += row
            val data = linkedMapOf<String, Any>("marker" to marker)
            val props = linkedMapOf<String, Any>("marker" to "global-$marker", "probePageId" to id)
            if (oldOnly) { data["oldOnly"] = "A-only"; props["oldOnly"] = "A-global-only" }
            onMain {
                val builder = LynxViewBuilder().setLynxViewGroup(requireNotNull(group))
                    .setThreadStrategyForRendering(ThreadStrategyForRendering.MOST_ON_TASM)
                page.view = builder.build(launcher)
                page.context = page.view!!.lynxContext
                page.view!!.addLynxViewClient(object : LynxViewClient() {
                    override fun onFirstScreen() { page.sdkFirstScreens.incrementAndGet(); page.sdkFirst.countDown() }
                    override fun onPageStart(url: String?) { record("SDK pageStart marker=$marker") }
                    override fun onPageUpdate() { record("SDK pageUpdate marker=$marker") }
                    override fun onDataUpdated() { record("SDK dataUpdated marker=$marker") }
                    override fun onLoadSuccess() { record("SDK loadSuccess marker=$marker") }
                    override fun onRuntimeReady() { record("SDK runtimeReady marker=$marker") }
                    override fun onReceivedError(error: LynxError) { if (error.isFatal) page.fatal.set(error.toString()) }
                })
                page.view!!.updateGlobalProps(TemplateData.fromMap(props))
                ShellMessageHub.register(LynxRouterPageInfo(id, id, "diagnostic", "page"), launcher, page.view!!)
                page.row["renderStartNs"] = SystemClock.elapsedRealtimeNanos()
                if (!oldOnly && ordering == "pre-reload") {
                    page.view!!.resetData(TemplateData.fromMap(data))
                    page.view!!.reloadTemplate(TemplateData.fromMap(data), TemplateData.fromMap(props))
                }
                // SDK公开重建保证attach前Android子View存在，不触碰MTS私有flag。
                page.view!!.lynxUIRenderer().lynxUIOwner().rootUI?.rebuildViewTree()
                frame.addView(page.view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                page.view!!.renderTemplateUrl("assets://diagnostic/EngineReuseLifecycleProbe.lynx.bundle", TemplateData.fromMap(data))
            }
            return page
        }
        fun close(page: Page) {
            if (!page.closed.compareAndSet(false, true)) return
            onMain {
                ShellMessageHub.unregister(page.id)
                page.view?.let { frame.removeView(it); it.destroy() }
            }
            page.row["destroyed"] = true
            persist()
            instrumentation.waitForIdleSync()
        }
        try {
            val a = open("DIAG_PAGE_A", true)
            assertTrue("冷页真实SDK首屏", a.sdkFirst.await(30, TimeUnit.SECONDS))
            assertNativeState(a, awaitEvent(a, STATE_EVENT, 0), 0)
            assertRenderedText(a, 0, results, "A-counter0.png")
            val first = identity(requireNotNull(a.view))
            assertNotNull("必须是官方真实LynxEngine", first.engine)
            assertTrue(first.ptr != null && first.ptr != 0L)
            a.row.putAll(first.toRow())
            awaitEvent(a, TRACE_EVENT, 0)
            val cursor = a.events.size
            tap(requireNotNull(a.view))
            assertNativeState(a, awaitEvent(a, STATE_EVENT, cursor), 1)
            assertRenderedText(a, 1, results, "A-counter1.png")
            awaitEvent(a, TRACE_EVENT, cursor)
            close(a)
            a.row["enginePtrAfterDestroy"] = enginePtr(requireNotNull(first.engine))
            persist()

            val b = open("DIAG_PAGE_B", false)
            assertNativeState(b, awaitEvent(b, STATE_EVENT, 0), 0)
            val second = identity(requireNotNull(b.view))
            b.row.putAll(second.toRow())
            b.row["sdkFirstScreenCount"] = b.sdkFirstScreens.get()
            assertNotSame(a.view, b.view)
            assertNotSame(a.context, b.context)
            assertSame("必须命中original真实Engine，不能用Template-only冒充", first.engine, second.engine)
            assertEquals(first.ptr, second.ptr)
            assertTrue(second.ptr != null && second.ptr != 0L)
            awaitEvent(b, TRACE_EVENT, 0)
            // UI真值改为公开origin/layout文本+pixels，旧metadata getter单独记录。
            assertRenderedText(b, 0, results, "B-rendered.png")
            b.row["sameOriginalEngine"] = true
            persist()
            close(b)
            val c = open("DIAG_PAGE_C", false)
            assertNativeState(c, awaitEvent(c, STATE_EVENT, 0), 0)
            val third = identity(requireNotNull(c.view))
            c.row.putAll(third.toRow())
            assertSame("C仍必须命中original Engine", first.engine, third.engine)
            assertEquals(first.ptr, third.ptr)
            assertTrue(third.ptr != null && third.ptr != 0L)
            awaitEvent(c, TRACE_EVENT, 0)
            assertRenderedText(c, 0, results, "C-rendered.png")
            c.row["sameOriginalEngine"] = true
            persist()
            close(c)
        } finally {
            try { pages.values.forEach(::close) } finally {
                onMain { LynxRouter.setMessageHandler(null); group?.release(); launcher.finish() }
            }
        }
    }

    private fun awaitEvent(page: Page, name: String, after: Int): Event {
        val deadline = SystemClock.elapsedRealtime() + 30_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            assertNull("SDK fatal", page.fatal.get())
            page.events.toList().drop(after).firstOrNull { it.name == name }?.let { return it }
            SystemClock.sleep(30)
        }
        fail("真实Native事件未到达 $name marker=${page.marker}")
        error("unreachable")
    }
    private fun assertNativeState(page: Page, event: Event, counter: Int) {
        assertTrue(event.accepted)
        assertEquals(page.id, event.source)
        assertEquals(page.id, event.payload["pageId"])
        assertEquals(page.marker, event.payload["marker"])
        assertEquals("global-${page.marker}", event.payload["globalMarker"])
        assertEquals(page.oldOnly, event.payload["oldOnly"])
        assertEquals(page.oldOnly, event.payload["globalOldOnly"])
        assertEquals(counter, (event.payload["counter"] as Number).toInt())
        assertEquals("独立onceEffect实际module count", 1, (event.payload["moduleMountCount"] as Number).toInt())
        page.row["nativeState"] = event.payload
    }
    private fun assertRenderedText(page: Page, counter: Int, results: File, screenshotName: String) {
        val expected = "diag:${page.marker}:page=${page.id}:counter=$counter:mount=1:oldOnly=${page.oldOnly}:globalOldOnly=${page.oldOnly}"
        var origin = ""
        var layout: String? = null
        var metadata: String? = null
        onMain {
                val ui = requireNotNull(page.view).findUIByIdSelector("engine-diagnostic-ready")
                metadata = ui?.accessibilityLabel?.toString()
                origin = when (ui) { is UIText -> ui.originText.toString(); is FlattenUIText -> ui.originText.toString(); else -> "" }
                layout = (ui as? IUIText)?.textLayout?.text?.toString()
        }
        page.row["expectedRenderedText"] = expected
        page.row["originText"] = origin
        page.row["layoutText"] = layout
        page.row["accessibilityLabelGetter"] = metadata
        page.row["accessibilityGetterMatchesOrigin"] = metadata == origin
        record("UI marker=${page.marker} origin=$origin layout=$layout metadata=$metadata")
        val frame = CountDownLatch(1)
        onMain { page.view!!.postOnAnimation { page.view!!.postOnAnimation { frame.countDown() } } }
        assertTrue(frame.await(10, TimeUnit.SECONDS))
        onMain {
            val rootNodes = mutableListOf<Map<String, Any?>>()
            fun collect(ui: LynxBaseUI) {
                val text = when (ui) { is UIText -> ui.originText?.toString(); is FlattenUIText -> ui.originText?.toString(); else -> null }
                rootNodes += mapOf("uiClass" to ui.javaClass.name, "uiObjectIdentity" to System.identityHashCode(ui),
                    "sign" to ui.sign, "nodeIndex" to ui.nodeIndex, "idSelector" to ui.idSelector,
                    "originText" to text, "layoutText" to (ui as? IUIText)?.textLayout?.text?.toString(),
                    "accessibilityLabel" to ui.accessibilityLabel?.toString(), "screenRect" to ui.rectToWindow.toString())
                ui.children.forEach(::collect)
            }
            page.view!!.lynxUIRenderer().lynxUIOwner().rootUI?.let(::collect)
            page.row["rootUiChildren"] = rootNodes
            val nativeNodes = mutableListOf<Map<String, Any?>>()
            fun collectNative(view: View) {
                if (view is AndroidText) nativeNodes += mapOf("viewClass" to view.javaClass.name,
                    "viewObjectIdentity" to System.identityHashCode(view), "originText" to view.originText?.toString(),
                    "layoutText" to view.textLayout?.text?.toString())
                if (view is ViewGroup) for (i in 0 until view.childCount) collectNative(view.getChildAt(i))
            }
            collectNative(page.view!!)
            page.row["actualAndroidTextViews"] = nativeNodes
            page.row["expectedTextFoundInRootTree"] = rootNodes.any { it["originText"] == expected || it["layoutText"] == expected }
            page.row["expectedTextFoundInAndroidViewTree"] = nativeNodes.any { it["originText"] == expected || it["layoutText"] == expected }
        }
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { File(results, screenshotName).outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
        page.row["selectorOriginMatchesExpected"] = origin == expected
        page.row["pixelScreenshotBasename"] = screenshotName
        page.row["diagnosticCollectionIsNotUiAcceptance"] = true
    }
    private fun tap(view: LynxView) {
        val rect = Rect()
        onMain { rect.set(requireNotNull(view.findUIByIdSelector("engine-diagnostic-increment")).rectToWindow) }
        assertTrue(rect.width() > 0 && rect.height() > 0)
        val time = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(time, SystemClock.uptimeMillis(), action, rect.exactCenterX(), rect.exactCenterY(), 0)
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
        }
    }
    private fun identity(view: LynxView): Identity {
        var result: Identity? = null
        onMain {
            val render = requireNotNull(LynxView::class.java.getDeclaredField("mLynxTemplateRender").apply { isAccessible = true }.get(view))
            val engine = render.javaClass.getDeclaredField("mLynxEngineRef").apply { isAccessible = true }.get(render)
            result = Identity(engine, engine?.let(::enginePtr), render.javaClass.getDeclaredField("mNativePtr").apply { isAccessible = true }.getLong(render))
        }
        return requireNotNull(result)
    }
    private fun enginePtr(engine: Any): Long = engine.javaClass.getMethod("getNativePtr").invoke(engine) as Long
    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    private fun onMain(block: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync { try { block() } catch (error: Throwable) { failure.set(error) } }
        failure.get()?.let { throw it }
    }
    private fun record(message: String) { instrumentation.sendStatus(0, Bundle().apply { putString("stream", "\nEngineLifecycleDiagnostic: $message\n") }) }
    private class Page(val id: String, val marker: String, val oldOnly: Boolean, val row: MutableMap<String, Any?>) {
        var view: LynxView? = null
        var context: Any? = null
        val closed = AtomicBoolean(false)
        val sdkFirst = CountDownLatch(1)
        val sdkFirstScreens = AtomicInteger()
        val fatal = AtomicReference<String?>()
        val events = ConcurrentLinkedQueue<Event>()
    }
    private data class Event(val name: String, val source: String, val payload: Map<String, Any?>, val accepted: Boolean)
    private data class Identity(val engine: Any?, val ptr: Long?, val shellPtr: Long) {
        fun toRow(): Map<String, Any?> = mapOf("originalEngineObjectIdentity" to engine?.let(System::identityHashCode), "originalEngineNativePtr" to ptr, "nativeShellPtr" to shellPtr)
    }
    private companion object {
        const val STATE_EVENT = "engine-reuse-diagnostic.state"
        const val TRACE_EVENT = "engine-reuse-diagnostic.mts-trace"
    }
}
