package com.example.lynxshell.sample

import android.graphics.Typeface
import android.os.Bundle
import android.view.View
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.setPadding
import com.example.lynxshell.LynxRouter
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.ota.android.sdk.OtaStorageAppSnapshot
import com.ota.android.sdk.OtaStorageReleaseRole
import com.ota.android.sdk.OtaStorageSnapshot
import java.util.Locale
import java.util.concurrent.Executors

/** Demo-only 原生只读 OTA Store 浏览器。 */
class OtaStorageInspectorActivity : AppCompatActivity() {
    private lateinit var rootPath: TextView
    private lateinit var summary: TextView
    private lateinit var content: LinearLayout
    private lateinit var refresh: MaterialButton
    private lateinit var progress: ProgressBar
    private val scanner = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ota-storage-inspector").apply { isDaemon = true }
    }
    @Volatile
    private var generation = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_ota_storage_inspector)
        val toolbar = findViewById<MaterialToolbar>(R.id.ota_inspector_toolbar)
        setSupportActionBar(toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        rootPath = findViewById(R.id.ota_inspector_root_path)
        summary = findViewById(R.id.ota_inspector_summary)
        content = findViewById(R.id.ota_inspector_content)
        refresh = findViewById(R.id.ota_inspector_refresh)
        progress = findViewById(R.id.ota_inspector_progress)
        refresh.setOnClickListener { loadSnapshot() }
        loadSnapshot()
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    override fun onDestroy() {
        generation += 1L
        scanner.shutdownNow()
        super.onDestroy()
    }

    private fun loadSnapshot() {
        val requestGeneration = ++generation
        progress.visibility = View.VISIBLE
        refresh.isEnabled = false
        summary.text = "正在读取一致性快照；不会联网或修改文件…"
        scanner.execute {
            val result = runCatching {
                LynxRouter.otaStorageSnapshot()
                    ?: error("当前没有安装 Router OTA Runtime")
            }
            runOnUiThread {
                if (isFinishing || isDestroyed || generation != requestGeneration) return@runOnUiThread
                progress.visibility = View.GONE
                refresh.isEnabled = true
                result.fold(::renderSnapshot) { error ->
                    rootPath.text = "Store 不可用"
                    summary.text = error.message ?: "OTA 磁盘快照读取失败"
                    content.removeAllViews()
                }
            }
        }
    }

    private fun renderSnapshot(snapshot: OtaStorageSnapshot) {
        rootPath.text = snapshot.rootPath
        summary.text = "${snapshot.apps.size} 个 App ID · ${snapshot.fileCount} 个文件 · ${formatBytes(snapshot.totalBytes)} · Store v3 CAS · 只读"
        content.removeAllViews()
        if (snapshot.apps.isEmpty()) {
            content.addView(bodyText("当前没有远程 OTA Bundle；页面会直接使用 APK embedded baseline。"))
            return
        }
        snapshot.apps.forEach { content.addView(appCard(it)) }
    }

    private fun appCard(app: OtaStorageAppSnapshot): MaterialCardView {
        val card = MaterialCardView(this).apply {
            radius = dp(16).toFloat()
            cardElevation = dp(1).toFloat()
            setCardBackgroundColor(android.graphics.Color.WHITE)
            strokeWidth = dp(1)
            strokeColor = android.graphics.Color.rgb(222, 225, 230)
            val params = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
            params.bottomMargin = dp(14)
            layoutParams = params
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18))
        }
        box.addView(titleText("App ID  ${app.appId}"))
        val state = app.state
        box.addView(
            bodyText(
                "current: ${state?.currentReleaseId ?: "—"} (${state?.currentKind ?: "none"})\n" +
                    "previous: ${state?.previousReleaseId ?: "—"}\n" +
                    "candidate: ${app.candidate?.releaseId ?: "—"}" +
                    (app.candidate?.status?.let { " ($it)" } ?: "") +
                    "\nCAS 对象: ${app.objectCount} 个 / ${formatBytes(app.objectBytes)}" +
                    "\nManifest: ${formatBytes(app.manifestBytes)}" +
                    "\n占用: ${formatBytes(app.totalBytes)} / ${app.fileCount} 文件",
            ),
        )
        app.releases.forEach { release ->
            val roleText = release.roles.joinToString(" · ") { roleLabel(it) }
            box.addView(sectionText("${release.releaseId}  [$roleText]"))
            box.addView(
                codeText(
                    "manifest: ${if (release.manifestValid) "valid" else "invalid"}\n" +
                        "manifestId: ${release.manifestId ?: "—"}\n" +
                        "Bundle 数: ${release.bundleCount} · CAS 对象引用: ${release.objectIds.size}\n" +
                        "size: ${formatBytes(release.totalBytes)} / ${release.fileCount} 文件\n" +
                        release.files.joinToString("\n") { file ->
                            "├─ ${file.relativePath}  ${formatBytes(file.byteCount)}"
                        } + if (release.truncated) "\n└─ …文件列表已截断" else "",
                ),
            )
        }
        if (app.staging.isNotEmpty()) {
            box.addView(sectionText("未完成的 staging"))
            app.staging.forEach { staging ->
                box.addView(
                    codeText(
                        "${staging.transactionName}  ${formatBytes(staging.totalBytes)}\n" +
                            staging.files.joinToString("\n") { "├─ ${it.relativePath}  ${formatBytes(it.byteCount)}" },
                    ),
                )
            }
        }
        card.addView(box)
        return card
    }

    private fun titleText(value: String) = TextView(this).apply {
        text = value
        textSize = 20f
        setTextColor(android.graphics.Color.rgb(22, 25, 30))
        setTypeface(typeface, Typeface.BOLD)
    }

    private fun sectionText(value: String) = TextView(this).apply {
        text = value
        textSize = 15f
        setTextColor(android.graphics.Color.rgb(17, 116, 104))
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(14), 0, dp(4))
    }

    private fun bodyText(value: String) = TextView(this).apply {
        text = value
        textSize = 14f
        setTextColor(android.graphics.Color.rgb(75, 80, 88))
        setLineSpacing(0f, 1.2f)
        setPadding(0, dp(8), 0, 0)
    }

    private fun codeText(value: String) = TextView(this).apply {
        text = value
        textSize = 12f
        typeface = Typeface.MONOSPACE
        setTextColor(android.graphics.Color.rgb(47, 52, 60))
        setTextIsSelectable(true)
        setLineSpacing(0f, 1.15f)
    }

    private fun roleLabel(role: OtaStorageReleaseRole): String = when (role) {
        OtaStorageReleaseRole.CURRENT -> "当前"
        OtaStorageReleaseRole.PREVIOUS -> "上一个"
        OtaStorageReleaseRole.CANDIDATE -> "候选"
        OtaStorageReleaseRole.LEASED -> "页面使用中"
        OtaStorageReleaseRole.ORPHAN -> "孤儿"
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024L) return "$bytes B"
        val units = arrayOf("KB", "MB", "GB")
        var value = bytes.toDouble()
        var unit = -1
        while (value >= 1024.0 && unit < units.lastIndex) {
            value /= 1024.0
            unit += 1
        }
        return String.format(Locale.US, "%.1f %s", value, units[unit])
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
