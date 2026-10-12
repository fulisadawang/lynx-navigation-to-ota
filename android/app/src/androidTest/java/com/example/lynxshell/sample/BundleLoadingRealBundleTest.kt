package com.example.lynxshell.sample

import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
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
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.resource.ShellTemplateProvider
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateData
import com.ota.android.sdk.ContentAddressedOtaStore
import com.ota.android.sdk.OtaJson
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.ReleaseTransaction
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** 同一真实 Rspeedy fixture 分别装到 baseline/optimized APK，使用生产 Provider 与 Fetchers。 */
class BundleLoadingRealBundleTest : InstrumentationTestCase() {
    fun testRealFixtureSmallLargeAndAsyncRender() {
        val context = instrumentation.targetContext
        assertEquals("只允许隔离的验收 App", "com.hugboga.custom.otae2e", context.packageName)
        val label = (instrumentation as InstrumentationTestRunner).arguments.getString("runLabel")
            ?: error("必须提供 runLabel=baseline 或 optimized")
        require(label == "baseline" || label == "optimized")
        // 主流程从受保护API取Manifest后写入无token描述，不将凭证放instrumentation参数。
        val fixtureFile = File(context.filesDir, "bundle-loading-fixture.json")
        val description = OtaJson.asObject(OtaJson.parse(fixtureFile.readText()), "BundleLoadingFixture")
        val manifest = OtaModels.ReleaseManifest.fromJsonMap(OtaJson.asObject(description["manifest"], "manifest"), requireStatus = true)
        assertEquals("10030071", manifest.lynxAppId)
        val cases = OtaJson.asArray(description["cases"], "cases").map { raw ->
            val value = OtaJson.asObject(raw, "case")
            Case(value["caseName"] as String, value["path"] as String, value["expectedReadyLabel"] as String,
                OtaJson.asObject(value["expectedReadyPayload"], "expectedReadyPayload"))
        }
        assertEquals(listOf("small", "large", "async"), cases.map { it.name })
        val storeRoot = File(context.cacheDir, "real-bundle-loading-${UUID.randomUUID()}")
        val results = File(context.filesDir, "bundle-loading-results/$label").also { assertTrue(it.isDirectory || it.mkdirs()) }
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
        val observations = mutableListOf<Map<String, Any?>>()
        val destroyView = LynxShell::class.java.declaredMethods.single {
            it.name.startsWith("destroyView") && it.parameterTypes.contentEquals(arrayOf(LynxView::class.java))
        }.apply { isAccessible = true }
        try {
            for (case in cases) {
                val lease = requireNotNull(store.acquireCurrentBundleLease(scope, case.bundlePath))
                val logicalUrl = "assets://bundles/${case.bundlePath}"
                val provider = ShellTemplateProvider(launcher, preparedUrl = logicalUrl, preparedFile = lease.file)
                val generation = UUID.randomUUID().toString()
                val pageId = "bundle-bench-$label-${case.name}-$generation"
                var view: LynxView? = null
                var observation: MutableMap<String, Any?>? = null
                val destroying = AtomicBoolean(false)
                val lateCallbacks = AtomicInteger()
                val rejectedMessages = AtomicInteger()
                try {
                    val reader = measureReader(provider, lease.file)
                    val firstScreen = CountDownLatch(1)
                    val fatal = AtomicReference<String?>()
                    val nativePayload = AtomicReference<Map<String, Any?>?>()
                    onMain {
                        LynxRouter.setMessageHandler { message ->
                            val matches = !destroying.get() && message.source.pageId == pageId &&
                                message.eventName == "bundle-loading-bench.ready" &&
                                message.payload["caseName"] == case.name &&
                                listOf("moduleCount", "payloadLength", "checksum").all { key ->
                                    (message.payload[key] as? Number)?.toDouble() ==
                                        (case.expectedPayload[key] as Number).toDouble()
                                }
                            if (matches) nativePayload.set(message.payload)
                            else rejectedMessages.incrementAndGet()
                            record("native-event source=${message.source.pageId} accepted=$matches payload=${message.payload}")
                            LynxRouterMessageReply(accepted = matches, message = "Bundle benchmark payload核对")
                        }
                    }
                    val client = object : LynxViewClient() {
                        override fun onFirstScreen() {
                            if (destroying.get()) lateCallbacks.incrementAndGet() else firstScreen.countDown()
                        }
                        override fun onReceivedError(error: LynxError) {
                            if (destroying.get()) { lateCallbacks.incrementAndGet(); return }
                            if (error.isFatal) { fatal.set(error.toString()); firstScreen.countDown() }
                        }
                    }
                    val started = System.nanoTime()
                    onMain {
                        val created = LynxContainerFactory.create(
                            activity = launcher,
                            request = LynxPageRequest(bundleUrl = logicalUrl, lynxAppId = manifest.lynxAppId,
                                bundleName = case.bundlePath, showToolbar = false),
                            templateProvider = provider, lynxViewClient = client,
                            sidecarResources = lease.sidecars,
                            bundleMetadata = mapOf("lynxAppId" to manifest.lynxAppId, "bundleName" to case.bundlePath,
                                "releaseId" to manifest.releaseId, "source" to "ota_current", "sha256" to lease.bundle.bundleSha256),
                        )
                        view = created
                        ShellMessageHub.register(LynxRouterPageInfo(pageId, pageId, case.bundlePath, "page"), launcher, created)
                        frame.addView(created, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                        created.renderTemplateUrl(logicalUrl, TemplateData.fromMap(emptyMap<String, Any>()))
                    }
                    assertTrue("${case.name} 真实SDK首屏未到达", firstScreen.await(30, TimeUnit.SECONDS))
                    val firstScreenNs = System.nanoTime() - started
                    assertNull("${case.name} SDK fatal", fatal.get())
                    val ready = awaitReady(requireNotNull(view), case.readyLabel, fatal, results)
                    assertEquals(case.readyLabel, ready)
                    assertNotNull("真实Native ready payload必须被宿主核对接受", nativePayload.get())
                    onMain {
                        assertTrue("真实View需attach与layout", view!!.isAttachedToWindow && view!!.width > 0 && view!!.height > 0)
                        val readyUI = requireNotNull(view!!.findUIByIdSelector("bundle-bench-ready"))
                        assertTrue("真实READY节点必须完成layout", readyUI.latestSize.x > 0 && readyUI.latestSize.y > 0)
                        assertNull("READY不能同时有错误节点", view!!.findUIByIdSelector("bundle-bench-error"))
                    }
                    awaitDrawFrames(requireNotNull(view))
                    val screenshot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
                    File(results, "${case.name}.png").outputStream().use {
                        assertTrue(screenshot.compress(Bitmap.CompressFormat.PNG, 100, it))
                    }
                    screenshot.recycle()
                    val row = linkedMapOf<String, Any?>("caseName" to case.name, "runLabel" to label,
                        "generation" to generation, "pageId" to pageId,
                        "releaseId" to manifest.releaseId, "bundlePath" to case.bundlePath,
                        "bundleSha256" to lease.bundle.bundleSha256, "bundleSize" to lease.file.length(),
                        "readyLabel" to ready, "sdkFirstScreen" to true, "sdkFatal" to fatal.get(),
                        "readyLabelSource" to "LynxBaseUI.accessibilityLabel",
                        "nativeReadyPayload" to nativePayload.get(),
                        "firstScreenNs" to firstScreenNs, "asyncEntryCount" to lease.sidecars?.entries?.size,
                        "reader" to reader)
                    observations += row
                    observation = row
                    record("$label ${case.name} size=${lease.file.length()} READY=$ready firstScreenNs=$firstScreenNs reader=$reader")
                    File(results, "results.json").writeText(OtaJson.stringify(observations))
                } finally {
                    destroying.set(true)
                    onMain {
                        ShellMessageHub.unregister(pageId)
                        LynxRouter.setMessageHandler(null)
                        view?.let { frame.removeView(it); destroyView.invoke(LynxShell, it) }
                    }
                    provider.close()
                    lease.close()
                    instrumentation.waitForIdleSync()
                    observation?.let {
                        it["destroyPath"] = "LynxShell.destroyView"
                        it["lateCallbacksAfterMainIdle"] = lateCallbacks.get()
                        it["rejectedMessages"] = rejectedMessages.get()
                        File(results, "results.json").writeText(OtaJson.stringify(observations))
                    }
                }
            }
        } finally {
            onMain { launcher.finish() }
            storeRoot.deleteRecursively()
        }
    }

    private fun measureReader(provider: ShellTemplateProvider, file: File): Map<String, Long> {
        val method = ShellTemplateProvider::class.java.getDeclaredMethod("loadFile", File::class.java).apply { isAccessible = true }
        repeat(3) { assertEquals(file.length().toInt(), (method.invoke(provider, file) as ByteArray).size) }
        val allocatedBefore = requireNotNull(Debug.getRuntimeStat("art.gc.bytes-allocated")).toLong()
        val started = System.nanoTime()
        repeat(5) { assertEquals(file.length().toInt(), (method.invoke(provider, file) as ByteArray).size) }
        val elapsed = System.nanoTime() - started
        val allocated = requireNotNull(Debug.getRuntimeStat("art.gc.bytes-allocated")).toLong() - allocatedBefore
        return mapOf("repetitions" to 5L, "allocatedApprox" to allocated, "elapsedNs" to elapsed)
    }

    private fun awaitReady(view: LynxView, expected: String, fatal: AtomicReference<String?>, results: File): String {
        val deadline = SystemClock.elapsedRealtime() + 30_000L
        var actual = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            assertNull("ready 前出现SDK fatal", fatal.get())
            onMain { actual = view.findUIByIdSelector("bundle-bench-ready")?.accessibilityLabel?.toString().orEmpty() }
            if (actual == expected) return actual
            SystemClock.sleep(30)
        }
        onMain {
            val readyUI = view.findUIByIdSelector("bundle-bench-ready")
            val errorUI = view.findUIByIdSelector("bundle-bench-error")
            record("READY-diagnostic UI=${readyUI?.javaClass?.name} uiLabel=${readyUI?.accessibilityLabel} viewLabel=$actual errorUI=${errorUI?.javaClass?.name} errorLabel=${errorUI?.accessibilityLabel}")
        }
        instrumentation.uiAutomation.takeScreenshot()?.let { screenshot ->
            File(results, "failure.png").outputStream().use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) }
            screenshot.recycle()
        }
        fail("真实View READY不匹配 expected=$expected actual=$actual")
        return actual
    }

    private fun record(message: String) {
        instrumentation.sendStatus(0, Bundle().apply { putString("stream", "\nBundleLoadingRealBundle: $message\n") })
    }

    private fun awaitDrawFrames(view: LynxView) {
        val frames = CountDownLatch(1)
        onMain {
            view.invalidate()
            view.postOnAnimation { view.postOnAnimation { frames.countDown() } }
        }
        assertTrue("READY 后实际绘制帧未到达", frames.await(10, TimeUnit.SECONDS))
    }

    private fun onMain(block: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync { try { block() } catch (error: Throwable) { failure.set(error) } }
        failure.get()?.let { throw it }
    }

    private data class Case(val name: String, val bundlePath: String, val readyLabel: String,
        val expectedPayload: Map<String, Any?>)
}
