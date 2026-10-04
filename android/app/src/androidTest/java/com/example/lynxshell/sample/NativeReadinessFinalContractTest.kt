package com.example.lynxshell.sample

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.test.InstrumentationTestCase
import android.view.View
import android.view.ViewGroup
import androidx.core.content.FileProvider
import com.example.lynxcapacitormodule.LynxCapacitorModule
import com.example.lynxcapacitormodule.NativeCameraCaptureCapabilities
import com.example.lynxcapacitormodule.NativeFileProviderContract
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.container.LynxShellActivity
import com.example.lynxshell.ota.LynxOtaConfig
import com.lynx.jsbridge.LynxModuleFactory
import com.lynx.react.bridge.Callback
import com.lynx.tasm.LynxTemplateRender
import com.lynx.tasm.LynxView
import java.io.File
import java.io.OutputStream
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.jvm.functions.Function1
import org.json.JSONObject

/** 普通软件契约：系统方向、文本缩放、HTTP 失败边界与真实 Bitmap 解码路径。 */
class NativeReadinessFinalContractTest : InstrumentationTestCase() {
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

    fun testFactoryModuleAppliesOrientationContractsAndTextZoomRequest() {
        control("v1", reset = true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        val module = factoryModule(requireNotNull(shell.currentLynxView()))
        val originalRequested = shell.requestedOrientation
        val originalZoom = invoke(module, "TextZoom", "get", JSONObject())
            .getJSONObject("data")
            .getDouble("value")
        try {
            val landscape = invoke(module, "ScreenOrientation", "lock", JSONObject().put("orientation", "landscape"))
            assertTrue("landscape lock must complete through the active Host adapter: $landscape", landscape.optBoolean("success"))
            val landscapeData = landscape.getJSONObject("data")
            assertTrue("landscape lock must report applied window state", landscapeData.getBoolean("applied"))
            assertEquals("window_orientation", landscapeData.getString("verification"))
            assertEquals("landscape", landscapeData.getString("requested"))
            assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, shell.requestedOrientation)
            assertEquals(Configuration.ORIENTATION_LANDSCAPE, shell.resources.configuration.orientation)

            val rejected = invoke(module, "ScreenOrientation", "lock", JSONObject().put("orientation", "landscape-secondary"))
            assertFalse("secondary orientation must not be claimed by this Host: $rejected", rejected.optBoolean("success"))
            assertEquals("UNSUPPORTED", rejected.getJSONObject("error").getString("code"))
            assertEquals("unsupported secondary request must not alter current requested orientation", ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, shell.requestedOrientation)
            assertEquals("unsupported secondary request must not alter current window orientation", Configuration.ORIENTATION_LANDSCAPE, shell.resources.configuration.orientation)

            val portrait = invoke(module, "ScreenOrientation", "lock", JSONObject().put("orientation", "portrait"))
            assertTrue("portrait lock must complete through the active Host adapter: $portrait", portrait.optBoolean("success"))
            assertEquals("portrait", portrait.getJSONObject("data").getString("orientation"))
            assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, shell.requestedOrientation)
            assertEquals(Configuration.ORIENTATION_PORTRAIT, shell.resources.configuration.orientation)

            val unlocked = invoke(module, "ScreenOrientation", "unlock", JSONObject())
            assertTrue("unlock must complete through the active Host adapter: $unlocked", unlocked.optBoolean("success"))
            assertFalse("unlock reply must declare unlocked", unlocked.getJSONObject("data").getBoolean("locked"))
            assertTrue("unlock must still report actual request verification", unlocked.getJSONObject("data").getBoolean("applied"))
            assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, shell.requestedOrientation)

