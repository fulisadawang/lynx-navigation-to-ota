package com.example.lynxshell.sample

import android.content.Intent
import android.os.Build
import android.os.Debug
import android.os.Bundle
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
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.ota.PreparedActivityBundle
import com.example.lynxshell.resource.ShellTemplateProvider
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateData
import com.lynx.tasm.TemplateBundle
import com.lynx.tasm.group.ILynxViewGroup
import com.ota.android.sdk.ContentAddressedOtaStore
import com.ota.android.sdk.OtaJson
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.ReleaseTransaction
import java.io.File
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** 用固定真实 Bundle 验证 SDK parsed模板身份和新页 Native source，安全缓存方案。 */
class LynxTemplateGroupReuseTest : InstrumentationTestCase() {
    fun testDestroyedSameSnapshotReusesParsedTemplateWithFreshShellAndNativeSource() = withFixture { fixture ->
        for (case in fixture.cases) {
            val first = fixture.open(case)
            fixture.assertReady(first)
            val a = requireNotNull(first.identity)
            fixture.destroy(first)
            val second = fixture.open(case)
            try {
                fixture.assertReady(second)
                val b = requireNotNull(second.identity)
                assertNotSame(first.view, second.view)
                assertSame("同snapshot必须复用真实parsed TemplateBundle对象", a.template, b.template)
                assertTrue("真实nativeTplPtr必须非零", a.templateNativePtr != null && a.templateNativePtr != 0L)
                assertEquals(a.templateNativePtr, b.templateNativePtr)
                assertTrue("每页必须创建fresh native shell", a.renderNativePtr != b.renderNativePtr)
                assertNull(a.engine)
                assertNull(b.engine)
                second.row["sameParsedTemplateObject"] = true
                second.row["sameNonzeroNativeTemplatePtr"] = true
                second.row["freshNativeShell"] = true
                fixture.persist()
            } finally { fixture.destroy(second) }
        }
    }

    fun testConcurrentSameSnapshotUsesIndependentFreshShells() = withFixture { fixture ->
        for (case in fixture.cases) {
            val first = fixture.open(case)
            fixture.assertReady(first)
            val second = fixture.open(case, separateActivity = true)
            try {
                fixture.assertReady(second)
                val firstIdentity = requireNotNull(first.identity)
                val secondIdentity = requireNotNull(second.identity)
                assertNotSame("同时存活的页面必须有独立 View", first.view, second.view)
                assertTrue("同时存活页面的 native shell不能相同", firstIdentity.renderNativePtr != secondIdentity.renderNativePtr)
                assertNull("第一活体页不得缓存Engine", firstIdentity.engine)
                assertNull("第二活体页不得缓存Engine", secondIdentity.engine)
                var stillCurrent: TemplateIdentity? = null
                onMain { stillCurrent = readIdentity(first.view) }
                assertEquals("创建第二页不能销毁第一页 native shell", firstIdentity.renderNativePtr, requireNotNull(stillCurrent).renderNativePtr)
                assertNull("第一活体页没有cached Engine", requireNotNull(stillCurrent).engine)
                fixture.assertReady(first)
                assertEquals(first.pageId, first.row["nativeSourcePageId"])
                assertEquals(second.pageId, second.row["nativeSourcePageId"])
                second.row["activeShellAffected"] = false
                fixture.persist()
            } finally {
                fixture.destroy(first)
                fixture.destroy(second)
            }
        }
    }

