package com.example.lynxshell.sample

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import com.example.lynxcapacitormodule.LynxCapacitorHost
import com.example.lynxcapacitormodule.LynxCapacitorHostProvider
import com.example.lynxcapacitormodule.LynxCapacitorModule
import com.example.lynxcapacitormodule.LynxCapacitorRuntime
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.LynxShell
import com.example.lynxshell.bridge.LynxShellModule
import com.example.lynxshell.container.LynxShellActivity
import com.example.lynxshell.ota.LynxOtaConfig
import com.example.lynxshell.ota.LynxOtaRuntime
import com.lynx.jsbridge.LynxModuleFactory
import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.react.bridge.ReadableMap
import com.lynx.react.bridge.Callback
import com.lynx.tasm.LynxTemplateRender
import com.lynx.tasm.LynxView
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
import org.json.JSONObject

/**
 * Android Host 的真实 Module transport 与 Runtime snapshot 回归。
 *
 * 依赖主流程已把 emulator 127.0.0.1:60543 reverse 到本机真实模板 fixture；不创建替代 Bundle。
 */
class NativeReadinessHostTest : InstrumentationTestCase() {
    private lateinit var application: Application
    private lateinit var launcher: MainActivity
    private lateinit var watcher: ShellWatcher
    private val launchers = mutableListOf<MainActivity>()
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
        launchers += launcher
    }

    override fun tearDown() {
        opened.asReversed().forEach { activity ->
            if (!activity.isFinishing && !activity.isDestroyed) runOnMain { activity.finish() }
        }
        launchers.distinct().asReversed().forEach { activity ->
            if (!activity.isFinishing && !activity.isDestroyed) runOnMain { activity.finish() }
        }
        runOnMain {
            LynxRouter.debugExposeOtaState(false)
            LynxCapacitorDemoHost.install(application)
        }
        application.unregisterActivityLifecycleCallbacks(watcher)
        super.tearDown()
    }

    fun testFactoryModuleTransportCoversInvalidBudgetFilesystemSQLiteAndLoopbackHttp() {
        control("v1", true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        val module = factoryModule(requireNotNull(shell.currentLynxView()))

        val heartbeat = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post { heartbeat.countDown() }
        val written = invoke(module, "Filesystem", "writeFile", JSONObject()
            .put("directory", "CACHE")
            .put("path", "native-readiness/io.txt")
            .put("data", "hello"))
        assertTrue("main looper heartbeat must remain schedulable during local IO", heartbeat.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertTrue("Filesystem.writeFile must use real module transport: $written", written.optBoolean("success"))

        val read = invoke(module, "Filesystem", "readFile", JSONObject()
            .put("directory", "CACHE")
            .put("path", "native-readiness/io.txt"))
        assertEquals("hello", read.getJSONObject("data").getString("data"))

        val database = "native_readiness_${UUID.randomUUID().toString().replace('-', '_')}"
        val created = invoke(module, "CapacitorSQLite", "createConnection", JSONObject().put("database", database).put("version", 1))
        assertTrue("SQLite createConnection must use real module transport: $created", created.optBoolean("success"))
        val executed = invoke(module, "CapacitorSQLite", "execute", JSONObject()
            .put("database", database)
            .put("statements", "CREATE TABLE IF NOT EXISTS readiness(v TEXT); INSERT INTO readiness(v) VALUES ('ok');"))
        assertTrue("SQLite execute must use real module transport: $executed", executed.optBoolean("success"))
        val queried = invoke(module, "CapacitorSQLite", "query", JSONObject()
            .put("database", database)
            .put("statement", "SELECT v FROM readiness"))
        assertTrue("SQLite query must use real module transport: $queried", queried.optBoolean("success"))
        invoke(module, "CapacitorSQLite", "close", JSONObject().put("database", database))

        val http = invoke(module, "CapacitorHttp", "get", JSONObject().put("url", "$FIXTURE_ORIGIN/_readiness/state"))
        assertTrue("CapacitorHttp must read loopback fixture through real network lane: $http", http.optBoolean("success"))

        val malformed = invokeRaw(module, "not-json")
        assertEquals("INVALID_PAYLOAD", malformed.getJSONObject("error").getString("code"))
        val tooLarge = invokeRaw(module, "x".repeat(REQUEST_LIMIT_BYTES + 1))
        assertEquals("PAYLOAD_TOO_LARGE", tooLarge.getJSONObject("error").getString("code"))
    }

    fun testRuntimeRejectsOldNonceAndRetiresCandidateSnapshotWithoutChangingStableCurrent() {
        control("v1", true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        val runtime = installedRuntime()
        val currentBefore = currentReleaseId()
        assertEquals("template-v1", currentBefore)

        val oldNonce = "ota-snapshot:prior-process:session-${UUID.randomUUID()}:${UUID.randomUUID()}"
        assertFalse("unknown prior-process nonce must not be accepted as a live snapshot", runtime.isNavigationSnapshotValid(oldNonce))
        val recovered = requireNotNull(runtime.resolveRecoveredCurrent(TEMPLATE_APP_ID, HOME_BUNDLE, oldNonce))
        val recoveredId = requireNotNull(recovered.navigationSnapshotID)
        assertFalse("recovery must allocate a new process snapshot id", oldNonce == recoveredId)
        assertTrue("new recovery snapshot must be valid", runtime.isNavigationSnapshotValid(recoveredId))
        assertEquals("recovery creates one activity snapshot reference", 1, snapshotInt(runtime, recoveredId, "activityCount"))
        recovered.releaseLease?.close()
        runtime.releaseNavigationSnapshot(recoveredId)
        assertFalse("released recovery snapshot must no longer be valid", runtime.isNavigationSnapshotValid(recoveredId))
        assertNull("released recovery snapshot must leave the runtime map", snapshotRecord(runtime, recoveredId))

        control("v2", false)
        refreshAll()
        val candidate = requireNotNull(runtime.resolvePage(TEMPLATE_APP_ID, HOME_BUNDLE, "candidate-${UUID.randomUUID()}"))
        assertEquals("candidate_trial", candidate.source)
        val candidateId = requireNotNull(candidate.navigationSnapshotID)
        assertTrue(runtime.isNavigationSnapshotValid(candidateId))
        assertTrue(runtime.recoverFailedCandidate(TEMPLATE_APP_ID, candidate.releaseId, candidate.userIdentityEpoch))
        assertFalse("failed candidate snapshot must become retired", runtime.isNavigationSnapshotValid(candidateId))
        assertTrue("failed candidate snapshot must retain its retired marker until release", snapshotBoolean(runtime, candidateId, "retired"))
        assertEquals("retired candidate keeps its original activity reference until release", 1, snapshotInt(runtime, candidateId, "activityCount"))
        assertEquals("candidate failure must not roll back stable current", currentBefore, currentReleaseId())

        val stable = requireNotNull(runtime.resolveRecoveredCurrent(TEMPLATE_APP_ID, HOME_BUNDLE, candidateId))
        assertEquals("template-v1", stable.releaseId)
        assertTrue(runtime.isNavigationSnapshotValid(stable.navigationSnapshotID))
        candidate.releaseLease?.close()
        runtime.releaseNavigationSnapshot(candidateId)
        assertNull("last retired snapshot release must remove its runtime root", snapshotRecord(runtime, candidateId))
        stable.releaseLease?.close()
        runtime.releaseNavigationSnapshot(stable.navigationSnapshotID)
    }

    fun testSlowHttpAndFileTransferDestroyOnceKeepsOriginalAndClearsPart() {
        control("v1", true)
        installRuntime()

        val first = openHome()
        awaitPromoted(first)
        val firstView = requireNotNull(first.currentLynxView())
        val firstModule = factoryModule(firstView)
        val http = MultiCallback()
        runOnMain {
            firstModule.handleCall(payload("CapacitorHttp", "get", JSONObject().put("url", "$FIXTURE_ORIGIN/_readiness/stream?id=http-owner"), "http-owner"), http)
        }
        waitForStartedStreams(1)
        runOnMain { firstView.destroy() }
        assertTrue("destroyed HTTP owner must receive a terminal callback", http.awaitCount(1))
        assertEquals("destroyed HTTP owner must receive HOST_DESTROYED", "HOST_DESTROYED", http.errorCodeAt(0))
        waitForClosedStreams(1)
        assertEquals("late HTTP completion must not invoke a second callback", 1, http.count())

        val second = openHome()
        awaitReadyCurrent(second)
        val secondView = requireNotNull(second.currentLynxView())
        val secondModule = factoryModule(secondView)
        val target = File(second.cacheDir, "native-readiness/stream.bin")
        target.parentFile?.mkdirs()
        target.writeText("original")
        val transfer = MultiCallback()
        runOnMain {
            secondModule.handleCall(payload("FileTransfer", "downloadFile", JSONObject()
                .put("url", "$FIXTURE_ORIGIN/_readiness/stream?id=file-owner")
                .put("directory", "CACHE")
                .put("path", "native-readiness/stream.bin"), "file-owner"), transfer)
        }
        waitForStartedStreams(2)
        runOnMain { secondView.destroy() }
        assertTrue("destroyed FileTransfer owner must receive a terminal callback", transfer.awaitCount(1))
        assertEquals("destroyed FileTransfer owner must receive HOST_DESTROYED", "HOST_DESTROYED", transfer.errorCodeAt(0))
        waitForClosedStreams(2)
        assertEquals("late FileTransfer completion must not invoke a second callback", 1, transfer.count())
        assertEquals("cancelled transfer must preserve the original target", "original", target.readText())
        waitForNoPartFiles(requireNotNull(target.parentFile))
    }

    fun testBackgroundStateUsesResumedOwnerAndDestroyingOldSlowHttpDoesNotAffectNewView() {
        control("v1", true)
        installRuntime()
        val first = openHome()
        awaitPromoted(first)
        val firstView = requireNotNull(first.currentLynxView())
        val firstModule = factoryModule(firstView)
        val firstCallback = MultiCallback()
        runOnMain {
            firstModule.handleCall(
                payload("CapacitorHttp", "get", JSONObject().put("url", "$FIXTURE_ORIGIN/_readiness/stream?id=background-owner"), "background-owner"),
                firstCallback,
            )
        }
        waitForStartedStreams(1)

        val movedToBack = AtomicBoolean(false)
        runOnMain { movedToBack.set(first.moveTaskToBack(false) || first.moveTaskToBack(true)) }
        assertTrue("real Shell Activity must move its task to background", movedToBack.get())
        awaitAppState(firstModule, expectedActive = false)

        val foregroundLauncher = foregroundLauncher()
        val second = openHome(foregroundLauncher)
        awaitReadyCurrent(second)
        val secondModule = factoryModule(requireNotNull(second.currentLynxView()))
        awaitAppState(secondModule, expectedActive = true)

        runOnMain { firstView.destroy() }
        assertTrue("background A must receive exactly one terminal callback after its View is destroyed", firstCallback.awaitCount(1))
        assertEquals("destroyed background A must receive HOST_DESTROYED", "HOST_DESTROYED", firstCallback.errorCodeAt(0))
        waitForClosedStreams(1)
        assertEquals("late slow HTTP completion must not create a second A callback", 1, firstCallback.count())

        val secondCallback = MultiCallback()
        runOnMain {
            secondModule.handleCall(payload("App", "getState", JSONObject(), "background-owner"), secondCallback)
        }
        assertTrue("foreground B with the same callback id must still receive its own result", secondCallback.awaitCount(1))
        val secondState = secondCallback.jsonAt(0)
        assertTrue("foreground B App.getState must succeed: $secondState", secondState.optBoolean("success"))
        assertTrue("foreground B must remain active after A is destroyed", secondState.getJSONObject("data").getBoolean("isActive"))
    }

    fun testLocalNotificationPermissionDenialReturnsDeniedAndBlocksScheduling() {
        control("v1", true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        val module = factoryModule(requireNotNull(shell.currentLynxView()))

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            val legacy = invoke(module, "LocalNotifications", "requestPermissions", JSONObject())
            assertTrue("API 26-32 notification permission branch must complete without a runtime dialog: $legacy", legacy.optBoolean("success"))
            assertEquals("granted", legacy.getJSONObject("data").getString("display"))
            return
        }

        assertTrue(
            "runner must revoke POST_NOTIFICATIONS before this test opens the real deny dialog",
            application.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED,
        )
        try {
            val permissionCallback = MultiCallback()
            runOnMain {
                module.handleCall(
                    payload("LocalNotifications", "requestPermissions", JSONObject(), "notification-deny-${UUID.randomUUID()}"),
                    permissionCallback,
                )
            }
            val deny = awaitPermissionDenyNode()
            try {
                assertTrue("system notification deny control did not accept the click", deny.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            } finally {
                deny.recycle()
            }

            assertTrue("LocalNotifications.requestPermissions did not return after the real deny action", permissionCallback.awaitCount(1))
            val permissionResult = permissionCallback.jsonAt(0)
            assertTrue("permission response must be a normal result envelope: $permissionResult", permissionResult.optBoolean("success"))
            assertEquals("real Android notification denial must be reported as denied", "denied", permissionResult.getJSONObject("data").getString("display"))

            val schedule = invoke(
                module,
                "LocalNotifications",
                "schedule",
                JSONObject().put(
                    "notifications",
                    JSONArray().put(
                        JSONObject()
                            .put("id", 860_000 + (SystemClock.elapsedRealtime() % 10_000).toInt())
                            .put("title", "native-readiness")
                            .put("body", "permission-denied")
                            .put("schedule", JSONObject().put("at", System.currentTimeMillis() + 600_000L)),
                    ),
                ),
            )
            assertFalse("scheduling must not claim success without POST_NOTIFICATIONS: $schedule", schedule.optBoolean("success"))
            assertEquals("PERMISSION_DENIED", schedule.getJSONObject("error").getString("code"))
        } finally {
            restoreNotificationPermissionForTest()
        }
    }

    fun testDelayedHostOwnerDestroyReturnsOnceAndSameCallbackIdWorksForSecondView() {
        control("v1", true)
        installRuntime()
        val first = openHome()
        awaitPromoted(first)
        val firstView = requireNotNull(first.currentLynxView())
        val firstModule = factoryModule(firstView)
        val host = DelayedHostProvider()
        runOnMain { LynxCapacitorRuntime.setHostProvider(host) }
        try {
            val firstCallback = MultiCallback()
            runOnMain {
                firstModule.handleCall(payload("StatusBar", "hide", JSONObject(), "shared-callback"), firstCallback)
            }
            assertTrue("delayed Host did not receive A call", host.awaitStarted())
            runOnMain { firstView.destroy() }
            assertTrue("destroyed owner A must receive one terminal callback", firstCallback.awaitCount(1))
            assertEquals("destroyed owner A must receive HOST_DESTROYED", "HOST_DESTROYED", firstCallback.errorCodeAt(0))
            host.completeLate()
            assertEquals("late Host success must not create a second A callback", 1, firstCallback.count())

            host.hold = false
            val second = openHome()
            awaitReadyCurrent(second)
            val secondModule = factoryModule(requireNotNull(second.currentLynxView()))
            val secondCallback = MultiCallback()
            runOnMain {
                secondModule.handleCall(payload("StatusBar", "hide", JSONObject(), "shared-callback"), secondCallback)
            }
            assertTrue("same callback id on B must still complete", secondCallback.awaitCount(1))
            assertTrue("B must receive a normal success despite A using the same callback id", secondCallback.successAt(0))
        } finally {
            runOnMain { LynxCapacitorDemoHost.install(application) }
        }
    }

    fun testFactoryShellModuleReports1002AfterReleasedViewHealthCall() {
        control("v1", true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        val module = factoryShellModule(requireNotNull(shell.currentLynxView()))

        val released = AtomicReference<Boolean>()
        runOnMain {
            val method = LynxShellActivity::class.java
                .declaredMethods
                .single { it.name.startsWith("releaseContentForRouteSnapshot") && it.parameterCount == 0 }
                .apply { isAccessible = true }
            released.set(method.invoke(shell) as Boolean)
        }
        assertTrue("test must release the actual Shell View and its message endpoint", released.get())
        assertNull("released Shell must no longer retain its View", shell.currentLynxView())

        val callback = RawMapCallback()
        runOnMain { module.markOtaHealthy(callback) }
        assertTrue("destroyed Shell Module health callback did not arrive", callback.await())
        val raw = callback.value()
        assertTrue("Shell Module callback must return the Lynx JavaOnlyMap, not the Cap String transport", raw is JavaOnlyMap)
        val reply = raw as ReadableMap
        assertEquals("released view must reject markOtaHealthy with the invalid/destroy code", 1002, reply.getInt("code"))
    }

    fun testCandidateFirstScreenFailureRecoversStableCurrentExactlyOnce() {
        control("v1", true)
        installRuntime()
        val stable = openHome()
        awaitPromoted(stable)
        assertEquals("template-v1", currentReleaseId())

        control("v2", false)
        refreshAll()
        assertPendingCandidate("template-v2")
        val bundleRequestsBeforeFailure = fixtureBundleRequestFingerprint()

        runOnMain { LynxRouter.debugFailNextFirstScreen() }
        val failedCandidate = openHome()
        val recoveredState = awaitReadyCurrentRelease(failedCandidate, "template-v1")

        assertTrue("recovery must leave the actual Shell in ready/current state: $recoveredState", recoveredState.contains("state=ready"))
        assertTrue("candidate first-screen failure must use its one recovery allowance", activityBoolean(failedCandidate, "otaRecoveryUsed"))
        assertEquals("candidate first-screen failure must render exactly candidate then stable recovery", 2L, activityLong(failedCandidate, "contentGeneration"))
        assertEquals("candidate failure must retain the stable downloaded current", "template-v1", currentReleaseId())
        assertNull("failed candidate must be discarded instead of remaining TRIAL/FAILED", otaApp().candidate)
        assertEquals("candidate failure and local stable recovery must not request a second bundle", bundleRequestsBeforeFailure, fixtureBundleRequestFingerprint())
    }

    fun testStableCurrentFirstScreenFailureRollsBackPreviousExactlyOnce() {
        control("v1", true)
        installRuntime()
        val first = openHome()
        awaitPromoted(first)

        control("v2", false)
        refreshAll()
        assertPendingCandidate("template-v2")
        val promoted = openHome()
        awaitPromotedRelease(promoted, "template-v2")
        assertEquals("template-v2", currentReleaseId())
        assertEquals("template-v1", otaApp().state?.previousReleaseId)
        assertNull("healthy v2 must no longer remain candidate", otaApp().candidate)
        val bundleRequestsBeforeFailure = fixtureBundleRequestFingerprint()

        runOnMain { LynxRouter.debugFailNextFirstScreen() }
        val failedCurrent = openHome()
        val recoveredState = awaitReadyCurrentRelease(failedCurrent, "template-v1")

        assertTrue("previous fallback must leave a ready OTA current: $recoveredState", recoveredState.contains("source=ota_current"))
        assertTrue("stable current failure must consume one rollback allowance", activityBoolean(failedCurrent, "otaRecoveryUsed"))
        assertEquals("stable current failure must render exactly failed current then previous recovery", 2L, activityLong(failedCurrent, "contentGeneration"))
        assertEquals("rollback must promote exactly the previous release", "template-v1", currentReleaseId())
        assertEquals("rollback recovery must remain local", bundleRequestsBeforeFailure, fixtureBundleRequestFingerprint())
    }

    fun testBadShaKeepsCurrentAndMissingCandidateBundleRemainsPending() {
        control("v1", true)
        installRuntime()
        val stable = openHome()
        awaitPromoted(stable)
        val requestsBeforeBadSha = fixtureState().getJSONObject("requests").optInt("/files/$HOME_BUNDLE", 0)

        control("bad-sha", false)
        refreshAllExpectFailure()
        assertTrue("bad SHA sync must fetch real Home bytes before verification", fixtureState().getJSONObject("requests").optInt("/files/$HOME_BUNDLE", 0) > requestsBeforeBadSha)
        assertEquals("bad SHA must keep the known-good current", "template-v1", currentReleaseId())
        assertNull("bad SHA must not activate a candidate", otaApp().candidate)

        control("v2", false)
        refreshAll()
        assertPendingCandidate("template-v2")
        val missing = installedRuntime().resolvePage(TEMPLATE_APP_ID, MISSING_BUNDLE, "missing-${UUID.randomUUID()}")
        assertNull("candidate without its requested Bundle must not enter trial or substitute another Bundle", missing)
        assertEquals("missing Bundle must keep the stable current", "template-v1", currentReleaseId())
        assertPendingCandidate("template-v2")
    }

    fun testCatalogUnsupportedAndPermissionChecksReturnObservedStateWithoutGrantClaim() {
        control("v1", true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        val module = factoryModule(requireNotNull(shell.currentLynxView()))

        val biometrics = invoke(module, "Biometrics", "isAvailable", JSONObject())
        assertEquals("catalog-declared unsupported Biometrics must match its transport result", "UNSUPPORTED", biometrics.getJSONObject("error").getString("code"))

        val notifications = invoke(module, "LocalNotifications", "checkPermissions", JSONObject())
        assertTrue("permission check itself must return a real callback envelope: $notifications", notifications.optBoolean("success"))
        val observed = notifications.getJSONObject("data").getString("display")
        assertTrue("permission check must report observed state, not claim grant", observed in setOf("granted", "denied", "prompt"))
    }

    private fun installRuntime() {
        val storage = File(application.filesDir, "native-readiness-host-${UUID.randomUUID()}")
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

    private fun refreshAll() {
        val completed = CountDownLatch(1)
        val success = AtomicBoolean(false)
        runOnMain { LynxRouter.refreshAllOtaBundles { success.set(it); completed.countDown() } }
        assertTrue("fixture OTA sync did not finish", completed.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertTrue("fixture OTA sync failed", success.get())
    }

    private fun refreshAllExpectFailure() {
        val completed = CountDownLatch(1)
        val success = AtomicBoolean(true)
        runOnMain { LynxRouter.refreshAllOtaBundles { success.set(it); completed.countDown() } }
        assertTrue("fixture bad SHA sync did not finish", completed.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertFalse("fixture bad SHA sync must report failure", success.get())
    }

    private fun foregroundLauncher(): MainActivity {
        val activity = instrumentation.startActivitySync(
            Intent(application, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
                .putExtra("lynx_shell.show_native_launcher", true),
        ) as MainActivity
        launcher = activity
        launchers += activity
        return activity
    }

    private fun openHome(host: MainActivity = launcher): LynxShellActivity {
        watcher.expect()
        val accepted = AtomicBoolean(false)
        runOnMain {
            accepted.set(LynxRouter.open(
                host,
                TEMPLATE_APP_ID,
                HOME_BUNDLE,
                mapOf("nativeReadinessHost" to true),
                mapOf("animated" to false, "showToolbar" to false),
            ).isSuccess)
        }
        assertTrue("router must accept real Home template", accepted.get())
        return watcher.await().also(opened::add)
    }

    private fun awaitAppState(module: LynxCapacitorModule, expectedActive: Boolean): JSONObject {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = JSONObject()
        while (SystemClock.elapsedRealtime() < deadline) {
            latest = invoke(module, "App", "getState", JSONObject())
            val data = latest.optJSONObject("data")
            if (latest.optBoolean("success") && data?.has("isActive") == true && data.getBoolean("isActive") == expectedActive) return latest
            SystemClock.sleep(80)
        }
        fail("App.getState did not reach isActive=$expectedActive: $latest")
        error("unreachable")
    }

    private fun restoreNotificationPermissionForTest() {
        executeShell("pm grant ${application.packageName} android.permission.POST_NOTIFICATIONS")
    }

    private fun executeShell(command: String): String =
        instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
            FileInputStream(descriptor.fileDescriptor).bufferedReader().use { it.readText() }
        }

    private fun awaitPermissionDenyNode(): AccessibilityNodeInfo {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            val root = instrumentation.uiAutomation.rootInActiveWindow
            if (root != null) {
                val deny = findPermissionDenyNode(root)
                if (deny != null) return deny
                root.recycle()
            }
            SystemClock.sleep(80)
        }
        fail("Android notification permission dialog did not expose a deny control")
        error("unreachable")
    }

    private fun findPermissionDenyNode(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val viewId = node.viewIdResourceName.orEmpty()
        val text = node.text?.toString().orEmpty()
        val description = node.contentDescription?.toString().orEmpty()
        if (
            viewId.endsWith("/permission_deny_button") ||
            text.equals("Don't allow", ignoreCase = true) ||
            text.equals("Don’t allow", ignoreCase = true) ||
            text.contains("不允许") ||
            description.equals("Don't allow", ignoreCase = true) ||
            description.contains("不允许")
        ) return node
        for (index in 0 until node.childCount) {
            val child = node.getChild(index) ?: continue
            val found = findPermissionDenyNode(child)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    private fun awaitPromoted(shell: LynxShellActivity) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && latest.contains("source=ota_current") && latest.contains("promoted=true")) return
            SystemClock.sleep(80)
        }
        fail("real template did not promote candidate: $latest")
    }

    private fun awaitReadyCurrent(shell: LynxShellActivity) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && latest.contains("source=ota_current")) return
            SystemClock.sleep(80)
        }
        fail("real template did not render the existing OTA current: $latest")
    }

    private fun awaitPromotedRelease(shell: LynxShellActivity, releaseId: String) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && latest.contains("release=$releaseId") &&
                latest.contains("source=ota_current") && latest.contains("promoted=true")) return
            SystemClock.sleep(80)
        }
        fail("real template did not promote expected release $releaseId: $latest")
    }

    private fun awaitReadyCurrentRelease(shell: LynxShellActivity, releaseId: String): String {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && latest.contains("release=$releaseId") && latest.contains("source=ota_current")) return latest
            SystemClock.sleep(80)
        }
        fail("real template did not recover expected current $releaseId: $latest")
        error("unreachable")
    }

    private fun otaApp() = requireNotNull(
        LynxRouter.otaStorageSnapshot()?.apps?.firstOrNull { it.appId == TEMPLATE_APP_ID },
    ) { "OTA storage has no template app snapshot" }

    private fun assertPendingCandidate(releaseId: String) {
        val candidate = requireNotNull(otaApp().candidate) { "expected pending candidate $releaseId" }
        assertEquals(releaseId, candidate.releaseId)
        assertEquals("pending", candidate.status)
    }

    private fun activityBoolean(activity: LynxShellActivity, name: String): Boolean =
        activity.javaClass.getDeclaredField(name).apply { isAccessible = true }.getBoolean(activity)

    private fun activityLong(activity: LynxShellActivity, name: String): Long =
        activity.javaClass.getDeclaredField(name).apply { isAccessible = true }.getLong(activity)

    private fun factoryModule(view: LynxView): LynxCapacitorModule {
        val render = LynxView::class.java.getDeclaredField("mLynxTemplateRender").apply { isAccessible = true }.get(view) as? LynxTemplateRender
            ?: error("Lynx 4.1 View has no TemplateRender")
        val factory = LynxTemplateRender::class.java.getDeclaredField("mModuleFactory").apply { isAccessible = true }.get(render) as? LynxModuleFactory
            ?: error("Lynx 4.1 TemplateRender has no ModuleFactory")
        return factory.getModule(LynxCapacitorModule.MODULE_NAME)?.module as? LynxCapacitorModule
            ?: error("Lynx factory did not bind Cap Module")
    }

    private fun factoryShellModule(view: LynxView): LynxShellModule {
        val render = LynxView::class.java.getDeclaredField("mLynxTemplateRender").apply { isAccessible = true }.get(view) as? LynxTemplateRender
            ?: error("Lynx 4.1 View has no TemplateRender")
        val factory = LynxTemplateRender::class.java.getDeclaredField("mModuleFactory").apply { isAccessible = true }.get(render) as? LynxModuleFactory
            ?: error("Lynx 4.1 TemplateRender has no ModuleFactory")
        return factory.getModule(LynxShellModule.MODULE_NAME)?.module as? LynxShellModule
            ?: error("Lynx factory did not bind Shell Module")
    }

    private fun invoke(module: LynxCapacitorModule, plugin: String, method: String, options: JSONObject): JSONObject =
        invokeRaw(module, JSONObject().put("callbackId", "host-$plugin-$method").put("pluginId", plugin).put("methodName", method).put("options", options).toString())

    private fun payload(plugin: String, method: String, options: JSONObject, callbackId: String): String =
        JSONObject().put("callbackId", callbackId).put("pluginId", plugin).put("methodName", method).put("options", options).toString()

    private fun invokeRaw(module: LynxCapacitorModule, payload: String): JSONObject {
        val callback = CallbackCapture()
        runOnMain { module.handleCall(payload, callback) }
        assertTrue("module callback did not arrive", callback.await())
        assertTrue("module callback must arrive on Android main Looper", callback.onMain.get())
        return JSONObject(requireNotNull(callback.value.get()))
    }

    private fun installedRuntime(): LynxOtaRuntime {
        val field = LynxShell::class.java.getDeclaredField("installedActivityBundleRuntime").apply { isAccessible = true }
        return field.get(LynxShell) as? LynxOtaRuntime ?: error("test runtime is not installed")
    }

    /** 固定本轮 LynxOtaRuntime 的私有 snapshot map，只读验证 retired/count，不作为生产 API。 */
    @Suppress("UNCHECKED_CAST")
    private fun snapshotRecord(runtime: LynxOtaRuntime, snapshotId: String): Any? {
        val field = LynxOtaRuntime::class.java.getDeclaredField("navigationSnapshots").apply { isAccessible = true }
        return (field.get(runtime) as Map<String, Any?>)[snapshotId]
    }

    private fun snapshotBoolean(runtime: LynxOtaRuntime, snapshotId: String, name: String): Boolean {
        val record = requireNotNull(snapshotRecord(runtime, snapshotId))
        return record.javaClass.getDeclaredField(name).apply { isAccessible = true }.getBoolean(record)
    }

    private fun snapshotInt(runtime: LynxOtaRuntime, snapshotId: String, name: String): Int {
        val record = requireNotNull(snapshotRecord(runtime, snapshotId))
        return record.javaClass.getDeclaredField(name).apply { isAccessible = true }.getInt(record)
    }

    private fun currentReleaseId(): String? =
        LynxRouter.otaStorageSnapshot()?.apps?.firstOrNull { it.appId == TEMPLATE_APP_ID }?.state?.currentReleaseId

    private fun control(phase: String, reset: Boolean) {
        val bytes = JSONObject().put("phase", phase).put("offline", false).put("resetMetrics", reset).toString().toByteArray(Charsets.UTF_8)
        val connection = URL("$FIXTURE_ORIGIN/_readiness/control").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"; connection.doOutput = true
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { output: OutputStream -> output.write(bytes) }
            assertTrue("fixture control failed: ${connection.responseCode}", connection.responseCode in 200..299)
        } finally { connection.disconnect() }
    }

    private fun fixtureState(): JSONObject {
        val connection = URL("$FIXTURE_ORIGIN/_readiness/state").openConnection() as HttpURLConnection
        try {
            assertTrue("fixture state failed: ${connection.responseCode}", connection.responseCode in 200..299)
            return connection.inputStream.bufferedReader(Charsets.UTF_8).use { JSONObject(it.readText()) }
        } finally { connection.disconnect() }
    }

    private fun fixtureBundleRequestFingerprint(): String {
        val requests = fixtureState().getJSONObject("requests")
        return listOf(
            "/files/$HOME_BUNDLE",
            "/files/$ECOMMERCE_BUNDLE",
            "/async-manifest.json",
        ).joinToString(";") { path -> "$path=${requests.optInt(path, 0)}" }
    }

    private fun waitForStartedStreams(expected: Int) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            val streams = fixtureState().optJSONArray("streams")
            if (streams != null && streams.length() >= expected) {
                var started = 0
                for (index in 0 until streams.length()) if (streams.getJSONObject(index).optBoolean("started")) started += 1
                if (started >= expected) return
            }
            SystemClock.sleep(80)
        }
        fail("fixture did not observe $expected started slow streams")
    }

    private fun waitForNoPartFiles(parent: File) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            if (parent.listFiles().orEmpty().none { it.name.endsWith(".part") }) return
            SystemClock.sleep(80)
        }
        fail("cancelled FileTransfer left a .part file in ${parent.path}")
    }

    private fun waitForClosedStreams(expected: Int) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            val streams = fixtureState().optJSONArray("streams")
            if (streams != null && streams.length() >= expected) {
                var closed = 0
                for (index in 0 until streams.length()) if (streams.getJSONObject(index).optBoolean("closed")) closed += 1
                if (closed >= expected) return
            }
            SystemClock.sleep(80)
        }
        fail("fixture did not close $expected slow streams")
    }

    private fun installedVersionCode(): Long {
        val info = application.packageManager.getPackageInfo(application.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else {
            @Suppress("DEPRECATION") info.versionCode.toLong()
        }
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
            } catch (throwable: Throwable) {
                failure.set(throwable)
            }
        }
        failure.get()?.let { throw it }
    }

    private class CallbackCapture : Callback {
        val value = AtomicReference<String?>()
        val onMain = AtomicBoolean(false)
        private val completed = CountDownLatch(1)
        override fun invoke(vararg args: Any?) {
            onMain.set(Looper.myLooper() == Looper.getMainLooper())
            value.set(args.firstOrNull() as? String)
            completed.countDown()
        }
        fun await(): Boolean = completed.await(NativeReadinessHostTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)
    }

    private class RawMapCallback : Callback {
        private val raw = AtomicReference<Any?>()
        private val completed = CountDownLatch(1)
        override fun invoke(vararg args: Any?) {
            raw.set(args.firstOrNull())
            completed.countDown()
        }
        fun await(): Boolean = completed.await(NativeReadinessHostTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)
        fun value(): Any? = raw.get()
    }

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
            return completed.await(NativeReadinessHostTest.TIMEOUT_SECONDS, TimeUnit.SECONDS) && count() >= expected
        }
        fun count(): Int = synchronized(lock) { values.size }
        fun jsonAt(index: Int): JSONObject = JSONObject(synchronized(lock) { values[index] })
        fun errorCodeAt(index: Int): String = JSONObject(synchronized(lock) { values[index] }).getJSONObject("error").getString("code")
        fun successAt(index: Int): Boolean = JSONObject(synchronized(lock) { values[index] }).optBoolean("success")
    }

    private class DelayedHostProvider : LynxCapacitorHostProvider {
        @Volatile var hold = true
        override val supportedMethods: Set<String> = setOf("StatusBar.hide")
        private val started = CountDownLatch(1)
        @Volatile private var pending: ((JSONObject) -> Unit)? = null
        override fun resolve(callerContext: android.content.Context): LynxCapacitorHost = object : LynxCapacitorHost {
            override fun call(pluginId: String, methodName: String, options: JSONObject, complete: (JSONObject) -> Unit) {
                if (hold) {
                    pending = complete
                    started.countDown()
                } else {
                    complete(JSONObject())
                }
            }
        }
        override fun release(callerContext: android.content.Context) = Unit
        fun awaitStarted(): Boolean = started.await(NativeReadinessHostTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)
        fun completeLate() {
            pending?.invoke(JSONObject())
        }
    }

    private class ShellWatcher : Application.ActivityLifecycleCallbacks {
        private var latch = CountDownLatch(1)
        @Volatile private var activity: LynxShellActivity? = null
        fun expect() { activity = null; latch = CountDownLatch(1) }
        fun await(): LynxShellActivity {
            check(latch.await(NativeReadinessHostTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)) { "LynxShellActivity did not resume" }
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
        const val REQUEST_LIMIT_BYTES = 1_048_576
        const val TEMPLATE_APP_ID = "10020000"
        const val HOME_BUNDLE = "HomePage.lynx.bundle"
        const val ECOMMERCE_BUNDLE = "OtaEcommercePage.lynx.bundle"
        const val MISSING_BUNDLE = "MissingPage.lynx.bundle"
        const val DEBUG_PREFIX = "lynx-debug-ota-state:"
        const val FIXTURE_ORIGIN = "http://127.0.0.1:60543"
        val FIXTURE_URI: URI = URI.create(FIXTURE_ORIGIN)
    }
}
