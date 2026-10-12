package com.example.lynxshell.sample

import android.content.Context
import android.content.Intent
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.example.lynxshell.LynxRouter
import com.example.lynxshell.bridge.LynxRouterMessageReply
import com.example.lynxshell.ota.ActivityBundleRuntime
import com.example.lynxshell.ota.PreparedActivityBundle
import com.google.android.material.button.MaterialButton
import com.ota.android.sdk.ContentAddressedOtaStore
import com.ota.android.sdk.OtaJson
import com.ota.android.sdk.OtaModels
import com.ota.android.sdk.ReleaseTransaction
import java.io.File

/** Debug 隔离宿主的手动入口：使用与自动验收相同的真实清单、Store 和原生 Page。 */
internal object BundleLoadingManualDemo {
    private const val DESCRIPTOR = "bundle-loading-fixture.json"

    fun enabled(context: Context): Boolean =
        BuildConfig.DEBUG && BuildConfig.LYNX_OTA_DEVICE_E2E && File(context.filesDir, DESCRIPTOR).isFile

    fun show(activity: AppCompatActivity) {
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            val padding = (24 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
        }
        activity.setContentView(ScrollView(activity).apply { addView(root) })
        root.addView(TextView(activity).apply {
            text = "Bundle 加载优化 · 手动验收"
            textSize = 24f
        })
        root.addView(TextView(activity).apply {
            text = "点击进入独立原生页面；返回键回到这里。\n同一个包连续打开：第 1 次冷加载，第 2 次复用 Engine，第 3 次新建。\n大包会计算 3 MiB 数据，Async 会执行十个实际脚本。"
            textSize = 16f
        })
        val status = TextView(activity).apply {
            text = "正在从本地服务下载并校验测试资源…"
            textSize = 15f
        }
        root.addView(status)
        val buttons = listOf(
            "小包 · 88 KB" to "BundleLoadSmall.lynx.bundle",
            "大包 · 3.23 MB" to "BundleLoadLarge.lynx.bundle",
            "Async · 十个脚本" to "BundleLoadAsync.lynx.bundle",
        ).map { (label, path) ->
            MaterialButton(activity).apply {
                text = label
                textSize = 17f
                isEnabled = false
                setOnClickListener {
                    val result = LynxRouter.open(activity, "10030071", path,
                        options = mapOf("fullscreen" to false, "showToolbar" to true,
                            "title" to label, "routeKey" to path))
                    if (!result.isSuccess) status.text = "打开失败：${result.message}"
                }
                root.addView(this)
            }
        }
        val inspect = MaterialButton(activity).apply {
            text = "查看已下载的 OTA Store"
            isEnabled = false
            setOnClickListener { activity.startActivity(Intent(activity, OtaStorageInspectorActivity::class.java)) }
        }
        root.addView(inspect)

        val context = activity.applicationContext
        Thread({
            try {
                val description = OtaJson.asObject(OtaJson.parse(File(context.filesDir, DESCRIPTOR).readText()), "fixture")
                val manifest = OtaModels.ReleaseManifest.fromJsonMap(OtaJson.asObject(description["manifest"], "manifest"), requireStatus = true)
                require(manifest.lynxAppId == "10030071") { "不是本次 Bundle 验收清单" }
                val cases = OtaJson.asArray(description["cases"], "cases").map { OtaJson.asObject(it, "case") }
                val scope = ReleaseTransaction.ReleaseScope.fromManifest(manifest)
                val store = ContentAddressedOtaStore(File(context.filesDir, "bundle-loading-manual-store"), allowLocalHTTPForTest = true)
                if (store.current(scope)?.context?.releaseId != manifest.releaseId) {
                    store.reserveSidecars(manifest.lynxAppId, manifest.asyncBundleManifest).use {
                        store.stageAsyncResources(manifest)
                        store.install(ReleaseTransaction.InstallRequest(scope, manifest))
                    }
                }
                val runtime = object : ActivityBundleRuntime {
                    override val userIdentityEpoch: Long = 0L
                    override fun prepare(lynxAppId: String, bundleName: String): PreparedActivityBundle =
                        requireNotNull(resolveCurrent(lynxAppId, bundleName)) { "本地测试 Bundle 不可用：$bundleName" }

                    override fun resolveCurrent(lynxAppId: String, bundleName: String): PreparedActivityBundle? {
                        require(lynxAppId == manifest.lynxAppId) { "不属于本次验收 App" }
                        val lease = store.acquireCurrentBundleLease(scope, bundleName) ?: return null
                        return PreparedActivityBundle(lynxAppId, bundleName, file = lease.file,
                            releaseId = manifest.releaseId, sha256 = lease.bundle.bundleSha256,
                            source = "ota_current", releaseLease = lease, sidecarResources = lease.sidecars,
                            userIdentityEpoch = userIdentityEpoch)
                    }

                    override fun otaStorageSnapshot() = store.storageSnapshot(200)
                }
                activity.runOnUiThread {
                    if (activity.isFinishing || activity.isDestroyed) return@runOnUiThread
                    LynxRouter.installActivityBundleRuntime(runtime)
                    LynxRouter.setMessageHandler { message ->
                        val case = cases.singleOrNull { it["path"] == message.source.pageKey }
                        val expected = case?.let { OtaJson.asObject(it["expectedReadyPayload"], "expectedReadyPayload") }
                        val accepted = message.eventName == "bundle-loading-bench.ready" && expected != null &&
                            message.payload["caseName"] == expected["caseName"] &&
                            listOf("moduleCount", "payloadLength", "checksum").all { key ->
                                (message.payload[key] as? Number)?.toDouble() == (expected[key] as Number).toDouble()
                            }
                        LynxRouterMessageReply(accepted = accepted, message = "真实脚本结果与页面归属校验")
                    }
                    status.text = "资源已就绪 · ${manifest.releaseId}\n来自持久 OTA Store；重开页面继续使用已验证文件。"
                    buttons.forEach { it.isEnabled = true }
                    inspect.isEnabled = true
                }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    if (!activity.isFinishing && !activity.isDestroyed) status.text = "准备失败：${error.message}"
                }
            }
        }, "bundle-loading-manual-prepare").start()
    }
}
