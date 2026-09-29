package com.example.lynxshell.ota

import android.content.Context
import com.ota.android.sdk.OtaSidecarModels
import com.ota.android.sdk.OtaSidecarViewResources
import org.json.JSONObject
import java.io.IOException
import java.security.MessageDigest

/** APK 内置版本的附属资源；索引只来自 embedded-bundles.json，不参与下载 Store 的状态机。 */
internal class EmbeddedSidecarResources(context: Context) {
    private val assets = context.applicationContext.assets
    private val snapshots = mutableMapOf<String, Snapshot>()
    private val shaPattern = Regex("^sha256:[0-9a-f]{64}$")

    @Synchronized
    fun resolve(bundle: EmbeddedBundle, indexPath: String, owners: Set<String>): OtaSidecarViewResources? {
        val snapshot = snapshots.getOrPut(indexPath) { readSnapshot(bundle.lynxAppId, indexPath, owners) }
        val entries = snapshot.asyncEntries.filter { it.ownerBundlePath == bundle.bundlePath }.map { entry ->
            OtaSidecarViewResources.ResolvedEntry.fromAsset(entry.requestKey, entry.kind) {
                verifiedAsset(entry.assetPath, entry.size, entry.sha256)
            }
        }
        if (entries.isEmpty()) return null
        return OtaSidecarViewResources(bundle.bundlePath, entries)
    }

    private fun readSnapshot(appId: String, indexPath: String, owners: Set<String>): Snapshot {
        val indexBytes = assets.open(indexPath).use { it.readBytes() }
        require(indexBytes.isNotEmpty() && indexBytes.size <= MAX_INDEX_BYTES) { "内置附属资源索引大小不合法" }
        val index = JSONObject(indexBytes.toString(Charsets.UTF_8))
        require(index.getInt("schemaVersion") == 1 && index.getString("appId") == appId) {
            "内置附属资源索引与 App ID 不匹配"
        }
        require(!index.has("i18nRequirement") && !index.has("i18nCatalog")) {
            "旧内置词典索引需要重新构建双语 Bundle"
        }
        val directory = indexPath.substringBeforeLast('/')
        val asyncEntries = buildList {
            index.optJSONArray("asyncEntries")?.let { array ->
                for (i in 0 until array.length()) {
                    val entry = array.getJSONObject(i)
                    val owner = OtaSidecarModels.safePath(entry.getString("ownerBundlePath"))
                    require(owner in owners) { "内置 Async Bundle 的页面归属未登记：$owner" }
                    val path = OtaSidecarModels.safePath(entry.getString("path"))
                    val requestKey = OtaSidecarModels.safePath(entry.getString("requestKey"), true)
                    require(requestKey == "/$path") { "内置 Async Bundle requestKey 与文件路径不一致" }
                    val kind = OtaSidecarModels.AsyncKind.fromWire(entry.getString("kind"))
                    require(kind == OtaSidecarModels.AsyncKind.BUNDLE) {
                        "APK 内置附属资源目前只支持 Async Bundle"
                    }
                    val size = entry.getInt("size")
                    val sha = entry.getString("sha256")
                    val assetPath = "$directory/$path"
                    verifiedAsset(assetPath, size, sha)
                    add(AsyncEntry(owner, requestKey, kind, assetPath, size, sha))
                }
            }
        }
        require(asyncEntries.map { it.ownerBundlePath to it.requestKey }.distinct().size == asyncEntries.size) {
            "内置 Async Bundle requestKey 重复"
        }

        return Snapshot(asyncEntries)
    }

    private fun verifiedAsset(path: String, expectedSize: Int, expectedSha: String): ByteArray {
        require(expectedSize in 1..MAX_RESOURCE_BYTES && shaPattern.matches(expectedSha)) {
            "内置附属资源大小或 SHA256 不合法：$path"
        }
        val bytes = assets.open(path).use { it.readBytes() }
        if (bytes.size != expectedSize || sha256(bytes) != expectedSha) {
            throw IOException("内置附属资源校验失败：$path")
        }
        return bytes
    }

    private fun sha256(bytes: ByteArray): String = "sha256:" +
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private data class AsyncEntry(
        val ownerBundlePath: String,
        val requestKey: String,
        val kind: OtaSidecarModels.AsyncKind,
        val assetPath: String,
        val size: Int,
        val sha256: String,
    )

    private data class Snapshot(
        val asyncEntries: List<AsyncEntry>,
    )

    private companion object {
        const val MAX_INDEX_BYTES = 1024 * 1024
        const val MAX_RESOURCE_BYTES = 20 * 1024 * 1024
    }
}
