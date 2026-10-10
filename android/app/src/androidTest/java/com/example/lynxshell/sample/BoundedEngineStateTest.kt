package com.example.lynxshell.sample

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.test.InstrumentationTestRunner
import android.view.MotionEvent
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
import com.example.lynxshell.transition.LynxElementResolver
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateData
import com.lynx.tasm.TemplateBundle
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.lynx.tasm.behavior.ui.text.IUIText
import com.lynx.tasm.group.ILynxViewGroup
import com.lynx.tasm.resourceprovider.LynxResourceCallback
import com.lynx.tasm.resourceprovider.LynxResourceRequest
import com.lynx.tasm.resourceprovider.LynxResourceResponse
import com.lynx.tasm.resourceprovider.template.LynxTemplateResourceFetcher
import com.lynx.tasm.resourceprovider.template.TemplateProviderResult
import com.ota.android.sdk.ContentAddressedOtaStore
import com.ota.android.sdk.OtaJson
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.OtaSidecarModels
import com.ota.android.sdk.ReleaseTransaction
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Collections
import java.util.IdentityHashMap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** 每个真实Engine最多借给一个新View；冷SDK首屏与暖真实Frame收据分别验收。 */
class BoundedEngineStateTest : InstrumentationTestCase() {
    fun testTenPagesInFiveEnginePairsResetStateAndUseCurrentRootGeometry() = withFixture { fixture ->
        val priorEngines = mutableListOf<Any>()
        repeat(5) { pair ->
            val first = fixture.open("state", "state-A-pair-$pair", withOldOnly = true)
            fixture.assertInitialReady(first, expectedReused = false)
            priorEngines.forEach { assertNotSame("下一对必须创建新的真实Engine对象", it, first.engine) }
            priorEngines += requireNotNull(first.engine)
            val firstReadyHeight = fixture.assertResolverMatchesCurrentRoot(first).height()
            fixture.assertSingleInitialEffect(first)
            val cursor = first.events.size
            tap(first.view, "engine-reuse-increment")
            fixture.assertReady(first, fixture.awaitEvent(first, READY_EVENT, cursor), counter = 1)
            fixture.assertSingleCounterEffect(first)
            fixture.destroy(first)
            assertTrue("A的真实页面lease必须关闭", isLeaseClosed(first.lease))
            assertEquals("A归还后真实Engine必须留存以供一次复用", first.enginePtr, enginePtr(requireNotNull(first.engine)))

            val second = fixture.open("state", "state-B-pair-$pair-" + "fresh-long-marker-".repeat(12), withOldOnly = false)
            try {
                fixture.assertInitialReady(second, expectedReused = true)
                fixture.assertSameEngineAndFreshContext(first, second)
                val secondRect = fixture.assertResolverMatchesCurrentRoot(second)
                assertTrue("长B marker必须改变当前READY换行几何", secondRect.height() > firstReadyHeight)
                fixture.assertSingleInitialEffect(second)
                val secondCursor = second.events.size
                tap(second.view, "engine-reuse-increment")
                fixture.assertReady(second, fixture.awaitEvent(second, READY_EVENT, secondCursor), counter = 1)
                fixture.assertSingleCounterEffect(second)
                if (pair == 0) fixture.saveAssertionScreenshot(second, "pair-0-B-counter1.png")
            } finally { fixture.destroy(second) }
            fixture.assertReleasedAfterWarmPage(second)
        }
    }

