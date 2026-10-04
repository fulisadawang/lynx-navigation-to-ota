package com.example.lynxshell.sample

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.example.lynxcapacitormodule.LynxCapacitorHost
import com.example.lynxcapacitormodule.LynxCapacitorHostProvider
import com.example.lynxcapacitormodule.LynxCapacitorModule
import com.example.lynxcapacitormodule.LynxCapacitorRuntime
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.container.LynxShellActivity
import com.example.lynxshell.ota.LynxOtaConfig
import com.example.lynxshell.tab.LynxTabFragment
import com.example.lynxshell.tab.LynxTabSpec
import com.lynx.jsbridge.LynxModuleFactory
import com.lynx.react.bridge.Callback
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxTemplateRender
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import java.io.File
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/**
 * 使用真实模板产物、真实 OTA Runtime 与 Android 4.1 ModuleFactory 的 Instrumentation 回归。
 *
 * 运行前由主流程完成 adb reverse，使 emulator 的 127.0.0.1:60543 指向本机模板 fixture。
 * 这里不启动/停止 fixture，不重启测试进程，也不替换 View 的 ModuleFactory。
 */
class NativeReadinessTemplateTest : InstrumentationTestCase() {
    private lateinit var application: Application
    private lateinit var watcher: ActivityWatcher
    private lateinit var launcher: MainActivity
    private val openedActivities = mutableListOf<LynxShellActivity>()

