package com.example.lynxshell.sample

import android.os.Bundle
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.FragmentContainerView
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.tab.LynxTabFragment
import com.example.lynxshell.tab.LynxTabSpec
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.button.MaterialButton

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
    private var refreshing = false

    private val tabSpecs = listOf(
        LynxTabSpec(
            tabId = "home",
            bundleUrl = "assets://bundles/main.lynx.bundle",
            title = "首页",
            routeKey = "native-tab-home",
            initDataJson = "{\"source\":\"android-native-tab-demo\"}",
            globalPropsJson = "{\"queryItems\":{\"native_tab_id\":\"home\"}}",
            lynxAppId = PLAYGROUND_OTA_APP_ID,
            bundleName = PLAYGROUND_OTA_BUNDLE_NAME,
        ),
        LynxTabSpec(
            tabId = "settings",
            bundleUrl = "assets://bundles/main.lynx.bundle",
            title = "设置",
            routeKey = "native-tab-settings",
            initDataJson = "{\"source\":\"android-native-tab-demo\"}",
            globalPropsJson = "{\"queryItems\":{\"native_tab_id\":\"settings\"}}",
            lynxAppId = PLAYGROUND_OTA_APP_ID,
            bundleName = PLAYGROUND_OTA_BUNDLE_NAME,
        ),
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "原生 Tab 承载 Demo"

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(android.graphics.Color.WHITE)
        }
        container = FragmentContainerView(this).apply {
            id = ViewGroup.generateViewId()
            setBackgroundColor(android.graphics.Color.WHITE)
        }
        refreshButton = MaterialButton(this).apply {
            text = "刷新 OTA 后重载 Tab"
            setOnClickListener { refreshTabsFromOta() }
        }
        bottomNavigation = BottomNavigationView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
            labelVisibilityMode = BottomNavigationView.LABEL_VISIBILITY_LABELED
        }
        root.addView(
            refreshButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
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
    }

    /** 先显式同步全量 OTA，再让所有 Tab 重新读取本地已提交 current。 */
    private fun refreshTabsFromOta() {
        if (refreshing) return
        refreshing = true
        refreshButton.isEnabled = false
        refreshButton.text = "正在同步 OTA…"
        LynxRouter.refreshAllOtaBundles { success ->
            runOnUiThread {
                refreshing = false
                refreshButton.isEnabled = true
                refreshButton.text = "刷新 OTA 后重载 Tab"
                if (success) {
                    tabSpecs.forEach { spec ->
                        (supportFragmentManager.findFragmentByTag(fragmentTag(spec.tabId)) as? LynxTabFragment)
                            ?.refreshFromCurrent()
                    }
                    Toast.makeText(this, "OTA 同步完成，Tab 已重新加载", Toast.LENGTH_LONG).show()
                } else {
                    Toast.makeText(this, "OTA 同步失败，保留当前 Tab 版本", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun showTab(index: Int) {
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

    companion object {
        private const val MENU_ID_BASE = 0x4C5958
        private const val PLAYGROUND_OTA_APP_ID = "10000001"
        private const val PLAYGROUND_OTA_BUNDLE_NAME = "main.lynx.bundle"
    }
}
