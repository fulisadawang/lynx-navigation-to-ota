package com.example.lynxshell.sample

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import com.example.lynxcapacitormodule.LynxCapacitorModule
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.container.LynxShellActivity
import com.example.lynxshell.ota.EmbeddedBundleRegistry
import com.example.lynxshell.ota.LynxOtaConfig
import com.example.lynxshell.ota.LynxOtaRuntime
import com.example.lynxshell.tab.LynxTabFragment
import com.example.lynxshell.tab.LynxTabSpec
import com.ota.android.sdk.OtaStorageReleaseRole
import com.lynx.jsbridge.LynxModuleFactory
import com.lynx.react.bridge.Callback
import com.lynx.tasm.LynxTemplateRender
import com.lynx.tasm.LynxView
import java.io.File
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/**
 * 只覆盖真实 Host 的跨 View Window lease 与网络队列边界。
 *
 * 不替换 ModuleFactory、不伪造 Bundle，依赖主流程把 emulator 的 loopback 转到本机 fixture。
 */
class NativeReadinessBoundaryTest : InstrumentationTestCase() {
    private lateinit var application: Application
    private lateinit var launcher: MainActivity
    private lateinit var watcher: ShellWatcher
    private val opened = mutableListOf<LynxShellActivity>()

    override fun setUp() {
        super.setUp()
        application = instrumentation.targetContext.applicationContext as Application
        watcher = ShellWatcher()
        application.registerActivityLifecycleCallbacks(watcher)
        runOnMain { LynxRouter.debugExposeOtaState(true) }
        launcher = instrumentation.startActivitySync(
            Intent(application, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("lynx_shell.show_native_launcher", true),
        ) as MainActivity
    }

    override fun tearDown() {
        opened.asReversed().forEach { activity ->
            if (!activity.isFinishing && !activity.isDestroyed) runOnMain { activity.finish() }
        }
        if (!launcher.isFinishing && !launcher.isDestroyed) runOnMain { launcher.finish() }
        runOnMain { LynxRouter.debugExposeOtaState(false) }
        application.unregisterActivityLifecycleCallbacks(watcher)
        super.tearDown()
    }

    fun testTwoFactoryBoundTabsRetainSharedWindowLeasesUntilLastViewDestroys() {
        control("v1", reset = true)
        installRuntime()
        val tabs = installTabs()
        visitBothTabsAndReturnHome(tabs)
        val homeView = requireNotNull(findLynxView(requireNotNull(tabs.home.view)))
        val ecommerceView = requireNotNull(findLynxView(requireNotNull(tabs.ecommerce.view)))
        val homeModule = factoryModule(homeView)
        val ecommerceModule = factoryModule(ecommerceView)
        val initialKeepAwake = hasFlag(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val initialSecure = hasFlag(WindowManager.LayoutParams.FLAG_SECURE)
        assertFalse("boundary host must start without an inherited keep-awake lease", initialKeepAwake)
        assertFalse("boundary host must start without an inherited privacy lease", initialSecure)

        assertTrue("active Home KeepAwake must use the real factory module", invoke(homeModule, "KeepAwake", "keepAwake", JSONObject()).optBoolean("success"))
        assertTrue("active Home PrivacyScreen must use the real factory module", invoke(homeModule, "PrivacyScreen", "enable", JSONObject()).optBoolean("success"))
        assertTrue("Home owner must set KEEP_SCREEN_ON", hasFlag(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON))
        assertTrue("Home owner must set FLAG_SECURE", hasFlag(WindowManager.LayoutParams.FLAG_SECURE))

        runOnMain {
            launcher.supportFragmentManager.beginTransaction()
                .hide(tabs.home)
                .show(tabs.ecommerce)
                .commitNow()
        }
        assertTrue("active Ecommerce KeepAwake must acquire the same Window lease", invoke(ecommerceModule, "KeepAwake", "keepAwake", JSONObject()).optBoolean("success"))
        assertTrue("active Ecommerce PrivacyScreen must acquire the same Window lease", invoke(ecommerceModule, "PrivacyScreen", "enable", JSONObject()).optBoolean("success"))

        runOnMain {
            homeView.destroy()
            homeView.destroy()
        }
        assertTrue("destroying A must not clear B's keep-awake lease", hasFlag(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON))
        assertTrue("destroying A must not clear B's privacy lease", hasFlag(WindowManager.LayoutParams.FLAG_SECURE))

        runOnMain {
            ecommerceView.destroy()
            ecommerceView.destroy()
        }
        awaitWindowFlags(initialKeepAwake, initialSecure)
    }

    fun testFactoryBoundNetworkQueueCapsSlowRequestsAndReleasesOwnerExactlyOnce() {
        control("v1", reset = true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        val view = requireNotNull(shell.currentLynxView())
        val module = factoryModule(view)
        val initialStreamIds = streamIds()
        val callbacks = List(TOTAL_NETWORK_REQUESTS) { MultiCallback() }
        val heartbeat = CountDownLatch(1)

        runOnMain {
            repeat(TOTAL_NETWORK_REQUESTS) { index ->
                module.handleCall(
                    payload(
                        "CapacitorHttp",
                        "get",
                        JSONObject().put("url", "$FIXTURE_ORIGIN/_readiness/stream?id=queue-$index-${UUID.randomUUID()}"),
                        "queue-$index",
                    ),
                    callbacks[index],
                )
            }
            Handler(Looper.getMainLooper()).post { heartbeat.countDown() }
        }
        assertTrue("main Looper must remain responsive while the network queue is occupied", heartbeat.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        val startedIds = awaitStartedStreamIds(initialStreamIds, NETWORK_PARALLELISM)
        assertEquals("network executor must start exactly its two worker slots", NETWORK_PARALLELISM, startedIds.size)
        awaitBusyCallbacks(callbacks, NETWORK_REJECTIONS)
        assertEquals("network executor must reject exactly two requests beyond 2 workers plus 16 queue slots", NETWORK_REJECTIONS, callbacks.count { it.firstCodeOrNull() == "BUSY" })

        runOnMain { view.destroy() }
        callbacks.forEachIndexed { index, callback ->
            assertTrue("network request $index did not receive one terminal result", callback.awaitCount(1))
            assertEquals("network request $index must receive exactly one result", 1, callback.count())
            val code = requireNotNull(callback.firstCodeOrNull())
            assertTrue("network request $index must be BUSY or HOST_DESTROYED, actual=$code", code == "BUSY" || code == "HOST_DESTROYED")
        }
        assertEquals("only queue-overflow requests may report BUSY", NETWORK_REJECTIONS, callbacks.count { it.firstCodeOrNull() == "BUSY" })
        assertEquals("all accepted requests must become terminal when their View is destroyed", TOTAL_NETWORK_REQUESTS - NETWORK_REJECTIONS, callbacks.count { it.firstCodeOrNull() == "HOST_DESTROYED" })
        awaitClosedStreamIds(startedIds)
        assertEquals("destroying the owner must not start queued HTTP bodies", startedIds, newStreamIds(initialStreamIds))
        assertTrue("HTTP-only queue test must leave no partial transfer files", application.cacheDir.walkTopDown().none { it.isFile && it.name.endsWith(".part") })

        val next = openHome()
        awaitReadyCurrent(next)
        val nextModule = factoryModule(requireNotNull(next.currentLynxView()))
        val recovered = invoke(nextModule, "CapacitorHttp", "get", JSONObject().put("url", "$FIXTURE_ORIGIN/_readiness/state"))
        assertTrue("a new factory-bound View must use the released network lane normally: $recovered", recovered.optBoolean("success"))
    }

    fun testEmbeddedBaselineRecoversOnceWithoutLatestOrDownloadedRelease() {
        val storage = File(application.filesDir, "native-readiness-embedded-${UUID.randomUUID()}")
        val embedded = requireNotNull(EmbeddedBundleRegistry(application).resolve(TEMPLATE_APP_ID, HOME_BUNDLE)) {
            "test APK must include the real embedded Home bundle"
        }
        val runtime = installEmbeddedOnlyRuntime(storage)
        assertEmbeddedOnlyStoreState(embedded.releaseId)
        val direct = requireNotNull(runtime.resolveCurrent(TEMPLATE_APP_ID, HOME_BUNDLE))
        assertEquals("runtime must resolve the Registry identity", embedded.releaseId, direct.releaseId)
        assertEquals("runtime source must be the real APK embedded baseline", "embedded_baseline", direct.source)
        assertNull("embedded baseline has no downloaded release lease", direct.releaseLease)
        val requestsBefore = otaAndBundleRequests(fixtureState())

        runOnMain { LynxRouter.debugFailNextFirstScreen() }
        val shell = openHome()
        val recovered = awaitEmbeddedRecovery(shell, embedded.releaseId)

        assertTrue("Shell debug label must mark the embedded recovery path: $recovered", recovered.contains("source=rollback_fallback"))
        assertTrue("embedded first-screen recovery must consume only one allowance", activityBoolean(shell, "otaRecoveryUsed"))
        assertEquals("embedded first-screen recovery must render exactly failed baseline then recovered baseline", 2L, activityLong(shell, "contentGeneration"))
        assertEmbeddedOnlyStoreState(embedded.releaseId)
        assertEquals("embedded-only Runtime must not request latest or Bundle resources", requestsBefore, otaAndBundleRequests(fixtureState()))
    }

    private fun installRuntime() {
        val storage = File(application.filesDir, "native-readiness-boundary-${UUID.randomUUID()}")
        val versionCode = installedVersionCode().takeIf { it > 0L }?.toString() ?: "150"
        runOnMain {
            LynxRouter.install(application, LynxOtaConfig(
                apiBaseUri = FIXTURE_URI,
                hostApp = "capp",
                defaultLynxAppId = TEMPLATE_APP_ID,
                environment = "TEST",
                platform = "android",
                appVersion = "1.0.0",
                buildNumber = versionCode,
                versionCode = versionCode,
                lynxSdkVersion = "4.1.0",
                clientToken = "native-readiness-fixture-only",
                storageDirectory = storage,
                pageRefreshIntervalMillis = 0L,
                candidateActivationEnabled = true,
                allowLocalHTTPForTest = true,
            ))
        }
        refreshAll()
    }

    private fun installEmbeddedOnlyRuntime(storage: File): LynxOtaRuntime {
        val versionCode = installedVersionCode().takeIf { it > 0L }?.toString() ?: "150"
        val installed = AtomicReference<LynxOtaRuntime?>()
        runOnMain {
            installed.set(
                LynxRouter.install(
                    application,
                    LynxOtaConfig(
                        apiBaseUri = FIXTURE_URI,
                        hostApp = "capp",
                        defaultLynxAppId = TEMPLATE_APP_ID,
                        environment = "TEST",
                        platform = "android",
                        appVersion = "1.0.0",
                        buildNumber = versionCode,
                        versionCode = versionCode,
                        lynxSdkVersion = "4.1.0",
                        clientToken = null,
                        storageDirectory = storage,
                        candidateActivationEnabled = false,
                        allowLocalHTTPForTest = true,
                    ),
                ),
            )
        }
        return requireNotNull(installed.get())
    }

    private fun installTabs(): Tabs {
        val home = LynxTabFragment.newInstance(
            LynxTabSpec(
                tabId = "boundary-home-${UUID.randomUUID()}",
                bundleUrl = "assets://bundles/$HOME_BUNDLE",
                routeKey = "boundary-home",
                lynxAppId = TEMPLATE_APP_ID,
                bundleName = HOME_BUNDLE,
            ),
        )
        val ecommerce = LynxTabFragment.newInstance(
            LynxTabSpec(
                tabId = "boundary-ecommerce-${UUID.randomUUID()}",
                bundleUrl = "assets://bundles/$ECOMMERCE_BUNDLE",
                routeKey = "boundary-ecommerce",
                lynxAppId = TEMPLATE_APP_ID,
                bundleName = ECOMMERCE_BUNDLE,
            ),
        )
        runOnMain {
            val container = FrameLayout(launcher).apply {
                id = View.generateViewId()
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            }
            launcher.addContentView(container, container.layoutParams)
            launcher.supportFragmentManager.beginTransaction()
                .add(container.id, home, "boundary-home")
                .add(container.id, ecommerce, "boundary-ecommerce")
                .hide(ecommerce)
                .commitNow()
        }
        return Tabs(home, ecommerce)
    }

    /** 隐藏 Tab 不会自动完成业务健康确认，Window lease 验收前必须实际显示两页。 */
    private fun visitBothTabsAndReturnHome(tabs: Tabs) {
        awaitTabReady(tabs.home)
        runOnMain {
            launcher.supportFragmentManager.beginTransaction()
                .hide(tabs.home)
                .show(tabs.ecommerce)
                .commitNow()
        }
        awaitTabReady(tabs.ecommerce)
        runOnMain {
            launcher.supportFragmentManager.beginTransaction()
                .hide(tabs.ecommerce)
                .show(tabs.home)
                .commitNow()
        }
        awaitTabReady(tabs.home)
    }

    private fun openHome(): LynxShellActivity {
        watcher.expect()
        val accepted = AtomicBoolean(false)
        runOnMain {
            accepted.set(
                LynxRouter.open(
                    launcher,
                    TEMPLATE_APP_ID,
                    HOME_BUNDLE,
                    mapOf("nativeReadinessBoundary" to true),
                    mapOf("animated" to false, "showToolbar" to false),
                ).isSuccess,
            )
        }
        assertTrue("router must accept the real Home template", accepted.get())
        return watcher.await().also(opened::add)
    }

    private fun refreshAll() {
        val completed = CountDownLatch(1)
        val success = AtomicBoolean(false)
        runOnMain { LynxRouter.refreshAllOtaBundles { success.set(it); completed.countDown() } }
        assertTrue("fixture OTA sync did not finish", completed.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertTrue("fixture OTA sync failed", success.get())
    }

    private fun awaitPromoted(shell: LynxShellActivity) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && latest.contains("source=ota_current") && latest.contains("promoted=true")) return
            SystemClock.sleep(80)
        }
        fail("real Home did not promote the candidate: $latest")
    }

    private fun awaitReadyCurrent(shell: LynxShellActivity) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && latest.contains("source=ota_current")) return
            SystemClock.sleep(80)
        }
        fail("real Home did not become ready on the current release: $latest")
    }

    private fun awaitEmbeddedRecovery(shell: LynxShellActivity, releaseId: String): String {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && latest.contains("release=$releaseId") && latest.contains("source=rollback_fallback")) return latest
            SystemClock.sleep(80)
        }
        fail("embedded baseline did not recover after one injected first-screen failure: $latest")
        error("unreachable")
    }

    private fun awaitTabReady(tab: LynxTabFragment) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = tab.debugStateDescription() }
            if (latest.contains("error=ready") && latest.contains("source=ota_current")) return
            SystemClock.sleep(80)
        }
        fail("real native Tab did not become ready/current: $latest")
    }

    private fun factoryModule(view: LynxView): LynxCapacitorModule {
        val render = LynxView::class.java.getDeclaredField("mLynxTemplateRender").apply { isAccessible = true }.get(view) as? LynxTemplateRender
            ?: error("Lynx 4.1 View has no TemplateRender")
        val factory = LynxTemplateRender::class.java.getDeclaredField("mModuleFactory").apply { isAccessible = true }.get(render) as? LynxModuleFactory
            ?: error("Lynx 4.1 TemplateRender has no ModuleFactory")
        return factory.getModule(LynxCapacitorModule.MODULE_NAME)?.module as? LynxCapacitorModule
            ?: error("Lynx factory did not bind Cap Module")
    }

    private fun invoke(module: LynxCapacitorModule, plugin: String, method: String, options: JSONObject): JSONObject {
        val callback = MultiCallback()
        runOnMain { module.handleCall(payload(plugin, method, options, "boundary-$plugin-$method-${UUID.randomUUID()}"), callback) }
        assertTrue("$plugin.$method did not reply", callback.awaitCount(1))
        return callback.jsonAt(0)
    }

    private fun payload(plugin: String, method: String, options: JSONObject, callbackId: String): String =
        JSONObject().put("callbackId", callbackId).put("pluginId", plugin).put("methodName", method).put("options", options).toString()

    private fun hasFlag(flag: Int): Boolean = launcher.window.attributes.flags and flag != 0

    private fun awaitWindowFlags(expectedKeepAwake: Boolean, expectedSecure: Boolean) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var keepAwake = !expectedKeepAwake
        var secure = !expectedSecure
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain {
                keepAwake = hasFlag(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                secure = hasFlag(WindowManager.LayoutParams.FLAG_SECURE)
            }
            if (keepAwake == expectedKeepAwake && secure == expectedSecure) return
            SystemClock.sleep(80)
        }
        fail("last View destruction did not restore Window flags: keepAwake=$keepAwake expected=$expectedKeepAwake secure=$secure expected=$expectedSecure")
    }

    private fun assertEmbeddedOnlyStoreState(releaseId: String) {
        val app = requireNotNull(LynxRouter.otaStorageSnapshot()?.apps?.firstOrNull { it.appId == TEMPLATE_APP_ID }) {
            "fresh embedded Runtime must expose its Store state"
        }
        assertEquals("fresh state must point at the Registry release identity", releaseId, app.state?.currentReleaseId)
        assertEquals("fresh current must be embedded, never a downloaded release", "embedded", app.state?.currentKind)
        assertNull("embedded baseline has no downloaded previous", app.state?.previousReleaseId)
        assertNull("embedded-only Runtime must not create a candidate", app.candidate)
        assertTrue(
            "embedded-only Runtime must not create downloaded CURRENT/PREVIOUS manifests",
            app.releases.none { release ->
                OtaStorageReleaseRole.CURRENT in release.roles || OtaStorageReleaseRole.PREVIOUS in release.roles
            },
        )
    }

    private fun activityBoolean(activity: LynxShellActivity, name: String): Boolean =
        activity.javaClass.getDeclaredField(name).apply { isAccessible = true }.getBoolean(activity)

    private fun activityLong(activity: LynxShellActivity, name: String): Long =
        activity.javaClass.getDeclaredField(name).apply { isAccessible = true }.getLong(activity)

    private fun control(phase: String, reset: Boolean) {
        val bytes = JSONObject().put("phase", phase).put("offline", false).put("resetMetrics", reset).toString().toByteArray(Charsets.UTF_8)
        val connection = URL("$FIXTURE_ORIGIN/_readiness/control").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { output: OutputStream -> output.write(bytes) }
            assertTrue("fixture control failed: ${connection.responseCode}", connection.responseCode in 200..299)
        } finally {
            connection.disconnect()
        }
    }

    private fun fixtureState(): JSONObject {
        val connection = URL("$FIXTURE_ORIGIN/_readiness/state").openConnection() as HttpURLConnection
        try {
            assertTrue("fixture state failed: ${connection.responseCode}", connection.responseCode in 200..299)
            return connection.inputStream.bufferedReader(Charsets.UTF_8).use { JSONObject(it.readText()) }
        } finally {
            connection.disconnect()
        }
    }

    private fun otaAndBundleRequests(state: JSONObject): Map<String, Int> {
        val requests = state.getJSONObject("requests")
        return requests.keys().asSequence()
            .filter { it == LATEST_PATH || it == "/async-manifest.json" || it.startsWith("/files/") }
            .associateWith { requests.getInt(it) }
    }

    private fun streamIds(): Set<String> = fixtureState().optJSONArray("streams")?.let { streams ->
        buildSet {
            for (index in 0 until streams.length()) add(streams.getJSONObject(index).getString("id"))
        }
    } ?: emptySet()

    private fun newStreamIds(baseline: Set<String>): Set<String> = fixtureState().optJSONArray("streams")?.let { streams ->
        buildSet {
            for (index in 0 until streams.length()) {
                val id = streams.getJSONObject(index).getString("id")
                if (id !in baseline) add(id)
            }
        }
    } ?: emptySet()

    private fun awaitStartedStreamIds(baseline: Set<String>, expected: Int): Set<String> {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            val streams = fixtureState().optJSONArray("streams")
            val started = buildSet {
                if (streams != null) for (index in 0 until streams.length()) {
                    val stream = streams.getJSONObject(index)
                    val id = stream.getString("id")
                    if (id !in baseline && stream.optBoolean("started")) add(id)
                }
            }
            if (started.size >= expected) return started
            SystemClock.sleep(80)
        }
        fail("fixture did not observe $expected new slow streams")
        error("unreachable")
    }

    private fun awaitClosedStreamIds(expected: Set<String>) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            val streams = fixtureState().optJSONArray("streams")
            val closed = buildSet {
                if (streams != null) for (index in 0 until streams.length()) {
                    val stream = streams.getJSONObject(index)
                    if (stream.getString("id") in expected && stream.optBoolean("closed")) add(stream.getString("id"))
                }
            }
            if (closed == expected) return
            SystemClock.sleep(80)
        }
        fail("fixture did not close slow streams $expected")
    }

    private fun awaitBusyCallbacks(callbacks: List<MultiCallback>, expected: Int) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            if (callbacks.count { it.firstCodeOrNull() == "BUSY" } == expected) return
            SystemClock.sleep(80)
        }
        fail("network queue did not report exactly $expected BUSY callbacks")
    }

    private fun installedVersionCode(): Long {
        val info = application.packageManager.getPackageInfo(application.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else {
            @Suppress("DEPRECATION") info.versionCode.toLong()
        }
    }

    private fun findLynxView(view: View): LynxView? {
        if (view is LynxView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            findLynxView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun debugState(view: View): String? {
        view.contentDescription?.toString()?.takeIf { it.startsWith(DEBUG_PREFIX) }?.let { return it.removePrefix(DEBUG_PREFIX) }
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            debugState(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun runOnMain(action: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync {
            try {
                action()
            } catch (throwable: Throwable) {
                failure.set(throwable)
            }
        }
        failure.get()?.let { throw it }
    }

    private data class Tabs(val home: LynxTabFragment, val ecommerce: LynxTabFragment)

    private class MultiCallback : Callback {
        private val values = mutableListOf<String>()
        private val lock = Any()
        private val completed = CountDownLatch(1)
        override fun invoke(vararg args: Any?) {
            val value = args.firstOrNull() as? String ?: return
            synchronized(lock) { values += value }
            completed.countDown()
        }
        fun awaitCount(expected: Int): Boolean {
            if (count() >= expected) return true
            return completed.await(NativeReadinessBoundaryTest.TIMEOUT_SECONDS, TimeUnit.SECONDS) && count() >= expected
        }
        fun count(): Int = synchronized(lock) { values.size }
        fun jsonAt(index: Int): JSONObject = JSONObject(synchronized(lock) { values[index] })
        fun firstCodeOrNull(): String? = if (count() == 0) null else {
            val json = jsonAt(0)
            if (json.optBoolean("success")) null else json.optJSONObject("error")?.optString("code")
        }
    }

    private class ShellWatcher : Application.ActivityLifecycleCallbacks {
        private var latch = CountDownLatch(1)
        @Volatile private var activity: LynxShellActivity? = null
        fun expect() {
            activity = null
            latch = CountDownLatch(1)
        }
        fun await(): LynxShellActivity {
            check(latch.await(NativeReadinessBoundaryTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)) { "LynxShellActivity did not resume" }
            return requireNotNull(activity)
        }
        override fun onActivityResumed(activity: Activity) {
            if (activity is LynxShellActivity) {
                this.activity = activity
                latch.countDown()
            }
        }
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    private companion object {
        const val TIMEOUT_SECONDS = 20L
        const val TEMPLATE_APP_ID = "10020000"
        const val HOME_BUNDLE = "HomePage.lynx.bundle"
        const val ECOMMERCE_BUNDLE = "OtaEcommercePage.lynx.bundle"
        const val DEBUG_PREFIX = "lynx-debug-ota-state:"
        const val FIXTURE_ORIGIN = "http://127.0.0.1:60543"
        const val LATEST_PATH = "/api/ota/v1/releases/latest-bundle-list"
        const val NETWORK_PARALLELISM = 2
        const val NETWORK_REJECTIONS = 2
        const val TOTAL_NETWORK_REQUESTS = 20
        val FIXTURE_URI: URI = URI.create(FIXTURE_ORIGIN)
    }
}
