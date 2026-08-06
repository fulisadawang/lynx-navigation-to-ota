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

        // 启动首页固定保留为原生壳调试页；不再自动打开旧的 main.lynx.bundle。
        // OTA 验收从下方“打开 OTA”按钮进入，便于明确区分原生壳与远程 Bundle 页面。
        setContentView(R.layout.activity_launcher)

        // 真实 OTA 验收入口：不读取 APK assets/ota，直接把 appId + bundleName 交给 Router。
        // 旧的 main.lynx.bundle 手工入口已从首页移除，避免验收时误触进入 Sparkling Go。
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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // reLaunch 的 CLEAR_TOP 会复用当前实例；更新 Intent 方便宿主读取最新主页参数。
        setIntent(intent)
    }

}
