package com.ota.android.sdk

import java.io.File
import java.io.IOException
import java.net.URI
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** 一次页面 lease 的不可变本地资源视图；新 current 不改变旧页面的寻址。 */
class OtaSidecarViewResources internal constructor(
  val ownerBundlePath: String,
  val entries: List<ResolvedEntry>,
  val snapshotIdentity: String? = null,
) {
  class ResolvedEntry private constructor(
    val requestKey: String,
    val url: String,
    val kind: OtaSidecarModels.AsyncKind,
    private val fileSource: File?,
    private val assetReader: (() -> ByteArray)?,
    val expectedSha256: String? = null,
    val expectedSize: Int? = null,
  ) {
    @JvmOverloads constructor(requestKey: String, url: String, kind: OtaSidecarModels.AsyncKind, file: File,
      expectedSha256: String? = null, expectedSize: Int? = null) :
      this(requestKey, url, kind, file, null, expectedSha256, expectedSize)

    /** 下载态保留文件入口；APK assets 没有对应的 java.io.File。 */
    val file: File get() = fileSource ?: throw IllegalStateException("APK 内置资源没有文件路径")

    fun readBytes(): ByteArray = when {
      fileSource != null -> {
        if (!fileSource.isFile) throw IOException("本地附属资源已丢失：$requestKey")
        fileSource.readBytes()
      }
      assetReader != null -> assetReader.invoke()
      else -> error("附属资源没有可用来源")
    }

    fun localFile(): File? = fileSource?.takeIf(File::isFile)

    companion object {
      fun fromAsset(requestKey: String, kind: OtaSidecarModels.AsyncKind,
        reader: () -> ByteArray): ResolvedEntry = ResolvedEntry(requestKey, requestKey, kind, null, reader)

      fun fromAsset(requestKey: String, kind: OtaSidecarModels.AsyncKind,
        expectedSha256: String, expectedSize: Int,
        reader: () -> ByteArray): ResolvedEntry =
        ResolvedEntry(requestKey, requestKey, kind, null, reader, expectedSha256, expectedSize)
    }
  }

  fun resource(raw: String): ResolvedEntry? {
    val normalized = when {
      raw.startsWith("webpack:///") -> "/" + OtaSidecarModels.safePath(raw.removePrefix("webpack:///"))
      raw.startsWith('/') && !raw.startsWith("//") -> OtaSidecarModels.safePath(raw, true)
      else -> raw
    }
    return entries.singleOrNull { it.requestKey == normalized || it.url == raw }
  }

  internal companion object {
    fun downloadedSnapshotIdentity(ownerBundlePath: String, entries: List<OtaSidecarModels.AsyncEntry>): String {
      val sorted = entries.sortedWith(compareBy<OtaSidecarModels.AsyncEntry>(
        { it.requestKey }, { it.url.toString() }, { it.kind.wireValue }, { it.path },
        { it.ownerBundlePath }, { it.sha256 }, { it.size },
      ))
      // 用字段数组序列化，避免路径、URL 中的分隔符造成身份碰撞；不使用 CAS 绝对路径。
      return identityHash(listOf("downloaded-sidecar-v1", ownerBundlePath, sorted.map { entry ->
        listOf(entry.requestKey, entry.url.toString(), entry.kind.wireValue, entry.path,
          entry.ownerBundlePath, entry.sha256, entry.size)
      }))
    }

    fun embeddedSnapshotIdentity(ownerBundlePath: String, indexSha256: String): String =
      identityHash(listOf("embedded-sidecar-v1", ownerBundlePath, indexSha256))

    private fun identityHash(value: List<Any>): String = "sha256:" +
      MessageDigest.getInstance("SHA-256").digest(OtaJson.stringify(value).toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
  }
}

/** App ID 内的 Async CAS；只负责资源快照，不改 Store v3 主包目录。 */
internal class OtaSidecarDisk(
  private val storageRoot: File,
  private val environment: OtaModels.Environment,
  private val allowLocalHTTPForTest: Boolean,
  private val capacityProbe: ReleaseTransaction.CapacityProbe,
) {
  private val validationCache = VerifiedOtaFileCache()

  fun pinStaged(appId: String, asyncRef: OtaSidecarModels.AsyncManifestRef?,
    owners: Set<String>): AutoCloseable = withLock(appId) {
    requireAsync(appId, asyncRef, owners)
    val token = UUID.randomUUID().toString()
    ACTIVE_STAGES[token] = StageRoot(storageRoot.canonicalPath, appId, asyncRef)
    val closed = AtomicBoolean(false)
    AutoCloseable { if (closed.compareAndSet(false, true)) ACTIVE_STAGES.remove(token) }
  }

  /** 先登记计划根，未完成的快照会阻止 GC sweep；失败时由调用方关闭唯一 token。 */
  fun reserveStage(appId: String, asyncRef: OtaSidecarModels.AsyncManifestRef?): AutoCloseable = withLock(appId) {
    val token = UUID.randomUUID().toString()
    ACTIVE_STAGES[token] = StageRoot(storageRoot.canonicalPath, appId, asyncRef)
    val closed = AtomicBoolean(false)
    AutoCloseable { if (closed.compareAndSet(false, true)) ACTIVE_STAGES.remove(token) }
  }

  fun stageAsync(
    appId: String,
    ref: OtaSidecarModels.AsyncManifestRef,
    mainBundles: Set<String>,
    validatePublication: () -> Unit = {},
  ): OtaSidecarModels.AsyncManifest = withLock(appId) {
    val reservation = reserveStage(appId, ref)
    try {
      // 暂存根先阻止 GC；已有快照的 SHA 与清单解析不占用页面读取锁。
      withoutLock(appId) { readAsync(appId, ref, mainBundles) }?.let {
        validatePublication()
        return@withLock it
      }
      requireUrl(ref.url)
      val tx = transactionDir(appId, "async-bundles")
      try {
        val manifestPart = File(tx, "manifest.part")
        val result = withoutLock(appId) { download(ref.url, manifestPart, ref.size) }
        validatePublication()
        if (result.sha256 != ref.sha256) throw IOException("Async 清单 SHA256 不匹配")
        val manifest = withoutLock(appId) { parseAsync(manifestPart.readText(Charsets.UTF_8), mainBundles) }
        val missingBytes = withoutLock(appId) { manifest.entries.distinctBy { it.sha256 }.filterNot {
          usable(objectPath(appId, "async-bundles", it.sha256), it.sha256, it.size)
        }.sumOf { it.size.toLong() } }
        ensureSpace(missingBytes)
        manifest.entries.distinctBy { it.path }.forEachIndexed { index, item ->
          requireUrl(item.url)
          val target = objectPath(appId, "async-bundles", item.sha256)
          if (!withoutLock(appId) { usable(target, item.sha256, item.size) }) {
            val part = File(tx, "resource-$index.part")
            val downloaded = withoutLock(appId) { download(item.url, part, item.size) }
            validatePublication()
            if (downloaded.sha256 != item.sha256) throw IOException("Async 资源 SHA256 不匹配：${item.path}")
            // 网络期间另一事务可能已经提交相同对象；只复用完整且校验通过的文件。
            if (withoutLock(appId) { usable(target, item.sha256, item.size) }) part.delete() else publish(part, target)
          }
        }
        validatePublication()
        publish(manifestPart, asyncManifestPath(appId, ref.sha256))
        // 快照已原子发布且暂存根仍在；完整 SHA 复核无需阻塞同 App 的页面读取。
        requireNotNull(withoutLock(appId) { readAsync(appId, ref, mainBundles) }) { "Async 快照提交后不完整" }
      } finally {
        ACTIVE_TRANSACTIONS.remove(tx.canonicalPath)
        tx.deleteRecursively()
      }
    } finally {
      reservation.close()
    }
  }

  fun requireAsync(appId: String, ref: OtaSidecarModels.AsyncManifestRef?, mainBundles: Set<String>): OtaSidecarModels.AsyncManifest? =
    if (ref == null) null else withLock(appId) {
      readAsync(appId, ref, mainBundles) ?: throw IOException("Async 快照缺失或损坏：${ref.sha256}")
    }

  fun viewResources(
    appId: String,
    ownerBundlePath: String,
    async: OtaSidecarModels.AsyncManifest,
  ): OtaSidecarViewResources = withLock(appId) {
    val ownerEntries = async.entries.filter { it.ownerBundlePath == ownerBundlePath }
    val entries = ownerEntries.map { entry ->
      OtaSidecarViewResources.ResolvedEntry(
        entry.requestKey, entry.url.toString(), entry.kind,
        objectPath(appId, "async-bundles", entry.sha256),
        entry.sha256, entry.size,
      )
    }
    OtaSidecarViewResources(ownerBundlePath, entries,
      OtaSidecarViewResources.downloadedSnapshotIdentity(ownerBundlePath, ownerEntries))
  }

  fun prune(appId: String, asyncRefs: Set<OtaSidecarModels.AsyncManifestRef>): Boolean = withLock(appId) {
    val asyncManifests = linkedSetOf<String>()
    val asyncObjects = linkedSetOf<String>()
    val stageRoots = ACTIVE_STAGES.values.filter { it.rootPath == storageRoot.canonicalPath && it.appId == appId }
    val allAsyncRefs = asyncRefs + stageRoots.mapNotNull { it.asyncRef }

    // 任何根不完整时完全停止 sweep；不能用部分标记集删除仍被引用的字节。
    for (ref in allAsyncRefs) {
      val manifest = readAsync(appId, ref, emptySet(), restrictOwners = false) ?: return@withLock false
      asyncManifests += ref.sha256
      manifest.entries.forEach { asyncObjects += it.sha256 }
    }
    sweep(File(root(appId, "async-bundles"), "manifests"), asyncManifests.map { it.removePrefix("sha256:") + ".json" }.toSet())
    sweep(File(root(appId, "async-bundles"), "objects"), asyncObjects.map { it.removePrefix("sha256:") }.toSet())
    recoverTransactions(appId, "async-bundles")
    true
  }

  private fun readAsync(
    appId: String,
    ref: OtaSidecarModels.AsyncManifestRef,
    owners: Set<String>,
    restrictOwners: Boolean = true,
  ): OtaSidecarModels.AsyncManifest? {
    val file = asyncManifestPath(appId, ref.sha256)
    if (!usable(file, ref.sha256, ref.size)) return null
    val manifest = runCatching { parseAsync(file.readText(Charsets.UTF_8), owners, restrictOwners) }.getOrNull() ?: return null
    return manifest.takeIf { it.entries.all { entry -> usable(objectPath(appId, "async-bundles", entry.sha256), entry.sha256, entry.size) } }
  }

  private fun parseAsync(raw: String, owners: Set<String>, restrictOwners: Boolean = true): OtaSidecarModels.AsyncManifest {
    val manifest = OtaSidecarModels.AsyncManifest.fromJsonMap(OtaJson.asObject(OtaJson.parse(raw), "AsyncBundleManifest"))
    if (restrictOwners && manifest.entries.any { it.ownerBundlePath !in owners }) throw IOException("Async owner 不属于代码 Manifest")
    if (manifest.entries.any { !OtaURLPolicy.isAllowed(it.url, environment, allowLocalHTTPForTest) || it.url.userInfo != null || it.url.fragment != null }) {
      throw IOException("Async 资源 URL 不允许")
    }
    return manifest
  }

  private fun download(url: URI, target: File, size: Int): OtaIO.StreamResult = OtaIO.downloadAndHash(
    url, target, size.toLong(), OtaModels.MAX_BUNDLE_BYTES.toLong(), allowLocalHTTPForTest, environment,
  )

  private fun requireUrl(url: URI) {
    if (!OtaURLPolicy.isAllowed(url, environment, allowLocalHTTPForTest) || url.userInfo != null || url.fragment != null) {
      throw IOException("附属资源 URL 不允许")
    }
  }

  private fun ensureSpace(missingBytes: Long) {
    val required = missingBytes + 1024L * 1024L + maxOf(32L * 1024L * 1024L, (missingBytes + 9L) / 10L)
    val available = capacityProbe.usableSpace(storageRoot)
    if (available >= 0L && available < required) {
      throw OtaSdkException("OTA 附属资源预检空间不足：需要 $required bytes，可用 $available bytes", null, "insufficient_storage")
    }
  }

  private fun usable(file: File, sha: String, size: Int): Boolean {
    return validationCache.matches(file, sha, size.toLong())
  }

  private fun root(appId: String, type: String): File = File(File(File(storageRoot, "apps"), OtaModels.requireLynxAppId(appId)), type)
  private fun objectPath(appId: String, type: String, sha: String): File {
    require(sha.matches(Regex("^sha256:[0-9a-f]{64}$")))
    val hex = sha.removePrefix("sha256:")
    return File(File(File(root(appId, type), "objects"), hex.take(2)), hex)
  }
  private fun asyncManifestPath(appId: String, sha: String): File = File(File(root(appId, "async-bundles"), "manifests"), sha.removePrefix("sha256:") + ".json")
  private fun transactionDir(appId: String, type: String): File = File(File(root(appId, type), "transactions"), UUID.randomUUID().toString()).also {
    if (!it.mkdirs()) throw IOException("无法创建附属资源事务目录")
    ACTIVE_TRANSACTIONS.add(it.canonicalPath)
  }
  private fun publish(source: File, target: File) {
    target.parentFile?.mkdirs()
    // 与主 Store 一样使用同文件系统 POSIX rename；minSdk 24 不依赖 API 26 的 java.nio.Files。
    if (!source.renameTo(target)) throw IOException("无法原子发布附属资源：$target")
  }
  private fun sweep(directory: File, names: Set<String>) {
    if (!directory.isDirectory) return
    directory.walkBottomUp().filter { it.isFile && it.name !in names }.forEach {
      if (it.delete()) validationCache.evict(it)
    }
    directory.walkBottomUp().filter { it.isDirectory && it != directory && it.listFiles().isNullOrEmpty() }.forEach(File::delete)
  }
  private fun recoverTransactions(appId: String, type: String) {
    File(root(appId, type), "transactions").listFiles().orEmpty().filter(File::isDirectory).forEach { tx ->
      if (tx.canonicalPath !in ACTIVE_TRANSACTIONS) tx.deleteRecursively()
    }
  }
  private fun appLock(appId: String): ReentrantLock {
    val key = storageRoot.canonicalPath + "|" + OtaModels.requireLynxAppId(appId)
    return LOCKS.computeIfAbsent(key) { ReentrantLock() }
  }

  private fun <T> withLock(appId: String, block: () -> T): T = appLock(appId).withLock(block)

  /** 暂存根保护下载和复核中的字节；网络与完整校验释放锁，本地提交仍持锁。 */
  private fun <T> withoutLock(appId: String, block: () -> T): T {
    val lock = appLock(appId)
    val held = lock.holdCount
    check(held > 0)
    repeat(held) { lock.unlock() }
    try { return block() } finally { repeat(held) { lock.lock() } }
  }

  private companion object {
    data class StageRoot(val rootPath: String, val appId: String,
      val asyncRef: OtaSidecarModels.AsyncManifestRef?)
    val LOCKS = ConcurrentHashMap<String, ReentrantLock>()
    val ACTIVE_TRANSACTIONS = ConcurrentHashMap.newKeySet<String>()
    val ACTIVE_STAGES = ConcurrentHashMap<String, StageRoot>()
  }
}
