package com.example.lynxshell.sample

import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.view.ViewGroup
import android.widget.FrameLayout
import com.example.lynxshell.LynxShell
import com.example.lynxshell.bridge.LynxRouterPageInfo
import com.example.lynxshell.container.LynxContainerFactory
import com.example.lynxshell.container.LynxFirstFrameSource
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.ota.PreparedActivityBundle
import com.example.lynxshell.resource.ShellTemplateProvider
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateData
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.ota.android.sdk.OtaJson
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** 静态Bundle没有effect/state/native任务，用于验证warm页无需后续业务脏更新也能拿到真实frame收据。 */
class StaticEngineWarmFrameTest : InstrumentationTestCase() {
    fun testStaticCurrentRootUsesFreshInputsAndGetsWarmCommittedFrameWithoutBusinessMutation() {
        val context = instrumentation.targetContext
        assertEquals("只允许隔离验收App", "com.hugboga.custom.otae2e", context.packageName)
        val input = File(context.filesDir, "engine-reuse-static")
        val metadata = OtaJson.asObject(OtaJson.parse(File(input, "fixture-metadata.json").readText()), "staticFixture")
        assertEquals("ENGINE_REUSE_STATIC_V1", metadata["fixture"])
        val checks = OtaJson.asObject(metadata["staticSourceChecks"], "staticSourceChecks")
        assertEquals(true, checks["noEffects"])
        assertEquals(true, checks["noState"])
        assertEquals(true, checks["noNative"])
        assertEquals(true, checks["noTimers"])
        val artifact = OtaJson.asObject(metadata["bundle"], "bundle")
        val bundle = File(input, artifact["path"] as String)
        val bytes = bundle.readBytes()
        assertEquals((artifact["size"] as Number).toInt(), bytes.size)
        val sha = sha256(bytes)
        assertEquals(artifact["sha256"], sha)

        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("lynx_shell.show_native_launcher", true),
        ) as MainActivity
        val frame = FrameLayout(activity)
        val output = File(context.filesDir, "engine-reuse-static/results/$name").also {
            assertTrue(it.isDirectory || it.mkdirs())
        }
        val rows = mutableListOf<MutableMap<String, Any?>>()
        fun persist() = File(output, "results.json").writeText(OtaJson.stringify(rows.map { LinkedHashMap(it) }))
        onMain { activity.setContentView(frame); LynxShell.onTrimMemory(10) }