    fun testOnceReusedEngineLazyRequestUsesCurrentLeaseAndRealBundleBytes() = withFixture { fixture ->
        val first = fixture.open("lazy", "lazy-A", withOldOnly = true)
        fixture.assertInitialReady(first, expectedReused = false)
        fixture.assertSingleInitialEffect(first)
        fixture.observeRealFetchers(first)
        assertEquals("A初始未点击Lazy，不能发生Native Lazy请求", 0, fixture.lazyFetches.get())
        fixture.destroy(first)
        assertTrue("A已结束后不能依赖未关闭的页面lease", isLeaseClosed(first.lease))

        val second = fixture.open("lazy", "lazy-B", withOldOnly = false)
        try {
            fixture.assertInitialReady(second, expectedReused = true)
            fixture.assertSameEngineAndFreshContext(first, second)
            fixture.assertResolverMatchesCurrentRoot(second)
            fixture.assertSingleInitialEffect(second)
            fixture.observeRealFetchers(second)
            assertEquals("warm B首次点击前真实Lazy请求必须为0", 0, fixture.lazyFetches.get())
            val cursor = second.events.size
            tap(second.view, "engine-reuse-load-lazy")
            val mounted = fixture.awaitEvent(second, LAZY_EVENT, cursor)
            fixture.assertPayload(second, mounted, counter = 0, phase = "lazy-mounted")
            assertEquals("必须由真实独立组件返回", "EngineReuseLazyPanel", mounted.payload["component"])
            assertEquals("mounted", mounted.payload["lazyStatus"])
            awaitLabel(second, "engine-reuse-lazy-ready",
                "engine-reuse:lazy-mounted:page=${second.pageId}:marker=${second.marker}:mount=1")
            assertEquals("一个首次Lazy加载必须经过一次真实Native fetch", 1, fixture.lazyFetches.get())
            assertEquals("原delegate交付SDK的真实binary必须有固定SHA", fixture.lazySha, fixture.lazyResponseSha.get())
            assertEquals("原delegate交付SDK的真实binary大小必须匹配", fixture.lazySize, fixture.lazyResponseSize.get())
            second.row["lazyFetchCountBeforeTap"] = 0
            second.row["lazyFetchCountAfterTap"] = fixture.lazyFetches.get()
            second.row["lazyResponseSha256"] = fixture.lazyResponseSha.get()
            second.row["lazyResponseSize"] = fixture.lazyResponseSize.get()
            second.row["lazyNativePayload"] = mounted.payload
            fixture.persist()
            fixture.saveAssertionScreenshot(second, "lazy-B-mounted.png")
        } finally { fixture.destroy(second) }
        fixture.assertReleasedAfterWarmPage(second)
    }

