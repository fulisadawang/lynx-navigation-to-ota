package com.example.lynxshell.sample

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.bridge.ShellMessageHub
import com.example.lynxshell.container.LynxContainerFactory
import com.example.lynxshell.container.LynxShellActivity
import com.example.lynxshell.model.LynxPageRequest
import com.example.lynxshell.ota.LynxOtaConfig
import com.example.lynxshell.ota.LynxOtaRuntime
import com.example.lynxshell.ota.PreparedActivityBundle
import com.example.lynxshell.resource.ShellTemplateProvider
import com.lynx.tasm.LynxError
import com.lynx.tasm.LynxView
import com.lynx.tasm.LynxViewClient
import com.lynx.tasm.TemplateData
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.OtaStorageAppSnapshot
import com.ota.android.sdk.OtaStorageDiagnostics
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/**
 * 两个方法必须由 CLI 分别运行，中间真实 force-stop 测试 App，保留同一私有 Store。
 *
 * 阶段 A 只发布 READY_TO_KILL 并等待外部终止；等待自然结束会失败，不算冷启动通过。
 * 阶段 B 依赖主流程把 fixture 切到 503；它不调用控制接口，也不清除任何 App 数据。
 */
class NativeReadinessColdStartTest : InstrumentationTestCase() {
    private lateinit var application: Application
    private lateinit var watcher: ShellWatcher
    private lateinit var launcher: MainActivity
    private var runtime: LynxOtaRuntime? = null
    private val opened = mutableListOf<LynxShellActivity>()
    private val preparedBundles = mutableListOf<PreparedActivityBundle>()
    private var trialView: LynxView? = null
    private var trialProvider: ShellTemplateProvider? = null
    private val trialFatal = AtomicReference<String?>()

    private val storeDirectory: File get() = File(application.filesDir, STORE_DIRECTORY)
    private val markerFile: File get() = File(application.filesDir, MARKER_FILE)

    override fun setUp() {
        super.setUp()
        application = instrumentation.targetContext.applicationContext as Application
        assertEquals("cold-start tests must use the isolated test App", TEST_PACKAGE, application.packageName)
        watcher = ShellWatcher()
        application.registerActivityLifecycleCallbacks(watcher)
        runOnMain { LynxRouter.debugExposeOtaState(true) }
    }

    override fun tearDown() {
        runOnMain {
            trialView?.let { view ->
                (view.parent as? ViewGroup)?.removeView(view)
                view.destroy()
            }
            trialView = null
            trialProvider?.close()
            trialProvider = null
        }
        opened.asReversed().forEach { activity ->
            if (!activity.isFinishing && !activity.isDestroyed) runOnMain { activity.finish() }
        }
        if (::launcher.isInitialized && !launcher.isFinishing && !launcher.isDestroyed) {
            runOnMain { launcher.finish() }
        }
        preparedBundles.forEach { prepared ->
            prepared.releaseLease?.close()
            runtime?.releaseNavigationSnapshot(prepared.navigationSnapshotID)
        }
        preparedBundles.clear()
        // 仅结束进程内资源；不能在阶段 A teardown 清除待恢复的 TRIAL。
        runOnMain {
            LynxRouter.debugExposeOtaState(false)
            LynxRouter.install(application)
        }
        application.unregisterActivityLifecycleCallbacks(watcher)
        super.tearDown()
    }

