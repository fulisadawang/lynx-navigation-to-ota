package com.example.lynxshell.runtime

import android.content.Context
import android.os.Build
import java.util.Locale
import java.util.concurrent.CopyOnWriteArraySet
import org.json.JSONObject

/**
 * Android Module 的 App 语言状态源。
 *
 * App 选择只保存覆盖值；没有覆盖值时根据系统语言在当前两种受支持语言中选择，其他
 * 系统语言回退中文。这个 Store 不调用 Android 的系统语言设置 API，避免改变宿主 App
 * 或设备的语言设置。
 */
data class LynxLocaleState(
    val schemaVersion: Int,
    val revision: Long,
    val systemLocale: String,
    val appLocale: String?,
    val effectiveLocale: String,
    val language: String,
    val direction: String,
    val source: String,
    val status: String,
) {
    /** 提供给 Bridge/GlobalEvent 的字段；没有 App 覆盖时省略可空的覆盖字段。 */
    fun toMap(): HashMap<String, Any> = hashMapOf<String, Any>(
        "schemaVersion" to schemaVersion,
        "revision" to revision,
        "systemLocale" to systemLocale,
        "locale" to effectiveLocale,
        "effectiveLocale" to effectiveLocale,
        "language" to language,
        "appLanguage" to language,
        "direction" to direction,
        "source" to source,
        "status" to status,
        "formatLocale" to effectiveLocale,
    ).also { values ->
        appLocale?.let {
            values["appLocale"] = it
            values["appLocaleOverride"] = it
        }
    }

    /** GlobalProps 需要保留 null 与“未提供”之间的区别，使用 Lynx 可识别的 JSONObject.NULL。 */
    fun toGlobalMap(): HashMap<String, Any> = toMap().also { values ->
        if (appLocale == null) {
            values["appLocale"] = JSONObject.NULL
            values["appLocaleOverride"] = JSONObject.NULL
        }
    }
}

data class LynxLocaleChange(
    val state: LynxLocaleState,
    val changed: Boolean,
)

/** 只支持业务已经确认的中文和英文。 */
object LynxLocaleStore {
    const val ZH_CN = "zh-CN"
    const val EN_US = "en-US"

    private const val PREFERENCES_NAME = "lynx_shell_environment"
    private const val APP_LOCALE_KEY = "app_locale"
    private const val REVISION_KEY = "locale_revision"

    private val lock = Any()
    private var applicationContext: Context? = null
    private var appLocale: String? = null
    private var revision = 0L
    private var lastSignature: String? = null
    private val changeListeners = CopyOnWriteArraySet<(LynxLocaleState) -> Unit>()

    /** 供宿主自己的原生 Chrome（例如 Native TabBar）订阅同一份语言状态。 */
    fun addChangeListener(listener: (LynxLocaleState) -> Unit): AutoCloseable {
        changeListeners += listener
        return AutoCloseable { changeListeners -= listener }
    }

    internal fun notifyChanged(state: LynxLocaleState) {
        changeListeners.forEach { listener -> listener(state) }
    }

    fun install(context: Context) {
        val appContext = context.applicationContext
        synchronized(lock) {
            if (applicationContext === appContext) return
            applicationContext = appContext
            val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            appLocale = preferences.getString(APP_LOCALE_KEY, null)?.let(::normalizePersistedLocale)
            revision = preferences.getLong(REVISION_KEY, 0L).coerceAtLeast(0L)
            lastSignature = null
        }
    }

    fun current(context: Context): LynxLocaleState = synchronized(lock) {
        ensureInstalledLocked(context)
        currentLocked(context)
    }

    fun current(): LynxLocaleState = synchronized(lock) {
        val context = applicationContext
            ?: error("LynxRouter.install(application) 必须先于 currentLocale() 调用")
        currentLocked(context)
    }

    fun applicationContext(): Context = synchronized(lock) {
        applicationContext
            ?: error("LynxRouter.install(application) 必须先于 setLocale() 调用")
    }

    fun setLocale(context: Context, localeTag: String?): LynxLocaleChange = synchronized(lock) {
        ensureInstalledLocked(context)
        val before = currentLocked(context)
        val normalized = localeTag?.let { value ->
            if (value.trim().equals("system", ignoreCase = true)) null else normalizeRequestedLocale(value)
        }
        if (normalized == appLocale) return LynxLocaleChange(before, changed = false)

        appLocale = normalized
        preferencesLocked().edit().apply {
            if (normalized == null) remove(APP_LOCALE_KEY) else putString(APP_LOCALE_KEY, normalized)
        }.apply()
        val after = currentLocked(context)
        LynxLocaleChange(after, changed = before != after)
    }

    fun normalizeRequestedLocale(value: String): String {
        return when (value.trim().lowercase(Locale.ROOT)) {
            "zh-cn" -> ZH_CN
            "en-us" -> EN_US
            else -> throw IllegalArgumentException("仅支持 zh-CN 和 en-US")
        }
    }

    private fun normalizePersistedLocale(value: String): String? =
        runCatching { normalizeRequestedLocale(value) }.getOrNull()

    private fun ensureInstalledLocked(context: Context) {
        if (applicationContext == null) {
            val appContext = context.applicationContext
            applicationContext = appContext
            val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            appLocale = preferences.getString(APP_LOCALE_KEY, null)?.let(::normalizePersistedLocale)
            revision = preferences.getLong(REVISION_KEY, 0L).coerceAtLeast(0L)
        }
    }

    private fun preferencesLocked() = requireNotNull(applicationContext)
        .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private fun currentLocked(context: Context): LynxLocaleState {
        val system = readSystemLocale(context)
        val supportedSystem = when {
            system.equals(ZH_CN, ignoreCase = true) || system.startsWith("zh-", ignoreCase = true) -> ZH_CN
            system.equals(EN_US, ignoreCase = true) || system.startsWith("en-", ignoreCase = true) -> EN_US
            else -> null
        }
        val effective = appLocale ?: supportedSystem ?: ZH_CN
        val source = when {
            appLocale != null -> "app"
            supportedSystem != null -> "system"
            else -> "fallback"
        }
        val signature = listOf(system, appLocale, effective, source).joinToString("|")
        if (lastSignature == null) {
            revision = revision.coerceAtLeast(1L)
            lastSignature = signature
            persistRevisionLocked()
        } else if (lastSignature != signature) {
            revision = revision.coerceAtLeast(0L) + 1L
            lastSignature = signature
            persistRevisionLocked()
        }
        return LynxLocaleState(
            schemaVersion = 1,
            revision = revision,
            systemLocale = system,
            appLocale = appLocale,
            effectiveLocale = effective,
            language = if (effective == EN_US) "en" else "zh",
            direction = "ltr",
            source = source,
            status = "ready",
        )
    }

    private fun persistRevisionLocked() {
        preferencesLocked().edit().putLong(REVISION_KEY, revision).apply()
    }

    private fun readSystemLocale(context: Context): String {
        val configuration = context.resources.configuration
        val locale = if (Build.VERSION.SDK_INT >= 24) {
            configuration.locales.takeIf { !it.isEmpty }?.get(0)
        } else {
            @Suppress("DEPRECATION") configuration.locale
        } ?: Locale.getDefault()
        return locale.toLanguageTag().ifBlank { Locale.getDefault().toLanguageTag() }
    }
}
