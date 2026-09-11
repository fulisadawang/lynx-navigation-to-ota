package com.example.lynxshell.sample

import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.TextView
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowInsetsControllerCompat
import androidx.fragment.app.FragmentContainerView
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.ota.EmbeddedBundleRegistry
import com.example.lynxshell.tab.LynxTabFragment
import com.example.lynxshell.tab.LynxTabSpec
import com.google.android.material.R
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.button.MaterialButton
import com.google.android.material.color.MaterialColors
import org.json.JSONObject

/**
 * Android 原生 Tab Host Demo。
 *
 * BottomNavigationView 只属于 Sample；可复用的 LynxTabFragment 不知道也不持有任何
 * TabBar。每个 Tab 都是一个独立 Fragment + LynxView，切换时 hide/show 保留旧实例。
 */
class NativeTabDemoActivity : AppCompatActivity() {
    private lateinit var container: FragmentContainerView
    private lateinit var bottomNavigation: BottomNavigationView
    private lateinit var refreshButton: MaterialButton
    private lateinit var tabSpecs: List<LynxTabSpec>
    private var refreshing = false
    private var syncGeneration = 0L
    private var syncStatus = "idle"
    private var activeTabId = "home"
    private var debugStateView: TextView? = null
    private val debugHandler = Handler(Looper.getMainLooper())
    private val debugTick = object : Runnable {
        override fun run() {
            updateDebugState()
            debugHandler.postDelayed(this, 250L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "原生 Tab 承载 Demo"
        // 普通运行直接读取构建同步到 APK assets 根目录的最新 Playground Bundle；
        // 只有显式开启本地 OTA fixture 时才读取 Manifest/current，避免示例 Tab 被旧的
        // OTA current 与最新前端产物分成两个版本，出现两个 Tab 主题不一致。
        val otaV3FixtureEnabled = OtaUserSelectionDebug.enabled ||
            (BuildConfig.DEBUG && BuildConfig.LYNX_OTA_LOCAL_SERVER)
        val tabAppId = if (otaV3FixtureEnabled) {
            if (OtaUserSelectionDebug.enabled) {
                OtaUserSelectionDebug.APP_ID
            } else {
                EmbeddedBundleRegistry(this).uniqueAppIdForBundles(
                    setOf(PLAYGROUND_OTA_BUNDLE_NAME),
                ) ?: error("内置 Manifest 中没有唯一的 Tab Demo appId")
            }
        } else {
            null
        }
        val tabBundleName = if (otaV3FixtureEnabled) {
            OTA_STORE_V3_FIXTURE_BUNDLE_NAME
        } else {
            null
        }
        tabSpecs = listOf(
            LynxTabSpec(
                tabId = "home",
                bundleUrl = "assets://bundles/main.lynx.bundle",
                title = "首页",
                routeKey = "native-tab-home",
                initDataJson = "{\"source\":\"android-native-tab-demo\"}",
                globalPropsJson = "{\"queryItems\":{\"native_tab_id\":\"home\"}}",
                lynxAppId = tabAppId,
                bundleName = tabBundleName,
            ),
            LynxTabSpec(
                tabId = "settings",
                bundleUrl = "assets://bundles/main.lynx.bundle",
                title = "设置",
                routeKey = "native-tab-settings",
                initDataJson = "{\"source\":\"android-native-tab-demo\"}",
                globalPropsJson = "{\"queryItems\":{\"native_tab_id\":\"settings\"}}",
                lynxAppId = tabAppId,
                bundleName = tabBundleName,
            ),
        )

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(android.graphics.Color.WHITE)
        }
        container = FragmentContainerView(this).apply {
            id = if (OtaUserSelectionDebug.enabled) DEBUG_CONTAINER_ID else ViewGroup.generateViewId()
            setBackgroundColor(android.graphics.Color.WHITE)
        }
        refreshButton = MaterialButton(this).apply {
            text = if (OtaUserSelectionDebug.enabled) "刷新 OTA" else "刷新 OTA 后重载 Tab"
            if (OtaUserSelectionDebug.enabled) contentDescription = "ota-refresh"
            setOnClickListener { refreshTabsFromOta() }
        }
        bottomNavigation = BottomNavigationView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
            labelVisibilityMode = BottomNavigationView.LABEL_VISIBILITY_LABELED
        }
        if (OtaUserSelectionDebug.enabled) addDebugControls(root) else {
            root.addView(refreshButton, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        root.addView(
            container,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ),
        )
        root.addView(bottomNavigation)
        setContentView(root)

        tabSpecs.forEachIndexed { index, spec ->
            bottomNavigation.menu.add(0, menuId(index), index, spec.title).apply {
                icon = getDrawable(
                    if (index == 0) android.R.drawable.ic_menu_view
                    else android.R.drawable.ic_menu_preferences,
                )
            }
        }

        val transaction = supportFragmentManager.beginTransaction()
        tabSpecs.forEachIndexed { index, spec ->
            val tag = fragmentTag(spec.tabId)
            val fragment = supportFragmentManager.findFragmentByTag(tag)
                ?: LynxTabFragment.newInstance(spec)
            if (!fragment.isAdded) transaction.add(container.id, fragment, tag)
            if (index != 0) transaction.hide(fragment)
        }
        transaction.commit()

        bottomNavigation.setOnItemSelectedListener { item ->
            val index = tabSpecs.indexOfFirst { tab -> tab.tabId == tabIdFor(item.itemId) }
            if (index >= 0) {
                showTab(index)
                true
            } else {
                false
            }
        }
        bottomNavigation.selectedItemId = menuId(0)
        if (OtaUserSelectionDebug.enabled) bottomNavigation.post {
            tabSpecs.forEachIndexed { index, spec ->
                bottomNavigation.findViewById<android.view.View>(menuId(index))?.contentDescription = "ota-tab-${spec.tabId}"
            }
        }
        syncNativeChrome()
    }

    /** 夜间模式由 Manifest 的 uiMode 接管时，重新应用 DayNight 资源并同步存活 Tab。 */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        delegate.applyDayNight()
        syncNativeChrome()
    }

