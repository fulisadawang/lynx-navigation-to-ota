package com.example.lynxshell.sample

import android.content.Context
import android.os.Build
import com.example.lynxshell.LynxRouter
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Sample-only 测试配置；持久化身份只允许 A/B/anonymous，不保存业务 userId。 */
object OtaUserSelectionDebug {
    const val APP_ID = "10000001"
    const val BUNDLE_NAME = "pages/10000001/bundle-050.lynx.bundle"
    const val STATE_PREFIX = "ota-user-debug-state|"
    const val BOOTSTRAP_PATH = "ota-user-gray-test/bootstrap.json"
    private const val PREFS = "ota_user_gray_demo"
    private const val STORE_PARENT = "ota-user-gray-test/stores"

    enum class Audience(val wire: String, val userId: String?) {
        A("A", "user_demo_A"),
        B("B", "user_demo_B"),
        ANONYMOUS("anonymous", null);

        companion object {
            fun fromWire(value: String): Audience = values().firstOrNull { it.wire == value }
                ?: error("验收身份仅允许 A/B/anonymous")
        }
    }

    data class Settings(val nativeStoreId: String, val candidateMode: Boolean, val initialAudience: Audience)

    val enabled: Boolean get() = BuildConfig.DEBUG && BuildConfig.LYNX_TEST_OTA_USER_SELECTION
    lateinit var settings: Settings
        private set
    @Volatile private var runtimeStoreRoot: String? = null
    @Volatile private var storeVerificationError: String? = null

    /** 必须在 Router.install 前调用；bootstrap 是 ADB 脚本写入的独立合成测试输入。 */
    fun prepareBeforeInstall(context: Context): Settings? {
        if (!enabled) return null
        require(BuildConfig.LYNX_OTA_LOCAL_SERVER)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val bootstrap = File(context.filesDir, BOOTSTRAP_PATH)
        if (bootstrap.isFile) {
            val json = JSONObject(bootstrap.readText())
            val audience = Audience.fromWire(json.getString("audience"))
            val storeId = validateStoreId(json.getString("nativeStoreId"))
            val candidate = if (json.has("candidateMode")) json.getBoolean("candidateMode")
                else prefs.getBoolean("candidateMode", BuildConfig.LYNX_OTA_CANDIDATE_MODE)
            check(prefs.edit().putString("audience", audience.wire).putString("nativeStoreId", storeId)
                .putBoolean("candidateMode", candidate).commit())
            check(bootstrap.delete()) { "无法消费独立验收 bootstrap" }
        }
        val storeId = validateStoreId(prefs.getString("nativeStoreId", null) ?: "android-${UUID.randomUUID()}")
        check(prefs.edit().putString("nativeStoreId", storeId).commit())
        settings = Settings(storeId, prefs.getBoolean("candidateMode", BuildConfig.LYNX_OTA_CANDIDATE_MODE), audience(context))
        LynxRouter.registerOtaUserId(settings.initialAudience.userId)
        LynxRouter.debugExposeOtaState(true)
        return settings
    }

    fun audience(context: Context): Audience = Audience.fromWire(
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("audience", "anonymous") ?: "anonymous",
    )

    fun select(context: Context, audience: Audience): Boolean {
        check(enabled)
        check(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("audience", audience.wire).commit())
        return if (audience == Audience.ANONYMOUS) LynxRouter.clearOtaUserId() else LynxRouter.registerOtaUserId(audience.userId)
    }

    fun candidateForNextLaunch(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("candidateMode", settings.candidateMode)

    fun setCandidateForNextLaunch(context: Context, enabled: Boolean) {
        check(OtaUserSelectionDebug.enabled)
        check(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("candidateMode", enabled).commit())
    }

    fun storageDirectory(context: Context): File = File(context.filesDir, "$STORE_PARENT/${settings.nativeStoreId}")

    /** 对照真实 Runtime 只读诊断根目录，不能仅把配置值当作实际 Store 证据。 */
    fun verifyRuntimeStore(context: Context) {
        if (!enabled) return
        Thread({
            runCatching {
                val actual = LynxRouter.otaStorageSnapshot()?.rootPath ?: error("Runtime Store 诊断不可用")
                check(File(actual).canonicalFile == storageDirectory(context).canonicalFile) { "Runtime Store 未使用独立验收目录" }
                runtimeStoreRoot = actual
            }.onFailure { storeVerificationError = it.message ?: "Store 校验失败" }
        }, "ota-debug-store-identity").apply { isDaemon = true }.start()
    }

    fun state(context: Context): JSONObject = JSONObject().apply {
        put("testMode", enabled)
        put("audience", audience(context).wire)
        put("nativeStoreId", settings.nativeStoreId)
        put("storeRelativePath", "files/$STORE_PARENT/${settings.nativeStoreId}")
        put("runtimeStoreRoot", runtimeStoreRoot ?: JSONObject.NULL)
        put("storeVerified", runtimeStoreRoot != null)
        put("storeVerificationError", storeVerificationError ?: JSONObject.NULL)
        put("versioncode", nativeVersionCode(context))
        put("apiOrigin", BuildConfig.LYNX_OTA_LOCAL_BASE_URL)
        put("epoch", LynxRouter.otaUserIdentityEpoch)
        put("candidateMode", settings.candidateMode)
        put("candidateNextLaunch", candidateForNextLaunch(context))
    }

    fun nativeVersionCode(context: Context): String {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toString() else {
            @Suppress("DEPRECATION")
            info.versionCode.toString()
        }
    }

    private fun validateStoreId(value: String): String {
        require(value.matches(Regex("[A-Za-z0-9_-]{1,96}"))) { "验收 Store ID 不合法" }
        return value
    }
}