    override fun setUp() {
        super.setUp()
        application = instrumentation.targetContext.applicationContext as Application
        watcher = ActivityWatcher()
        application.registerActivityLifecycleCallbacks(watcher)
        runOnMain { LynxRouter.debugExposeOtaState(true) }
        launcher = instrumentation.startActivitySync(
            Intent(application, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("lynx_shell.show_native_launcher", true),
        ) as MainActivity
    }

    override fun tearDown() {
        openedActivities.toList().asReversed().forEach { activity ->
            if (!activity.isFinishing && !activity.isDestroyed) runOnMain { activity.finish() }
        }
        if (!launcher.isFinishing && !launcher.isDestroyed) runOnMain { launcher.finish() }
        runOnMain {
            LynxRouter.debugExposeOtaState(false)
            // 恢复 Sample composition root；避免同一 instrumentation 进程后续测试继承 spy provider。
            LynxCapacitorDemoHost.install(application)
        }
        application.unregisterActivityLifecycleCallbacks(watcher)
        super.tearDown()
    }

    fun testRealTemplateHomeAndEcommerceDownloadThenReportHealthy() {
        controlFixture(phase = "v1", resetMetrics = true)
        installIsolatedFixtureRuntime()

        val home = openTemplate(HOME_BUNDLE)
        val homeState = awaitReady(home, requirePromotion = true)
        assertTrue("Home must be promoted by the template's real markOtaHealthy call: $homeState", homeState.contains("release=template-v1"))
        assertTrue("Home must be current after health confirmation: $homeState", homeState.contains("source=ota_current"))
        assertTrue("Home debug state must record promotion: $homeState", homeState.contains("promoted=true"))
        assertNotNull("Home must create a real LynxView", home.currentLynxView())

        val ecommerce = openTemplate(ECOMMERCE_BUNDLE)
        val ecommerceState = awaitReady(ecommerce, requirePromotion = false)
        assertTrue("Ecommerce must read the downloaded release: $ecommerceState", ecommerceState.contains("release=template-v1"))
        assertNotNull("Ecommerce must create a real LynxView", ecommerce.currentLynxView())

        val requests = fixtureState().getJSONObject("requests")
        assertTrue("fixture must receive latest selection", requests.optInt(LATEST_PATH, 0) >= 1)
        assertTrue("fixture must serve real HomePage bytes", requests.optInt("/files/$HOME_BUNDLE", 0) >= 1)
        assertTrue("fixture must serve real OtaEcommercePage bytes", requests.optInt("/files/$ECOMMERCE_BUNDLE", 0) >= 1)
    }

    fun testFactoryBoundCapModuleReleasesOwnerExactlyOnceWhenRealViewDestroys() {
        controlFixture(phase = "v1", resetMetrics = true)
        installIsolatedFixtureRuntime()
        val shell = openTemplate(HOME_BUNDLE)
        awaitReady(shell, requirePromotion = true)
        val view = requireNotNull(shell.currentLynxView())

        val spy = ReleaseSpyHostProvider()
        runOnMain { LynxCapacitorRuntime.setHostProvider(spy) }
        try {
            val callback = CapturingCallback()
            runOnMain {
                val module = factoryBoundCapacitorModule(view)
                assertEquals("android", module.getPlatform())
                module.handleCall(
                    JSONObject()
                        .put("callbackId", "native-readiness")
                        .put("pluginId", "StatusBar")
                        .put("methodName", "hide")
                        .put("options", JSONObject())
                        .toString(),
                    callback,
                )
            }
            assertTrue("factory-bound Cap transport did not reply", callback.await())
            assertTrue("factory-bound Cap transport must use the active Host", spy.calls.get() == 1)

            // 只销毁真实 View；不手动 new/destroy Module，也不替换 SDK factory。
            runOnMain { view.destroy() }
            assertTrue("view destruction did not release the bound Cap owner", spy.awaitRelease())
            assertEquals("Cap owner must release exactly once", 1, spy.releases.get())
        } finally {
            runOnMain { LynxCapacitorDemoHost.install(application) }
        }
    }

    fun testNativeTabsReuseTemplateViewsAcrossHideShowWithoutNetwork() {
        controlFixture(phase = "v1", resetMetrics = true)
        installIsolatedFixtureRuntime()
        val tabs = installTemplateTabs()
        visitBothTabsAndReturnHome(tabs)
        val beforeHome = awaitTabReady(tabs.home)
        val homeView = requireNotNull(findLynxView(requireNotNull(tabs.home.view)))
        val requestsBefore = fixtureState().getJSONObject("requests").toString()

        repeat(3) {
            runOnMain {
                launcher.supportFragmentManager.beginTransaction()
                    .hide(tabs.home)
                    .show(tabs.ecommerce)
                    .commitNow()
                launcher.supportFragmentManager.beginTransaction()
                    .hide(tabs.ecommerce)
                    .show(tabs.home)
                    .commitNow()
            }
        }

        assertSame("ordinary tab hide/show must reuse the same Home LynxView", homeView, findLynxView(requireNotNull(tabs.home.view)))
        assertEquals("ordinary tab hide/show must not reload the fragment", beforeHome, tabs.home.debugStateDescription())
        assertEquals("ordinary tab hide/show must not request latest or main bundles", requestsBefore, fixtureState().getJSONObject("requests").toString())
    }

    fun testConfirmedFatalStopsViewButKeepsCurrentAndTestPersistence() {
        controlFixture(phase = "v1", resetMetrics = true)
        installIsolatedFixtureRuntime()
        val shell = openTemplate(HOME_BUNDLE)
        awaitReady(shell, requirePromotion = true)
        val currentBefore = currentReleaseId()
        assertEquals("confirmed template must have an active OTA current", "template-v1", currentBefore)
        val preferences = application.getSharedPreferences("native-readiness-fatal", Activity.MODE_PRIVATE)
        preferences.edit().putString("value", "persisted").commit()
        val database = SQLiteDatabase.openOrCreateDatabase(File(application.filesDir, "native-readiness-fatal.db"), null)
        database.execSQL("CREATE TABLE IF NOT EXISTS readiness (v TEXT)")
        database.execSQL("DELETE FROM readiness")
        database.execSQL("INSERT INTO readiness(v) VALUES ('persisted')")
        database.close()

        val fatal = LynxError(
            102,
            "native-readiness-confirmed-fatal",
            "native-readiness-test",
            "fatal",
        )
        assertTrue("test injection must be a real Fatal LynxError", fatal.isFatal)
        runOnMain { shellClient(shell).onReceivedError(fatal) }
        awaitError(shell)

        assertNull("confirmed fatal must stop the invalid LynxView", shell.currentLynxView())
        assertEquals("confirmed fatal must not roll back current", currentBefore, currentReleaseId())
        assertEquals("confirmed fatal must not roll back test Preferences", "persisted", preferences.getString("value", null))
        val reopened = SQLiteDatabase.openDatabase(File(application.filesDir, "native-readiness-fatal.db").path, null, SQLiteDatabase.OPEN_READONLY)
        try {
            reopened.rawQuery("SELECT v FROM readiness", null).use { cursor ->
                assertTrue("confirmed fatal must not roll back test SQLite data", cursor.moveToFirst())
                assertEquals("persisted", cursor.getString(0))
            }
        } finally {
            reopened.close()
        }
    }

    fun testResourceWarningKeepsConfirmedTemplateViewAndCurrent() {
        controlFixture(phase = "v1", resetMetrics = true)
        installIsolatedFixtureRuntime()
        val shell = openTemplate(HOME_BUNDLE)
        awaitReady(shell, requirePromotion = true)
        val view = requireNotNull(shell.currentLynxView())
        val currentBefore = currentReleaseId()
        assertEquals("confirmed template must have an active OTA current", "template-v1", currentBefore)

        val resourceWarning = LynxError(
            301,
            "native-readiness-resource-warning",
            "native-readiness-test",
            "error",
        )
        val unrelatedWarning = LynxError(
            9001,
            "native-readiness-non-root-warning",
            "native-readiness-test",
            "warn",
        )
        assertFalse("resource warning must not be fatal", resourceWarning.isFatal)
        assertFalse("non-root warning must not be fatal", unrelatedWarning.isFatal)
        runOnMain {
            shellClient(shell).onReceivedError(resourceWarning)
            shellClient(shell).onReceivedError(unrelatedWarning)
        }

        assertSame("resource/warn error must not tear down a healthy page", view, shell.currentLynxView())
        assertEquals("resource/warn error must not roll back current", currentBefore, currentReleaseId())
        assertTrue("resource/warn error must leave the page in ready state", findDebugState(shell.window.decorView).orEmpty().contains("state=ready"))
    }

    fun testDemoHostSystemBarsRejectsInactiveTabAndAppliesActiveTabInsets() {
        controlFixture(phase = "v1", resetMetrics = true)
        installIsolatedFixtureRuntime()
        val tabs = installTemplateTabs()
        visitBothTabsAndReturnHome(tabs)
        val homeModule = factoryBoundCapacitorModule(requireNotNull(findLynxView(requireNotNull(tabs.home.view))))
        val ecommerceModule = factoryBoundCapacitorModule(requireNotNull(findLynxView(requireNotNull(tabs.ecommerce.view))))

        val hidden = invokeCap(homeModule, "StatusBar", "hide")
        assertTrue("active Home StatusBar.hide must return actual success: $hidden", hidden.optBoolean("success"))
        assertFalse("active Home StatusBar.hide must be reflected by Insets", statusBarsVisible())

        runOnMain {
            launcher.supportFragmentManager.beginTransaction()
                .hide(tabs.home)
                .show(tabs.ecommerce)
                .commitNow()
        }
        val inactive = invokeCap(homeModule, "StatusBar", "show")
        assertEquals("inactive Home module must not control the active tab window", "HOST_INACTIVE", inactive.optJSONObject("error")?.optString("code"))

        val style = invokeCap(ecommerceModule, "SystemBars", "setStyle", JSONObject().put("style", "DARK"))
        assertTrue("active Ecommerce SystemBars.setStyle must return actual success: $style", style.optBoolean("success"))
        val shown = invokeCap(ecommerceModule, "StatusBar", "show")
        assertTrue("active Ecommerce StatusBar.show must return actual success: $shown", shown.optBoolean("success"))
        assertTrue("active Ecommerce StatusBar.show must be reflected by Insets", statusBarsVisible())
    }

    private fun installIsolatedFixtureRuntime() {
        val storage = File(application.filesDir, "native-readiness-template-${UUID.randomUUID()}")
        val versionCode = installedVersionCode().takeIf { it > 0L }?.toString() ?: "150"
        runOnMain {
            LynxRouter.install(
                application,
                LynxOtaConfig(
                    apiBaseUri = FIXTURE_ORIGIN,
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
                ),
            )
        }
        val completed = CountDownLatch(1)
        val success = AtomicReference(false)
        runOnMain {
            LynxRouter.refreshAllOtaBundles {
                success.set(it)
                completed.countDown()
            }
        }
        assertTrue("fixture OTA full sync did not finish", completed.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertTrue("fixture OTA full sync failed", success.get())
    }

    private fun openTemplate(bundleName: String): LynxShellActivity {
        watcher.expectShell()
        val result = AtomicReference<com.example.lynxshell.routing.LynxNavigationResult>()
        runOnMain {
            result.set(
                LynxRouter.open(
                    context = launcher,
                    lynxAppId = TEMPLATE_APP_ID,
                    bundleName = bundleName,
                    params = mapOf("nativeReadiness" to true),
                    options = mapOf("animated" to false, "showToolbar" to false, "fullscreen" to true),
                ),
            )
        }
        assertTrue("router must accept real template route: ${result.get()?.message}", result.get()?.isSuccess == true)
        return watcher.awaitShell().also(openedActivities::add)
    }

    private data class TemplateTabs(
        val home: LynxTabFragment,
        val ecommerce: LynxTabFragment,
    )

    private fun installTemplateTabs(): TemplateTabs {
        val home = LynxTabFragment.newInstance(
            LynxTabSpec(
                tabId = "readiness-home-${UUID.randomUUID()}",
                bundleUrl = "assets://bundles/$HOME_BUNDLE",
                routeKey = "native-readiness-home",
                lynxAppId = TEMPLATE_APP_ID,
                bundleName = HOME_BUNDLE,
            ),
        )
        val ecommerce = LynxTabFragment.newInstance(
            LynxTabSpec(
                tabId = "readiness-ecommerce-${UUID.randomUUID()}",
                bundleUrl = "assets://bundles/$ECOMMERCE_BUNDLE",
                routeKey = "native-readiness-ecommerce",
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
                .add(container.id, home, "native-readiness-home")
                .add(container.id, ecommerce, "native-readiness-ecommerce")
                .hide(ecommerce)
                .commitNow()
        }
        return TemplateTabs(home, ecommerce)
    }

    /** 隐藏 Tab 不承诺业务健康确认；验收前先让两个真实 View 都实际前台一次。 */
    private fun visitBothTabsAndReturnHome(tabs: TemplateTabs) {
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

    private fun awaitTabReady(tab: LynxTabFragment): String {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = tab.debugStateDescription() }
            if (latest.contains("error=ready") && latest.contains("source=ota_current")) return latest
            SystemClock.sleep(80)
        }
        fail("native tab did not reach ready/current state: $latest")
        return latest
    }

    private fun findLynxView(view: View): LynxView? {
        if (view is LynxView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findLynxView(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    private fun shellClient(shell: LynxShellActivity): LynxViewClient {
        val field = LynxShellActivity::class.java.getDeclaredField("lynxViewClient").apply { isAccessible = true }
        return field.get(shell) as? LynxViewClient ?: error("LynxShellActivity has no current LynxViewClient")
    }

    private fun awaitError(shell: LynxShellActivity) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = findDebugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=error")) return
            SystemClock.sleep(80)
        }
        fail("confirmed fatal did not enter shell error state: $latest")
    }

    private fun currentReleaseId(): String? =
        LynxRouter.otaStorageSnapshot()?.apps?.firstOrNull { it.appId == TEMPLATE_APP_ID }?.state?.currentReleaseId

    private fun invokeCap(module: LynxCapacitorModule, pluginId: String, methodName: String, options: JSONObject = JSONObject()): JSONObject {
        val callback = CapturingCallback()
        runOnMain {
            module.handleCall(
                JSONObject()
                    .put("callbackId", "native-readiness-$pluginId-$methodName")
                    .put("pluginId", pluginId)
                    .put("methodName", methodName)
                    .put("options", options)
                    .toString(),
                callback,
            )
        }
        assertTrue("$pluginId.$methodName did not reply", callback.await())
        return JSONObject(requireNotNull(callback.value()))
    }

    private fun statusBarsVisible(): Boolean =
        requireNotNull(ViewCompat.getRootWindowInsets(launcher.window.decorView)) {
            "launcher Window has no root Insets"
        }.isVisible(WindowInsetsCompat.Type.statusBars())

    private fun awaitReady(activity: LynxShellActivity, requirePromotion: Boolean): String {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain {
                latest = findDebugState(activity.window.decorView).orEmpty()
            }
            if (latest.contains("state=ready") && (!requirePromotion || latest.contains("promoted=true"))) return latest
            SystemClock.sleep(80)
        }
        fail("real template did not reach expected ready state; requirePromotion=$requirePromotion last=$latest")
        return latest
    }

    /** 只读 SDK 4.1 已绑定的 factory；字段/类型由本轮 Lynx 4.1 AAR javap 固定。 */
    private fun factoryBoundCapacitorModule(view: LynxView): LynxCapacitorModule {
        val renderField = LynxView::class.java.getDeclaredField("mLynxTemplateRender").apply { isAccessible = true }
        val render = renderField.get(view) as? LynxTemplateRender
            ?: error("Lynx 4.1 View has no TemplateRender")
        val factoryField = LynxTemplateRender::class.java.getDeclaredField("mModuleFactory").apply { isAccessible = true }
        val factory = factoryField.get(render) as? LynxModuleFactory
            ?: error("Lynx 4.1 TemplateRender has no ModuleFactory")
        return factory.getModule(LynxCapacitorModule.MODULE_NAME)?.module as? LynxCapacitorModule
            ?: error("Lynx 4.1 factory did not bind LynxCapacitorModule to this View")
    }

    private fun controlFixture(phase: String, resetMetrics: Boolean) {
        val body = JSONObject()
            .put("phase", phase)
            .put("offline", false)
            .put("resetMetrics", resetMetrics)
            .toString()
            .toByteArray(Charsets.UTF_8)
        val connection = (URL("$FIXTURE_ORIGIN/_readiness/control").openConnection() as HttpURLConnection)
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { output: OutputStream -> output.write(body) }
            assertTrue("fixture control failed: ${connection.responseCode}", connection.responseCode in 200..299)
        } finally {
            connection.disconnect()
        }
    }

    private fun fixtureState(): JSONObject {
        val connection = (URL("$FIXTURE_ORIGIN/_readiness/state").openConnection() as HttpURLConnection)
        try {
            assertTrue("fixture state failed: ${connection.responseCode}", connection.responseCode in 200..299)
            return connection.inputStream.bufferedReader(Charsets.UTF_8).use { JSONObject(it.readText()) }
        } finally {
            connection.disconnect()
        }
    }

    private fun installedVersionCode(): Long {
        val info = application.packageManager.getPackageInfo(application.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }

    private fun findDebugState(view: View): String? {
        view.contentDescription?.toString()?.takeIf { it.startsWith(DEBUG_STATE_PREFIX) }?.let { return it.removePrefix(DEBUG_STATE_PREFIX) }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findDebugState(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    private fun runOnMain(block: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync {
            try {
                block()
            } catch (throwable: Throwable) {
                failure.set(throwable)
            }
        }
        failure.get()?.let { throw it }
    }

    private class CapturingCallback : Callback {
        private val completed = CountDownLatch(1)
        private val result = AtomicReference<String?>()
        override fun invoke(vararg args: Any?) {
            result.set(args.firstOrNull() as? String)
            completed.countDown()
        }
        fun await(): Boolean = completed.await(NativeReadinessTemplateTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)
        fun value(): String? = result.get()
    }

    private class ReleaseSpyHostProvider : LynxCapacitorHostProvider {
        val calls = AtomicInteger()
        val releases = AtomicInteger()
        private val released = CountDownLatch(1)
        override val supportedMethods: Set<String> = setOf("StatusBar.hide")
        override fun resolve(callerContext: android.content.Context): LynxCapacitorHost = object : LynxCapacitorHost {
            override fun call(pluginId: String, methodName: String, options: JSONObject, complete: (JSONObject) -> Unit) {
                calls.incrementAndGet()
                complete(JSONObject())
            }
        }
        override fun release(callerContext: android.content.Context) {
            releases.incrementAndGet()
            released.countDown()
        }
        fun awaitRelease(): Boolean = released.await(NativeReadinessTemplateTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)
    }

    private class ActivityWatcher : Application.ActivityLifecycleCallbacks {
        private var shellLatch = CountDownLatch(1)
        @Volatile private var shell: LynxShellActivity? = null

        fun expectShell() {
            shell = null
            shellLatch = CountDownLatch(1)
        }

        fun awaitShell(): LynxShellActivity {
            check(shellLatch.await(NativeReadinessTemplateTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                "LynxShellActivity did not resume"
            }
            return requireNotNull(shell)
        }

        override fun onActivityResumed(activity: Activity) {
            if (activity is LynxShellActivity) {
                shell = activity
                shellLatch.countDown()
            }
        }

        override fun onActivityDestroyed(activity: Activity) = Unit

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    }

    private companion object {
        const val TIMEOUT_SECONDS = 20L
        const val TEMPLATE_APP_ID = "10020000"
        const val HOME_BUNDLE = "HomePage.lynx.bundle"
        const val ECOMMERCE_BUNDLE = "OtaEcommercePage.lynx.bundle"
        const val LATEST_PATH = "/api/ota/v1/releases/latest-bundle-list"
        const val DEBUG_STATE_PREFIX = "lynx-debug-ota-state:"
        val FIXTURE_ORIGIN: URI = URI.create("http://127.0.0.1:60543")
    }
}
