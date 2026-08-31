package com.example.lynxshell.ota

import android.content.Context
import com.ota.android.sdk.OtaModels
import org.json.JSONObject
import java.io.FileNotFoundException
import java.io.InputStream
import java.net.URI
import java.security.MessageDigest
import java.time.Instant

/** 已校验的 APK 内置 Bundle；assetPath 只来自受控 Manifest，不来自页面参数。 */
data class EmbeddedBundle(
    val lynxAppId: String,
    val releaseId: String,
    val pageId: Int,
    val bundleName: String,
    val bundlePath: String,
    val assetPath: String,
    val size: Int,
    val sha256: String,
    val bytes: ByteArray,
)

/** 构建期 Manifest 暴露给 Demo/宿主的逻辑 identity；不包含物理文件路径。 */
data class EmbeddedBundleIdentity(
    val lynxAppId: String,
    val releaseId: String,
    val bundleName: String,
)

/**
 * 多个 Lynx App 共存时的 APK assets 索引。
 *
 * 目录不是身份来源；`lynxAppId + bundleName` 先查 embedded-bundles.json，再按 Manifest
 * 指定的 assetPath 读取并重新校验 size/SHA。没有 Manifest 的宿主保持原有 OTA 行为。
 */
class EmbeddedBundleRegistry(
    context: Context,
    private val manifestAssetPath: String = DEFAULT_MANIFEST_ASSET_PATH,
) {
    private val appContext = context.applicationContext
    private val entries: List<Descriptor> by lazy(::loadManifest)

    fun resolve(lynxAppId: String, bundleName: String): EmbeddedBundle? {
        val descriptor = entries.firstOrNull {
            it.lynxAppId == lynxAppId && it.bundleName == bundleName
        } ?: return null
        val bytes = appContext.assets.open(descriptor.assetPath).use(::readBytes)
        require(bytes.size == descriptor.size) {
            "内置 Bundle size 校验失败：${descriptor.assetPath}"
        }
        val actualSha = sha256(bytes)
        require(actualSha.equals(descriptor.sha256, ignoreCase = true)) {
            "内置 Bundle SHA-256 校验失败：${descriptor.assetPath}"
        }
        return EmbeddedBundle(
            lynxAppId = descriptor.lynxAppId,
            releaseId = descriptor.releaseId,
            pageId = descriptor.pageId,
            bundleName = descriptor.bundleName,
            bundlePath = descriptor.bundlePath,
            assetPath = descriptor.assetPath,
            size = descriptor.size,
            sha256 = descriptor.sha256,
            bytes = bytes,
        )
    }

    /** 判断 App 是否有内置 baseline；只查 Manifest，不读取或复制 Bundle。 */
    fun containsApp(lynxAppId: String): Boolean {
        return entries.any { it.lynxAppId == lynxAppId }
    }

    /** 返回指定 bundleName 的全部身份；同名 Bundle 跨 appId 时不会擅自挑选。 */
    fun identities(bundleName: String): List<EmbeddedBundleIdentity> {
        return entries.asSequence()
            .filter { it.bundleName == bundleName }
            .map { EmbeddedBundleIdentity(it.lynxAppId, it.releaseId, it.bundleName) }
            .distinct()
            .toList()
    }

    /** 仅当一组 Bundle 唯一属于一个 appId 时才返回它，避免按文件名猜身份。 */
    fun uniqueAppIdForBundles(bundleNames: Set<String>): String? {
        if (bundleNames.isEmpty()) return null
        return entries.groupBy { it.lynxAppId }
            .filterValues { descriptors -> bundleNames.all { name -> descriptors.any { it.bundleName == name } } }
            .keys
            .singleOrNull()
    }

    /**
     * 将 APK asset Manifest 转成 OTA Store 的内置 Release 描述。
     *
     * 这里只生成元数据和受控 asset URI，不读取 Bundle bytes，也不会把 asset 复制到
     * files/lynx-ota-store；实际页面仍由 resolve() 直接通过 AssetManager 读取。
     */
    fun installedReleases(
        environment: OtaModels.Environment = OtaModels.Environment.TEST,
        hostApp: OtaModels.HostApp = OtaModels.HostApp.CAPP,
        platform: OtaModels.Platform = OtaModels.Platform.ANDROID,
    ): List<OtaModels.InstalledRelease> {
        return entries.groupBy { it.lynxAppId to it.releaseId }
            .toSortedMap(compareBy<Pair<String, String>> { it.first }.thenBy { it.second })
            .map { (identity, descriptors) ->
                OtaModels.InstalledRelease(
                    OtaModels.CurrentReleaseContext(
                        environment,
                        hostApp,
                        identity.first,
                        identity.second,
                        platform,
                        OtaModels.ReleaseStatus.ACTIVE,
                    ),
                    Instant.EPOCH,
                    descriptors.map { descriptor ->
                        OtaModels.InstalledBundle(
                            descriptor.pageId,
                            descriptor.bundlePath,
                            descriptor.sha256,
                            URI.create("asset://${descriptor.assetPath}"),
                            "asset://${descriptor.assetPath}",
                        )
                    },
                )
            }
    }

    private fun loadManifest(): List<Descriptor> {
        val stream = try {
            appContext.assets.open(manifestAssetPath)
        } catch (_: FileNotFoundException) {
            return emptyList()
        }
        stream.use { input ->
            val root = JSONObject(input.reader(Charsets.UTF_8).use { it.readText() })
            require(root.optInt("schemaVersion", 0) == 1) {
                "内置 Bundle Manifest schemaVersion 不支持"
            }
            val apps = root.optJSONArray("apps") ?: error("内置 Bundle Manifest 缺少 apps")
            return buildList {
                for (appIndex in 0 until apps.length()) {
                    val app = apps.getJSONObject(appIndex)
                    val appId = app.getString("lynxAppId")
                    val releaseId = app.getString("releaseId")
                    val bundles = app.optJSONArray("bundles")
                        ?: error("内置 Bundle Manifest 缺少 bundles：$appId")
                    for (bundleIndex in 0 until bundles.length()) {
                        val bundle = bundles.getJSONObject(bundleIndex)
                        add(
                            Descriptor(
                                lynxAppId = appId,
                                releaseId = releaseId,
                                pageId = bundle.optInt("pageId", 0),
                                bundleName = bundle.getString("bundleName"),
                                bundlePath = validateBundlePath(
                                    bundle.optString("bundlePath", bundle.getString("bundleName")),
                                ),
                                assetPath = validateAssetPath(bundle.getString("assetPath")),
                                size = bundle.getInt("size"),
                                sha256 = validateSha(bundle.getString("sha256")),
                            ),
                        )
                    }
                }
            }
        }
    }

    private fun validateAssetPath(value: String): String {
        require(
            value.startsWith("bundles/") &&
                value.endsWith(".lynx.bundle") &&
                !value.startsWith('/') &&
                !value.contains('\\') &&
                value.split('/').none { it.isBlank() || it == "." || it == ".." },
        ) { "内置 Bundle assetPath 不安全：$value" }
        return value
    }

    private fun validateSha(value: String): String {
        require(Regex("^sha256:[0-9a-fA-F]{64}$").matches(value)) {
            "内置 Bundle sha256 格式错误：$value"
        }
        return value
    }

    private fun validateBundlePath(value: String): String {
        require(
            value.isNotBlank() &&
                value.endsWith(".lynx.bundle") &&
                !value.startsWith('/') &&
                !value.contains('\\') &&
                value.split('/').none { it.isBlank() || it == "." || it == ".." },
        ) { "内置 Bundle bundlePath 不安全：$value" }
        return value
    }

    private fun readBytes(input: InputStream): ByteArray {
        val bytes = input.readBytes()
        require(bytes.isNotEmpty() && bytes.size <= MAX_BUNDLE_BYTES) {
            "内置 Bundle 为空或超过 20MB"
        }
        return bytes
    }

    private fun sha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return "sha256:" + digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private data class Descriptor(
        val lynxAppId: String,
        val releaseId: String,
        val pageId: Int,
        val bundleName: String,
        val bundlePath: String,
        val assetPath: String,
        val size: Int,
        val sha256: String,
    )

    private companion object {
        const val DEFAULT_MANIFEST_ASSET_PATH = "bundles/lynx/embedded-bundles.json"
        const val MAX_BUNDLE_BYTES = 20 * 1024 * 1024
    }
}

/** 无 OTA 服务配置时的 Android embedded-only runtime；绝不触发网络请求。 */
class EmbeddedBundleRuntime(context: Context) : ActivityBundleRuntime {
    private val registry = EmbeddedBundleRegistry(context)

    override fun prepare(lynxAppId: String, bundleName: String): PreparedActivityBundle {
        val embedded = registry.resolve(lynxAppId, bundleName)
            ?: throw IllegalStateException("没有内置 Bundle：$lynxAppId/$bundleName")
        return PreparedActivityBundle(
            lynxAppId = embedded.lynxAppId,
            bundleName = embedded.bundleName,
            bytes = embedded.bytes,
            releaseId = embedded.releaseId,
            sha256 = embedded.sha256,
            source = "embedded_baseline",
        )
    }

    override fun resolveCurrent(
        lynxAppId: String,
        bundleName: String,
    ): PreparedActivityBundle? {
        val embedded = registry.resolve(lynxAppId, bundleName) ?: return null
        return PreparedActivityBundle(
            lynxAppId = embedded.lynxAppId,
            bundleName = embedded.bundleName,
            bytes = embedded.bytes,
            releaseId = embedded.releaseId,
            sha256 = embedded.sha256,
            source = "embedded_baseline",
        )
    }
}
