package com.example.lynxshell.sample

import android.content.Intent
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
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateData
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

/** 真JS状态、Native回执和真正Lazy Bundle；不通过注入JS或假字节驱动结果。 */
class EngineStateReuseTest : InstrumentationTestCase() {
    fun testWarmStatePageResetsInitialDataGlobalPropsAndJsState() = withFixture { fixture ->
        val first = fixture.open("state", "state-A", withOldOnly = true)
        fixture.assertInitialReady(first)
        val cursor = first.events.size
        tap(first.view, "engine-reuse-increment")
        fixture.assertReady(first, fixture.awaitEvent(first, READY_EVENT, cursor), counter = 1)
        fixture.destroy(first)
        assertTrue("A的真实页面lease必须关闭", isLeaseClosed(first.lease))

        val second = fixture.open("state", "state-B", withOldOnly = false)
        try {
            fixture.assertInitialReady(second)
            fixture.assertSameCachedEngineAndFreshContext(first, second)
        } finally { fixture.destroy(second) }
    }

    fun testWarmLazyPageFirstRequestUsesCurrentBindingAndRealBundleBytes() = withFixture { fixture ->
        val first = fixture.open("lazy", "lazy-A", withOldOnly = true)
        fixture.assertInitialReady(first)
        fixture.observeRealFetchers(first)
        assertEquals("A初始未点击Lazy，不能发生Native Lazy请求", 0, fixture.lazyFetches.get())
        fixture.destroy(first)
        assertTrue("A已结束后不能依赖未关闭的页面lease", isLeaseClosed(first.lease))

        val second = fixture.open("lazy", "lazy-B", withOldOnly = false)
        try {
            fixture.assertInitialReady(second)
            fixture.assertSameCachedEngineAndFreshContext(first, second)
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
        } finally { fixture.destroy(second) }
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
        val storeRoot = File(context.cacheDir, "engine-state-fixture-${UUID.randomUUID()}")
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
        onMain { launcher.setContentView(frame) }
        val results = File(context.filesDir, "engine-group-cache-results/$label/$name")
            .also { assertTrue(it.isDirectory || it.mkdirs()) }
        val fixture = Fixture(manifest, cases, store, scope, launcher, frame, results, label, lazyUrl, lazySha, lazySize)
        try {
            fixture.installMessageHandler()
            block(fixture)
        } finally {
            try { fixture.close() } finally {
                onMain { launcher.finish() }
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
                    it.row["cachedFirstFrameCountAtNativeEvent"] = it.cachedFirstFrameCount.get()
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
                            page.frameSource.compareAndSet(null, LynxFirstFrameSource.SDK_FIRST_SCREEN.name)
                            page.firstScreen.countDown()
                        }
                    }
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
                    onCachedFirstFrame = { source ->
                        if (!page.destroyed.get()) {
                            page.cachedFirstFrameCount.incrementAndGet()
                            page.cachedFirstFrameNs.compareAndSet(0L, SystemClock.elapsedRealtimeNanos())
                            page.frameSource.compareAndSet(null, source.name)
                            page.firstScreen.countDown()
                        }
                    },
                )
                ShellMessageHub.register(info, launcher, page.view)
                assertEquals(pageId, ShellMessageHub.pageIdFor(launcher))
                frame.addView(page.view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                page.context = page.view.lynxContext
                page.view.renderTemplateUrl(url, TemplateData.fromMap(initData))
            }
            return page
        }

        fun assertInitialReady(page: Page) {
            assertTrue("冷SDK首屏/暖实际draw收据未到达", page.firstScreen.await(30, TimeUnit.SECONDS))
            assertNull("SDK fatal", page.fatal.get())
            assertReady(page, awaitEvent(page, READY_EVENT, 0), counter = 0)
            onMain {
                val render = readField(page.view, "mLynxTemplateRender", LynxView::class.java)
                page.engine = readNullableField(render, "mLynxEngineRef")
                page.reusedIdentity = isGroupReused(page.view)
                page.enginePtr = page.engine?.let(::nativeEnginePtr)
                page.row["engineObjectIdentity"] = page.engine?.let(System::identityHashCode)
                page.row["engineNativePtr"] = page.enginePtr
                page.context = page.view.lynxContext
                page.row["lynxContextObjectIdentity"] = System.identityHashCode(requireNotNull(page.context))
            }
            page.row["reusedIdentity"] = page.reusedIdentity
            page.row["deviceApi"] = Build.VERSION.SDK_INT
            page.row["hardwareAccelerated"] = page.view.isHardwareAccelerated
            page.row["actualFirstFrameSource"] = page.frameSource.get()
            page.row["sdkFirstScreenCount"] = page.sdkFirstScreenCount.get()
            page.row["cachedFirstFrameCount"] = page.cachedFirstFrameCount.get()
            page.row["sdkFirstScreen"] = page.sdkFirstScreenCount.get() > 0
            page.row["sdkFirstScreenElapsedRealtimeNs"] = page.sdkFirstScreenNs.get().takeIf { it != 0L }
            page.row["cachedFirstFrameElapsedRealtimeNs"] = page.cachedFirstFrameNs.get().takeIf { it != 0L }
            persist()
            val expectedSource = if (page.reusedIdentity) {
                if (Build.VERSION.SDK_INT >= 29 && page.view.isHardwareAccelerated)
                    LynxFirstFrameSource.CACHED_FRAME_COMMITTED.name else LynxFirstFrameSource.CACHED_DRAW_CYCLE.name
            } else LynxFirstFrameSource.SDK_FIRST_SCREEN.name
            assertEquals("帧收据必须匹配Group lease与真实渲染能力", expectedSource, page.frameSource.get())
            if (page.reusedIdentity) {
                assertEquals("暖engine不能伪造SDK首屏callback", 0, page.sdkFirstScreenCount.get())
                assertEquals("暖页面必须交付一次真实draw收据", 1, page.cachedFirstFrameCount.get())
            } else {
                assertTrue("冷页面必须收到真实SDK首屏callback", page.sdkFirstScreenCount.get() > 0)
                assertEquals("冷页面不得通过cached hook伪装首屏", 0, page.cachedFirstFrameCount.get())
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

        fun assertSameCachedEngineAndFreshContext(first: Page, second: Page) {
            assertNotSame("新页面必须有新LynxView", first.view, second.view)
            assertNotSame("新页面必须有新LynxContext", first.context, second.context)
            assertNotNull("必须观察真实SDK缓存引擎", first.engine)
            assertSame("销毁后新页面必须使用同一个真实SDK engine", first.engine, second.engine)
            assertTrue("SDK engine wrapper必须非零", first.enginePtr != null && first.enginePtr != 0L)
            assertEquals("真实SDK engine wrapper身份必须相同", first.enginePtr, second.enginePtr)
            second.row["sameEngineObject"] = true
            second.row["freshLynxContext"] = true
            persist()
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
        fun close() {
            try { pages.values.forEach(::destroy) } finally { onMain { LynxRouter.setMessageHandler(null) } }
        }
    }

    private fun tap(view: LynxView, selector: String) {
        val rect = Rect()
        onMain {
            val ui = requireNotNull(view.findUIByIdSelector(selector))
            ui.scrollIntoView(false, "nearest", "nearest")
        }
        instrumentation.waitForIdleSync()
        onMain {
            val ui = requireNotNull(view.findUIByIdSelector(selector))
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
            onMain { actual = page.view.findUIByIdSelector(selector)?.accessibilityLabel?.toString().orEmpty() }
            if (actual == expected) {
                onMain {
                    val ui = requireNotNull(page.view.findUIByIdSelector(selector))
                    assertTrue("真实READY必须有layout", ui.latestSize.x > 0 && ui.latestSize.y > 0)
                    assertTrue("真实View必须attach/layout", page.view.isAttachedToWindow && page.view.width > 0 && page.view.height > 0)
                    assertNull("Lazy不能有error节点", page.view.findUIByIdSelector("engine-reuse-lazy-error"))
                }
                return
            }
            SystemClock.sleep(30)
        }
        assertEquals("Native接受后必须显示真实READY节点", expected, actual)
    }

    private class Page(val pageId: String, val caseName: String, val marker: String, val withOldOnly: Boolean,
        val provider: ShellTemplateProvider, val lease: ReleaseTransaction.BundleLease, val row: MutableMap<String, Any?>) {
        var createdView: LynxView? = null
        val view: LynxView get() = requireNotNull(createdView)
        var context: Any? = null
        var engine: Any? = null
        var enginePtr: Long? = null
        val firstScreen = CountDownLatch(1)
        val sdkFirstScreenCount = AtomicInteger()
        val cachedFirstFrameCount = AtomicInteger()
        val sdkFirstScreenNs = AtomicLong()
        val cachedFirstFrameNs = AtomicLong()
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
    private fun nativeEnginePtr(engine: Any): Long = engine.javaClass.getMethod("getNativePtr").invoke(engine) as Long
    private fun isGroupReused(view: LynxView): Boolean {
        val cache = Class.forName("com.example.lynxshell.container.EngineViewCache")
        val instance = cache.getField("INSTANCE").get(null)
        return cache.getDeclaredMethod("isReused", LynxView::class.java).invoke(instance, view) as Boolean
    }
    private fun isLeaseClosed(lease: ReleaseTransaction.BundleLease): Boolean =
        (readField(lease, "closed") as AtomicBoolean).get()
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
        instrumentation.sendStatus(0, Bundle().apply { putString("stream", "\nEngineStateReuse: $message\n") })
    }

    private companion object {
        const val READY_EVENT = "engine-reuse-probe.ready"
        const val LAZY_EVENT = "engine-reuse-probe.lazy-ready"
        const val FIXTURE_MARKER = "ENGINE_REUSE_FIXTURE_V1"
    }
}
