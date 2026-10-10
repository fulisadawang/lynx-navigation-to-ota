package com.example.lynxshell.sample

import android.content.Intent
import android.os.Build
import android.os.Debug
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.test.InstrumentationTestRunner
import android.view.ViewGroup
import android.widget.FrameLayout
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.LynxShell
import com.example.lynxshell.bridge.LynxRouterMessageReply
import com.example.lynxshell.bridge.LynxRouterPageInfo
import com.example.lynxshell.bridge.ShellMessageHub
import com.example.lynxshell.container.LynxContainerFactory
import com.example.lynxshell.container.LynxFirstFrameSource
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.ota.PreparedActivityBundle
import com.example.lynxshell.resource.ShellTemplateProvider
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateBundle
import com.lynx.tasm.TemplateData
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.lynx.tasm.behavior.ui.text.IUIText
import com.lynx.tasm.group.ILynxViewGroup
import com.ota.android.sdk.ContentAddressedOtaStore
import com.ota.android.sdk.OtaJson
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.ReleaseTransaction
import java.io.File
import java.lang.ref.WeakReference
import java.util.Collections
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * 只验证生产 Factory 的有界 A→B Engine 借用；不改 fixture、不替代 SDK 回调、也不使用 ID finder 作为 UI 真值。
 */
class BoundedEngineSmokeTest : InstrumentationTestCase() {
    fun testEveryFixedBundleReusesOnlyOnceThenCreatesNewPair() = withFixture { fixture ->
        fixture.cases.forEach { case ->
            val first = fixture.open(case)
            fixture.assertReady(first, expectedReused = false)
            val firstEngine = requireNotNull(first.engine)
            val firstPtr = first.enginePtr
            val firstView = first.view
            val firstContext = requireNotNull(first.context)
            fixture.destroy(first)
            assertEquals("A退出后必须保留一次可借的真实Engine ${case.name}", firstPtr, enginePtr(firstEngine))

            val second = fixture.open(case)
            fixture.assertReady(second, expectedReused = true)
            assertSame("B必须复用A的真实Java Engine ${case.name}", firstEngine, second.engine)
            assertEquals("B必须沿用同一非零Engine pointer ${case.name}", firstPtr, second.enginePtr)
            assertNotSame("B必须是新LynxView ${case.name}", firstView, second.view)
            assertNotSame("B必须是新LynxContext ${case.name}", firstContext, requireNotNull(second.context))
            second.row["sameOriginalEngine"] = true
            second.row["sameOriginalEnginePointer"] = true
            second.row["freshViewAndContext"] = true
            if (case.name == "small") {
                // 本测试在B render后没有点击、reload或任何测试端状态写入；warm frame只能来自生产的真实预绘制/提交链路。
                second.row["staticSmallWarmFrameWithoutManualStateMutation"] = true
                assertEquals("静态Small warm页必须有真实cached frame", 1, second.cachedFrameCount.get())
            }
            fixture.persist()
            fixture.destroy(second)
            assertEquals("B结束后不能第三次借用Engine ${case.name}", 0L, enginePtr(firstEngine))

            val third = fixture.open(case)
            fixture.assertReady(third, expectedReused = false)
            val thirdEngine = requireNotNull(third.engine)
            assertNotSame("C必须创建新Java Engine ${case.name}", firstEngine, thirdEngine)
            assertTrue("C真实Engine pointer必须非零 ${case.name}", third.enginePtr != 0L)
            fixture.destroy(third)
            assertEquals("C退出后可保留给D一次 ${case.name}", third.enginePtr, enginePtr(thirdEngine))

            val fourth = fixture.open(case)
            fixture.assertReady(fourth, expectedReused = true)
            assertSame("D必须只复用C的Engine ${case.name}", thirdEngine, fourth.engine)
            assertEquals("D必须沿用C的非零Engine pointer ${case.name}", third.enginePtr, fourth.enginePtr)
            fixture.destroy(fourth)
            assertEquals("D退出后必须释放C/D的Engine ${case.name}", 0L, enginePtr(thirdEngine))
        }
    }

    fun testTwoActiveViewsInSameActivityUseIndependentEnginesAndExactSources() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        val first = fixture.open(case)
        fixture.assertReady(first, expectedReused = false)
        val firstEngine = requireNotNull(first.engine)
        val firstPtr = first.enginePtr