            val requestedZoom = if (originalZoom == 1.15) 1.0 else 1.15
            val setZoom = invoke(module, "TextZoom", "set", JSONObject().put("value", requestedZoom))
            assertTrue("TextZoom.set must reach the active LynxView adapter: $setZoom", setZoom.optBoolean("success"))
            assertEquals("lynx_view_request", setZoom.getJSONObject("data").getString("verification"))
            assertEquals(requestedZoom, setZoom.getJSONObject("data").getDouble("value"), 0.001)
            val observedZoom = invoke(module, "TextZoom", "get", JSONObject())
            assertEquals("lynx_view_request", observedZoom.getJSONObject("data").getString("verification"))
            assertEquals(requestedZoom, observedZoom.getJSONObject("data").getDouble("value"), 0.001)
        } finally {
            runOnMain { shell.requestedOrientation = originalRequested }
            invoke(module, "TextZoom", "set", JSONObject().put("value", originalZoom))
        }
    }

    fun testFactoryModuleReturnsStructuredTimeoutAndLocalTlsFailuresThenRecovers() {
        control("v1", reset = true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        val module = factoryModule(requireNotNull(shell.currentLynxView()))

        val timeout = invoke(
            module,
            "CapacitorHttp",
            "get",
            JSONObject()
                .put("url", "$FIXTURE_ORIGIN/_readiness/stream?id=final-timeout-${UUID.randomUUID()}")
                .put("connectTimeout", 1_000)
                .put("readTimeout", 25),
        )
        assertFalse("read timeout below the fixture's 100ms chunk interval must fail structurally: $timeout", timeout.optBoolean("success"))
        assertEquals("NATIVE_ERROR", timeout.getJSONObject("error").getString("code"))

        val tls = invoke(
            module,
            "CapacitorHttp",
            "get",
            JSONObject()
                .put("url", "https://127.0.0.1:60543/_readiness/state")
                .put("connectTimeout", 1_000)
                .put("readTimeout", 1_000),
        )
        assertFalse("HTTPS against the owned plain-HTTP loopback fixture must fail structurally: $tls", tls.optBoolean("success"))
        assertEquals("NATIVE_ERROR", tls.getJSONObject("error").getString("code"))

        val recovered = invoke(module, "CapacitorHttp", "get", JSONObject().put("url", "$FIXTURE_ORIGIN/_readiness/state"))
        assertTrue("a later real HTTP request must still use the network lane normally: $recovered", recovered.optBoolean("success"))
    }

    fun testCorruptImageUsesProductionCameraResultIoAndReturnsStructuredFailure() {
        control("v1", reset = true)
        installRuntime()
        val shell = openHome()
        awaitPromoted(shell)
        factoryModule(requireNotNull(shell.currentLynxView()))

        val directory = File(application.cacheDir, "native-readiness-final-image").apply { mkdirs() }
        val corrupt = File(directory, "invalid-${UUID.randomUUID()}.img").apply { writeBytes(byteArrayOf(0x00, 0x13, 0x37, 0x42)) }
        val uri = FileProvider.getUriForFile(application, NativeFileProviderContract.authority(application), corrupt)
        val result = invokeCorruptImageResultPath(shell, uri)

        assertTrue("corrupt image must return a structured camera-result error: $result", result.has("error"))
        assertEquals("actual BitmapFactory bounds path reports IO for undecodable bytes", "IO", result.getJSONObject("error").getString("code"))
        assertTrue("test-only corrupt image must be removed", corrupt.delete())
    }

    private fun installRuntime() {
        val storage = File(application.filesDir, "native-readiness-final-${UUID.randomUUID()}")
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

    private fun invokeCorruptImageResultPath(activity: LynxShellActivity, uri: Uri): JSONObject {
        val requestCode = 47_701
        val completed = CountDownLatch(1)
        val result = AtomicReference<JSONObject?>()
        val callback = object : Function1<JSONObject, Unit> {
            override fun invoke(value: JSONObject) {
                result.set(value)
                completed.countDown()
            }
        }
        val root = NativeCameraCaptureCapabilities::class.java
        val pendingField = root.getDeclaredField("pendingRequest").apply { isAccessible = true }
        assertNull("camera result path must start without a pending production request", pendingField.get(null))
        val pendingClass = Class.forName("com.example.lynxcapacitormodule.NativeCameraCaptureCapabilities\$PendingRequest")
        val requestKind = Class.forName("com.example.lynxcapacitormodule.NativeCameraCaptureCapabilities\$RequestKind")
            .enumConstants
            .single { (it as Enum<*>).name == "PICK_IMAGES" }
        val resultMode = Class.forName("com.example.lynxcapacitormodule.NativeCameraCaptureCapabilities\$ResultMode")
            .enumConstants
            .single { (it as Enum<*>).name == "LEGACY" }
        val constructor = pendingClass.declaredConstructors.single { it.parameterCount == 11 }.apply { isAccessible = true }
        val pending = constructor.newInstance(
            "native-readiness-invalid-image",
            WeakReference<Activity>(activity),
            requestCode,
            requestKind,
            Intent(),
            null,
            1,
            callback,
            resultMode,
            false,
            null,
        )
        pendingField.set(null, pending)
        try {
            val handled = NativeCameraCaptureCapabilities.onActivityResult(
                requestCode,
                Activity.RESULT_OK,
                Intent().setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            )
            assertTrue("production Camera result handler must accept the injected real URI result", handled)
            assertTrue("production local IO path did not return an image result", completed.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
            return requireNotNull(result.get())
        } finally {
            pendingField.set(null, null)
        }
    }

    private fun refreshAll() {
        val completed = CountDownLatch(1)
        val success = AtomicBoolean(false)
        runOnMain { LynxRouter.refreshAllOtaBundles { success.set(it); completed.countDown() } }
        assertTrue("fixture OTA sync did not finish", completed.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertTrue("fixture OTA sync failed", success.get())
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
                    mapOf("nativeReadinessFinalContract" to true),
                    mapOf("animated" to false, "showToolbar" to false),
                ).isSuccess,
            )
        }
        assertTrue("router must accept real Home template", accepted.get())
        return watcher.await().also(opened::add)
    }

    private fun awaitPromoted(shell: LynxShellActivity) {
        val deadline = SystemClock.elapsedRealtime() + TIMEOUT_SECONDS * 1_000L
        var latest = ""
        while (SystemClock.elapsedRealtime() < deadline) {
            runOnMain { latest = debugState(shell.window.decorView).orEmpty() }
            if (latest.contains("state=ready") && latest.contains("source=ota_current") && latest.contains("promoted=true")) return
            SystemClock.sleep(80)
        }
        fail("real Home did not promote candidate: $latest")
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
        val callback = CallbackCapture()
        runOnMain {
            module.handleCall(
                JSONObject()
                    .put("callbackId", "final-$plugin-$method-${UUID.randomUUID()}")
                    .put("pluginId", plugin)
                    .put("methodName", method)
                    .put("options", options)
                    .toString(),
                callback,
            )
        }
        assertTrue("$plugin.$method did not return", callback.await())
        return JSONObject(requireNotNull(callback.value.get()))
    }

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

    private fun installedVersionCode(): Long {
        val info = application.packageManager.getPackageInfo(application.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else {
            @Suppress("DEPRECATION") info.versionCode.toLong()
        }
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

    private class CallbackCapture : Callback {
        val value = AtomicReference<String?>()
        private val completed = CountDownLatch(1)
        override fun invoke(vararg args: Any?) {
            value.set(args.firstOrNull() as? String)
            completed.countDown()
        }
        fun await(): Boolean = completed.await(NativeReadinessFinalContractTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)
    }

    private class ShellWatcher : Application.ActivityLifecycleCallbacks {
        private var latch = CountDownLatch(1)
        @Volatile private var activity: LynxShellActivity? = null
        fun expect() {
            activity = null
            latch = CountDownLatch(1)
        }
        fun await(): LynxShellActivity {
            check(latch.await(NativeReadinessFinalContractTest.TIMEOUT_SECONDS, TimeUnit.SECONDS)) { "LynxShellActivity did not resume" }
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
        const val DEBUG_PREFIX = "lynx-debug-ota-state:"
        const val FIXTURE_ORIGIN = "http://127.0.0.1:60543"
        val FIXTURE_URI: URI = URI.create(FIXTURE_ORIGIN)
    }
}
