package com.example.lynxshell.sample

import android.content.Intent
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.test.InstrumentationTestRunner
import android.view.ViewGroup
import android.view.MotionEvent
import android.widget.FrameLayout
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.LynxShell
import com.example.lynxshell.bridge.LynxRouterMessageReply
import com.example.lynxshell.bridge.LynxRouterPageInfo
import com.example.lynxshell.bridge.ShellMessageHub
import com.example.lynxshell.resource.ShellTemplateProvider
import com.example.lynxshell.runtime.XElementRuntime
import com.lynx.tasm.LynxEnv
import com.lynx.tasm.DefaultLogicExecutor
import com.lynx.tasm.EmbeddedMode
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewBuilder
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateBundle
import com.lynx.tasm.TemplateData
import com.lynx.tasm.ThreadStrategyForRendering
import com.lynx.tasm.group.LynxViewGroupBuilder
import com.lynx.tasm.behavior.ui.text.IUIText
import com.lynx.tasm.behavior.ui.LynxBaseUI
import com.ota.android.sdk.ContentAddressedOtaStore
import com.ota.android.sdk.OtaJson
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.ReleaseTransaction
import java.io.File
import java.io.FileOutputStream
import android.graphics.Bitmap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

/** 诊断实验只操作测试的 Group；安全生产 Factory 与冻结输入保持原样。 */
class EngineReusePublicApiOrderingTest : InstrumentationTestCase() {
    fun testThreeFreshPagesOnSameEngineWithPublicApiOrdering() {
        val ctx = instrumentation.targetContext
        assertEquals("com.hugboga.custom.otae2e", ctx.packageName)
        val order = (instrumentation as InstrumentationTestRunner).arguments.getString("ordering") ?: "pre-reload"
        require(order in setOf("pre-reload", "normal", "post-reload", "logic", "paired"))
        val description = OtaJson.asObject(OtaJson.parse(File(ctx.filesDir, "engine-reuse-fixture.json").readText()), "fixture")
        val manifest = OtaModels.ReleaseManifest.fromJsonMap(OtaJson.asObject(description["manifest"], "manifest"), true)
        val path = "EngineReuseStateProbe.lynx.bundle"
        val scope = ReleaseTransaction.ReleaseScope.fromManifest(manifest)
        val storeDir = File(ctx.cacheDir, "engine-order-${UUID.randomUUID()}")
        val store = ContentAddressedOtaStore(storeDir, allowLocalHTTPForTest = true)
        store.reserveSidecars(manifest.lynxAppId, manifest.asyncBundleManifest).use {
            store.stageAsyncResources(manifest)
            store.install(ReleaseTransaction.InstallRequest(scope, manifest))
        }
        val lease = requireNotNull(store.acquireCurrentBundleLease(scope, path))
        val activity = instrumentation.startActivitySync(Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("lynx_shell.show_native_launcher", true)) as MainActivity
        val frame = FrameLayout(activity)
        main { activity.setContentView(frame); LynxViewBuilder() }
        assertTrue("Native库须在后台解析前完成加载", LynxEnv.inst().isNativeLibraryLoaded)
        val template = TemplateBundle.fromTemplate(lease.file.readBytes())
        assertTrue(template.errorMessage, template.isValid)
        val url = "assets://bundles/$path"
        lateinit var group: com.lynx.tasm.group.ILynxViewGroup
        main {
            val builder = LynxViewGroupBuilder().setContext(ctx.applicationContext).setUrl(url)
                .setTemplateBundle(template).setEnableCacheEngine(true).setEnableSharedModule(false)
            if (order == "logic") { builder.setEmbeddedMode(EmbeddedMode.EMBEDDED_MODE_BASE); builder.setLogicExecutor(DefaultLogicExecutor()) }
            group = builder.build()
        }
        val events = ConcurrentHashMap<String, CopyOnWriteArrayList<Map<String, Any?>>>()
        val rows = CopyOnWriteArrayList<Map<String, Any?>>()
        val output = File(ctx.filesDir, "engine-ordering-results/$order").also { it.mkdirs() }
        fun persist() = File(output, "results.json").writeText(OtaJson.stringify(rows.toList()))
        main { LynxRouter.setMessageHandler { message ->
            events[message.source.pageId]?.add(message.payload)
            println("EngineOrdering event=${message.source.pageId} payload=${OtaJson.stringify(message.payload)}")
            persist()
            LynxRouterMessageReply(events.containsKey(message.source.pageId), "真实source诊断")
        } }
        var firstEngine: Any? = null
        var firstPtr = 0L
        var current: LynxView? = null
        var currentProvider: ShellTemplateProvider? = null
        var currentId = ""
        val destroy = LynxShell.javaClass.declaredMethods.single { it.name.startsWith("destroyView") && it.parameterTypes.contentEquals(arrayOf(LynxView::class.java)) }
            .also { it.isAccessible = true }
        try {
            val markers = if (order == "paired") (0..9).map { "order-${'A' + it}" } else listOf("order-A", "order-B", "order-C")
            for ((index, marker) in markers.withIndex()) {
                val cold = index == 0 || (order == "paired" && index % 2 == 0)
                if (cold && index > 0) {
                    val nextTemplate = TemplateBundle.fromTemplate(lease.file.readBytes())
                    assertTrue(nextTemplate.errorMessage, nextTemplate.isValid)
                    main { group = LynxViewGroupBuilder().setContext(ctx.applicationContext).setUrl(url)
                        .setTemplateBundle(nextTemplate).setEnableCacheEngine(true).setEnableSharedModule(false).build() }
                }
                val id = "engine-order-${UUID.randomUUID()}"
                currentId = id
                events[id] = CopyOnWriteArrayList()
                val data = linkedMapOf<String, Any>("marker" to marker)
                val props = linkedMapOf<String, Any>("marker" to "global-$marker", "probePageId" to id)
                if (cold) { data["oldOnly"] = "old"; props["oldOnly"] = "old" }
                val provider = ShellTemplateProvider(ctx, preparedUrl = url, preparedFile = lease.file)
                currentProvider = provider
                val fatal = AtomicReference<String?>()
                val calls = CopyOnWriteArrayList<String>()
                lateinit var view: LynxView
                main {
                    val builder = LynxViewBuilder().setTemplateProvider(provider).setLynxViewGroup(group)
                        .setThreadStrategyForRendering(ThreadStrategyForRendering.MOST_ON_TASM)
                    XElementRuntime.install(builder)
                    view = builder.build(activity)
                    current = view
                    view.addLynxViewClient(object : LynxViewClient() {
                        override fun onRuntimeReady() { calls.add("runtimeReady") }
                        override fun onPageStart(url: String?) { calls.add("pageStart") }
                        override fun onFirstScreen() { calls.add("sdkFirstScreen") }
                        override fun onPageUpdate() { calls.add("pageUpdate") }
                        override fun onLoadSuccess() { calls.add("loadSuccess") }
                        override fun onReceivedError(error: LynxError) { if (error.isFatal) fatal.set(error.msg) }
                    })
                    view.updateGlobalProps(TemplateData.fromMap(props))
                    ShellMessageHub.register(LynxRouterPageInfo(id, id, path, "android_activity"), activity, view)
                    if (!cold) {
                        if (order == "paired") {
                            view.resetData(TemplateData.fromMap(data))
                            view.reloadTemplate(TemplateData.fromMap(data), TemplateData.fromMap(props))
                        }
                        view.lynxUIRenderer().lynxUIOwner().rootUI.rebuildViewTree()
                    }
                    frame.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                    if (index > 0 && order == "pre-reload") {
                        view.resetData(TemplateData.fromMap(data))
                        view.reloadTemplate(TemplateData.fromMap(data), TemplateData.fromMap(props))
                    }
                    view.renderTemplateUrl(url, TemplateData.fromMap(data))
                    if (index > 0 && order == "post-reload") {
                        view.resetData(TemplateData.fromMap(data))
                        view.reloadTemplate(TemplateData.fromMap(data), TemplateData.fromMap(props))
                    }
                }
                val expected = "engine-reuse:state:page=$id:marker=$marker:counter=0:mount=1:oldOnly=$cold:globalOldOnly=$cold"
                var actual = ""
                var accessibilityLabel = ""
                var lookupText = ""
                var currentNodes: List<Map<String, Any?>> = emptyList()
                val end = SystemClock.elapsedRealtime() + 8000
                while (SystemClock.elapsedRealtime() < end) {
                    main {
                        val ui = view.findUIByIdSelector("engine-reuse-ready")
                        lookupText = (ui as? IUIText)?.textLayout?.text?.toString().orEmpty()
                        accessibilityLabel = ui?.accessibilityLabel?.toString().orEmpty()
                        val nodes = tree(view.lynxUIRenderer().lynxUIOwner().rootUI)
                            .filter { it.idSelector == "engine-reuse-ready" }
                        currentNodes = nodes.map { node -> linkedMapOf<String, Any?>(
                            "identity" to System.identityHashCode(node), "sign" to node.sign,
                            "sameAsLookup" to (node === ui), "detached" to node.isDetachedWithView,
                            "text" to (node as? IUIText)?.textLayout?.text?.toString(),
                            "label" to node.accessibilityLabel?.toString()) }
                        actual = (nodes.singleOrNull() as? IUIText)?.textLayout?.text?.toString().orEmpty()
                    }
                    if (actual == expected || fatal.get() != null) break
                    SystemClock.sleep(30)
                }
                // 在真实节点之后继续观察副作用；同一B/C出现第二mount不能因首个正确回执而通过。
                SystemClock.sleep(250)
                val renderer = field(view, "mLynxTemplateRender")!!
                val engine = field(renderer, "mLynxEngineRef")!!
                val ptr = engine.javaClass.getMethod("getNativePtr").invoke(engine) as Long
                val native = events[id]!!.toList()
                val row = linkedMapOf<String, Any?>("marker" to marker, "order" to order, "pageId" to id,
                    "expectedUi" to expected, "actualUi" to actual, "lookupText" to lookupText,
                    "currentNodes" to currentNodes, "accessibilityLabel" to accessibilityLabel, "nativeEvents" to native,
                    "engineIdentity" to System.identityHashCode(engine), "enginePtr" to ptr,
                    "sameEngine" to (index == 0 || engine === firstEngine), "samePtr" to (index == 0 || ptr == firstPtr),
                    "callbacks" to calls.toList(), "fatal" to fatal.get())
                rows.add(row); persist()
                println("EngineOrdering row=${OtaJson.stringify(row)}")
                val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
                try { FileOutputStream(File(output, "$marker.png")).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } }
                finally { bitmap.recycle() }
                if (cold) {
                    if (index > 0) assertNotSame("下一对必须新Engine", firstEngine, engine)
                    firstEngine = engine; firstPtr = ptr
                }
                assertNull(fatal.get())
                assertTrue(ptr != 0L)
                assertSame("必须三次同Engine", firstEngine, engine)
                assertEquals(firstPtr, ptr)
                assertEquals("必须真实UI成为新页", expected, actual)
                assertTrue("新页副作用必须恰好一次", native.size == 1 && (native.single()["moduleMountCount"] as? Number)?.toInt() == 1)
                if (cold) {
                    val rect = android.graphics.Rect()
                    main {
                        val ui = requireNotNull(view.findUIByIdSelector("engine-reuse-increment"))
                        ui.scrollIntoView(false, "nearest", "nearest")
                        rect.set(ui.rectToWindow)
                    }
                    instrumentation.waitForIdleSync()
                    val start = SystemClock.uptimeMillis()
                    for ((action, time) in listOf(MotionEvent.ACTION_DOWN to start, MotionEvent.ACTION_UP to start + 50)) {
                        val event = MotionEvent.obtain(start, time, action, rect.exactCenterX(), rect.exactCenterY(), 0)
                        try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
                    }
                    val counterEnd = SystemClock.elapsedRealtime() + 5000
                    while (events[id]!!.size < 2 && SystemClock.elapsedRealtime() < counterEnd) SystemClock.sleep(30)
                    assertEquals("A须真实点击到counter1", 1, (events[id]!!.last()["counter"] as Number).toInt())
                }
                main { ShellMessageHub.unregister(id); frame.removeView(view); destroy.invoke(LynxShell, view) }
                provider.close(); current = null; currentProvider = null
                if (order == "paired" && index % 2 == 1) {
                    main { group.release() }
                    assertEquals("B退出必须释放Engine wrapper", 0L, engine.javaClass.getMethod("getNativePtr").invoke(engine) as Long)
                }
            }
        } finally {
            main {
                ShellMessageHub.unregister(currentId)
                current?.let { frame.removeView(it); destroy.invoke(LynxShell, it) }
                group.release(); activity.finish(); LynxRouter.setMessageHandler(null)
            }
            currentProvider?.close(); lease.close(); storeDir.deleteRecursively(); persist()
        }
    }
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun tree(ui: LynxBaseUI): List<LynxBaseUI> = listOf(ui) + ui.children.flatMap(::tree)
    private fun field(target: Any, name: String): Any? {
        var type: Class<*>? = target.javaClass
        while (type != null) {
            val f = type.declaredFields.firstOrNull { it.name == name }
            if (f != null) return f.also { it.isAccessible = true }.get(target)
            type = type.superclass
        }
        error(name)
    }
}