    private fun withFixture(block: (Fixture) -> Unit) {
        val context = instrumentation.targetContext
        assertEquals("只允许隔离验收App", "com.hugboga.custom.otae2e", context.packageName)
        val label = (instrumentation as InstrumentationTestRunner).arguments.getString("runLabel")
            ?: error("必须提供runLabel=baseline或grouped")
        require(label in setOf("baseline", "grouped"))
        val description = OtaJson.asObject(
            OtaJson.parse(File(context.filesDir, "engine-reuse-fixture.json").readText()), "EngineStateFixture",
        )
        val manifest = OtaModels.ReleaseManifest.fromJsonMap(
            OtaJson.asObject(description["manifest"], "manifest"), requireStatus = true,
        )
        val cases = OtaJson.asArray(description["cases"], "cases").map { raw ->
            val value = OtaJson.asObject(raw, "case")
            value["caseName"] as String to value
        }.toMap()
        assertEquals(setOf("state", "lazy"), cases.keys)
        val lazyCase = requireNotNull(cases["lazy"])
        val lazyResources = OtaJson.asArray(lazyCase["asyncResources"], "asyncResources")
        val lazyResource = OtaJson.asObject(lazyResources.single(), "lazyResource")
        assertEquals("lazy-bundle/EngineReuseLazyPanel.lynx.bundle", lazyResource["path"])
        val lazyUrl = lazyResource["url"] as String
        assertEquals("http://127.0.0.1:18782/lazy-bundle/EngineReuseLazyPanel.lynx.bundle", lazyUrl)
        val lazySha = "sha256:" + (lazyResource["sha256"] as String).removePrefix("sha256:")
        val lazySize = (lazyResource["size"] as Number).toInt()
        for (artifact in manifest.bundles) {
            val metadata = cases.values.single { it["path"] == artifact.bundlePath }
            assertEquals((metadata["size"] as Number).toInt(), requireNotNull(artifact.size))
            assertEquals("sha256:" + (metadata["sha256"] as String).removePrefix("sha256:"), artifact.bundleSha256)
        }
        val storeRoot = File(context.cacheDir, "bounded-engine-fixture-${UUID.randomUUID()}")
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
        val results = File(context.filesDir, "bounded-engine-state-results/$label/$name")
            .also { assertTrue(it.isDirectory || it.mkdirs()) }
        val fixture = Fixture(manifest, cases, store, scope, launcher, frame, results, label, lazyUrl, lazySha, lazySize)
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
        private val cases: Map<String, Map<String, Any?>>,
        private val store: ContentAddressedOtaStore,
        private val scope: ReleaseTransaction.ReleaseScope,
        private val launcher: MainActivity,
        private val frame: FrameLayout,
        private val results: File,
        private val label: String,
        private val lazyUrl: String,
        val lazySha: String,
        val lazySize: Int,
    ) {
        private val pages = ConcurrentHashMap<String, Page>()
        private val rows = Collections.synchronizedList(mutableListOf<MutableMap<String, Any?>>())
        private val resultWriteLock = Any()
        private val observedHelpers = IdentityHashMap<Any, Boolean>()
        private val observedDelegates = IdentityHashMap<LynxTemplateResourceFetcher, FetchObserver>()
        val lazyFetches = AtomicInteger()
        val lazyResponseSha = AtomicReference<String?>()
        val lazyResponseSize = AtomicInteger()

        fun installMessageHandler() = onMain {
            LynxRouter.setMessageHandler { message ->
                val page = pages[message.source.pageId]
                val accepted = page != null && !page.destroyed.get() &&
                    message.eventName in setOf(READY_EVENT, LAZY_EVENT) &&
                    message.payload["fixture"] == FIXTURE_MARKER &&
                    message.payload["caseName"] == page.caseName &&
                    message.payload["pageId"] == page.pageId &&
                    message.payload["marker"] == page.marker &&
                    message.payload["globalMarker"] == "global-${page.marker}"
                page?.let {
                    val observed = Event(message.source.pageId, message.eventName, message.payload, accepted)
                    it.events.add(observed)
                    it.row["lastActualNativeEvent"] = observed.toRow()
                    it.row["actualNativeEventCount"] = it.events.size
                    it.row["sdkFirstScreenCountAtNativeEvent"] = it.sdkFirstScreenCount.get()
                    it.row["frameSourceAtNativeEvent"] = it.frameSource.get()
                    persist()
                    record("actual Native event=${message.eventName} source=${message.source.pageId} accepted=$accepted payload=${OtaJson.stringify(message.payload)}")
                }
                LynxRouterMessageReply(accepted, "Engine探针真实source与marker核对")
            }
        }

        fun open(caseName: String, marker: String, withOldOnly: Boolean): Page {
            val metadata = requireNotNull(cases[caseName])
            val path = metadata["path"] as String
            val lease = requireNotNull(store.acquireCurrentBundleLease(scope, path))
            if (caseName == "lazy") {
                val entry = requireNotNull(lease.sidecars).entries.single()
                assertEquals("实际Store sidecar必须为bundle，不能用十个JS替代", OtaSidecarModels.AsyncKind.BUNDLE, entry.kind)
                assertEquals("/lazy-bundle/EngineReuseLazyPanel.lynx.bundle", entry.requestKey)
                assertEquals(lazySha, entry.expectedSha256)
                assertEquals(lazySize, requireNotNull(entry.expectedSize))
            }
            val url = "assets://bundles/$path"
            val provider = ShellTemplateProvider(launcher, preparedUrl = url, preparedFile = lease.file)
            val pageId = "engine-state-$caseName-${UUID.randomUUID()}"
            val initData = linkedMapOf<String, Any>("marker" to marker)
            val globalProps = linkedMapOf<String, Any>("marker" to "global-$marker", "probePageId" to pageId)
            if (withOldOnly) {
                initData["oldOnly"] = "old-init-$marker"
                globalProps["oldOnly"] = "old-global-$marker"
            }
            val row = Collections.synchronizedMap(linkedMapOf<String, Any?>(
                "testMethod" to name, "runLabel" to label, "caseName" to caseName,
                "pageId" to pageId, "marker" to marker, "withOldOnly" to withOldOnly,
                "lynxAppId" to manifest.lynxAppId, "releaseId" to manifest.releaseId,
                "bundlePath" to path, "bundleSha256" to lease.bundle.bundleSha256,
            ))
            val page = Page(pageId, caseName, marker, withOldOnly, provider, lease, row)
            pages[pageId] = page
            rows += row
            val info = LynxRouterPageInfo(pageId, pageId, path, "page")
            onMain {
                val client = object : LynxViewClient() {
                    override fun onFirstScreen() {
                        if (!page.destroyed.get()) {
                            page.sdkFirstScreenCount.incrementAndGet()
                            page.sdkFirstScreenNs.compareAndSet(0L, SystemClock.elapsedRealtimeNanos())
                            page.firstFrameNs.compareAndSet(0L, SystemClock.elapsedRealtimeNanos())
                            page.frameSource.compareAndSet(null, "SDK_FIRST_SCREEN")
                            page.firstScreen.countDown()
                        }
                    }
                    override fun onPageStart(url: String?) { page.sdkCallbacks.add("pageStart") }
                    override fun onPageUpdate() { page.sdkCallbacks.add("pageUpdate") }
                    override fun onDataUpdated() { page.sdkCallbacks.add("dataUpdated") }
                    override fun onUpdateDataWithoutChange() { page.sdkCallbacks.add("dataWithoutChange") }
                    override fun onLoadSuccess() { page.sdkCallbacks.add("loadSuccess") }
                    override fun onRuntimeReady() { page.sdkCallbacks.add("runtimeReady") }
                    override fun onReceivedError(error: LynxError) {
                        if (!page.destroyed.get() && error.isFatal) {
                            page.fatal.set(error.toString())
                            page.firstScreen.countDown()
                        }
                    }
                }
                page.createdView = LynxContainerFactory.create(
                    activity = launcher,
                    request = LynxPageRequest(bundleUrl = url, lynxAppId = manifest.lynxAppId,
                        bundleName = path, showToolbar = false,
                        initDataJson = OtaJson.stringify(initData), globalPropsJson = OtaJson.stringify(globalProps)),
                    templateProvider = provider, lynxViewClient = client, sidecarResources = lease.sidecars,
                    bundleMetadata = mapOf("lynxAppId" to manifest.lynxAppId, "bundleName" to path,
                        "releaseId" to manifest.releaseId, "source" to "ota_current",
                        "sha256" to lease.bundle.bundleSha256, "userIdentityEpoch" to 0L),
                    preparedBundle = PreparedActivityBundle(lynxAppId = manifest.lynxAppId, bundleName = path,
                        file = lease.file, releaseId = manifest.releaseId, sha256 = lease.bundle.bundleSha256,
                        source = "ota_current", userIdentityEpoch = 0L, sidecarResources = lease.sidecars),
                    pageInfo = info,
                    onCachedFrame = { source ->
                        if (!page.destroyed.get()) {
                            page.cachedFrameCount.incrementAndGet()
                            page.firstFrameNs.compareAndSet(0L, SystemClock.elapsedRealtimeNanos())
                            page.frameSource.compareAndSet(null, source.name)
                            page.firstScreen.countDown()
                        }
                    },
                )
                ShellMessageHub.register(info, launcher, page.view)
                assertEquals(pageId, ShellMessageHub.pageIdFor(launcher))
                frame.addView(page.view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                page.context = page.view.lynxContext
                page.renderStartNs = SystemClock.elapsedRealtimeNanos()
                page.row["renderStartElapsedRealtimeNs"] = page.renderStartNs
                page.view.renderTemplateUrl(url, TemplateData.fromMap(initData))
            }
            return page
        }

        fun assertInitialReady(page: Page, expectedReused: Boolean) {
            assertTrue("冷SDK首屏或暖真实Frame收据未到达", page.firstScreen.await(30, TimeUnit.SECONDS))
            assertNull("SDK fatal", page.fatal.get())
            assertReady(page, awaitEvent(page, READY_EVENT, 0), counter = 0)
            onMain {
                val render = readField(page.view, "mLynxTemplateRender", LynxView::class.java)
                page.engine = readNullableField(render, "mLynxEngineRef")
                page.reusedIdentity = isGroupReused(page.view)
                page.template = requireNotNull(groupFor(page.view).templateBundleNonBlocking)
                page.templatePtr = requireNotNull(page.template).nativePtr
                page.shellPtr = render.javaClass.getDeclaredField("mNativePtr").apply { isAccessible = true }.getLong(render)
                assertNotNull("真实Engine缓存必须观察到官方LynxEngine对象", page.engine)
                page.enginePtr = enginePtr(requireNotNull(page.engine))
                assertTrue("真实Engine wrapper nativePtr必须非零", page.enginePtr != 0L)
                assertTrue("当前native shell必须非零", page.shellPtr != 0L)
                assertTrue("真实parsedTemplate nativePtr必须非零", page.templatePtr != 0L)
                page.row["templateObjectIdentity"] = System.identityHashCode(requireNotNull(page.template))
                page.row["templateNativePtr"] = page.templatePtr
                page.row["nativeShellPtr"] = page.shellPtr
                page.row["engineObjectIdentity"] = System.identityHashCode(requireNotNull(page.engine))
                page.row["engineNativePtr"] = page.enginePtr
                page.row["cachedEnginePresent"] = true
                page.context = page.view.lynxContext
                page.row["lynxContextObjectIdentity"] = System.identityHashCode(requireNotNull(page.context))
            }
            page.row["engineReused"] = page.reusedIdentity
            page.row["deviceApi"] = Build.VERSION.SDK_INT
            page.row["hardwareAccelerated"] = page.view.isHardwareAccelerated
            page.row["actualFirstFrameSource"] = page.frameSource.get()
            page.row["sdkFirstScreenCount"] = page.sdkFirstScreenCount.get()
            page.row["cachedFrameCount"] = page.cachedFrameCount.get()
            page.row["sdkCallbacks"] = page.sdkCallbacks.toList()
            page.row["actualFirstFrameElapsedRealtimeNs"] = page.firstFrameNs.get()
            page.row["renderToActualFirstFrameNs"] = page.firstFrameNs.get() - page.renderStartNs
            page.row["sdkFirstScreen"] = page.sdkFirstScreenCount.get() > 0
            page.row["sdkFirstScreenElapsedRealtimeNs"] = page.sdkFirstScreenNs.get().takeIf { it != 0L }
            persist()
            assertEquals("实际Registration复用来源必须符合预期", expectedReused, page.reusedIdentity)
            if (expectedReused) {
                val source = if (Build.VERSION.SDK_INT >= 29 && page.view.isHardwareAccelerated)
                    LynxFirstFrameSource.CACHED_FRAME_COMMITTED else LynxFirstFrameSource.CACHED_DRAW_CYCLE
                assertEquals("warm必须由真实draw/commit交付typed收据", source.name, page.frameSource.get())
                assertEquals("warm不能伪造SDK onFirstScreen", 0, page.sdkFirstScreenCount.get())
                assertEquals("warm真实Frame收据必须恰好一次", 1, page.cachedFrameCount.get())
            } else {
                assertEquals("cold必须由真实SDK首屏交付", "SDK_FIRST_SCREEN", page.frameSource.get())
                assertEquals("cold真实SDK首屏必须恰好一次", 1, page.sdkFirstScreenCount.get())
                assertEquals("cold不能借暖Frame hook", 0, page.cachedFrameCount.get())
            }
        }

        fun awaitEvent(page: Page, eventName: String, after: Int): Event {
            val deadline = SystemClock.elapsedRealtime() + 30_000L
            while (SystemClock.elapsedRealtime() < deadline) {
                assertNull("Native探针等待期间SDK fatal", page.fatal.get())
                page.events.toList().drop(after).firstOrNull { it.name == eventName }?.let { event ->
                    page.row["lastObservedNativeEvent"] = event.toRow()
                    persist()
                    return event
                }
                SystemClock.sleep(30)
            }
            page.row["observedNativeEvents"] = page.events.map(Event::toRow)
            persist()
            fail("真实Native事件未到达 event=$eventName page=${page.pageId}")
            error("unreachable")
        }

        fun assertReady(page: Page, event: Event, counter: Int) {
            assertPayload(page, event, counter, if (counter == 0) "initial" else "counter")
            if (page.caseName == "lazy") assertEquals("not-requested", event.payload["lazyStatus"])
            awaitLabel(page, "engine-reuse-ready",
                "engine-reuse:${page.caseName}:page=${page.pageId}:marker=${page.marker}:counter=$counter:mount=1:oldOnly=${page.withOldOnly}:globalOldOnly=${page.withOldOnly}")
            page.row["nativeReadyPayload"] = event.payload
            page.row["nativeSourcePageId"] = event.source
            persist()
        }

        fun assertPayload(page: Page, event: Event, counter: Int, phase: String) {
            assertEquals("exact Native source必须归新页", page.pageId, event.source)
            assertEquals("真实JS pageId必须归新页", page.pageId, event.payload["pageId"])
            assertEquals("真实JS initialData marker必须更新", page.marker, event.payload["marker"])
            assertEquals("真实JS globalProps marker必须更新", "global-${page.marker}", event.payload["globalMarker"])
            assertEquals("省略的initData字段不能残留", page.withOldOnly, event.payload["hasOldOnly"])
            assertEquals("省略的globalProps字段不能残留", page.withOldOnly, event.payload["globalHasOldOnly"])
            assertEquals("新页面React counter必须重置", counter, (event.payload["counter"] as Number).toInt())
            assertEquals("新页面模块mount计数必须为1", 1, (event.payload["moduleMountCount"] as Number).toInt())
            assertEquals(phase, event.payload["phase"])
            assertTrue("Node READY必须有宿主接受的真实回执", event.accepted)
        }

        fun assertSameEngineAndFreshContext(first: Page, second: Page) {
            assertNotSame("新页面必须有新LynxView", first.view, second.view)
            assertNotSame("新页面必须有新LynxContext", first.context, second.context)
            assertNotNull("必须观察真实parsed TemplateBundle", first.template)
            assertSame("同snapshot重开必须复用真实parsedTemplate对象", first.template, second.template)
            assertTrue("真实nativeTplPtr必须非零", first.templatePtr != 0L)
            assertEquals("真实parsedTemplate nativePtr必须相同", first.templatePtr, second.templatePtr)
            assertNotNull("A必须观察到真实Engine对象", first.engine)
            assertSame("B必须复用A的真实Engine对象", first.engine, second.engine)
            assertTrue("A真实Engine wrapper必须非零", first.enginePtr != 0L)
            assertEquals("B必须沿用同一真实Engine wrapper nativePtr", first.enginePtr, second.enginePtr)
            assertTrue("B真实Engine wrapper必须仍非零", second.enginePtr != 0L)
            second.row["sameParsedTemplateObject"] = true
            second.row["sameOriginalEngineObject"] = true
            second.row["sameOriginalEngineNativePtr"] = true
            second.row["freshLynxContext"] = true
            persist()
        }

        fun assertSingleInitialEffect(page: Page) {
            // UI READY后继续观察实际副作用；不能只挑第一个正确回执忽略重复mount。
            SystemClock.sleep(250)
            val events = page.events.toList()
            page.row["allInitialNativeEvents"] = events.map(Event::toRow)
            persist()
            assertEquals("新页initial effect必须恰好一次", 1, events.size)
            assertEquals(READY_EVENT, events.single().name)
            assertPayload(page, events.single(), counter = 0, phase = "initial")
        }

        fun assertSingleCounterEffect(page: Page) {
            SystemClock.sleep(250)
            val events = page.events.toList()
            page.row["allCounterNativeEvents"] = events.map(Event::toRow)
            persist()
            assertEquals("一次真实点击只能增加一次counter副作用，不能重复mount", 2, events.size)
            events.forEachIndexed { index, event ->
                assertEquals(READY_EVENT, event.name)
                assertPayload(page, event, counter = index, phase = if (index == 0) "initial" else "counter")
            }
        }

        fun assertResolverMatchesCurrentRoot(page: Page): Rect {
            onMain { requireNotNull(currentUi(page.view, "engine-reuse-ready")).scrollIntoView(false, "nearest", "nearest") }
            instrumentation.waitForIdleSync()
            val result = Rect()
            onMain {
                val ui = requireNotNull(currentUi(page.view, "engine-reuse-ready"))
                val currentRect = Rect(ui.rectToWindow)
                assertTrue("当前Root READY真实layout必须非零", !currentRect.isEmpty)
                val resolved = requireNotNull(LynxElementResolver.resolve(page.view, "engine-reuse-ready"))
                assertEquals("转场Resolver只能取当前Root READY几何", currentRect, resolved.rectOnScreen)
                result.set(currentRect)
                page.row["currentReadyObjectIdentity"] = System.identityHashCode(ui)
                page.row["currentReadyRect"] = currentRect.toShortString()
                page.row["resolverReadyRect"] = resolved.rectOnScreen.toShortString()
                page.row["resolverMatchesCurrentRoot"] = true
            }
            persist()
            return result
        }

        fun assertReleasedAfterWarmPage(page: Page) {
            assertTrue("B真实页面lease必须关闭", isLeaseClosed(page.lease))
            val ptr = enginePtr(requireNotNull(page.engine))
            page.row["engineNativePtrAfterWarmDestroy"] = ptr
            page.row["templateNativePtrAfterWarmDestroy"] = requireNotNull(page.template).nativePtr
            persist()
            assertEquals("B结束后必须销毁Group的Engine wrapper", 0L, ptr)
            assertEquals("B结束后Group真实模板也必须释放", 0L, requireNotNull(page.template).nativePtr)
        }

        fun observeRealFetchers(page: Page) = onMain {
            val render = readField(page.view, "mLynxTemplateRender", LynxView::class.java)
            var hooked = 0
            for (loaderName in listOf("mLoader", "mResourceLoader")) {
                val loader = readNullableField(render, loaderName) ?: continue
                val helper = readField(loader, "mTemplateLoaderHelper")
                if (observedHelpers.containsKey(helper)) { hooked++; continue }
                val field = helper.javaClass.getDeclaredField("mTemplateFetcher").apply { isAccessible = true }
                val delegate = requireNotNull(field.get(helper)) as LynxTemplateResourceFetcher
                val observer = if (delegate is FetchObserver) delegate else observedDelegates[delegate]
                    ?: FetchObserver(delegate, loaderName).also { observedDelegates[delegate] = it }
                field.set(helper, observer)
                observedHelpers[helper] = true
                hooked++
            }
            assertTrue("必须观察4.1真实loader捕获的TemplateFetcher", hooked > 0)
            page.row["nativeFetcherObserverHelpers"] = hooked
        }

        private inner class FetchObserver(
            private val delegate: LynxTemplateResourceFetcher,
            private val loaderName: String,
        ) : LynxTemplateResourceFetcher() {
            override fun fetchTemplate(request: LynxResourceRequest, callback: LynxResourceCallback<TemplateProviderResult>) {
                val isLazy = request.url == lazyUrl || request.url == "/lazy-bundle/EngineReuseLazyPanel.lynx.bundle"
                if (!isLazy) { delegate.fetchTemplate(request, callback); return }
                lazyFetches.incrementAndGet()
                record("真实Native Lazy请求 loader=$loaderName url=${request.url}")
                delegate.fetchTemplate(request, object : LynxResourceCallback<TemplateProviderResult> {
                    override fun onResponse(response: LynxResourceResponse<TemplateProviderResult>) {
                        response.data?.templateBinary?.let { bytes ->
                            lazyResponseSha.set("sha256:" + sha256(bytes))
                            lazyResponseSize.set(bytes.size)
                        }
                        callback.onResponse(response)
                    }
                })
            }
            override fun fetchSSRData(request: LynxResourceRequest, callback: LynxResourceCallback<ByteArray>) {
                delegate.fetchSSRData(request, callback)
            }
        }

        fun destroy(page: Page) {
            if (!page.destroyed.compareAndSet(false, true)) return
            try {
                onMain {
                    ShellMessageHub.unregister(page.pageId)
                    page.createdView?.let { view -> frame.removeView(view); destroyView.invoke(LynxShell, view) }
                }
            } finally {
                page.provider.close()
                page.lease.close()
                page.row["pageLeaseClosed"] = isLeaseClosed(page.lease)
                page.row["destroyPath"] = "LynxShell.destroyView"
                persist()
            }
            instrumentation.waitForIdleSync()
        }

        fun persist() = synchronized(resultWriteLock) {
            val rowCopies = synchronized(rows) { rows.toList() }.map { row ->
                synchronized(row) { LinkedHashMap(row) }
            }
            File(results, "results.json").writeText(OtaJson.stringify(rowCopies))
        }

        fun saveAssertionScreenshot(page: Page, basename: String) {
            val drawn = CountDownLatch(1)
            onMain {
                page.view.invalidate()
                page.view.postOnAnimation { page.view.postOnAnimation { drawn.countDown() } }
            }
            check(drawn.await(10, TimeUnit.SECONDS)) { "断言通过后的截图绘制帧未到达" }
            val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            try {
                FileOutputStream(File(results, basename)).use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) { "真实截图PNG写入失败" }
                }
            } finally { bitmap.recycle() }
            page.row["assertionScreenshotBasename"] = basename
            persist()
        }

