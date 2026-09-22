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
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors

/** Demo-only 原生只读 OTA Store 与 Direct HTTPS 缓存浏览器。 */
class OtaStorageInspectorActivity : AppCompatActivity() {
    private data class DirectHttpsCacheFileSnapshot(
        val name: String,
        val byteCount: Long,
        val temporary: Boolean,
    )

    private data class DirectHttpsCacheSnapshot(
        val rootPath: String,
        val files: List<DirectHttpsCacheFileSnapshot>,
        val totalBytes: Long,
    )

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
                LynxRouter.otaStorageSnapshot() to scanDirectHttpsCache()
            }
            runOnUiThread {
                if (isFinishing || isDestroyed || generation != requestGeneration) return@runOnUiThread
                progress.visibility = View.GONE
                refresh.isEnabled = true
                result.fold({ (snapshot, httpsCache) -> renderSnapshot(snapshot, httpsCache) }) { error ->
                    rootPath.text = "Store 不可用"
                    summary.text = error.message ?: "OTA 磁盘快照读取失败"
                    content.removeAllViews()
                }
            }
        }
    }

    private fun renderSnapshot(snapshot: OtaStorageSnapshot?, httpsCache: DirectHttpsCacheSnapshot) {
        rootPath.text = buildString {
            append("OTA Store: ")
            append(snapshot?.rootPath ?: "不可用")
            append("\nDirect HTTPS: ")
            append(httpsCache.rootPath)
        }
        val otaSummary = snapshot?.let {
            "${it.apps.size} 个 App ID · ${it.fileCount} 个文件 · ${formatBytes(it.totalBytes)} · Store v3 CAS"
        } ?: "OTA Store 不可用"
        summary.text = "$otaSummary · HTTPS 缓存 ${httpsCache.files.size} 个文件 / ${formatBytes(httpsCache.totalBytes)} · 只读"
        content.removeAllViews()
        content.addView(httpsCacheCard(httpsCache))
        if (snapshot == null) {
            content.addView(bodyText("当前无法读取 OTA Store；Direct HTTPS 缓存仍可单独查看。"))
            return
        }
        if (snapshot.apps.isEmpty()) {
            content.addView(bodyText("当前没有远程 OTA Bundle；页面会直接使用 APK embedded baseline。"))
            return
        }
        snapshot.apps.forEach { content.addView(appCard(it)) }
    }

    private fun scanDirectHttpsCache(): DirectHttpsCacheSnapshot {
        val root = File(applicationContext.filesDir, DIRECT_HTTPS_CACHE_DIRECTORY)
        val files = root.listFiles()
            .orEmpty()
            .filter { it.isFile }
            .sortedBy { it.name }
            .map { file ->
                DirectHttpsCacheFileSnapshot(
                    name = file.name,
                    byteCount = file.length(),
                    temporary = file.name.contains(".part-"),
                )
            }
        return DirectHttpsCacheSnapshot(
            rootPath = root.absolutePath,
            files = files,
            totalBytes = files.sumOf { it.byteCount },
        )
    }

    private fun httpsCacheCard(snapshot: DirectHttpsCacheSnapshot): MaterialCardView {
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
        box.addView(titleText("Direct HTTPS Bundle 缓存"))
        box.addView(
            bodyText(
                "路径: ${snapshot.rootPath}\n" +
                    "文件: ${snapshot.files.size} · 占用: ${formatBytes(snapshot.totalBytes)}\n" +
                    "缓存文件名使用 URL 定位摘要；此区域不会读取或展示原始 URL。",
            ),
        )
        if (snapshot.files.isEmpty()) {
            box.addView(sectionText("当前没有 HTTPS Bundle 缓存文件"))
        } else {
            box.addView(sectionText("缓存文件"))
            box.addView(
                codeText(
                    snapshot.files.joinToString("\n") { file ->
                        val kind = if (file.temporary) "临时" else "正式"
                        "├─ [$kind] ${file.name}  ${formatBytes(file.byteCount)}"
                    },
                ),
            )
        }
        card.addView(box)
        return card
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

    private companion object {
        const val DIRECT_HTTPS_CACHE_DIRECTORY = "lynx-https-bundles"
    }
}