    fun testPhaseAStageTrialAndWaitForForceStop() {
        if (markerFile.exists()) assertTrue("could not remove previous cold-start marker", markerFile.delete())
        if (storeDirectory.exists()) assertTrue("could not reset this test's Store scope", storeDirectory.deleteRecursively())
        controlFixture("v1", resetMetrics = true)
        val activeRuntime = installRuntime(syncEnabled = true)
        refreshAll()
        startLauncher()

        val stableHome = openHome()
        val ready = awaitHomeReady(stableHome, requirePromotion = true)
        assertTrue("real Home must promote v1: $ready", ready.contains("release=template-v1"))
        assertEquals("template-v1", storeApp().state?.currentReleaseId)
        val stable = requireNotNull(activeRuntime.resolveCurrent(TEMPLATE_APP_ID, HOME_BUNDLE))
        val stableSha = try {
            assertEquals("template-v1", stable.releaseId)
            requireNotNull(stable.sha256)
        } finally {
            stable.releaseLease?.close()
        }
        runOnMain { stableHome.finish() }
        instrumentation.waitForIdleSync()

        controlFixture("v2", resetMetrics = false)
        refreshAll()
        val trial = requireNotNull(activeRuntime.resolvePage(TEMPLATE_APP_ID, HOME_BUNDLE, TRIAL_SESSION))
            .also(preparedBundles::add)
        assertEquals("template-v2", trial.releaseId)
        assertEquals("candidate_trial", trial.source)
        assertEquals("v1/v2 must use the same real template artifact", stableSha, trial.sha256)
        val snapshot = requireNotNull(trial.navigationSnapshotID)
        assertTrue("v2 trial must have a live process snapshot", activeRuntime.isNavigationSnapshotValid(snapshot))

        renderTrialWithoutHealthEndpoint(trial)
        assertTrialStillUnconfirmed()
        val marker = JSONObject()
            .put("status", "READY_TO_KILL")
            .put("packageName", TEST_PACKAGE)
            .put("lynxAppId", TEMPLATE_APP_ID)
            .put("bundleName", HOME_BUNDLE)
            .put("oldSnapshot", snapshot)
            .put("currentReleaseId", "template-v1")
            .put("candidateReleaseId", "template-v2")
            .put("firstScreen", true)
            .put("healthEndpoint", "unregistered_test_host")
        writeMarker(marker)

        val deadline = SystemClock.elapsedRealtime() + KILL_WAIT_SECONDS * 1_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            assertTrialStillUnconfirmed()
            SystemClock.sleep(250)
        }
        writeMarker(marker.put("status", "TIMED_OUT_WAITING_FOR_FORCE_STOP"))
        fail("phase A must be interrupted by external am force-stop after READY_TO_KILL")
    }

    fun testPhaseBRecoverTrialAfterForceStopWithoutLatestOrBundleRequests() {
        assertTrue("phase A must publish its marker before force-stop", markerFile.isFile)
        val marker = JSONObject(markerFile.readText(Charsets.UTF_8))
        assertEquals("READY_TO_KILL", marker.getString("status"))
        assertEquals(TEST_PACKAGE, marker.getString("packageName"))
        assertEquals(TEMPLATE_APP_ID, marker.getString("lynxAppId"))
        assertEquals(HOME_BUNDLE, marker.getString("bundleName"))
        assertTrue("phase A must have observed the real SDK first screen", marker.getBoolean("firstScreen"))
        val oldSnapshot = marker.getString("oldSnapshot")
        val oldNonce = snapshotNonce(oldSnapshot)

        // 在新 Runtime 的首次读取前用只读诊断确认磁盘仍有遗留 TRIAL，不能靠测试提前丢弃。
        val interrupted = OtaStorageDiagnostics(storeDirectory, storeVersion = OtaModels.StoreVersion.V3)
            .snapshot().apps.first { it.appId == TEMPLATE_APP_ID }
        assertEquals("template-v1", interrupted.state?.currentReleaseId)
        assertEquals("template-v2", interrupted.candidate?.releaseId)
        assertTrue("phase A must leave an interrupted TRIAL", interrupted.candidate?.status.equals("TRIAL", ignoreCase = true))

        // Sample Application 自身可先启动同步；此安装关闭旧 Runtime，并明确关闭本测试后台同步。
        val activeRuntime = installRuntime(syncEnabled = false)
        assertFalse("old process snapshot must be invalid before restoration", activeRuntime.isNavigationSnapshotValid(oldSnapshot))
        val recovered = requireNotNull(activeRuntime.resolveRecoveredCurrent(TEMPLATE_APP_ID, HOME_BUNDLE, oldSnapshot))
            .also(preparedBundles::add)
        assertEquals("cold start must restore downloaded stable current", "template-v1", recovered.releaseId)
        assertEquals("ota_current", recovered.source)
        assertTrue("stable current must remain readable without downloads", requireNotNull(recovered.file).canRead())
        val newSnapshot = requireNotNull(recovered.navigationSnapshotID)
        assertFalse("recovery must create a different snapshot", oldSnapshot == newSnapshot)
        assertFalse("CLI must restart the process between phases", oldNonce == snapshotNonce(newSnapshot))
        assertTrue("new process snapshot must be valid", activeRuntime.isNavigationSnapshotValid(newSnapshot))
        assertFalse("old process snapshot must remain invalid", activeRuntime.isNavigationSnapshotValid(oldSnapshot))
        assertEquals("template-v1", storeApp().state?.currentReleaseId)
        assertNull("startup maintenance must discard interrupted TRIAL", storeApp().candidate)

        // 计数从测试 Runtime 完成启动维护后开始；503 fixture 不代表整机已断网。
        val beforeState = fixtureState()
        assertTrue("CLI must configure the fixture to return 503", beforeState.getBoolean("offline"))
        val beforeRequests = otaAndBundleRequests(beforeState)
        startLauncher()
        val stableHome = openHome()
        val ready = awaitHomeReady(stableHome, requirePromotion = false)
        assertTrue("offline real Home must render v1: $ready", ready.contains("release=template-v1"))
        assertTrue("offline real Home must read OTA current: $ready", ready.contains("source=ota_current"))
        assertNotNull("offline real Home must create a real LynxView", stableHome.currentLynxView())
        assertEquals("template-v1", storeApp().state?.currentReleaseId)
        assertNull("opening stable Home must not recreate the discarded candidate", storeApp().candidate)
        assertEquals("recovery/open must not request latest or Bundle/Async files", beforeRequests, otaAndBundleRequests(fixtureState()))
        writeMarker(marker
            .put("status", "RECOVERED")
            .put("newSnapshot", newSnapshot)
            .put("recoveredReleaseId", recovered.releaseId)
            .put("latestAndBundleRequestDelta", 0)
            .put("fixtureOffline", true))
    }

    private fun installRuntime(syncEnabled: Boolean): LynxOtaRuntime {
        val versionCode = installedVersionCode().toString()
        val installed = AtomicReference<LynxOtaRuntime>()
        runOnMain {
            installed.set(LynxRouter.install(application, LynxOtaConfig(
                apiBaseUri = URI.create(FIXTURE_ORIGIN),
                hostApp = "capp",
                defaultLynxAppId = TEMPLATE_APP_ID,
                environment = "TEST",
                platform = "android",
                appVersion = "1.0.0",
                buildNumber = versionCode,
                versionCode = versionCode,
                lynxSdkVersion = "4.1.0",
                clientToken = if (syncEnabled) "native-readiness-fixture-only" else null,
                storageDirectory = storeDirectory,
                candidateActivationEnabled = true,
                allowLocalHTTPForTest = true,
            )))
        }
        return requireNotNull(installed.get()).also { runtime = it }
    }

    private fun refreshAll() {
        val completed = CountDownLatch(1)
        val success = AtomicBoolean(false)
        runOnMain { LynxRouter.refreshAllOtaBundles { success.set(it); completed.countDown() } }
        assertTrue("fixture OTA sync did not finish", completed.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertTrue("fixture OTA sync failed", success.get())
    }

    private fun startLauncher() {
        launcher = instrumentation.startActivitySync(
            Intent(application, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("lynx_shell.show_native_launcher", true),
        ) as MainActivity
    }

    private fun openHome(): LynxShellActivity {
        watcher.expect()
        val accepted = AtomicBoolean(false)
        runOnMain {
            accepted.set(LynxRouter.open(
                launcher,
                TEMPLATE_APP_ID,
                HOME_BUNDLE,
                mapOf("nativeReadinessColdStart" to true),
                mapOf("animated" to false, "showToolbar" to false),
            ).isSuccess)
        }
        assertTrue("router must accept real Home template", accepted.get())
        return watcher.await().also(opened::add)
    }

    private fun renderTrialWithoutHealthEndpoint(prepared: PreparedActivityBundle) {
        val bytes = prepared.bytes ?: requireNotNull(prepared.file).readBytes()
        val firstScreen = CountDownLatch(1)
        val rendered = AtomicBoolean(false)
        val logicalUrl = "assets://bundles/$HOME_BUNDLE"
        val client = object : LynxViewClient() {
            override fun onFirstScreen() {
                rendered.set(true)
                firstScreen.countDown()
            }
            override fun onReceivedError(error: LynxError) {
                if (error.isFatal) {
                    trialFatal.set(error.toString())
                    firstScreen.countDown()
                }
            }
        }
        runOnMain {
            val provider = ShellTemplateProvider(launcher, preparedUrl = logicalUrl, preparedFile = prepared.file, preparedBytes = prepared.bytes)
            trialProvider = provider
            val request = LynxPageRequest(
                bundleUrl = logicalUrl,
                lynxAppId = TEMPLATE_APP_ID,
                bundleName = HOME_BUNDLE,
                routeKey = TRIAL_SESSION,
                showToolbar = false,
            )
            val view = LynxContainerFactory.create(
                activity = launcher,
                request = request,
                templateProvider = provider,
                lynxViewClient = client,
                bundleMetadata = mapOf(
                    "lynxAppId" to TEMPLATE_APP_ID,
                    "bundleName" to HOME_BUNDLE,
                    "releaseId" to requireNotNull(prepared.releaseId),
                    "source" to prepared.source,
                    "sha256" to requireNotNull(prepared.sha256),
                ),
                sidecarResources = prepared.sidecarResources,
            )
            trialView = view
            launcher.addContentView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            // 真实模板/SDK 正常渲染；这个测试 Host 刻意不注册健康 endpoint，以保留未确认 TRIAL。
            view.renderTemplateWithBaseUrl(bytes, TemplateData.fromMap(emptyMap<String, Any>()), logicalUrl)
        }
        assertTrue("v2 real template SDK first screen did not arrive", firstScreen.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertNull("v2 real template must not report fatal before first screen", trialFatal.get())
        assertTrue("first screen must come from the real SDK callback", rendered.get())
        runOnMain {
            val view = requireNotNull(trialView)
            assertTrue("real v2 View must be attached and laid out", view.isAttachedToWindow && view.width > 0 && view.height > 0)
        }

        val rejected = CountDownLatch(1)
        val healthCode = AtomicReference<Int>()
        ShellMessageHub.markOtaHealthy(trialView) { reply -> healthCode.set(reply.code); rejected.countDown() }
        assertTrue("test Host must reject health confirmation", rejected.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertEquals("unregistered test Host must not promote v2", 1002, healthCode.get().toInt())
    }

    private fun assertTrialStillUnconfirmed() {
        assertNull("v2 real template must not report fatal while waiting for force-stop", trialFatal.get())
        val app = storeApp()
        assertEquals("template-v1", app.state?.currentReleaseId)
        assertEquals("template-v2", app.candidate?.releaseId)
        assertTrue("v2 must remain TRIAL until external force-stop", app.candidate?.status.equals("TRIAL", ignoreCase = true))
    }

    private fun storeApp(): OtaStorageAppSnapshot =
        requireNotNull(LynxRouter.otaStorageSnapshot()).apps.first { it.appId == TEMPLATE_APP_ID }

    private fun awaitHomeReady(activity: LynxShellActivity, requirePromotion: Boolean): String {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(activity.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && (!requirePromotion || latest.contains("promoted=true"))) return latest
            SystemClock.sleep(80)
        }
        fail("real Home did not reach ready state; requirePromotion=$requirePromotion last=$latest")
        return latest
    }

    private fun snapshotNonce(snapshot: String): String {
        val parts = snapshot.split(':', limit = 4)
        assertEquals("snapshot must have the process-bound format", 4, parts.size)
        assertEquals("ota-snapshot", parts[0])
        return parts[1]
    }

    private fun writeMarker(value: JSONObject) {
        val temporary = File(application.filesDir, "$MARKER_FILE.tmp")
        FileOutputStream(temporary).use { output ->
            output.write(value.toString().toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        assertTrue("could not publish complete cold-start marker", temporary.renameTo(markerFile))
    }

    private fun controlFixture(phase: String, resetMetrics: Boolean) {
        val bytes = JSONObject().put("phase", phase).put("offline", false).put("resetMetrics", resetMetrics)
            .toString().toByteArray(Charsets.UTF_8)
        val connection = URL("$FIXTURE_ORIGIN/_readiness/control").openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 5_000
            connection.readTimeout = 5_000
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            assertTrue("fixture control failed: ${connection.responseCode}", connection.responseCode in 200..299)
        } finally {
            connection.disconnect()
        }
    }

    private fun fixtureState(): JSONObject {
        val connection = URL("$FIXTURE_ORIGIN/_readiness/state").openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 5_000
            connection.readTimeout = 5_000
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

    private fun installedVersionCode(): Long {
        val info = application.packageManager.getPackageInfo(application.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else {
            @Suppress("DEPRECATION") info.versionCode.toLong()
        }
        assertTrue("installed App must have a real positive versionCode", code > 0L)
        return code
    }

    private fun debugState(view: View): String? {
        view.contentDescription?.toString()?.takeIf { it.startsWith(DEBUG_PREFIX) }?.let { return it.removePrefix(DEBUG_PREFIX) }
        if (view is ViewGroup) for (index in 0 until view.childCount) debugState(view.getChildAt(index))?.let { return it }
        return null
    }

    private fun runOnMain(action: () -> Unit) {
        val failure = AtomicReference<Throwable?>()
        instrumentation.runOnMainSync {
            try {
                action()
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        failure.get()?.let { throw it }
    }

    private class ShellWatcher : Application.ActivityLifecycleCallbacks {
        private var latch = CountDownLatch(1)
        @Volatile private var activity: LynxShellActivity? = null
        fun expect() { activity = null; latch = CountDownLatch(1) }
        fun await(): LynxShellActivity {
            check(latch.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) { "LynxShellActivity did not resume" }
            return requireNotNull(activity)
        }
        override fun onActivityResumed(activity: Activity) { if (activity is LynxShellActivity) { this.activity = activity; latch.countDown() } }
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    private companion object {
        const val TIMEOUT_SECONDS = 20L
        const val KILL_WAIT_SECONDS = 120L
        const val TEST_PACKAGE = "com.hugboga.custom.otae2e"
        const val TEMPLATE_APP_ID = "10020000"
        const val HOME_BUNDLE = "HomePage.lynx.bundle"
        const val STORE_DIRECTORY = "native-readiness-cold"
        const val MARKER_FILE = "native-readiness-cold-marker.json"
        const val TRIAL_SESSION = "native-readiness-cold-trial"
        const val DEBUG_PREFIX = "lynx-debug-ota-state:"
        const val FIXTURE_ORIGIN = "http://127.0.0.1:60543"
        const val LATEST_PATH = "/api/ota/v1/releases/latest-bundle-list"
    }
}