        val second = fixture.open(case)
        try {
            fixture.assertReady(second, expectedReused = false)
            assertSame("必须在同一个Activity中打开第二View", first.hostActivity, second.hostActivity)
            assertNotSame("两个活体View不能共享Java Engine", firstEngine, second.engine)
            assertTrue("两个活体Engine不能共享native pointer", firstPtr != second.enginePtr)
            fixture.assertCurrentReady(first)
            fixture.assertCurrentReady(second)
            assertEquals("第一页Native source必须仍归第一页", first.pageId, first.lastAcceptedSource.get())
            assertEquals("第二页Native source必须归第二页", second.pageId, second.lastAcceptedSource.get())
            second.row["sameActivityIndependentEngines"] = true
            second.row["firstStillCurrentRootReady"] = true
            fixture.persist()
        } finally {
            fixture.destroy(second)
            fixture.destroy(first)
        }
    }

    fun testTrimReleasesIdleEngineAndNextOpenIsFresh() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "large" }
        val first = fixture.open(case)
        fixture.assertReady(first, expectedReused = false)
        val firstEngine = requireNotNull(first.engine)
        val firstPtr = first.enginePtr
        fixture.destroy(first)
        assertEquals("trim前必须确实留有idle Engine", firstPtr, enginePtr(firstEngine))
        onMain { LynxShell.onTrimMemory(10) }
        instrumentation.waitForIdleSync()
        assertEquals("trim必须释放idle Engine wrapper", 0L, enginePtr(firstEngine))

        val next = fixture.open(case)
        try {
            fixture.assertReady(next, expectedReused = false)
            assertNotSame("trim后不能再借已释放Engine", firstEngine, next.engine)
            next.row["freshAfterTrim"] = true
            fixture.persist()
        } finally {
            fixture.destroy(next)
        }
    }

    fun testColdCancellationCannotDonateHalfInitializedEngine() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        val cancelled = fixture.open(case, cancelBeforeFirstContent = true)
        assertTrue("取消页必须真的在首内容回执前销毁", cancelled.destroyed.get())
        assertEquals("取消页不能拿到SDK首屏", 0, cancelled.sdkFirstScreenCount.get())
        assertEquals("取消页不能拿到warm frame", 0, cancelled.cachedFrameCount.get())
        val cancelledEngine = cancelled.engine
        SystemClock.sleep(250)
        assertTrue("已取消页面不能接受迟到Native回执", cancelled.events.isEmpty())

        val next = fixture.open(case)
        try {
            fixture.assertReady(next, expectedReused = false)
            cancelledEngine?.let { assertNotSame("半初始化Engine绝不能被下一页借出", it, next.engine) }
            assertEquals("正常页Native source必须归自己", next.pageId, next.lastAcceptedSource.get())
            next.row["coldCancellationIsolation"] = true
            fixture.persist()
        } finally {
            fixture.destroy(next)
        }
    }

    fun testTenPagesInFivePairsRecordMemoryAndReleaseAfterEveryWarmPage() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        val seenColdEngines = mutableListOf<Any>()
        repeat(5) { pair ->
            val cold = fixture.open(case)
            fixture.assertReady(cold, expectedReused = false)
            val coldEngine = requireNotNull(cold.engine)
            seenColdEngines.forEach { assertNotSame("第${pair + 1}对冷页必须是新Java Engine", it, coldEngine) }
            seenColdEngines += coldEngine
            cold.row["pair"] = pair + 1
            cold.row["memoryPssKbWhileReady"] = Debug.getPss()
            cold.row["memoryJavaUsedBytesWhileReady"] = javaUsedBytes()
            fixture.persist()
            fixture.destroy(cold)
            assertEquals("冷页归还后必须可一次复用", cold.enginePtr, enginePtr(coldEngine))

            val warm = fixture.open(case)
            try {
                fixture.assertReady(warm, expectedReused = true)
                assertSame("同一对B必须复用A Engine", coldEngine, warm.engine)
                assertEquals(cold.enginePtr, warm.enginePtr)
                warm.row["pair"] = pair + 1
                warm.row["memoryPssKbWhileReady"] = Debug.getPss()
                warm.row["memoryJavaUsedBytesWhileReady"] = javaUsedBytes()
                warm.row["sameColdEngine"] = true
                fixture.persist()
            } finally {
                fixture.destroy(warm)
            }
            val after = enginePtr(coldEngine)
            warm.row["enginePointerAfterWarmDestroy"] = after
            warm.row["memoryPssKbAfterWarmDestroy"] = Debug.getPss()
            warm.row["memoryJavaUsedBytesAfterWarmDestroy"] = javaUsedBytes()
            warm.row["memoryObservationOnly"] = true
            fixture.persist()
            assertEquals("每对warm页后必须释放Engine", 0L, after)
        }
    }

    fun testFormerActivityWeakHostDiagnosticAndOptionalHprof() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        val probe = fixture.releaseSecondaryHostForGcProbe(case)
        assertTrue("诊断时必须保留真实idle Engine", probe.enginePointer != 0L)
        var attempts = 0
        while (attempts < 8 && probe.host.get() != null) {
            System.gc()
            System.runFinalization()
            instrumentation.waitForIdleSync()
            SystemClock.sleep(100)
            attempts++
        }
        val row = linkedMapOf<String, Any?>(
            "diagnostic" to "former-host-weak-reference",
            "hostObjectIdentity" to probe.hostIdentity,
            "idleEnginePointer" to probe.enginePointer,
            "gcAttempts" to attempts,
            "formerHostCollectedWithinBoundedGc" to (probe.host.get() == null),
            "gcResultConclusiveForNoLeak" to false,
        )
        if ((instrumentation as InstrumentationTestRunner).arguments.getString("captureHeap") == "true") {
            val file = fixture.captureHeap("former-host.hprof")
            row["heapFileBasename"] = file.name
            row["heapFileSize"] = file.length()
            // 只用于区分 Android 延迟队列与仍存活的 idle Engine；不进入产品加载时序。
            SystemClock.sleep(3000)
            repeat(3) { System.gc(); System.runFinalization(); instrumentation.waitForIdleSync(); SystemClock.sleep(100) }
            val idlePtr = enginePtr(requireNotNull(probe.engine.get()))
            assertTrue("第二dump期间idle Engine必须仍保留", idlePtr != 0L)
            row["idleEnginePointerAfterQueueDrain"] = idlePtr
            row["formerHostCollectedAfterQueueDrain"] = probe.host.get() == null
            val drained = fixture.captureHeap("former-host-after-drain.hprof")
            row["drainedHeapFileBasename"] = drained.name
            row["drainedHeapFileSize"] = drained.length()
            fixture.addDiagnostic(row)
            assertNull("idle Engine 不得通过旧 Renderer 保留已销毁 Activity", probe.host.get())
        }
        fixture.addDiagnostic(row)
    }

    fun testColdBusinessReloadIsRejectedThenCleanColdPairCanReuse() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "async" }
        val reloaded = fixture.open(case)
        fixture.assertReady(reloaded, expectedReused = false)
        val oldEngine = requireNotNull(reloaded.engine)
        val updatesBefore = reloaded.pageUpdates.get()
        onMain {
            reloaded.view.reloadTemplate(TemplateData.fromMap(emptyMap<String, Any>()), TemplateData.fromMap(emptyMap<String, Any>()))
        }
        fixture.awaitPageUpdate(reloaded, updatesBefore)
        reloaded.row["businessReloadObserved"] = true
        fixture.persist()
        fixture.destroy(reloaded)
        assertEquals("冷页业务reload后不得捐出Engine", 0L, enginePtr(oldEngine))

        val rejectedNext = fixture.open(case)
        fixture.assertReady(rejectedNext, expectedReused = false)
        assertNotSame("业务reload后的下一页必须是新Engine", oldEngine, rejectedNext.engine)
        fixture.destroy(rejectedNext)
        onMain { LynxShell.onTrimMemory(10) }

        val coldControl = fixture.open(case)
        fixture.assertReady(coldControl, expectedReused = false)
        val controlEngine = requireNotNull(coldControl.engine)
        fixture.destroy(coldControl)
        val warmControl = fixture.open(case)
        try {
            fixture.assertReady(warmControl, expectedReused = true)
            assertSame("未业务reload的冷页必须仍可一次复用", controlEngine, warmControl.engine)
            warmControl.row["cleanColdControlReused"] = true
            fixture.persist()
        } finally {
            fixture.destroy(warmControl)
        }
        assertEquals("控制组warm退出后也必须释放Engine", 0L, enginePtr(controlEngine))
    }

    private fun withFixture(block: (Fixture) -> Unit) {
        val context = instrumentation.targetContext
        assertEquals("只允许隔离验收App", "com.hugboga.custom.otae2e", context.packageName)
        val description = OtaJson.asObject(
            OtaJson.parse(File(context.filesDir, "bundle-loading-fixture.json").readText()), "BoundedEngineSmokeFixture",
        )
        val manifest = OtaModels.ReleaseManifest.fromJsonMap(
            OtaJson.asObject(description["manifest"], "manifest"), requireStatus = true,
        )
        assertEquals("10030071", manifest.lynxAppId)
        val cases = OtaJson.asArray(description["cases"], "cases").map { raw ->
            val value = OtaJson.asObject(raw, "case")
            Case(
                value["caseName"] as String,
                value["path"] as String,
                value["expectedReadyLabel"] as String,
                OtaJson.asObject(value["expectedReadyPayload"], "expectedReadyPayload"),
            )
        }
        assertEquals(listOf("small", "large", "async"), cases.map(Case::name))
        val async = cases.single { it.name == "async" }
        assertTrue("Async必须保留十个真实外部脚本", numericEquals(async.expectedPayload["moduleCount"], 10))
        assertTrue("Async必须保留固定脚本计算结果", numericEquals(async.expectedPayload["checksum"], 56_430))
        val frozen = mapOf(
            "BundleLoadSmall.lynx.bundle" to (88114L to "bd55248f0883f4492245ecc18309d241eb419e992f4b2bacc00502294809fbe2"),
            "BundleLoadLarge.lynx.bundle" to (3234076L to "3554ab411d9be7828d05029f42bcd77a5bacfaf50b43648865fbfe9e52505fbf"),
            "BundleLoadAsync.lynx.bundle" to (94510L to "374ddaf32e80cdb56a7b9e065d4fa1b3c0239e3da63221715e74ce354596da8c"),
        )
        manifest.bundles.forEach { bundle ->
            val expected = requireNotNull(frozen[bundle.bundlePath])
            assertEquals("固定Bundle size不得漂移", expected.first.toInt(), requireNotNull(bundle.size))
            assertEquals("固定Bundle SHA不得漂移", "sha256:${expected.second}", bundle.bundleSha256)
        }
        val storeRoot = File(context.cacheDir, "bounded-engine-smoke-${UUID.randomUUID()}")
        val store = ContentAddressedOtaStore(storeRoot, allowLocalHTTPForTest = true)
        val scope = ReleaseTransaction.ReleaseScope.fromManifest(manifest)
        store.reserveSidecars(manifest.lynxAppId, manifest.asyncBundleManifest).use {
            store.stageAsyncResources(manifest)
            store.install(ReleaseTransaction.InstallRequest(scope, manifest))
        }
        val launcher = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("lynx_shell.show_native_launcher", true),
        ) as MainActivity
        val frame = FrameLayout(launcher)
        onMain { launcher.setContentView(frame); LynxShell.onTrimMemory(10) }
        val results = File(context.filesDir, "bounded-engine-smoke-results/grouped/$name")
            .also { assertTrue(it.isDirectory || it.mkdirs()) }
        val fixture = Fixture(manifest, cases, store, scope, launcher, frame, results)
        try {
            fixture.installMessageHandler()
            block(fixture)
        } finally {
            try { fixture.close() } finally {
                onMain { LynxShell.onTrimMemory(10); launcher.finish() }
                storeRoot.deleteRecursively()
            }
        }
    }

    private inner class Fixture(
        private val manifest: OtaModels.ReleaseManifest,
        val cases: List<Case>,
        private val store: ContentAddressedOtaStore,
        private val scope: ReleaseTransaction.ReleaseScope,
        private val launcher: MainActivity,
        private val frame: FrameLayout,
        private val results: File,
    ) {
        private val pages = ConcurrentHashMap<String, Page>()
        private val rows = Collections.synchronizedList(mutableListOf<MutableMap<String, Any?>>())
        private val writeLock = Any()

        fun installMessageHandler() = onMain {
            LynxRouter.setMessageHandler { message ->
                val page = pages[message.source.pageId]
                val accepted = page != null && !page.destroyed.get() &&
                    message.eventName == READY_EVENT &&
                    message.payload["caseName"] == page.case.name &&
                    numericEquals(message.payload["moduleCount"], page.case.expectedPayload["moduleCount"]) &&
                    numericEquals(message.payload["payloadLength"], page.case.expectedPayload["payloadLength"]) &&
                    numericEquals(message.payload["checksum"], page.case.expectedPayload["checksum"])
                page?.let {
                    val event = Event(message.source.pageId, message.eventName, message.payload, accepted)
                    it.events += event
                    if (accepted) it.lastAcceptedSource.set(message.source.pageId)
                    it.row["lastActualNativeEvent"] = event.toRow()
                    it.row["actualNativeEventCount"] = it.events.size
                    persist()
                }
                LynxRouterMessageReply(accepted, "固定Bundle与exact新页source核对")
            }
        }

        fun open(case: Case, separateActivity: Boolean = false, cancelBeforeFirstContent: Boolean = false): Page {
            val host = if (separateActivity) {
                instrumentation.startActivitySync(
                    Intent(instrumentation.targetContext, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
                        .putExtra("lynx_shell.show_native_launcher", true),
                ) as MainActivity
            } else launcher
            val hostFrame = if (separateActivity) FrameLayout(host).also { onMain { host.setContentView(it) } } else frame
            val lease = requireNotNull(store.acquireCurrentBundleLease(scope, case.bundlePath))
            val url = "assets://bundles/${case.bundlePath}"
            val provider = ShellTemplateProvider(host, preparedUrl = url, preparedFile = lease.file)
            val pageId = "bounded-engine-${case.name}-${UUID.randomUUID()}"
            val row = Collections.synchronizedMap(linkedMapOf<String, Any?>(
                "testMethod" to name,
                "caseName" to case.name,
                "pageId" to pageId,
                "bundlePath" to case.bundlePath,
                "bundleSha256" to lease.bundle.bundleSha256,
                "bundleSize" to lease.file.length(),
                "hostActivityObjectIdentity" to System.identityHashCode(host),
                "separateActivity" to separateActivity,
            ))
            val page = Page(pageId, case, provider, lease, row, host, hostFrame, separateActivity)
            pages[pageId] = page
            rows += row
            val pageInfo = LynxRouterPageInfo(pageId, pageId, case.bundlePath, "page")
            onMain {
                page.factoryStartNs.set(SystemClock.elapsedRealtimeNanos())
                val client = object : LynxViewClient() {
                    override fun onFirstScreen() {
                        if (!page.destroyed.get()) {
                            page.sdkFirstScreenCount.incrementAndGet()
                            page.frameSource.compareAndSet(null, "SDK_FIRST_SCREEN")
                            page.firstContent.countDown()
                        }
                    }
                    override fun onPageUpdate() { page.pageUpdates.incrementAndGet() }
                    override fun onReceivedError(error: LynxError) {
                        if (!page.destroyed.get() && error.isFatal) {
                            page.fatal.set(error.toString())
                            page.firstContent.countDown()
                        }
                    }
                }
                page.createdView = LynxContainerFactory.create(
                    activity = host,
                    request = LynxPageRequest(bundleUrl = url, lynxAppId = manifest.lynxAppId,
                        bundleName = case.bundlePath, showToolbar = false),
                    templateProvider = provider,
                    lynxViewClient = client,
                    sidecarResources = lease.sidecars,
                    bundleMetadata = mapOf(
                        "lynxAppId" to manifest.lynxAppId,
                        "bundleName" to case.bundlePath,
                        "releaseId" to manifest.releaseId,
                        "source" to "ota_current",
                        "sha256" to lease.bundle.bundleSha256,
                        "userIdentityEpoch" to 0L,
                    ),
                    preparedBundle = PreparedActivityBundle(
                        lynxAppId = manifest.lynxAppId,
                        bundleName = case.bundlePath,
                        file = lease.file,
                        releaseId = manifest.releaseId,
                        sha256 = lease.bundle.bundleSha256,
                        source = "ota_current",
                        userIdentityEpoch = 0L,
                        sidecarResources = lease.sidecars,
                    ),
                    pageInfo = pageInfo,
                    onCachedFrame = { source ->
                        if (!page.destroyed.get()) {
                            page.cachedFrameCount.incrementAndGet()
                            page.frameSource.compareAndSet(null, source.name)
                            page.firstContent.countDown()
                        }
                    },
                )
                ShellMessageHub.register(pageInfo, host, page.view)
                hostFrame.addView(page.view, FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
                ))
                page.context = page.view.lynxContext
                page.renderStartNs.set(SystemClock.elapsedRealtimeNanos())
                page.view.renderTemplateUrl(url, TemplateData.fromMap(emptyMap<String, Any>()))
                captureIdentity(page)
                if (cancelBeforeFirstContent) {
                    assertEquals("取消必须早于真实首内容回执", 1L, page.firstContent.count)
                    page.destroyed.set(true)
                    destroySdkViewOnMain(page)
                }
            }
            if (cancelBeforeFirstContent) finishResources(page)
            return page
        }

        fun assertReady(page: Page, expectedReused: Boolean) {
            assertTrue("真实首内容回执未到达 ${page.case.name}", page.firstContent.await(30, TimeUnit.SECONDS))
            assertNull("SDK fatal ${page.case.name}", page.fatal.get())
            val event = awaitReadyEvent(page)
            assertEquals("Native source必须归当前页", page.pageId, event.source)
            assertTrue("Native回执必须被当前页接受", event.accepted)
            assertEquals(page.case.name, event.payload["caseName"])
            page.case.expectedPayload.forEach { (key, value) ->
                val actual = event.payload[key]
                if (value is Number || actual is Number) assertTrue("Native numeric payload $key", numericEquals(actual, value))
                else assertEquals("Native payload $key", value, actual)
            }
            assertCurrentReady(page)
            onMain { captureIdentity(page) }
            assertEquals("生产Group借用状态必须符合预期", expectedReused, page.reused)
            assertNotNull("必须观测官方LynxEngine", page.engine)
            assertTrue("真实Engine pointer必须非零", page.enginePtr != 0L)
            assertTrue("真实native render shell必须非零", page.renderPointer != 0L)
            assertNotNull("必须观测parsed TemplateBundle", page.template)
            assertTrue("真实TemplateBundle pointer必须非零", page.templatePointer != 0L)
            if (expectedReused) {
                val expectedFrame = if (Build.VERSION.SDK_INT >= 29 && page.view.isHardwareAccelerated)
                    LynxFirstFrameSource.CACHED_FRAME_COMMITTED.name else LynxFirstFrameSource.CACHED_DRAW_CYCLE.name
                assertEquals("warm只能由真实draw/commit回执", expectedFrame, page.frameSource.get())
                assertEquals("warm不能伪造SDK onFirstScreen", 0, page.sdkFirstScreenCount.get())
                assertEquals("warm cached frame必须恰好一次", 1, page.cachedFrameCount.get())
            } else {
                assertEquals("cold必须由SDK onFirstScreen回执", "SDK_FIRST_SCREEN", page.frameSource.get())
                assertEquals("cold SDK首屏必须恰好一次", 1, page.sdkFirstScreenCount.get())
                assertEquals("cold不能借用warm frame hook", 0, page.cachedFrameCount.get())
            }
            page.row["templateObjectIdentity"] = System.identityHashCode(requireNotNull(page.template))
            page.row["templateNativePointer"] = page.templatePointer
            page.row["engineObjectIdentity"] = System.identityHashCode(requireNotNull(page.engine))
            page.row["engineNativePointer"] = page.enginePtr
            page.row["nativeRenderPointer"] = page.renderPointer
            page.row["groupLeaseReused"] = page.reused
            page.row["frameSource"] = page.frameSource.get()
            page.row["sdkFirstScreenCount"] = page.sdkFirstScreenCount.get()
            page.row["cachedFrameCount"] = page.cachedFrameCount.get()
            page.row["renderStartElapsedRealtimeNs"] = page.renderStartNs.get()
            persist()
        }

        fun assertCurrentReady(page: Page) {
            val deadline = SystemClock.elapsedRealtime() + 30_000L
            var text = ""
            var layout: String? = null
            var readyAndLaidOut = false
            while (SystemClock.elapsedRealtime() < deadline) {
                onMain {
                    val node = currentUi(page.view, READY_SELECTOR)
                    if (node == null) {
                        text = ""
                        layout = null
                        readyAndLaidOut = false
                    } else {
                        text = node.accessibilityLabel?.toString().orEmpty()
                        layout = (node as? IUIText)?.textLayout?.text?.toString()
                        page.row["currentRootReadyIdentity"] = System.identityHashCode(node)
                        page.row["currentRootReadyAccessibilityLabel"] = text
                        page.row["currentRootReadyLayoutText"] = layout
                        page.row["currentRootReadyRect"] = node.rectToWindow.toShortString()
                        readyAndLaidOut = text == page.case.readyLabel && node.latestSize.x > 0 && node.latestSize.y > 0 &&
                            page.view.isAttachedToWindow && page.view.width > 0 && page.view.height > 0
                    }
                }
                if (readyAndLaidOut || page.fatal.get() != null) break
                SystemClock.sleep(30)
            }
            assertNull("当前Root等待READY期间SDK fatal", page.fatal.get())
            assertEquals("当前Root的唯一READY必须是固定fixture结果", page.case.readyLabel, text)
            assertTrue("当前Root READY必须已layout并且宿主attach", readyAndLaidOut)
            val validatedNs = SystemClock.elapsedRealtimeNanos()
            page.readyValidatedNs.compareAndSet(0L, validatedNs)
            page.row["currentRootReadyValidatedElapsedRealtimeNs"] = page.readyValidatedNs.get()
            page.row["factoryToCurrentRootReadyNs"] = page.readyValidatedNs.get() - page.factoryStartNs.get()
            page.row["renderToCurrentRootReadyNs"] = page.readyValidatedNs.get() - page.renderStartNs.get()
            page.row["currentRootReadyTimingIncludesPollingAndScheduling"] = true
            page.row["currentRootReadyTimingIsNotP95"] = true
            persist()
        }

        fun awaitPageUpdate(page: Page, before: Int) {
            val deadline = SystemClock.elapsedRealtime() + 30_000L
            while (SystemClock.elapsedRealtime() < deadline && page.pageUpdates.get() <= before) {
                assertNull("业务reload等待期间SDK fatal", page.fatal.get())
                SystemClock.sleep(30)
            }
            assertTrue("业务reload必须触发SDK onPageUpdate", page.pageUpdates.get() > before)
        }

        fun destroy(page: Page) {
            if (!page.destroyed.compareAndSet(false, true)) return
            try {
                onMain { destroySdkViewOnMain(page) }
            } finally {
                finishResources(page)
            }
            instrumentation.waitForIdleSync()
        }

        fun releaseSecondaryHostForGcProbe(case: Case): HostProbe {
            val page = open(case, separateActivity = true)
            assertReady(page, expectedReused = false)
            val host = WeakReference(page.hostActivity)
            val hostIdentity = System.identityHashCode(page.hostActivity)
            val ptr = page.enginePtr
            destroy(page)
            assertFalse("诊断完成后不得保留旧Page", pages.containsKey(page.pageId))
            return HostProbe(host, hostIdentity, ptr, WeakReference(requireNotNull(page.engine)))
        }

        fun captureHeap(basename: String): File {
            val file = File(results, basename)
            Debug.dumpHprofData(file.absolutePath)
            assertTrue("请求的HPROF必须实际落盘", file.isFile && file.length() > 0L)
            return file
        }

        fun addDiagnostic(row: MutableMap<String, Any?>) { rows += row; persist() }

        fun persist() = synchronized(writeLock) {
            val snapshot = synchronized(rows) { rows.toList() }.map { row -> synchronized(row) { LinkedHashMap(row) } }
            File(results, "results.json").writeText(OtaJson.stringify(snapshot))
        }

        fun close() {
            try { pages.values.toList().forEach(::destroy) } finally { onMain { LynxRouter.setMessageHandler(null) } }
        }

        private fun awaitReadyEvent(page: Page): Event {
            val deadline = SystemClock.elapsedRealtime() + 30_000L
            while (SystemClock.elapsedRealtime() < deadline) {
                assertNull("Native等待期间SDK fatal", page.fatal.get())
                page.events.toList().firstOrNull { it.name == READY_EVENT && it.accepted }?.let { return it }
                SystemClock.sleep(30)
            }
            page.row["observedNativeEvents"] = page.events.map(Event::toRow)
            persist()
            fail("真实Native READY未到达 page=${page.pageId}")
            error("unreachable")
        }

        private fun captureIdentity(page: Page) {
            val render = readField(page.view, "mLynxTemplateRender", LynxView::class.java)
            page.engine = readNullableField(render, "mLynxEngineRef")
            page.enginePtr = page.engine?.let(::enginePtr) ?: 0L
            page.renderPointer = render.javaClass.getDeclaredField("mNativePtr").apply { isAccessible = true }.getLong(render)
            page.template = groupFor(page.view).templateBundleNonBlocking
            page.templatePointer = page.template?.nativePtr ?: 0L
            page.reused = isGroupReused(page.view)
        }

        private fun destroySdkViewOnMain(page: Page) {
            ShellMessageHub.unregister(page.pageId)
            page.createdView?.let { page.hostFrame.removeView(it); destroyView.invoke(LynxShell, it) }
            if (page.ownsActivity) page.hostActivity.finish()
        }

        private fun finishResources(page: Page) {
            page.provider.close()
            page.lease.close()
            pages.remove(page.pageId, page)
            page.row["pageLeaseClosed"] = isLeaseClosed(page.lease)
            page.row["destroyPath"] = "LynxShell.destroyView"
            persist()
        }
    }

    private class Page(
        val pageId: String,
        val case: Case,
        val provider: ShellTemplateProvider,
        val lease: ReleaseTransaction.BundleLease,
        val row: MutableMap<String, Any?>,
        val hostActivity: MainActivity,
        val hostFrame: FrameLayout,
        val ownsActivity: Boolean,
    ) {
        var createdView: LynxView? = null
        val view: LynxView get() = requireNotNull(createdView)
        var context: Any? = null
        var engine: Any? = null
        var enginePtr = 0L
        var renderPointer = 0L
        var template: TemplateBundle? = null
        var templatePointer = 0L
        var reused = false
        val firstContent = CountDownLatch(1)
        val sdkFirstScreenCount = AtomicInteger()
        val cachedFrameCount = AtomicInteger()
        val frameSource = AtomicReference<String?>()
        val factoryStartNs = AtomicLong()
        val renderStartNs = AtomicLong()
        val readyValidatedNs = AtomicLong()
        val pageUpdates = AtomicInteger()
        val fatal = AtomicReference<String?>()
        val destroyed = AtomicBoolean(false)
        val events = ConcurrentLinkedQueue<Event>()
        val lastAcceptedSource = AtomicReference<String?>()
    }

    private data class Case(
        val name: String,
        val bundlePath: String,
        val readyLabel: String,
        val expectedPayload: Map<String, Any?>,
    )

    private data class Event(
        val source: String,
        val name: String,
        val payload: Map<String, Any?>,
        val accepted: Boolean,
    ) {
        fun toRow(): Map<String, Any?> = mapOf(
            "source" to source, "eventName" to name, "payload" to payload, "accepted" to accepted,
        )
    }

    private data class HostProbe(val host: WeakReference<MainActivity>, val hostIdentity: Int, val enginePointer: Long,
        val engine: WeakReference<Any>)

    private fun currentUi(view: LynxView, selector: String): LynxBaseUI? {
        fun collect(node: LynxBaseUI?): List<LynxBaseUI> = if (node == null) emptyList() else listOf(node) + node.children.flatMap(::collect)
        val matches = collect(view.lynxUIRoot).filter { it.idSelector == selector }
        assertTrue("当前Root不能有重复selector=$selector count=${matches.size}", matches.size <= 1)
        return matches.singleOrNull()
    }

    private fun groupFor(view: LynxView): ILynxViewGroup {
        val cache = Class.forName("com.example.lynxshell.container.LynxTemplateGroupCache")
        val instance = cache.getField("INSTANCE").get(null)
        val registrations = cache.getDeclaredField("registrations").apply { isAccessible = true }.get(instance) as Map<*, *>
        val registration = requireNotNull(registrations[view])
        val lease = readField(registration, "lease")
        val slot = lease.javaClass.getMethod("getValue").invoke(lease)
        return slot.javaClass.getMethod("getGroup").invoke(slot) as ILynxViewGroup
    }

    private fun isGroupReused(view: LynxView): Boolean {
        val cache = Class.forName("com.example.lynxshell.container.LynxTemplateGroupCache")
        val instance = cache.getField("INSTANCE").get(null)
        return cache.getDeclaredMethod("isReused", LynxView::class.java).invoke(instance, view) as Boolean
    }

    private fun readField(value: Any, name: String, owner: Class<*> = value.javaClass): Any =
        requireNotNull(owner.getDeclaredField(name).apply { isAccessible = true }.get(value))

    private fun readNullableField(value: Any, name: String): Any? =
        value.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(value)

    private fun enginePtr(engine: Any): Long = engine.javaClass.getMethod("getNativePtr").invoke(engine) as Long

    private fun numericEquals(left: Any?, right: Any?): Boolean =
        left is Number && right is Number && left.toLong() == right.toLong()

    private fun isLeaseClosed(lease: ReleaseTransaction.BundleLease): Boolean =
        (readField(lease, "closed") as AtomicBoolean).get()

    private fun javaUsedBytes(): Long = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }

    private val destroyView by lazy {
        LynxShell::class.java.declaredMethods.single {
            it.name.startsWith("destroyView") && it.parameterTypes.contentEquals(arrayOf(LynxView::class.java))
        }.apply { isAccessible = true }
    }

    private fun onMain(block: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync { try { block() } catch (error: Throwable) { failure.set(error) } }
        failure.get()?.let { throw it }
    }

    private companion object {
        const val READY_EVENT = "bundle-loading-bench.ready"
        const val READY_SELECTOR = "bundle-bench-ready"
    }
}