    /** Material 组件不会在接管 uiMode 后自动重建内部 tint，显式按当前主题刷新宿主 Chrome。 */
    private fun syncNativeChrome() {
        if (!::refreshButton.isInitialized || !::bottomNavigation.isInitialized) return
        val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        val primary = MaterialColors.getColor(
            this,
            R.attr.colorPrimary,
            if (dark) Color.rgb(208, 188, 255) else Color.rgb(103, 80, 164),
        )
        val onPrimary = MaterialColors.getColor(
            this,
            R.attr.colorOnPrimary,
            if (dark) Color.rgb(55, 41, 72) else Color.WHITE,
        )
        val surface = MaterialColors.getColor(
            this,
            R.attr.colorSurface,
            if (dark) Color.rgb(33, 31, 38) else Color.rgb(243, 237, 247),
        )
        val selected = MaterialColors.getColor(
            this,
            R.attr.colorOnSecondaryContainer,
            if (dark) Color.rgb(232, 222, 248) else Color.rgb(29, 25, 43),
        )
        val unselected = MaterialColors.getColor(
            this,
            R.attr.colorOnSurfaceVariant,
            if (dark) Color.rgb(202, 196, 208) else Color.rgb(73, 69, 79),
        )
        val activeIndicator = MaterialColors.getColor(
            this,
            R.attr.colorSecondaryContainer,
            if (dark) Color.rgb(74, 68, 88) else Color.rgb(234, 221, 255),
        )
        refreshButton.backgroundTintList = ColorStateList.valueOf(primary)
        refreshButton.setTextColor(onPrimary)
        bottomNavigation.backgroundTintList = ColorStateList.valueOf(surface)
        val itemColors = ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
            intArrayOf(selected, unselected),
        )
        bottomNavigation.itemIconTintList = itemColors
        bottomNavigation.itemTextColor = itemColors
        bottomNavigation.itemActiveIndicatorColor = ColorStateList.valueOf(activeIndicator)
        window.statusBarColor = primary
        window.navigationBarColor = surface
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = !MaterialColors.isColorLight(primary)
            isAppearanceLightNavigationBars = !dark
        }
    }

    /** 显式刷新结束后重读本地决定；部分 App 失败不遮住其他 App 已提交或撤销的结果。 */
    private fun refreshTabsFromOta(identityChanged: Boolean = false) {
        if (refreshing && !identityChanged) return
        val generation = ++syncGeneration
        val epoch = if (OtaUserSelectionDebug.enabled) LynxRouter.otaUserIdentityEpoch else 0L
        refreshing = true
        syncStatus = "syncing"
        refreshButton.isEnabled = false
        refreshButton.text = "正在同步 OTA…"
        LynxRouter.refreshAllOtaBundles { success ->
            runOnUiThread {
                if (isFinishing || isDestroyed || generation != syncGeneration ||
                    (OtaUserSelectionDebug.enabled && epoch != LynxRouter.otaUserIdentityEpoch)) return@runOnUiThread
                refreshing = false
                refreshButton.isEnabled = true
                refreshButton.text = if (OtaUserSelectionDebug.enabled) "刷新 OTA" else "刷新 OTA 后重载 Tab"
                syncStatus = if (success) "complete" else "failed"
                tabSpecs.forEach { spec ->
                    (supportFragmentManager.findFragmentByTag(fragmentTag(spec.tabId)) as? LynxTabFragment)
                        ?.refreshFromCurrent()
                }
                if (!OtaUserSelectionDebug.enabled) {
                    val message = if (success) "OTA 同步完成，Tab 已重新加载"
                        else "OTA 同步未全成功/部分失败，Tab 已按本地最新决定重新加载"
                    Toast.makeText(this, message, Toast.LENGTH_LONG).show()
                }
                updateDebugState()
            }
        }
    }

    private fun showTab(index: Int) {
        activeTabId = tabSpecs[index].tabId
        val transaction = supportFragmentManager.beginTransaction()
        tabSpecs.forEachIndexed { tabIndex, spec ->
            val fragment = supportFragmentManager.findFragmentByTag(fragmentTag(spec.tabId))
                ?: return@forEachIndexed
            if (tabIndex == index) transaction.show(fragment) else transaction.hide(fragment)
        }
        transaction.commit()
    }

    private fun menuId(index: Int): Int = MENU_ID_BASE + index

    private fun tabIdFor(menuId: Int): String? =
        tabSpecs.getOrNull(menuId - MENU_ID_BASE)?.tabId

    private fun fragmentTag(tabId: String): String = "native-lynx-tab-$tabId"

    private fun addDebugControls(root: LinearLayout) {
        val users = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun userButton(label: String, id: String, audience: OtaUserSelectionDebug.Audience) = MaterialButton(this).apply {
            text = label
            contentDescription = id
            textSize = 12f
            minWidth = 0
            setOnClickListener {
                val changed = OtaUserSelectionDebug.select(this@NativeTabDemoActivity, audience)
                if (changed) {
                    // 立即重新读取当前身份允许的本地版本；随后合并身份切换触发的同步。
                    tabSpecs.forEach { spec ->
                        (supportFragmentManager.findFragmentByTag(fragmentTag(spec.tabId)) as? LynxTabFragment)?.refreshFromCurrent()
                    }
                    refreshTabsFromOta(identityChanged = true)
                } else syncStatus = "unchanged"
                updateDebugState()
            }
        }
        for (button in listOf(
            userButton("用户 A", "ota-user-a", OtaUserSelectionDebug.Audience.A),
            userButton("用户 B", "ota-user-b", OtaUserSelectionDebug.Audience.B),
            userButton("退出", "ota-user-anonymous", OtaUserSelectionDebug.Audience.ANONYMOUS),
        )) users.addView(button, LinearLayout.LayoutParams(0, dp(44), 1f))
        root.addView(users)
        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        actions.addView(refreshButton, LinearLayout.LayoutParams(0, dp(44), 1f))
        actions.addView(MaterialButton(this).apply {
            text = "独立打开 050"
            textSize = 12f
            minWidth = 0
            contentDescription = "ota-open-050"
            setOnClickListener {
                LynxRouter.open(
                    this@NativeTabDemoActivity,
                    OtaUserSelectionDebug.APP_ID,
                    OtaUserSelectionDebug.BUNDLE_NAME,
                    params = mapOf("source" to "android-user-gray-standalone"),
                    options = mapOf("title" to "灰度独立页面", "fullscreen" to false, "showToolbar" to true),
                )
            }
        }, LinearLayout.LayoutParams(0, dp(44), 1f))
        root.addView(actions)
        debugStateView = TextView(this).apply {
            textSize = 11f
            maxLines = 5
            setTextColor(android.graphics.Color.DKGRAY)
            setPadding(dp(8), dp(2), dp(8), dp(2))
            importantForAccessibility = android.view.View.IMPORTANT_FOR_ACCESSIBILITY_YES
        }
        root.addView(debugStateView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(78)))
    }

    private fun updateDebugState() {
        if (!OtaUserSelectionDebug.enabled || !::tabSpecs.isInitialized) return
        val state = OtaUserSelectionDebug.state(this)
        val tabs = JSONObject()
        val visibleLines = mutableListOf<String>()
        for (spec in tabSpecs) {
            val fragment = supportFragmentManager.findFragmentByTag(fragmentTag(spec.tabId)) as? LynxTabFragment
            val raw = fragment?.debugStateDescription() ?: "ready=false release=none source=not_created"
            tabs.put(spec.tabId, JSONObject().put("fragmentInstanceId", fragment?.let(System::identityHashCode) ?: 0).put("state", raw))
            val release = Regex("(?:^|[; |])release=([^; |]+)").find(raw)?.groupValues?.get(1) ?: "none"
            val kind = Regex("(?:^|[; |])kind=([^; |]+)").find(raw)?.groupValues?.get(1) ?: "unknown"
            val ready = Regex("(?:^|;)error=ready(?:;|$)").containsMatchIn(raw)
            visibleLines += "${spec.title}: $release · $kind · ${if (ready) "ready" else "等待/无可用版本"}"
        }
        state.put("tabs", tabs).put("activeTab", activeTabId).put("syncStatus", syncStatus).put("syncGeneration", syncGeneration)
        val syncMessage = when (syncStatus) {
            "complete" -> "同步完成"
            "failed" -> "同步未全成功/部分失败"
            "syncing" -> "同步中"
            "unchanged" -> "身份未变化"
            else -> "等待操作"
        }
        val visibleText = "用户=${state.getString("audience")} · APK=${state.getString("versioncode")} · epoch=${state.getLong("epoch")} · 候选=${state.getBoolean("candidateMode")}\n" +
            visibleLines.joinToString("\n") + "\n$syncMessage · Store=${state.getString("nativeStoreId").takeLast(18)}"
        val accessibilityState = OtaUserSelectionDebug.STATE_PREFIX + state.toString()
        debugStateView?.let { view ->
            if (view.text?.toString() != visibleText) view.text = visibleText
            if (view.contentDescription?.toString() != accessibilityState) view.contentDescription = accessibilityState
        }
    }

    override fun onResume() {
        super.onResume()
        if (OtaUserSelectionDebug.enabled) { debugHandler.removeCallbacks(debugTick); debugHandler.post(debugTick) }
    }

    override fun onPause() {
        debugHandler.removeCallbacks(debugTick)
        super.onPause()
    }

    override fun onDestroy() {
        debugHandler.removeCallbacks(debugTick)
        super.onDestroy()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val MENU_ID_BASE = 0x4C5958
        private const val DEBUG_CONTAINER_ID = 0x4C5960
        private const val PLAYGROUND_OTA_BUNDLE_NAME = "main.lynx.bundle"
        private const val OTA_STORE_V3_FIXTURE_BUNDLE_NAME = "pages/10000001/bundle-050.lynx.bundle"
    }
}