        fun open(marker: String): Page {
            val id = "static-engine-${UUID.randomUUID()}"
            val initData = linkedMapOf<String, Any>("marker" to marker)
            val globals = linkedMapOf<String, Any>("marker" to "global-$marker", "probePageId" to id)
            val url = "assets://engine-reuse-static/${bundle.name}"
            val provider = ShellTemplateProvider(activity, preparedUrl = url, preparedFile = bundle)
            val page = Page(id, marker, provider, linkedMapOf(
                "pageId" to id,
                "marker" to marker,
                "bundlePath" to bundle.name,
                "bundleSha256" to "sha256:$sha",
                "bundleSize" to bytes.size,
                "businessStateMutationInjectedByTest" to false,
            ))
            rows += page.row
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
                    override fun onReceivedError(error: LynxError) {
                        if (!page.destroyed.get() && error.isFatal) {
                            page.fatal.set(error.toString())
                            page.firstContent.countDown()
                        }
                    }
                }
                page.createdView = LynxContainerFactory.create(
                    activity = activity,
                    request = LynxPageRequest(
                        bundleUrl = url,
                        lynxAppId = STATIC_APP_ID,
                        bundleName = bundle.name,
                        showToolbar = false,
                        initDataJson = OtaJson.stringify(initData),
                        globalPropsJson = OtaJson.stringify(globals),
                    ),
                    templateProvider = provider,
                    lynxViewClient = client,
                    bundleMetadata = mapOf(
                        "lynxAppId" to STATIC_APP_ID,
                        "bundleName" to bundle.name,
                        "releaseId" to STATIC_RELEASE,
                        "source" to "ota_current",
                        "sha256" to "sha256:$sha",
                        "userIdentityEpoch" to 0L,
                    ),
                    preparedBundle = PreparedActivityBundle(
                        lynxAppId = STATIC_APP_ID,
                        bundleName = bundle.name,
                        file = bundle,
                        releaseId = STATIC_RELEASE,
                        sha256 = "sha256:$sha",
                        source = "ota_current",
                        userIdentityEpoch = 0L,
                    ),
                    pageInfo = LynxRouterPageInfo(id, id, bundle.name, "page"),
                    onCachedFrame = { source ->
                        if (!page.destroyed.get()) {
                            page.cachedFrameCount.incrementAndGet()
                            page.frameSource.compareAndSet(null, source.name)
                            page.firstContent.countDown()
                        }
                    },
                )
                page.context = page.view.lynxContext
                frame.addView(page.view, FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
                ))
                page.renderStartNs.set(SystemClock.elapsedRealtimeNanos())
                page.view.renderTemplateUrl(url, TemplateData.fromMap(initData))
            }
            return page
        }

        fun assertReady(page: Page, warm: Boolean) {
            assertTrue("真实首内容回执未到达", page.firstContent.await(30, TimeUnit.SECONDS))
            assertNull("SDK fatal", page.fatal.get())
            val expected = "static-engine:marker=${page.marker}:global=global-${page.marker}:page=${page.pageId}"
            val deadline = SystemClock.elapsedRealtime() + 30_000L
            var actual = ""
            var readyAndLaidOut = false
            while (SystemClock.elapsedRealtime() < deadline) {
                onMain {
                    val node = currentRootUi(page.view, STATIC_READY_SELECTOR)
                    if (node == null) {
                        actual = ""
                        readyAndLaidOut = false
                    } else {
                        actual = node.accessibilityLabel?.toString().orEmpty()
                        page.row["currentRootReadyIdentity"] = System.identityHashCode(node)
                        page.row["currentRootReadyAccessibilityLabel"] = actual
                        page.row["currentRootReadyLayoutText"] = (node as? com.lynx.tasm.behavior.ui.text.IUIText)?.textLayout?.text?.toString()
                        page.row["currentRootReadyRect"] = node.rectToWindow.toShortString()
                        readyAndLaidOut = actual == expected && node.latestSize.x > 0 && node.latestSize.y > 0 &&
                            page.view.isAttachedToWindow && page.view.width > 0 && page.view.height > 0
                    }
                }
                if (readyAndLaidOut || page.fatal.get() != null) break
                SystemClock.sleep(30)
            }
            assertNull("等待静态READY期间SDK fatal", page.fatal.get())
            assertEquals("当前Root必须显示本次init/global输入", expected, actual)
            assertTrue("当前Root静态READY必须已layout并且宿主attach", readyAndLaidOut)
            onMain {
                val render = readField(page.view, "mLynxTemplateRender", LynxView::class.java)
                page.engine = requireNotNull(readNullableField(render, "mLynxEngineRef"))
                page.enginePtr = enginePtr(requireNotNull(page.engine))
                page.renderPtr = render.javaClass.getDeclaredField("mNativePtr").apply { isAccessible = true }.getLong(render)
                page.groupReused = isGroupReused(page.view)
            }
            assertTrue("真实Engine pointer必须非零", page.enginePtr != 0L)
            assertTrue("真实native shell必须非零", page.renderPtr != 0L)
            assertEquals("Group复用状态", warm, page.groupReused)
            if (warm) {
                val expectedFrame = if (Build.VERSION.SDK_INT >= 29 && page.view.isHardwareAccelerated)
                    LynxFirstFrameSource.CACHED_FRAME_COMMITTED.name else LynxFirstFrameSource.CACHED_DRAW_CYCLE.name
                assertEquals("静态warm页必须收到typed真实frame", expectedFrame, page.frameSource.get())
                assertEquals("静态warm页不得伪造SDK冷首屏", 0, page.sdkFirstScreenCount.get())
                assertEquals("静态warm页frame收据必须恰好一次", 1, page.cachedFrameCount.get())
            } else {
                assertEquals("静态cold页必须用SDK首屏", "SDK_FIRST_SCREEN", page.frameSource.get())
                assertEquals(1, page.sdkFirstScreenCount.get())
                assertEquals(0, page.cachedFrameCount.get())
            }
            page.readyValidatedNs.set(SystemClock.elapsedRealtimeNanos())
            page.row["engineObjectIdentity"] = System.identityHashCode(requireNotNull(page.engine))
            page.row["engineNativePointer"] = page.enginePtr
            page.row["nativeRenderPointer"] = page.renderPtr
            page.row["groupLeaseReused"] = page.groupReused
            page.row["frameSource"] = page.frameSource.get()
            page.row["factoryToCurrentRootReadyNs"] = page.readyValidatedNs.get() - page.factoryStartNs.get()
            page.row["renderToCurrentRootReadyNs"] = page.readyValidatedNs.get() - page.renderStartNs.get()
            page.row["currentRootReadyTimingIncludesPollingAndScheduling"] = true
            page.row["currentRootReadyTimingIsNotP95"] = true
            persist()
        }

        fun destroy(page: Page) {
            if (!page.destroyed.compareAndSet(false, true)) return
            try {
                onMain { frame.removeView(page.view); destroyView.invoke(LynxShell, page.view) }
            } finally {
                page.provider.close()
            }
            instrumentation.waitForIdleSync()
        }

        var first: Page? = null
        var second: Page? = null
        try {
            first = open("STATIC_A")
            assertReady(first, warm = false)
            val firstEngine = requireNotNull(first.engine)
            val firstPtr = first.enginePtr
            val firstContext = requireNotNull(first.context)
            destroy(first)
            assertEquals("A退出后必须保留一次静态warm候选", firstPtr, enginePtr(firstEngine))

            second = open("STATIC_B")
            assertReady(second, warm = true)
            assertSame("静态B必须复用A的Java Engine", firstEngine, second.engine)
            assertEquals("静态B必须复用A的native Engine pointer", firstPtr, second.enginePtr)
            assertNotSame("静态B必须有新View", first.view, second.view)
            assertNotSame("静态B必须有新Context", firstContext, requireNotNull(second.context))
            second.row["sameOriginalEngine"] = true
            second.row["sameOriginalPointer"] = true
            second.row["freshInputsValidatedByCurrentRoot"] = true
            persist()
            destroy(second)
            assertEquals("静态warm页退出后必须释放Group Engine", 0L, enginePtr(firstEngine))
        } finally {
            second?.let(::destroy)
            first?.let(::destroy)
            onMain { LynxShell.onTrimMemory(10); activity.finish() }
            persist()
        }
    }

    private class Page(
        val pageId: String,
        val marker: String,
        val provider: ShellTemplateProvider,
        val row: MutableMap<String, Any?>,
    ) {
        var createdView: LynxView? = null
        val view: LynxView get() = requireNotNull(createdView)
        var context: Any? = null
        var engine: Any? = null
        var enginePtr = 0L
        var renderPtr = 0L
        var groupReused = false
        val firstContent = CountDownLatch(1)
        val sdkFirstScreenCount = AtomicInteger()
        val cachedFrameCount = AtomicInteger()
        val frameSource = AtomicReference<String?>()
        val factoryStartNs = AtomicLong()
        val renderStartNs = AtomicLong()
        val readyValidatedNs = AtomicLong()
        val fatal = AtomicReference<String?>()
        val destroyed = AtomicBoolean(false)
    }

    private fun currentRootUi(view: LynxView, selector: String): LynxBaseUI? {
        fun collect(node: LynxBaseUI?): List<LynxBaseUI> = if (node == null) emptyList() else listOf(node) + node.children.flatMap(::collect)
        val matches = collect(view.lynxUIRoot).filter { it.idSelector == selector }
        assertEquals("当前Root静态selector必须唯一", 1, matches.size)
        return matches.single()
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

    private companion object {
        const val STATIC_APP_ID = "10030073"
        const val STATIC_RELEASE = "r20261010_static_001"
        const val STATIC_READY_SELECTOR = "engine-static-ready"
    }
}
