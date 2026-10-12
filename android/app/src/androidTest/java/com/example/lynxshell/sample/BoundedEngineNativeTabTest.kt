package com.example.lynxshell.sample

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.test.InstrumentationTestRunner
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.LynxShell
import com.example.lynxshell.bridge.LynxRouterMessageReply
import com.example.lynxshell.ota.ActivityBundleRuntime
import com.example.lynxshell.ota.PreparedActivityBundle
import com.example.lynxshell.tab.LynxTabFragment
import com.example.lynxshell.tab.LynxTabSpec
import com.lynx.tasm.LynxEnv
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewBuilder
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.lynx.tasm.behavior.ui.text.IUIText
import com.ota.android.sdk.ContentAddressedOtaStore
import com.ota.android.sdk.OtaJson
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.ReleaseTransaction
import java.io.File
import java.io.FileOutputStream
import java.util.Collections
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** 真实Native Fragment生命周期验收；scoped Store适配器不覆盖selectionServer选择合同。 */
class BoundedEngineNativeTabTest : InstrumentationTestCase() {
    fun testNativeTabFragmentsReuseOriginalEngineOnceWithFreshStateAndSource() {
        val context = instrumentation.targetContext
        assertEquals("只允许隔离验收App", "com.hugboga.custom.otae2e", context.packageName)
        val label = (instrumentation as InstrumentationTestRunner).arguments.getString("runLabel")
            ?: error("必须提供runLabel")
        require(label in setOf("baseline", "grouped"))
        val description = OtaJson.asObject(OtaJson.parse(File(context.filesDir,
            "engine-reuse-fixture.json").readText()), "FrozenStateFixture")
        val manifest = OtaModels.ReleaseManifest.fromJsonMap(OtaJson.asObject(description["manifest"], "manifest"), true)
        val state = OtaJson.asArray(description["cases"], "cases").map { OtaJson.asObject(it, "case") }
            .single { it["caseName"] == "state" }
        val path = state["path"] as String
        assertEquals("EngineReuseStateProbe.lynx.bundle", path)
        val artifact = manifest.bundles.single { it.bundlePath == path }
        assertEquals("sha256:" + (state["sha256"] as String).removePrefix("sha256:"), artifact.bundleSha256)
        assertEquals((state["size"] as Number).toInt(), requireNotNull(artifact.size))
        val scope = ReleaseTransaction.ReleaseScope.fromManifest(manifest)
        val storeRoot = File(context.cacheDir, "bounded-native-tab-${UUID.randomUUID()}")
        val store = ContentAddressedOtaStore(storeRoot, allowLocalHTTPForTest = true)
        store.reserveSidecars(manifest.lynxAppId, manifest.asyncBundleManifest).use {
            store.stageAsyncResources(manifest)
            store.install(ReleaseTransaction.InstallRequest(scope, manifest))
        }
        val leases = CopyOnWriteArrayList<ReleaseTransaction.BundleLease>()
        val runtimeCalls = ConcurrentLinkedQueue<String>()
        val runtime = object : ActivityBundleRuntime {
            override val userIdentityEpoch: Long = 0L
            override fun prepare(lynxAppId: String, bundleName: String): PreparedActivityBundle =
                error("Native Tab本用例必须走cache-only resolve，不得调用prepare")
            override fun resolveCurrent(lynxAppId: String, bundleName: String): PreparedActivityBundle {
                runtimeCalls.add("resolveCurrent")
                return acquire(lynxAppId, bundleName)
            }
            override fun resolvePage(lynxAppId: String, bundleName: String): PreparedActivityBundle {
                runtimeCalls.add("resolvePage")
                return acquire(lynxAppId, bundleName)
            }
            private fun acquire(appId: String, bundleName: String): PreparedActivityBundle {
                check(appId == manifest.lynxAppId && bundleName == path)
                val lease = requireNotNull(store.acquireCurrentBundleLease(scope, bundleName))
                leases += lease
                check(lease.bundle.bundleSha256 == artifact.bundleSha256)
                check(lease.file.length() == requireNotNull(artifact.size).toLong())
                return PreparedActivityBundle(lynxAppId = appId, bundleName = bundleName,
                    file = lease.file, releaseId = manifest.releaseId, sha256 = lease.bundle.bundleSha256,
                    source = "ota_current", userIdentityEpoch = 0L, sidecarResources = lease.sidecars,
                    releaseLease = lease)
            }
        }
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("lynx_shell.show_native_launcher", true)) as MainActivity
        val frame = FrameLayout(activity)
        val results = File(context.filesDir, "bounded-engine-native-tab-results/$label/$name")
            .also { assertTrue(it.isDirectory || it.mkdirs()) }
        val rows = Collections.synchronizedList(mutableListOf<MutableMap<String, Any?>>())
        val pages = ConcurrentHashMap<String, Page>()
        val writeLock = Any()
        fun persist() = synchronized(writeLock) {
            val snapshot = synchronized(rows) { rows.toList() }.map { synchronized(it) { LinkedHashMap(it) } }
            File(results, "results.json").writeText(OtaJson.stringify(snapshot))
        }
        val runtimeField = LynxShell::class.java.getDeclaredField("installedActivityBundleRuntime")
            .apply { isAccessible = true }
        var originalRuntime: Any? = null
        var runtimeReplaced = false
        fun installScopedRuntime() = onMain {
            frame.id = View.generateViewId()
            activity.setContentView(frame)
            LynxViewBuilder()
            assertTrue("真实Native环境必须先完成初始化", LynxEnv.inst().isNativeLibraryLoaded)
            LynxShell.onTrimMemory(10)
            originalRuntime = runtimeField.get(LynxShell)
            runtimeField.set(LynxShell, runtime)
            runtimeReplaced = true
            LynxRouter.setMessageHandler { message ->
                val page = pages[message.source.pageId]
                val accepted = page != null && !page.removed.get() && message.eventName == READY_EVENT &&
                    message.payload["fixture"] == FIXTURE_MARKER && message.payload["caseName"] == "state" &&
                    message.payload["pageId"] == page.pageId && message.payload["marker"] == page.marker &&
                    message.payload["globalMarker"] == "global-${page.marker}"
                page?.let {
                    val event = Event(message.source.pageId, message.payload, accepted)
                    it.events.add(event)
                    it.row["lastActualNativeEvent"] = event.toRow()
                    it.row["actualNativeEventCount"] = it.events.size
                    persist()
                }
                record("Native Tab source=${message.source.pageId} accepted=$accepted payload=${OtaJson.stringify(message.payload)}")
                LynxRouterMessageReply(accepted, "NativeTab真实source和marker核对")
            }
        }
        fun open(marker: String, oldOnly: Boolean): Page {
            val initData = linkedMapOf<String, Any>("marker" to marker)
            val props = linkedMapOf<String, Any>("marker" to "global-$marker")
            if (oldOnly) { initData["oldOnly"] = "A-only"; props["oldOnly"] = "A-global-only" }
            lateinit var page: Page
            onMain {
                val tabId = "bounded-engine-state"
                val fragment = LynxTabFragment.newInstance(LynxTabSpec(tabId = tabId,
                    bundleUrl = "assets://bundles/$path", routeKey = tabId,
                    initDataJson = OtaJson.stringify(initData), globalPropsJson = OtaJson.stringify(props),
                    lynxAppId = manifest.lynxAppId, bundleName = path))
                val id = "lynx-tab-$tabId-${System.identityHashCode(fragment)}"
                props["probePageId"] = id
                // 已核对生产ARG_GLOBAL_PROPS键；必须在真实Fragment.onCreate解析spec前更新。
                fragment.requireArguments().putString("lynx.tab.global.props", OtaJson.stringify(props))
                val row = Collections.synchronizedMap(linkedMapOf<String, Any?>(
                    "testMethod" to name, "runLabel" to label, "pageId" to id, "marker" to marker,
                    "withOldOnly" to oldOnly, "lynxAppId" to manifest.lynxAppId,
                    "releaseId" to manifest.releaseId, "bundlePath" to path, "bundleSha256" to artifact.bundleSha256,
                    "runtimeAdapterScope" to "real_store_cache_only_native_fragment_lifecycle",
                    "selectionServerAcceptance" to false))
                page = Page(id, marker, oldOnly, fragment, row)
                pages[id] = page
                rows += row
                page.row["fragmentAddElapsedRealtimeNs"] = SystemClock.elapsedRealtimeNanos()
                activity.supportFragmentManager.beginTransaction().add(frame.id, fragment, id).commitNow()
                assertTrue("必须真正add Fragment", fragment.isAdded)
                assertEquals("生产onCreate生成的真实pageID", id, requireNotNull(fragment.view).tag)
            }
            return page
        }
        fun remove(page: Page) {
            if (!page.removed.compareAndSet(false, true)) return
            onMain {
                if (page.fragment.isAdded) activity.supportFragmentManager.beginTransaction().remove(page.fragment).commitNow()
                assertFalse("真实remove必须执行Fragment销毁", page.fragment.isAdded)
                assertNull("真实onDestroyView后Fragment的host必须解除", page.fragment.view)
            }
            page.row["removedByFragmentTransaction"] = true
            persist()
            instrumentation.waitForIdleSync()
        }
        try {
            installScopedRuntime()
            val first = open("native-tab-A", true)
            awaitTabReady(first, expectedReused = false)
            assertNativeReady(first, awaitEvent(first, 0), counter = 0)
            assertSingleEffect(first, counter = 0)
            val firstCursor = first.events.size
            tap(requireNotNull(first.lynxView), "engine-reuse-increment")
            assertNativeReady(first, awaitEvent(first, firstCursor), counter = 1)
            assertSingleEffect(first, counter = 1)
            assertEquals("冷A只允许一次真实cache-only解析", 1, leases.size)
            val firstLease = leases[0]
            remove(first)
            assertTrue("A真实Fragment.onDestroyView必须关闭Store lease", isLeaseClosed(firstLease))
            assertEquals("A归还后必须留存原Engine以供一次复用", first.enginePtr, enginePtr(requireNotNull(first.engine)))

            val second = open("native-tab-B-fresh", false)
            awaitTabReady(second, expectedReused = true)
            assertNativeReady(second, awaitEvent(second, 0), counter = 0)
            assertSingleEffect(second, counter = 0)
            assertNotSame("B必须新Fragment", first.fragment, second.fragment)
            assertNotSame("B必须新LynxView", first.lynxView, second.lynxView)
            assertNotSame("B必须新LynxContext", first.lynxContext, second.lynxContext)
            assertSame("NativeTab B必须复用原真实Engine Java对象", first.engine, second.engine)
            assertEquals("NativeTab B必须复用同非零wrapper ptr", first.enginePtr, second.enginePtr)
            assertTrue(second.enginePtr != 0L)
            second.row["sameOriginalEngineObject"] = true
            second.row["sameOriginalEngineNativePtr"] = true
            second.row["firstLeaseClosedBeforeWarmB"] = isLeaseClosed(firstLease)
            val secondCursor = second.events.size
            tap(requireNotNull(second.lynxView), "engine-reuse-increment")
            assertNativeReady(second, awaitEvent(second, secondCursor), counter = 1)
            assertSingleEffect(second, counter = 1)
            saveScreenshot(requireNotNull(second.lynxView), results, "native-tab-B-counter1.png")
            assertEquals("两Fragment分别acquire真实lease", 2, leases.size)
            assertEquals(listOf("resolvePage", "resolvePage"), runtimeCalls.toList())
            remove(second)
            assertTrue("B真实Fragment.onDestroyView必须关闭Store lease", isLeaseClosed(leases[1]))
            val after = enginePtr(requireNotNull(second.engine))
            second.row["engineNativePtrAfterWarmFragmentRemove"] = after
            assertEquals("B退出后Group必须释放原真实Engine", 0L, after)
            persist()
        } finally {
            try { pages.values.forEach(::remove) } finally {
                try {
                    onMain {
                        LynxRouter.setMessageHandler(null)
                        if (runtimeReplaced) {
                            runtimeField.set(LynxShell, originalRuntime)
                            assertSame("scoped测试Runtime必须恢复原引用", originalRuntime, runtimeField.get(LynxShell))
                        }
                        LynxShell.onTrimMemory(10)
                        activity.finish()
                    }
                } finally {
                    leases.forEach { it.close() }
                    persist()
                    storeRoot.deleteRecursively()
                }
            }
        }
    }

    private fun awaitTabReady(page: Page, expectedReused: Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000L
        var ready = false
        while (SystemClock.elapsedRealtime() < deadline) {
            onMain {
                val views = androidTree(page.fragment.view).filterIsInstance<LynxView>()
                assertTrue("真实Fragment host不得同时保留多个LynxView", views.size <= 1)
                val view = views.singleOrNull()
                val state = page.fragment.debugStateDescription()
                page.row["actualFragmentDebugState"] = state
                if (view != null && state.split(';').contains("error=ready")) {
                    page.lynxView = view
                    page.lynxContext = view.lynxContext
                    val renderer = readField(view, "mLynxTemplateRender", LynxView::class.java)
                    page.engine = readField(renderer, "mLynxEngineRef")
                    page.enginePtr = enginePtr(requireNotNull(page.engine))
                    assertTrue("真实Tab Engine wrapper必须非零", page.enginePtr != 0L)
                    assertEquals("实际Cache registration命中必须符合冷暖预期", expectedReused, isReused(view))
                    assertTrue("真实Tab必须attach/layout", view.isAttachedToWindow && view.width > 0 && view.height > 0)
                    assertTrue("Tab必须只加载一次", state.split(';').contains("load=1"))
                    assertTrue("Tab必须只render一次", state.split(';').contains("render=1"))
                    page.row["engineReused"] = expectedReused
                    page.row["engineObjectIdentity"] = System.identityHashCode(requireNotNull(page.engine))
                    page.row["engineNativePtr"] = page.enginePtr
                    page.row["lynxViewObjectIdentity"] = System.identityHashCode(view)
                    page.row["lynxContextObjectIdentity"] = System.identityHashCode(requireNotNull(page.lynxContext))
                    page.row["tabReadyObservedElapsedRealtimeNs"] = SystemClock.elapsedRealtimeNanos()
                    page.row["firstFrameReceiptObservation"] = "production_tab_debug_error_ready"
                    page.row["warmCachedFrameConsumed"] = expectedReused
                    ready = true
                }
            }
            if (ready) return
            SystemClock.sleep(30)
        }
        fail("真实Tab健康首帧消费未完成 page=${page.pageId} state=${page.row["actualFragmentDebugState"]}")
    }

    private fun awaitEvent(page: Page, after: Int): Event {
        val deadline = SystemClock.elapsedRealtime() + 30_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            page.events.toList().drop(after).firstOrNull()?.let { return it }
            SystemClock.sleep(30)
        }
        fail("真实Native Tab事件未到达 page=${page.pageId}")
        error("unreachable")
    }

    private fun assertNativeReady(page: Page, event: Event, counter: Int) {
        assertPayload(page, event, counter)
        val expected = "engine-reuse:state:page=${page.pageId}:marker=${page.marker}:counter=$counter:mount=1:oldOnly=${page.oldOnly}:globalOldOnly=${page.oldOnly}"
        val deadline = SystemClock.elapsedRealtime() + 30_000L
        var actual = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            onMain {
                val view = requireNotNull(page.lynxView)
                val ui = currentUi(view, "engine-reuse-ready")
                actual = (ui as? IUIText)?.textLayout?.text?.toString().orEmpty()
                page.row["currentRootReadyText"] = actual
                page.row["currentRootReadyIdentity"] = ui?.let(System::identityHashCode)
                if (actual == expected) {
                    val readyUi = requireNotNull(ui)
                    assertTrue("真实READY节点必须完成layout", readyUi.latestSize.x > 0 && readyUi.latestSize.y > 0)
                    assertEquals("宿主接受后当前根状态必须READY", "READY",
                        (currentUi(view, "engine-reuse-status") as? IUIText)?.textLayout?.text?.toString())
                }
            }
            if (actual == expected) {
                page.row["nativeReadyPayload"] = event.payload
                page.row["nativeSourcePageId"] = event.source
                return
            }
            SystemClock.sleep(30)
        }
        assertEquals("NativeTab当前根唯一READY必须显示完整新页面文本", expected, actual)
    }

    private fun assertPayload(page: Page, event: Event, counter: Int) {
        assertTrue("必须收到真实宿主接受回执", event.accepted)
        assertEquals("Native source必须是该Fragment真实pageID", page.pageId, event.source)
        assertEquals(page.pageId, event.payload["pageId"])
        assertEquals(page.marker, event.payload["marker"])
        assertEquals("global-${page.marker}", event.payload["globalMarker"])
        assertEquals(page.oldOnly, event.payload["hasOldOnly"])
        assertEquals(page.oldOnly, event.payload["globalHasOldOnly"])
        assertEquals(counter, (event.payload["counter"] as Number).toInt())
        assertEquals("新Tab模块只mount一次", 1, (event.payload["moduleMountCount"] as Number).toInt())
        assertEquals(if (counter == 0) "initial" else "counter", event.payload["phase"])
    }

    private fun assertSingleEffect(page: Page, counter: Int) {
        SystemClock.sleep(250)
        val events = page.events.toList()
        page.row["allActualNativeEvents"] = events.map(Event::toRow)
        assertEquals("不能只取首个正确回执掩盖重复mount", counter + 1, events.size)
        events.forEachIndexed { index, event -> assertPayload(page, event, index) }
    }

    private fun tap(view: LynxView, selector: String) {
        onMain { requireNotNull(currentUi(view, selector)).scrollIntoView(false, "nearest", "nearest") }
        instrumentation.waitForIdleSync()
        val rect = Rect()
        onMain {
            val ui = requireNotNull(currentUi(view, selector))
            rect.set(ui.rectToWindow)
            assertTrue("真实flatten按钮必须完成layout", !rect.isEmpty)
            val origin = IntArray(2)
            view.getLocationOnScreen(origin)
            val viewport = Rect(origin[0], origin[1], origin[0] + view.width, origin[1] + view.height)
            assertTrue("触控必须落在真实attach的Tab可见区域", view.isAttachedToWindow && viewport.contains(rect.centerX(), rect.centerY()))
        }
        val start = SystemClock.uptimeMillis()
        for ((action, time) in listOf(MotionEvent.ACTION_DOWN to start, MotionEvent.ACTION_UP to start + 50)) {
            val event = MotionEvent.obtain(start, time, action, rect.exactCenterX(), rect.exactCenterY(), 0)
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
        }
    }

    private fun currentUi(view: LynxView, id: String): LynxBaseUI? {
        fun collect(ui: LynxBaseUI?): List<LynxBaseUI> = if (ui == null) emptyList() else listOf(ui) + ui.children.flatMap(::collect)
        val matches = collect(view.lynxUIRoot).filter { it.idSelector == id }
        assertTrue("当前Root同ID不能重复 id=$id count=${matches.size}", matches.size <= 1)
        return matches.singleOrNull()
    }

    private fun androidTree(view: View?): List<View> = if (view == null) emptyList() else listOf(view) +
        if (view is ViewGroup) (0 until view.childCount).flatMap { androidTree(view.getChildAt(it)) } else emptyList()

    private fun saveScreenshot(view: LynxView, results: File, basename: String) {
        val drawn = CountDownLatch(1)
        onMain { view.invalidate(); view.postOnAnimation { view.postOnAnimation { drawn.countDown() } } }
        check(drawn.await(10, TimeUnit.SECONDS)) { "真实Tab断言通过后的截图绘制帧未到达" }
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { FileOutputStream(File(results, basename)).use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
    }

    private class Page(val pageId: String, val marker: String, val oldOnly: Boolean,
        val fragment: LynxTabFragment, val row: MutableMap<String, Any?>) {
        val removed = AtomicBoolean(false)
        val events = ConcurrentLinkedQueue<Event>()
        var lynxView: LynxView? = null
        var lynxContext: Any? = null
        var engine: Any? = null
        var enginePtr = 0L
    }

    private data class Event(val source: String, val payload: Map<String, Any?>, val accepted: Boolean) {
        fun toRow(): Map<String, Any?> = mapOf("source" to source, "payload" to payload, "accepted" to accepted)
    }
    private fun readField(value: Any, fieldName: String, owner: Class<*> = value.javaClass): Any =
        requireNotNull(owner.getDeclaredField(fieldName).apply { isAccessible = true }.get(value))
    private fun enginePtr(engine: Any): Long = engine.javaClass.getMethod("getNativePtr").invoke(engine) as Long
    private fun isLeaseClosed(lease: ReleaseTransaction.BundleLease): Boolean = (readField(lease, "closed") as AtomicBoolean).get()
    private fun isReused(view: LynxView): Boolean {
        val cache = Class.forName("com.example.lynxshell.container.LynxTemplateGroupCache")
        return cache.getDeclaredMethod("isReused", LynxView::class.java).invoke(cache.getField("INSTANCE").get(null), view) as Boolean
    }
    private fun onMain(block: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync { try { block() } catch (error: Throwable) { failure.set(error) } }
        failure.get()?.let { throw it }
    }
    private fun record(message: String) = instrumentation.sendStatus(0, Bundle().apply {
        putString("stream", "\nBoundedEngineNativeTab: $message\n")
    })
    private companion object {
        const val READY_EVENT = "engine-reuse-probe.ready"
        const val FIXTURE_MARKER = "ENGINE_REUSE_FIXTURE_V1"
    }
}
