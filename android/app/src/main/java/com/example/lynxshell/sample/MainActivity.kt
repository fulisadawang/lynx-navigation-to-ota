package com.example.lynxshell.sample

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.ota.EmbeddedBundleRegistry
import com.google.android.material.button.MaterialButton

/**
 * 原生调试入口。
 *
 * 业务 App 集成时通常由自己的 Router 直接构造 LynxPageRequest，
 * 这个 Activity 可以保留为 InHouse 工具，也可以从 Release Manifest 中移除。
 */
class MainActivity : AppCompatActivity() {
    private companion object {
        const val OTA_TEST_BUNDLE_NAME = "home.lynx.bundle"
        const val PLAYGROUND_OTA_BUNDLE_NAME = "main.lynx.bundle"
        const val OTA_STORE_V3_FIXTURE_BUNDLE_NAME = "pages/10000001/bundle-050.lynx.bundle"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContentView(R.layout.activity_launcher)

        findViewById<MaterialButton>(R.id.open_playground_button).setOnClickListener {
            openPlaygroundHome()
        }

        findViewById<MaterialButton>(R.id.open_ota_acceptance_button).setOnClickListener {
            openOtaAcceptanceHome()
        }

        findViewById<MaterialButton>(R.id.open_native_tab_demo_button).setOnClickListener {
            startActivity(Intent(this, NativeTabDemoActivity::class.java))
        }

        findViewById<MaterialButton>(R.id.open_ota_storage_inspector_button).setOnClickListener {
            startActivity(Intent(this, OtaStorageInspectorActivity::class.java))
        }

        // Demo 脚本入口：复用 Application 启动/回前台的同一条原生全量 OTA 链路，
        // App ID 由接口返回，Demo 不自行拼接、过滤或生成 App ID。
        findViewById<MaterialButton>(R.id.manual_sync_all_ota_button).setOnClickListener {
            LynxRouter.onApplicationForeground()
            Toast.makeText(this, "已触发原生全量 OTA 同步，正在后台执行", Toast.LENGTH_LONG).show()
        }

        findViewById<MaterialButton>(R.id.clear_ota_button).setOnClickListener {
            it.isEnabled = false
            Toast.makeText(this, "正在清理本地 OTA Bundle…", Toast.LENGTH_SHORT).show()
            LynxRouter.deleteAllOtaBundles { success, message ->
                it.isEnabled = true
                val text = if (success) {
                    "已清理全部 OTA Bundle；下次打开会重新下载"
                } else {
                    message ?: "OTA Bundle 清理失败"
                }
                Toast.makeText(this, text, Toast.LENGTH_LONG).show()
            }
        }

        // 默认直接进入 OTA 验收首页；普通 Playground 入口仍保留在原生 Launcher 按钮中。
        // 真机验收可通过显式 debug intent 直接进入原生 Tab，避免依赖 Lynx 页面点击坐标。
        if (BuildConfig.DEBUG && intent.getBooleanExtra("lynx_shell.open_native_tab", false) && savedInstanceState == null) {
            startActivity(Intent(this, NativeTabDemoActivity::class.java))
            return
        }
        if (BuildConfig.DEBUG && intent.getBooleanExtra("lynx_shell.open_playground", false) && savedInstanceState == null) {
            if (intent.getBooleanExtra("lynx_shell.fail_first_screen", false)) {
                LynxRouter.debugFailNextFirstScreen()
            }
            openPlaygroundHome()
            return
        }
        if (!intent.getBooleanExtra("lynx_shell.show_native_launcher", false) && savedInstanceState == null) {
            openOtaAcceptanceHome()
        }
    }

    private fun openOtaAcceptanceHome() {
        runCatching {
            val appId = demoOtaAppId()
            LynxRouter.open(
                context = this,
                lynxAppId = appId,
                bundleName = demoBundleName(OTA_TEST_BUNDLE_NAME),
                params = mapOf(
                    "source" to "android-ota-acceptance-home",
                    "acceptance" to true,
                ),
                options = mapOf(
                    "title" to "OTA 验收首页",
                    "fullscreen" to true,
                    "showToolbar" to false,
                    "backGestureEnabled" to true,
                ),
            )
        }.onFailure { error ->
            Toast.makeText(this, error.message ?: "OTA 验收首页打开失败", Toast.LENGTH_LONG).show()
        }
    }

    private fun openPlaygroundHome() {
        runCatching {
            val appId = demoOtaAppId()
            LynxRouter.open(
                context = this,
                lynxAppId = appId,
                bundleName = demoBundleName(PLAYGROUND_OTA_BUNDLE_NAME),
                params = mapOf("source" to "android-playground-ota-home"),
                options = mapOf(
                    "title" to "Playground OTA 首页",
                    "fullscreen" to true,
                    "showToolbar" to false,
                    "backGestureEnabled" to true,
                ),
            )
        }.onFailure { error ->
            Toast.makeText(this, error.message ?: "Playground OTA 首页打开失败", Toast.LENGTH_LONG).show()
        }
    }

    /** Demo 的 appId 只从 APK 内置 Manifest 推导，不按 bundle 文件名猜测或自行生成。 */
    private fun demoOtaAppId(): String =
        EmbeddedBundleRegistry(this).uniqueAppIdForBundles(
            setOf(OTA_TEST_BUNDLE_NAME, PLAYGROUND_OTA_BUNDLE_NAME),
        ) ?: error("内置 Manifest 中没有唯一的 OTA Demo appId")

    private fun demoBundleName(embeddedBundleName: String): String =
        if (BuildConfig.DEBUG && BuildConfig.LYNX_OTA_LOCAL_SERVER) {
            OTA_STORE_V3_FIXTURE_BUNDLE_NAME
        } else {
            embeddedBundleName
        }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // reLaunch 的 CLEAR_TOP 会复用当前实例；更新 Intent 方便宿主读取最新主页参数。
        setIntent(intent)
    }

}
