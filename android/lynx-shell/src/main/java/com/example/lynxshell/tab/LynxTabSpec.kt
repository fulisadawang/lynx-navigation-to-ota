package com.example.lynxshell.tab

/**
 * 一个原生 Tab 内容的声明，不包含 BottomNavigation/TabBar UI。
 *
 * Tab Host 只负责把它交给 Fragment；页面 Bundle、业务参数和 OTA 逻辑仍由宿主决定。
 */
data class LynxTabSpec(
    val tabId: String,
    val bundleUrl: String,
    val title: String = tabId,
    val routeKey: String = tabId,
    val initDataJson: String = "{}",
    val globalPropsJson: String = "{}",
    val lynxAppId: String? = null,
    val bundleName: String? = null,
    val backgroundColor: String = "#FFFFFF",
)