        fun close() {
            try { pages.values.forEach(::destroy) } finally { onMain { LynxRouter.setMessageHandler(null) } }
        }
    }

    private fun tap(view: LynxView, selector: String) {
        val rect = Rect()
        onMain {
            val ui = requireNotNull(currentUi(view, selector))
            ui.scrollIntoView(false, "nearest", "nearest")
        }
        instrumentation.waitForIdleSync()
        onMain {
            val ui = requireNotNull(currentUi(view, selector))
            // SDK公开几何已处理flatten祖先和滚动，再加UIBody屏幕位置；不能假定节点拥有Android View。
            rect.set(ui.rectToWindow)
            assertTrue("真实按钮必须完成layout", rect.width() > 0 && rect.height() > 0)
            val hostLocation = IntArray(2)
            view.getLocationOnScreen(hostLocation)
            val viewport = Rect(hostLocation[0], hostLocation[1],
                hostLocation[0] + view.width, hostLocation[1] + view.height)
            assertTrue("真实按钮中心必须在宿主可见区域", view.isAttachedToWindow &&
                viewport.contains(rect.centerX(), rect.centerY()))
            record("真实UI触控 selector=$selector ui=${ui.javaClass.simpleName} screenRect=$rect")
        }
        val downTime = SystemClock.uptimeMillis()
        MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, rect.exactCenterX(), rect.exactCenterY(), 0).also { event ->
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
        }
        MotionEvent.obtain(downTime, downTime + 50, MotionEvent.ACTION_UP, rect.exactCenterX(), rect.exactCenterY(), 0).also { event ->
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
        }
    }

    private fun awaitLabel(page: Page, selector: String, expected: String) {
        val deadline = SystemClock.elapsedRealtime() + 30_000L
        var actual = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            assertNull("Node等待期间SDK fatal", page.fatal.get())
            onMain {
                val ui = currentUi(page.view, selector)
                actual = (ui as? IUIText)?.textLayout?.text?.toString().orEmpty()
                page.row["currentRootObservedText"] = actual
                page.row["currentRootObservedNodeIdentity"] = ui?.let(System::identityHashCode)
                page.row["currentRootObservedAccessibilityLabel"] = ui?.accessibilityLabel?.toString()
            }
            if (actual == expected) {
                onMain {
                    val ui = requireNotNull(currentUi(page.view, selector))
                    assertTrue("真实READY必须有layout", ui.latestSize.x > 0 && ui.latestSize.y > 0)
                    assertTrue("真实View必须attach/layout", page.view.isAttachedToWindow && page.view.width > 0 && page.view.height > 0)
                    assertNull("Lazy不能有当前根error节点", currentUi(page.view, "engine-reuse-lazy-error"))
                    assertEquals("真实状态节点必须显示READY", "READY",
                        (currentUi(page.view, "engine-reuse-status") as? IUIText)?.textLayout?.text?.toString())
                }
                return
            }
            SystemClock.sleep(30)
        }
        page.row["currentRootExpectedText"] = expected
        fail("Native接受后当前Root的唯一READY节点必须显示完整新文本 expected=$expected actual=$actual")
    }

    private fun currentUi(view: LynxView, selector: String): LynxBaseUI? {
        fun collect(ui: LynxBaseUI?): List<LynxBaseUI> = if (ui == null) emptyList()
            else listOf(ui) + ui.children.flatMap(::collect)
        val matches = collect(view.lynxUIRoot).filter { it.idSelector == selector }
        assertTrue("当前Root同ID不得重复 selector=$selector count=${matches.size}", matches.size <= 1)
        return matches.singleOrNull()
    }

    private class Page(val pageId: String, val caseName: String, val marker: String, val withOldOnly: Boolean,
        val provider: ShellTemplateProvider, val lease: ReleaseTransaction.BundleLease, val row: MutableMap<String, Any?>) {
        var createdView: LynxView? = null
        val view: LynxView get() = requireNotNull(createdView)
        var context: Any? = null
        var engine: Any? = null
        var enginePtr = 0L
        var template: TemplateBundle? = null
        var templatePtr = 0L
        var shellPtr = 0L
        val firstScreen = CountDownLatch(1)
        val sdkFirstScreenCount = AtomicInteger()
        val sdkFirstScreenNs = AtomicLong()
        val firstFrameNs = AtomicLong()
        var renderStartNs = 0L
        val cachedFrameCount = AtomicInteger()
        val sdkCallbacks = ConcurrentLinkedQueue<String>()
        val frameSource = AtomicReference<String?>()
        var reusedIdentity = false
        val fatal = AtomicReference<String?>()
        val destroyed = AtomicBoolean(false)
        val events = ConcurrentLinkedQueue<Event>()
    }

    private data class Event(val source: String, val name: String, val payload: Map<String, Any?>, val accepted: Boolean) {
        fun toRow(): Map<String, Any?> = mapOf("source" to source, "eventName" to name, "payload" to payload, "accepted" to accepted)
    }

    private fun readField(value: Any, fieldName: String, owner: Class<*> = value.javaClass): Any =
        requireNotNull(owner.getDeclaredField(fieldName).apply { isAccessible = true }.get(value))
    private fun readNullableField(value: Any, fieldName: String): Any? =
        value.javaClass.getDeclaredField(fieldName).apply { isAccessible = true }.get(value)
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
    private fun isLeaseClosed(lease: ReleaseTransaction.BundleLease): Boolean =
        (readField(lease, "closed") as AtomicBoolean).get()
    private fun enginePtr(engine: Any): Long = engine.javaClass.getMethod("getNativePtr").invoke(engine) as Long
    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
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
    private fun record(message: String) {
        instrumentation.sendStatus(0, Bundle().apply { putString("stream", "\nBoundedEngineState: $message\n") })
    }

    private companion object {
        const val READY_EVENT = "engine-reuse-probe.ready"
        const val LAZY_EVENT = "engine-reuse-probe.lazy-ready"
        const val FIXTURE_MARKER = "ENGINE_REUSE_FIXTURE_V1"
    }
}
