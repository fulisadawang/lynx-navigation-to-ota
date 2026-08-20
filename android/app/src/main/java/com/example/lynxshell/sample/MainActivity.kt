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
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContentView(R.layout.activity_launcher)

        findViewById<MaterialButton>(R.id.open_playground_button).setOnClickListener {
            openPlaygroundHome()
        }

        // 真实 OTA 验收入口：不读取 APK assets/ota，直接把 appId + bundleName 交给 Router。
        // OTA 入口继续使用 appId + bundleName，与本地 Playground 首页保持边界清晰。
        findViewById<MaterialButton>(R.id.open_ota_button).setOnClickListener {
            runCatching {
                LynxRouter.open(
                    context = this,
                    lynxAppId = "10000001",
                    bundleName = "home.lynx.bundle",
                    params = mapOf("source" to "android-shell-ota-demo"),
                    options = mapOf("title" to "OTA Home"),
                )
            }.onFailure { error ->
                Toast.makeText(this, error.message ?: "OTA 页面打开失败", Toast.LENGTH_LONG).show()
            }
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

        // 默认直接进入 Playground 首页；原生验收页通过显式调试参数保留。
        if (!intent.getBooleanExtra("lynx_shell.show_native_launcher", false) && savedInstanceState == null) {
            openPlaygroundHome()
        }
    }

    private fun openPlaygroundHome() {
        runCatching {
            LynxRouter.open(
                context = this,
                bundle = "assets://bundles/main.lynx.bundle",
                params = mapOf("source" to "android-playground-home"),
                options = mapOf(
                    "title" to "Sparkling Go",
                    "fullscreen" to true,
                    "showToolbar" to false,
                ),
            )
        }.onFailure { error ->
            Toast.makeText(this, error.message ?: "Playground 首页打开失败", Toast.LENGTH_LONG).show()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // reLaunch 的 CLEAR_TOP 会复用当前实例；更新 Intent 方便宿主读取最新主页参数。
        setIntent(intent)
    }

}