    fun testConcurrentSameActivityKeepsExactNativeSource() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        val first = fixture.open(case)
        fixture.assertReady(first)
        val second = fixture.open(case, sameActivityConcurrent = true)
        try {
            fixture.assertReady(second)
            assertSame("此用例必须实测同Activity双View", first.hostActivity, second.hostActivity)
            assertNotSame(first.view, second.view)
            val firstEngine = requireNotNull(first.identity).engine
            val secondEngine = requireNotNull(second.identity).engine
            assertNull(firstEngine)
            assertNull(secondEngine)
            assertTrue("同Activity双页必须各有fresh shell", requireNotNull(first.identity).renderNativePtr != requireNotNull(second.identity).renderNativePtr)
            assertEquals(first.pageId, first.nativeSourcePageId.get())
            assertEquals(second.pageId, second.nativeSourcePageId.get())
            fixture.assertReady(first)
            second.row["sameActivityExactSourceVerified"] = true
            fixture.persist()
        } finally { fixture.destroy(first); fixture.destroy(second) }
    }

    fun testTrimReleasesIdleParsedTemplateThenNextPageCreatesFreshTemplate() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        val first = fixture.open(case)
        fixture.assertReady(first)
        val template = requireNotNull(requireNotNull(first.identity).template)
        val activePtr = template.nativePtr
        assertTrue("真实parsedTemplate nativePtr必须非零", activePtr != 0L)
        fixture.destroy(first)
        assertEquals("trim前必须确实保留idle parsedTemplate", activePtr, template.nativePtr)
        onMain { LynxShell.onTrimMemory(10) }
        instrumentation.waitForIdleSync()
        assertEquals("SDK release必须使真实TemplateBundle指针归零", 0L, template.nativePtr)
        first.row["templateNativePtrAfterTrim"] = template.nativePtr
        fixture.persist()
        val second = fixture.open(case)
        try {
            fixture.assertReady(second)
            assertFalse("trim后不能借用已release的Group", second.reusedIdentity)
            assertNotSame(template, requireNotNull(second.identity).template)
        } finally { fixture.destroy(second) }
    }

    fun testTenRealRoundTripsRecordMemoryAndFrameReceiptDiagnostics() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        onMain { LynxShell.onTrimMemory(10) }
        var priorTemplate: TemplateBundle? = null
        repeat(10) { index ->
            val page = fixture.open(case)
            try {
                fixture.assertReady(page)
                val template = requireNotNull(requireNotNull(page.identity).template)
                if (priorTemplate != null) assertSame("连续相同snapshot应复用同一真实parsedTemplate", priorTemplate, template)
                priorTemplate = template
                page.row["roundTrip"] = index + 1
                page.row["pssKbWhileReady"] = Debug.getPss()
                page.row["javaUsedBytesWhileReady"] = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }
            } finally { fixture.destroy(page) }
            page.row["pssKbAfterDestroy"] = Debug.getPss()
            page.row["javaUsedBytesAfterDestroy"] = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }
            page.row["memoryObservationOnly"] = true
            fixture.persist()
        }
        // 这里不主动GC、不设内存增长阈值；这些进程级样本不能证明无泄漏。
    }

    fun testColdImmediateCancellationCannotDonateHalfInitializedTemplate() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        onMain { LynxShell.onTrimMemory(10) }
        val cancelled = fixture.open(case, cancelBeforeFirstFrame = true)
        assertTrue(cancelled.destroyed.get())
        assertEquals("取消时真实首帧尚未到达", 0, cancelled.sdkFirstScreenCount.get())
        val next = fixture.open(case)
        try {
            fixture.assertReady(next)
            assertFalse("半初始化Template Group不得进入idle可借状态", next.reusedIdentity)
            cancelled.identity?.template?.let { template ->
                assertNotSame("B不能借A的半初始化parsedTemplate", template, requireNotNull(next.identity).template)
                assertEquals("取消的parsedTemplate必须已释放", 0L, template.nativePtr)
            }
            assertEquals(next.pageId, next.nativeSourcePageId.get())
            assertNull("已取消A不能接受任何迟到Native ready", cancelled.nativePayload.get())
            next.row["coldCancellationIsolationVerified"] = true
            fixture.persist()
        } finally { fixture.destroy(next) }
    }

    fun testIdleTemplateGroupFormerHostWeakReferenceDiagnostic() = withFixture { fixture ->
        val case = fixture.cases.single { it.name == "small" }
        val probe = fixture.releaseSecondaryHostForGcProbe(case)
        assertTrue("诊断期间保留真实idle parsedTemplate，而不是先清池假装host释放", probe.template.nativePtr != 0L)
        var attempts = 0
        while (attempts < 8 && probe.host.get() != null) {
            System.gc()
            System.runFinalization()
            instrumentation.waitForIdleSync()
            SystemClock.sleep(100)
            attempts++
        }
        val collected = probe.host.get() == null
        val diagnostic = linkedMapOf<String, Any?>(
            "caseName" to "former-host-gc-diagnostic", "hostObjectIdentity" to probe.hostIdentity,
            "templateObjectIdentity" to System.identityHashCode(probe.template),
            "templateNativePtrDuringGc" to probe.template.nativePtr,
            "gcAttempts" to attempts, "formerHostCollectedWithinBoundedGc" to collected,
            "initialCollected" to collected,
            "gcResultConclusiveForNoLeak" to false,
        )
        fixture.addDiagnostic(diagnostic)
        val captureHeap = (instrumentation as InstrumentationTestRunner).arguments.getString("captureHeap") == "true"
        diagnostic["captureHeapRequested"] = captureHeap
        fixture.persist()
        if (!collected && captureHeap) {
            assertTrue("heap诊断时必须仍保留真实parsedTemplate", probe.template.nativePtr != 0L)
            diagnostic["templateNativePtrAtHeapCapture"] = probe.template.nativePtr
            fixture.persist()
            // 不取出WeakHost到dump调用栈，也不把此GC/heap暂停混入十次性能样本。
            val heap = fixture.captureFormerHostHeap()
            diagnostic["heapFileBasename"] = heap.name
            diagnostic["heapFileSize"] = heap.length()
            fixture.persist()
        }
        var afterQueueDrainCollected = collected
        var queueDrainGcAttempts = 0
        if (!collected) {
            // 首份heap已定位系统滚动条延时消息；等待真实队列排空后再单独诊断。
            SystemClock.sleep(3_000L)
            instrumentation.waitForIdleSync()
            while (queueDrainGcAttempts < 3 && probe.host.get() != null) {
                System.gc()
                System.runFinalization()
                instrumentation.waitForIdleSync()
                queueDrainGcAttempts++
            }
            afterQueueDrainCollected = probe.host.get() == null
        }
        diagnostic["queueDrainWaitMs"] = if (collected) 0L else 3_000L
        diagnostic["queueDrainGcAttempts"] = queueDrainGcAttempts
        diagnostic["afterQueueDrainCollected"] = afterQueueDrainCollected
        diagnostic["templateNativePtrAfterQueueDrain"] = probe.template.nativePtr
        fixture.persist()
        if (!afterQueueDrainCollected && captureHeap) {
            assertTrue("第二份heap必须仍保留真实parsedTemplate", probe.template.nativePtr != 0L)
            val heap = fixture.captureFormerHostHeap("former-host-after-drain.hprof")
            diagnostic["afterQueueDrainHeapFileBasename"] = heap.name
            diagnostic["afterQueueDrainHeapFileSize"] = heap.length()
            fixture.persist()
        }
        record("旧host WeakReference诊断 collected=$collected attempts=$attempts；不代表无泄漏")
        record("系统队列等待后WeakReference诊断 collected=$afterQueueDrainCollected gcAttempts=$queueDrainGcAttempts；不代表无泄漏")
    }

    private fun withFixture(block: (Fixture) -> Unit) {
        val context = instrumentation.targetContext
        assertEquals("只允许隔离验收App", "com.hugboga.custom.otae2e", context.packageName)
        val label = (instrumentation as InstrumentationTestRunner).arguments.getString("runLabel")
            ?: error("必须提供runLabel=baseline或grouped")
        require(label in setOf("baseline", "grouped"))
        val description = OtaJson.asObject(
            OtaJson.parse(File(context.filesDir, "bundle-loading-fixture.json").readText()), "EngineGroupFixture",
        )
        val manifest = OtaModels.ReleaseManifest.fromJsonMap(
            OtaJson.asObject(description["manifest"], "manifest"), requireStatus = true,
        )
        assertEquals("10030071", manifest.lynxAppId)
        val cases = OtaJson.asArray(description["cases"], "cases").map { raw ->
            val value = OtaJson.asObject(raw, "case")
            Case(value["caseName"] as String, value["path"] as String,
                value["expectedReadyLabel"] as String,
                OtaJson.asObject(value["expectedReadyPayload"], "expectedReadyPayload"))
        }
        assertEquals(listOf("small", "large", "async"), cases.map { it.name })
        val frozen = mapOf(
            "BundleLoadSmall.lynx.bundle" to Pair(88114L, "bd55248f0883f4492245ecc18309d241eb419e992f4b2bacc00502294809fbe2"),
            "BundleLoadLarge.lynx.bundle" to Pair(3234076L, "3554ab411d9be7828d05029f42bcd77a5bacfaf50b43648865fbfe9e52505fbf"),
            "BundleLoadAsync.lynx.bundle" to Pair(94510L, "374ddaf32e80cdb56a7b9e065d4fa1b3c0239e3da63221715e74ce354596da8c"),
        )
        for (bundle in manifest.bundles) {
            val expected = requireNotNull(frozen[bundle.bundlePath])
            assertEquals("保持原Fixture bytes", expected.first.toInt(), requireNotNull(bundle.size))
            assertEquals("保持原Fixture SHA", "sha256:${expected.second}", bundle.bundleSha256)
        }
        val storeRoot = File(context.cacheDir, "engine-group-fixture-${UUID.randomUUID()}")
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
        val results = File(context.filesDir, "template-group-cache-results/$label/$name")
            .also { assertTrue(it.isDirectory || it.mkdirs()) }
        val fixture = Fixture(manifest, cases, store, scope, launcher, frame, results, label)
        try {
            fixture.installMessageHandler()
            block(fixture)
        } finally {
            fixture.close()
            onMain { launcher.finish() }
            storeRoot.deleteRecursively()
        }
    }

    private inner class Fixture(
        val manifest: OtaModels.ReleaseManifest,
        val cases: List<Case>,
        private val store: ContentAddressedOtaStore,
        private val scope: ReleaseTransaction.ReleaseScope,
        private val launcher: MainActivity,
        private val frame: FrameLayout,
        private val results: File,
        private val label: String,
    ) {
        private val pages = ConcurrentHashMap<String, Page>()
        private val rows = mutableListOf<MutableMap<String, Any?>>()

        fun installMessageHandler() = onMain {
            LynxRouter.setMessageHandler { message ->
                val page = pages[message.source.pageId]
                val accepted = page != null && !page.destroyed.get() &&
                    message.eventName == "bundle-loading-bench.ready" &&
                    message.payload["caseName"] == page.case.name &&
                    listOf("moduleCount", "payloadLength", "checksum").all { key ->
                        (message.payload[key] as? Number)?.toLong() ==
                            (page.case.expectedPayload[key] as Number).toLong()
                    }
                if (accepted) {
                    requireNotNull(page).nativePayload.set(message.payload)
                    page.nativeSourcePageId.set(message.source.pageId)
                    page.nativeReady.countDown()
                }
                LynxRouterMessageReply(accepted, "真实Fixture与exact新页source核对")
            }
        }

        fun open(case: Case, separateActivity: Boolean = false,
            sameActivityConcurrent: Boolean = false, cancelBeforeFirstFrame: Boolean = false): Page {
            val hostActivity = if (separateActivity) {
                instrumentation.startActivitySync(
                    Intent(instrumentation.targetContext, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
                        .putExtra("lynx_shell.show_native_launcher", true),
                ) as MainActivity
            } else launcher
            val hostFrame = if (separateActivity) FrameLayout(hostActivity).also { frame ->
                onMain { hostActivity.setContentView(frame) }
            } else frame
            if (separateActivity) assertNotSame("并发Native source必须拥有独立Activity", launcher, hostActivity)
            val lease = requireNotNull(store.acquireCurrentBundleLease(scope, case.bundlePath))
            val logicalUrl = "assets://bundles/${case.bundlePath}"
            val provider = ShellTemplateProvider(hostActivity, preparedUrl = logicalUrl, preparedFile = lease.file)
            val pageId = "engine-reuse-${case.name}-${UUID.randomUUID()}"
            val row = linkedMapOf<String, Any?>(
                "testMethod" to name, "runLabel" to label, "caseName" to case.name,
                "pageId" to pageId, "lynxAppId" to manifest.lynxAppId,
                "releaseId" to manifest.releaseId, "bundlePath" to case.bundlePath,
                "bundleSha256" to lease.bundle.bundleSha256, "bundleSize" to lease.file.length(),
                "userIdentityEpoch" to 0L,
                "hostActivityObjectIdentity" to System.identityHashCode(hostActivity),
                "separateActivity" to separateActivity,
            )
            val page = Page(pageId, case, provider, lease, row, hostActivity, hostFrame, separateActivity)
            val pageInfo = LynxRouterPageInfo(pageId, pageId, case.bundlePath, "page")
            pages[pageId] = page
            rows += row
            val client = object : LynxViewClient() {
                override fun onFirstScreen() {
                    if (!page.destroyed.get()) {
                        page.sdkFirstScreenCount.incrementAndGet()
                        page.sdkFirstScreenNs.compareAndSet(0L, SystemClock.elapsedRealtimeNanos())
                        page.frameSource.compareAndSet(null, "SDK_FIRST_SCREEN")
                        page.firstScreenNs.compareAndSet(0L, SystemClock.elapsedRealtimeNanos())
                        page.firstScreen.countDown()
                    }
                }
                override fun onReceivedError(error: LynxError) {
                    if (!page.destroyed.get() && error.isFatal) {
                        page.fatal.set(error.toString())
                        page.firstScreen.countDown()
                        page.nativeReady.countDown()
                    }
                }
            }
            onMain {
                page.createdView = LynxContainerFactory.create(
                    activity = hostActivity,
                    request = LynxPageRequest(bundleUrl = logicalUrl, lynxAppId = manifest.lynxAppId,
                        bundleName = case.bundlePath, showToolbar = false),
                    templateProvider = provider,
                    lynxViewClient = client,
                    sidecarResources = lease.sidecars,
                    bundleMetadata = mapOf(
                        "lynxAppId" to manifest.lynxAppId, "bundleName" to case.bundlePath,
                        "releaseId" to manifest.releaseId, "source" to "ota_current",
                        "sha256" to lease.bundle.bundleSha256, "userIdentityEpoch" to 0L,
                    ),
                    preparedBundle = PreparedActivityBundle(
                        lynxAppId = manifest.lynxAppId, bundleName = case.bundlePath,
                        file = lease.file, releaseId = manifest.releaseId,
                        sha256 = lease.bundle.bundleSha256, source = "ota_current",
                        userIdentityEpoch = 0L, sidecarResources = lease.sidecars,
                    ),
                    pageInfo = pageInfo,
                )
                ShellMessageHub.register(pageInfo, hostActivity, page.view)
                if (sameActivityConcurrent) {
                    assertEquals("同Activity必须登记两个独立endpoint", pageInfo,
                        ShellMessageHub.pages().single { it.pageId == pageId })
                } else assertEquals("测试endpoint必须归自己Activity", pageId, ShellMessageHub.pageIdFor(hostActivity))
                hostFrame.addView(page.view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                page.renderStartNs.set(SystemClock.elapsedRealtimeNanos())
                page.view.renderTemplateUrl(logicalUrl, TemplateData.fromMap(emptyMap<String, Any>()))
                if (cancelBeforeFirstFrame) {
                    assertEquals("冷取消必须发生在首帧前", 1L, page.firstScreen.count)
                    page.identity = readIdentity(page.view)
                    page.row["cancelledBeforeFirstFrame"] = true
                    page.destroyed.set(true)
                    destroySdkViewOnMain(page)
                }
            }
            if (cancelBeforeFirstFrame) finishOwnedResources(page)
            return page
        }

        fun assertReady(page: Page) {
            assertTrue("${page.case.name} 真实SDK首屏未到达", page.firstScreen.await(30, TimeUnit.SECONDS))
            assertNull("${page.case.name} SDK fatal", page.fatal.get())
            assertTrue("${page.case.name} 新页Native ready未到达", page.nativeReady.await(30, TimeUnit.SECONDS))
            assertNull("${page.case.name} SDK fatal", page.fatal.get())
            assertNotNull("必须有正确真实Native payload", page.nativePayload.get())
            assertEquals("Native callback必须归新页exact source", page.pageId, page.nativeSourcePageId.get())
            val deadline = SystemClock.elapsedRealtime() + 30_000L
            var actual = ""
            while (SystemClock.elapsedRealtime() < deadline) {
                onMain { actual = page.view.findUIByIdSelector("bundle-bench-ready")?.accessibilityLabel?.toString().orEmpty() }
                if (actual == page.case.readyLabel) break
                assertNull("READY等待期间SDK fatal", page.fatal.get())
                SystemClock.sleep(30)
            }
            assertEquals("真实READY节点必须匹配", page.case.readyLabel, actual)
            onMain {
                assertTrue("真实View必须attach/layout", page.view.isAttachedToWindow && page.view.width > 0 && page.view.height > 0)
                val ready = requireNotNull(page.view.findUIByIdSelector("bundle-bench-ready"))
                assertTrue("真实READY节点必须有尺寸", ready.latestSize.x > 0 && ready.latestSize.y > 0)
                assertNull("真实READY不能伴随error节点", page.view.findUIByIdSelector("bundle-bench-error"))
                val identity = readIdentity(page.view)
                page.reusedIdentity = isGroupReused(page.view)
                assertTrue("每页必须有真实非零fresh native shell", identity.renderNativePtr != 0L)
                assertNull("setEnableCacheEngine(false)不得产生cached LynxEngine", identity.engine)
                assertNotNull("必须观察真实parsed TemplateBundle", identity.template)
                assertTrue("真实nativeTplPtr必须非零", identity.templateNativePtr != null && identity.templateNativePtr != 0L)
                page.identity = identity
                page.row.putAll(identity.toRow())
            }
            assertEquals("安全方案每页必须真实SDK首屏", "SDK_FIRST_SCREEN", page.frameSource.get())
            assertTrue("安全方案每页SDK首屏callback必须到达", page.sdkFirstScreenCount.get() > 0)
            page.row["templateGroupReused"] = page.reusedIdentity
            page.row["deviceApi"] = Build.VERSION.SDK_INT
            page.row["hardwareAccelerated"] = page.view.isHardwareAccelerated
            page.row["actualFirstFrameSource"] = page.frameSource.get()
            page.row["sdkFirstScreen"] = page.sdkFirstScreenCount.get() > 0
            page.row["sdkFirstScreenCount"] = page.sdkFirstScreenCount.get()
            page.row["renderStartElapsedRealtimeNs"] = page.renderStartNs.get()
            page.row["sdkFirstScreenElapsedRealtimeNs"] = page.sdkFirstScreenNs.get().takeIf { it != 0L }
            page.row["renderToSdkFirstScreenNs"] = page.sdkFirstScreenNs.get().takeIf { it != 0L }?.minus(page.renderStartNs.get())
            page.row["renderToActualFirstFrameNs"] = page.firstScreenNs.get() - page.renderStartNs.get()
            page.row["readyLabel"] = actual
            page.row["nativeReadyPayload"] = page.nativePayload.get()
            page.row["nativeSourcePageId"] = page.nativeSourcePageId.get()
            persist()
            record("${page.case.name} page=${page.pageId} template=${page.row["templateObjectIdentity"]} tplPtr=${page.row["templateNativePtr"]} shellPtr=${page.row["freshNativeShellPtr"]} READY=$actual")
        }

        fun destroy(page: Page) {
            if (!page.destroyed.compareAndSet(false, true)) return
            try {
                onMain { destroySdkViewOnMain(page) }
            } finally {
                finishOwnedResources(page)
            }
            instrumentation.waitForIdleSync()
        }

        private fun destroySdkViewOnMain(page: Page) {
            ShellMessageHub.unregister(page.pageId)
            page.createdView?.let { view ->
                page.hostFrame.removeView(view)
                destroyView.invoke(LynxShell, view)
            }
            page.identity?.template?.let { page.row["templateNativePtrAfterDestroy"] = it.nativePtr }
            if (page.ownsActivity) page.hostActivity.finish()
        }

        private fun finishOwnedResources(page: Page) {
            page.provider.close()
            page.lease.close()
            pages.remove(page.pageId, page)
            page.row["destroyPath"] = "LynxShell.destroyView"
            page.row["pageLeaseClosed"] = true
            persist()
        }

        fun releaseSecondaryHostForGcProbe(case: Case): FormerHostProbe {
            val page = open(case, separateActivity = true)
            assertReady(page)
            val template = requireNotNull(requireNotNull(page.identity).template)
            val weakHost = WeakReference(page.hostActivity)
            val hostIdentity = System.identityHashCode(page.hostActivity)
            destroy(page)
            assertFalse("Fixture map不得保留旧Page/Activity", pages.containsKey(page.pageId))
            // 返回值仅含WeakHost、数字和parsedTemplate；不持旧Engine/Page/View/provider。
            return FormerHostProbe(weakHost, hostIdentity, template)
        }

        fun addDiagnostic(row: MutableMap<String, Any?>) { rows += row; persist() }

        fun captureFormerHostHeap(basename: String = "former-host.hprof"): File {
            val heap = File(results, basename)
            Debug.dumpHprofData(heap.absolutePath)
            assertTrue("HPROF必须实际落盘且非空", heap.isFile && heap.length() > 0L)
            return heap
        }

        fun persist() { File(results, "results.json").writeText(OtaJson.stringify(rows)) }

        fun close() {
            try { pages.values.forEach(::destroy) } finally {
                onMain { LynxRouter.setMessageHandler(null) }
            }
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
        val firstScreen = CountDownLatch(1)
        val renderStartNs = AtomicLong()
        val firstScreenNs = AtomicLong()
        val sdkFirstScreenNs = AtomicLong()
        val sdkFirstScreenCount = AtomicInteger()
        val frameSource = AtomicReference<String?>()
        var reusedIdentity = false
        val nativeReady = CountDownLatch(1)
        val fatal = AtomicReference<String?>()
        val nativePayload = AtomicReference<Map<String, Any?>?>()
        val nativeSourcePageId = AtomicReference<String?>()
        val destroyed = AtomicBoolean(false)
        var identity: TemplateIdentity? = null
    }

    private data class TemplateIdentity(val template: TemplateBundle?, val templateNativePtr: Long?,
        val renderNativePtr: Long, val engine: Any?) {
        fun toRow(): Map<String, Any?> = mapOf("templateObjectIdentity" to template?.let(System::identityHashCode),
            "templateNativePtr" to templateNativePtr, "freshNativeShellPtr" to renderNativePtr,
            "cachedEnginePresent" to (engine != null))
    }

    private data class FormerHostProbe(val host: WeakReference<MainActivity>, val hostIdentity: Int, val template: TemplateBundle)

    private fun readIdentity(view: LynxView): TemplateIdentity {
        val render = requireNotNull(LynxView::class.java.getDeclaredField("mLynxTemplateRender")
            .apply { isAccessible = true }.get(view))
        val engine = render.javaClass.getDeclaredField("mLynxEngineRef").apply { isAccessible = true }.get(render)
        val renderPtr = render.javaClass.getDeclaredField("mNativePtr").apply { isAccessible = true }.getLong(render)
        val template = groupFor(view)?.templateBundleNonBlocking
        return TemplateIdentity(template, template?.nativePtr, renderPtr, engine)
    }

    private fun groupFor(view: LynxView): ILynxViewGroup? {
        val cache = Class.forName("com.example.lynxshell.container.LynxTemplateGroupCache")
        val instance = cache.getField("INSTANCE").get(null)
        val registrations = cache.getDeclaredField("registrations").apply { isAccessible = true }.get(instance) as Map<*, *>
        val registration = registrations[view] ?: return null
        val lease = registration.javaClass.getDeclaredField("lease").apply { isAccessible = true }.get(registration)
        val slot = lease.javaClass.getMethod("getValue").invoke(lease)
        return slot.javaClass.getMethod("getGroup").invoke(slot) as ILynxViewGroup
    }

    private fun isGroupReused(view: LynxView): Boolean {
        val cache = Class.forName("com.example.lynxshell.container.LynxTemplateGroupCache")
        val instance = cache.getField("INSTANCE").get(null)
        return cache.getDeclaredMethod("isReused", LynxView::class.java).invoke(instance, view) as Boolean
    }

    private val destroyView by lazy {
        LynxShell::class.java.declaredMethods.single {
            it.name.startsWith("destroyView") && it.parameterTypes.contentEquals(arrayOf(LynxView::class.java))
        }.apply { isAccessible = true }
    }

    private fun record(message: String) {
        instrumentation.sendStatus(0, Bundle().apply { putString("stream", "\nLynxTemplateGroupReuse: $message\n") })
    }

    private fun onMain(block: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync { try { block() } catch (error: Throwable) { failure.set(error) } }
        failure.get()?.let { throw it }
    }

    private data class Case(val name: String, val bundlePath: String, val readyLabel: String,
        val expectedPayload: Map<String, Any?>)
}
