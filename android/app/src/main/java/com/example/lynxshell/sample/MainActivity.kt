package com.example.lynxshell.sample

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.example.lynxshell.LynxRouter
import com.google.android.material.button.MaterialButton

/**
 * 原生调试入口。
 *
 * 业务 App 集成时通常由自己的 Router 直接构造 LynxPageRequest，
 * 这个 Activity 可以保留为 InHouse 工具，也可以从 Release Manifest 中移除。
 */
class MainActivity : AppCompatActivity() {
    private companion object {
        // 与服务端 TEST OTA demo 以及 lynx-ota-demo-10000001 保持一致。
        const val OTA_TEST_APP_ID = "10000001"
        const val OTA_TEST_BUNDLE_NAME = "home.lynx.bundle"
        const val PLAYGROUND_OTA_BUNDLE_NAME = "main.lynx.bundle"
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
        if (!intent.getBooleanExtra("lynx_shell.show_native_launcher", false) && savedInstanceState == null) {
            openOtaAcceptanceHome()
        }
    }

    private fun openOtaAcceptanceHome() {
        runCatching {
            LynxRouter.open(
                context = this,
                lynxAppId = OTA_TEST_APP_ID,
                bundleName = OTA_TEST_BUNDLE_NAME,
                params = mapOf(
                    "source" to "android-ota-acceptance-home",
                    "acceptance" to true,
                ),
                options = mapOf(
                    "title" to "OTA 验收首页",
                    "fullscreen" to true,
                    "showToolbar" to false,
                ),
            )
        }.onFailure { error ->
            Toast.makeText(this, error.message ?: "OTA 验收首页打开失败", Toast.LENGTH_LONG).show()
        }
    }

    private fun openPlaygroundHome() {
        runCatching {
            LynxRouter.open(
                context = this,
                lynxAppId = OTA_TEST_APP_ID,
                bundleName = PLAYGROUND_OTA_BUNDLE_NAME,
                params = mapOf("source" to "android-playground-ota-home"),
                options = mapOf(
                    "title" to "Playground OTA 首页",
                    "fullscreen" to true,
                    "showToolbar" to false,
                ),
            )
        }.onFailure { error ->
            Toast.makeText(this, error.message ?: "Playground OTA 首页打开失败", Toast.LENGTH_LONG).show()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // reLaunch 的 CLEAR_TOP 会复用当前实例；更新 Intent 方便宿主读取最新主页参数。
        setIntent(intent)
    }

}
