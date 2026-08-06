package com.ota.android.sdk

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Android OTA 的 durable storage deep module。
 *
 * 页面和宿主只需要调用 install/current/rollback；`.staging`、part 文件、校验和
 * Active State 的提交顺序都收敛在此处。这里刻意只使用 java.io.File，避免把
 * 桌面 JDK 的文件类型带入 Android APK。
 */
class ReleaseTransaction @JvmOverloads constructor(
  private val storageRoot: File,
  private val capacityProbe: CapacityProbe = CapacityProbe.FILE_STORE,
  private val clock: Clock = Clock.SYSTEM,
) {
  /** 一个宿主内的唯一存储作用域；appId 不能跨环境/宿主/平台复用状态。 */
  data class ReleaseScope(
    @JvmField val env: OtaModels.Environment,
    @JvmField val hostApp: OtaModels.HostApp,
    @JvmField val lynxAppId: String,
    @JvmField val platform: OtaModels.Platform,
  ) {
    init {
      require(lynxAppId.isNotBlank()) { "lynxAppId 不能为空" }
    }

    companion object {
      @JvmStatic
      fun fromManifest(manifest: OtaModels.ReleaseManifest): ReleaseScope {
        return ReleaseScope(manifest.env, manifest.hostApp, manifest.lynxAppId, manifest.platform)
      }

      @JvmStatic
      fun fromRelease(release: OtaModels.InstalledRelease): ReleaseScope {
        return ReleaseScope(
          release.context.env,
          release.context.hostApp,
          release.context.lynxAppId,
          release.context.platform,
        )
      }
    }
  }

  data class InstallRequest(
    @JvmField val scope: ReleaseScope,
    @JvmField val targetManifest: OtaModels.ReleaseManifest,
    @JvmField val embeddedDescriptor: OtaModels.InstalledRelease? = null,
  ) {
    constructor(scope: ReleaseScope, targetManifest: OtaModels.ReleaseManifest) : this(scope, targetManifest, null)
  }

  enum class InstallResultType {
    UPDATED,
    ALREADY_ACTIVE,
    SKIPPED,
    FAILED,
  }

  data class InstallOutcome(
    @JvmField val type: InstallResultType,
    @JvmField val current: OtaModels.InstalledRelease?,
    @JvmField val installed: OtaModels.InstalledRelease?,
    @JvmField val fromReleaseId: String? = null,
    @JvmField val toReleaseId: String? = null,
    @JvmField val copiedBundleCount: Int = 0,
    @JvmField val copiedBytes: Long = 0,
    @JvmField val downloadedBundleCount: Int = 0,
    @JvmField val downloadedBytes: Long = 0,
    @JvmField val errorCode: String? = null,
    @JvmField val stage: StorageStage? = null,
    @JvmField val retryable: Boolean = false,
    @JvmField val requiredBytes: Long? = null,
    @JvmField val availableBytes: Long? = null,
    @JvmField val writtenBytes: Long? = null,
  )

  data class RollbackOutcome(
    @JvmField val restored: OtaModels.InstalledRelease?,
    @JvmField val fromReleaseId: String?,
    @JvmField val toReleaseId: String?,
  )

  enum class StorageStage {
    RECOVERY,
    PREFLIGHT,
    COPY,
    DOWNLOAD,
    VALIDATE,
    PUBLISH,
    ACTIVATE,
    CLEANUP,
    ROLLBACK,
    MIGRATE,
  }

  /** 已完成路径校验、但尚未开始写入的 Bundle 传输计划。 */
  private data class BundleTransferPlan(
    val index: Int,
    val artifact: OtaModels.BundleArtifact,
    val normalizedPath: String,
    val finalStagedPath: File,
    val partPath: File,
  )

  /** Bundle 写入 staging 后的结果；结果按 manifest 顺序重新汇总。 */
  private data class BundleTransferResult(
    val index: Int,
    val artifact: OtaModels.BundleArtifact,
    val normalizedPath: String,
    val finalStagedPath: File,
    val partPath: File,
    val streamResult: OtaIO.StreamResult,
    val copiedFromPrevious: Boolean,
  )

  fun interface CapacityProbe {
    fun usableSpace(storageRoot: File): Long

    companion object {
      @JvmField
      val FILE_STORE: CapacityProbe = CapacityProbe { root ->
        // File.usableSpace 在目录尚不存在时可能返回 0；优先使用已经存在的父目录。
        val probe = if (root.exists()) root else root.parentFile ?: root
        probe.usableSpace
      }
    }
  }

  fun interface Clock {
    fun now(): Instant

    companion object {
      @JvmField
      val SYSTEM: Clock = Clock { Instant.now() }
    }
  }

  /** 注册随包 Bundle，并在首次启动时把 current 指向 embedded。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun registerEmbeddedRelease(release: OtaModels.InstalledRelease) {
    val scope = ReleaseScope.fromRelease(release)
    withStorageLock {
      val legacyStore = OtaReleaseStore(storageRoot)
      legacyStore.saveEmbeddedRelease(release)
      val state = readState(scope.lynxAppId)
      if (state == null) {
        // 迁移期间可能已经有 legacy downloaded current；初始化 embedded 不能覆盖它。
        val legacyCurrent = legacyStore.currentRelease(scope.lynxAppId)
        if (legacyCurrent != null && matchesScope(scope, legacyCurrent) &&
          legacyCurrent.context.releaseId != release.context.releaseId
        ) {
          // 旧 pointer 仍指向绝对路径，尚未物化到 releases/<releaseId>；保留 pointer，
          // 让 current/ensureBundleReady 继续走兼容读取，首次事务再完成迁移。
          return@withStorageLock
        }
        writeStateAtomic(
          StateRecord(
            scope,
            1L,
            ReleaseRef(RefKind.EMBEDDED, release.context.releaseId),
            null,
          ),
        )
      }
    }
  }

  /**
   * 安装完整 Release Snapshot。state 最后提交；下载失败或校验失败只会留下可清理
   * 的 staging，不会污染 current。
   */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun install(request: InstallRequest): InstallOutcome {
    validateManifest(request.scope, request.targetManifest)
    if (request.embeddedDescriptor != null && ReleaseScope.fromRelease(request.embeddedDescriptor) != request.scope) {
      throw transactionError("embedded 描述的 scope 与目标不一致", "scope_mismatch")
    }

    return withStorageLock {
      ensureDirectories()
      recoverStaging()
      request.embeddedDescriptor?.let { OtaReleaseStore(storageRoot).saveEmbeddedRelease(it) }

      val oldState = readState(request.scope.lynxAppId)
      ensureStateScope(oldState, request.scope)
      val oldCurrent = resolveCurrentUnsafe(request.scope, oldState)
      // 如果损坏的旧 pointer 与目标 releaseId 相同，不能把同一个 release 再写成
      // previous，否则回滚会回到同一份损坏数据；此时只保留可用 embedded 作为回退。
      val oldCurrentRef = when {
        oldState?.current != null && oldState.current.releaseId != request.targetManifest.releaseId -> oldState.current
        oldCurrent != null && oldCurrent.context.releaseId != request.targetManifest.releaseId ->
          referenceForRelease(request.scope, oldCurrent)
        else -> resolveEmbedded(request.scope)?.let { referenceForRelease(request.scope, it) }
      }

      if (oldCurrent != null && oldCurrent.context.releaseId == request.targetManifest.releaseId) {
        val existing = resolveDownloadedRelease(request.scope, request.targetManifest.releaseId)
        if (existing != null && verifyInstalledRelease(existing, request.scope, request.targetManifest)) {
          return@withStorageLock InstallOutcome(
            InstallResultType.ALREADY_ACTIVE,
            oldCurrent,
            existing,
            fromReleaseId = oldCurrent.context.releaseId,
            toReleaseId = existing.context.releaseId,
          )
        }
      }

      val declaredSizes = request.targetManifest.bundles.mapNotNull { it.size?.toLong() }
      val requiredBytes = if (declaredSizes.size == request.targetManifest.bundles.size) {
        val targetBytes = declaredSizes.sum()
        targetBytes + METADATA_ALLOWANCE_BYTES + maxOf(SAFETY_RESERVE_BYTES, (targetBytes + 9L) / 10L)
      } else {
        null
      }
      val availableBytes = capacityProbe.usableSpace(storageRoot)
      if (requiredBytes != null && availableBytes >= 0L && availableBytes < requiredBytes) {
        throw storageError(
          "OTA 预检空间不足：需要 $requiredBytes bytes，可用 $availableBytes bytes",
          "insufficient_storage",
          StorageStage.PREFLIGHT,
        )
      }

      val transactionId = UUID.randomUUID().toString()
      val stagingDirectory = stagingDirectory(request.targetManifest.releaseId, transactionId)
      var copiedBundleCount = 0
      var copiedBytes = 0L
      var downloadedBundleCount = 0
      var downloadedBytes = 0L
      var writtenBytes = 0L
      try {
        ensureDirectory(stagingDirectory)
        // 先在事务线程中完成路径校验和 staging 规划，避免并发任务之间出现路径冲突。
        // 真正的网络下载/旧文件复制在下面的 4 个 worker 中执行；current 仍然只在
        // 全部任务完成后提交，因此并发不会改变 Release 的原子性。
        val plans = createBundleTransferPlans(request.targetManifest, stagingDirectory)
        val transfers = transferBundlesConcurrently(plans, oldCurrent)
        for (transfer in transfers) {
          if (transfer.copiedFromPrevious) {
            copiedBundleCount += 1
            copiedBytes += transfer.streamResult.bytes
          } else {
            downloadedBundleCount += 1
            downloadedBytes += transfer.streamResult.bytes
          }
          writtenBytes += transfer.streamResult.bytes
          atomicMove(transfer.partPath, transfer.finalStagedPath)
        }

        writeLocalManifestAtomic(stagingDirectory, request.targetManifest)
        verifyStagedRelease(stagingDirectory, request.targetManifest)
        val targetDirectory = releaseDirectory(request.targetManifest.releaseId)
        publishReleaseDirectory(stagingDirectory, targetDirectory, request.scope, request.targetManifest)
        val installed = readPublishedRelease(request.scope, request.targetManifest.releaseId)
          ?: throw transactionError("发布后的 Release Manifest 不可读", "release_publish_failed")
        writeStateAtomic(
          StateRecord(
            request.scope,
            (oldState?.generation ?: 0L) + 1L,
            ReleaseRef(RefKind.DOWNLOADED, request.targetManifest.releaseId),
            oldCurrentRef,
          ),
        )
        return@withStorageLock InstallOutcome(
          InstallResultType.UPDATED,
          oldCurrent,
          installed,
          fromReleaseId = oldCurrent?.context?.releaseId,
          toReleaseId = installed.context.releaseId,
          copiedBundleCount = copiedBundleCount,
          copiedBytes = copiedBytes,
          downloadedBundleCount = downloadedBundleCount,
          downloadedBytes = downloadedBytes,
          writtenBytes = writtenBytes,
        )
      } catch (error: Throwable) {
        // 清理失败不能覆盖真正的下载/校验/发布错误；下一次事务会再次尝试恢复残留 staging。
        runCatching { cleanupRecursively(stagingDirectory) }
        when (error) {
          is OtaSdkException, is IOException, is InterruptedException -> throw error
          else -> throw IOException("OTA Release 事务失败", error)
        }
      } finally {
        // 激活成功后清理属于 best-effort，不能把已经提交的 state 报成失败。
        runCatching { cleanupRecursively(stagingDirectory) }
      }
    }
  }

  @JvmOverloads
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun install(
    scope: ReleaseScope,
    targetManifest: OtaModels.ReleaseManifest,
    embeddedDescriptor: OtaModels.InstalledRelease? = null,
  ): InstallOutcome = install(InstallRequest(scope, targetManifest, embeddedDescriptor))

  /** 读取新 Active State；没有新 state 时兼容旧 pointer。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(scope: ReleaseScope): OtaModels.InstalledRelease? {
    val state = readState(scope.lynxAppId)
    ensureStateScope(state, scope)
    return resolveCurrentUnsafe(scope, state)
  }

  /** 仅按 appId 读取 state，供已有宿主尚未持有完整 scope 时诊断使用。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String): OtaModels.InstalledRelease? {
    val state = readState(lynxAppId) ?: return OtaReleaseStore(storageRoot).currentRelease(lynxAppId)
    return resolveCurrentUnsafe(state.scope, state)
  }

  @Throws(IOException::class, OtaSdkException::class)
  /**
   * 路由热路径也必须验证 SHA；否则损坏的 current 会先进入 LynxView，再依赖渲染失败回滚，
   * 用户会看到白屏或黑屏。校验只读取本地文件，不会触发网络请求。
   */
  fun currentBundle(scope: ReleaseScope, bundleName: String): File? = resolveBundle(scope, bundleName, verify = true)

  @Throws(IOException::class, OtaSdkException::class)
  fun current(scope: ReleaseScope, bundleName: String): File? = currentBundle(scope, bundleName)

  /** appId 已足够定位新 state 时的便捷 overload；存在 state 时仍校验完整 scope。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun currentBundle(lynxAppId: String, bundleName: String): File? {
    val state = readState(lynxAppId)
    if (state != null) return currentBundle(state.scope, bundleName)
    val release = current(lynxAppId) ?: return null
    val exact = release.bundles.firstOrNull { it.bundlePath == bundleName }
      ?: release.bundles.singleOrNull { it.bundlePath.substringAfterLast('/') == bundleName }
      ?: return null
    val file = File(exact.localFilePath)
    return file.takeIf { it.isFile }
  }

  /** 回滚只把 current 切到 previous/embedded，不把坏的 current 自动再次设成 previous。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun rollback(scope: ReleaseScope): OtaModels.InstalledRelease? {
    return withStorageLock {
      ensureDirectories()
      val state = readState(scope.lynxAppId)
      ensureStateScope(state, scope)
      if (state == null) return@withStorageLock OtaReleaseStore(storageRoot).rollback(scope.lynxAppId)
      val previous = state.previous?.let { resolveRef(scope, it) }
      val embedded = resolveEmbedded(scope)
      val restored = when {
        previous != null && isUsableRelease(previous, scope) -> previous
        embedded != null && isUsableRelease(embedded, scope) -> embedded
        else -> return@withStorageLock null
      }
      writeStateAtomic(
        state.copy(
          generation = state.generation + 1L,
          current = referenceForRelease(scope, restored),
          previous = null,
        ),
      )
      restored
    }
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun rollback(lynxAppId: String): OtaModels.InstalledRelease? {
    val state = readState(lynxAppId)
    return if (state != null) rollback(state.scope) else OtaReleaseStore(storageRoot).rollback(lynxAppId)
  }

  /**
   * 直接删除指定 appId 的所有已下载 Bundle。
   *
   * Release 目录通过本地 `release-manifest.json` 的 `lynxAppId` 精确匹配；旧版没有
   * manifest 的目录只在该 appId 的 current/staged/previous pointer 明确引用时删除，
   * 不猜测目录归属，避免误删其它 appId。删除失败会抛出异常，调用方不能把失败当成功。
   */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteDownloadedBundles(lynxAppId: String) {
    require(lynxAppId.isNotBlank()) { "lynxAppId 不能为空" }
    withStorageLock {
      ensureDirectories()
      val releaseIds = linkedSetOf<String>()
      val state = runCatching { readState(lynxAppId) }.getOrNull()
      if (state?.scope?.lynxAppId == lynxAppId) {
        if (state.current.kind == RefKind.DOWNLOADED) releaseIds += state.current.releaseId
        state.previous?.takeIf { it.kind == RefKind.DOWNLOADED }?.let { releaseIds += it.releaseId }
      }

      // 兼容旧 pointer layout：pointer 文件名按 appId 生成，内容再做一次 scope 校验。
      val legacyStore = OtaReleaseStore(storageRoot)
      listOf(
        runCatching { legacyStore.currentRelease(lynxAppId) }.getOrNull(),
        runCatching { legacyStore.stagedRelease(lynxAppId) }.getOrNull(),
        runCatching { legacyStore.previousRelease(lynxAppId) }.getOrNull(),
      ).forEach { release ->
        if (release?.context?.lynxAppId == lynxAppId) releaseIds += release.context.releaseId
      }

      File(storageRoot, "releases").listFiles()?.forEach { releaseDirectory ->
        val manifestAppId = readLocalManifestAppId(File(releaseDirectory, LOCAL_MANIFEST_NAME))
        if (manifestAppId == lynxAppId || releaseDirectory.name in releaseIds) {
          // 这里是永久删除，不生成 .delete-*、.legacy-* 或其它备份目录。
          cleanupRecursively(releaseDirectory)
        }
      }
      File(storageRoot, ".staging").listFiles()?.forEach { stagingDirectory ->
        val manifestAppId = readLocalManifestAppId(File(stagingDirectory, LOCAL_MANIFEST_NAME))
        val referencesRelease = releaseIds.any { stagingDirectory.name.startsWith("$it.") }
        if (manifestAppId == lynxAppId || referencesRelease) cleanupRecursively(stagingDirectory)
      }

      // state 与 legacy downloaded pointer 是下载版本的元数据，也一并删除；embedded
      // pointer 刻意保留，保证清理后仍可从 APK assets 回退。
      listOf(
        statePath(lynxAppId),
        File(storageRoot, "current-release-${OtaModels.safeFileName(lynxAppId)}.json"),
        File(storageRoot, "staged-release-${OtaModels.safeFileName(lynxAppId)}.json"),
        File(storageRoot, "previous-release-${OtaModels.safeFileName(lynxAppId)}.json"),
      ).forEach { cleanupRecursively(it) }
    }
  }

  /** 直接删除所有 appId 的已下载 Bundle，保留 embedded 描述和 APK assets。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteAllDownloadedBundles() {
    withStorageLock {
      ensureDirectories()
      File(storageRoot, "releases").listFiles()?.forEach { cleanupRecursively(it) }
      File(storageRoot, ".staging").listFiles()?.forEach { cleanupRecursively(it) }
      File(storageRoot, "states").listFiles()?.forEach { cleanupRecursively(it) }
      storageRoot.listFiles()?.forEach { file ->
        // current/staged/previous pointer 只描述下载版本；embedded pointer 保留。
        if (file.isFile && (
            file.name.startsWith("current-release-") ||
              file.name.startsWith("staged-release-") ||
              file.name.startsWith("previous-release-")
          )
        ) {
          cleanupRecursively(file)
        }
      }
    }
  }

  /** 旧诊断入口的兼容别名；语义仍然是直接删除全部下载内容。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun clearDownloadedBundles() = deleteAllDownloadedBundles()

  @Throws(IOException::class, OtaSdkException::class)
  fun rollbackOutcome(scope: ReleaseScope): RollbackOutcome {
    val before = current(scope)?.context?.releaseId
    val restored = rollback(scope)
    return RollbackOutcome(restored, before, restored?.context?.releaseId)
  }

  /** 将旧 OtaReleaseStore 的 current 物化进新 layout。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun adoptLegacyCurrent(
    release: OtaModels.InstalledRelease,
    previous: OtaModels.InstalledRelease? = null,
  ): OtaModels.InstalledRelease {
    val scope = ReleaseScope.fromRelease(release)
    validateReleaseScope(scope, release)
    return withStorageLock {
      ensureDirectories()
      val existing = resolveDownloadedRelease(scope, release.context.releaseId)
      val installed = if (existing != null && isUsableRelease(existing, scope)) {
        existing
      } else {
        val staging = stagingDirectory(release.context.releaseId, UUID.randomUUID().toString())
        try {
          ensureDirectory(staging)
          for (bundle in release.bundles) {
            val normalized = validateBundlePath(bundle.bundlePath)
            val source = File(bundle.localFilePath)
            val part = partPath(resolveInside(staging, normalized))
            val copied = OtaIO.copyAndHash(source, part)
            validateStreamResult(bundle.bundleSha256, source.length(), copied)
            atomicMove(part, resolveInside(staging, normalized))
          }
          val manifest = releaseToManifest(release)
          writeLocalManifestAtomic(staging, manifest)
          verifyStagedRelease(staging, manifest)
          publishReleaseDirectory(staging, releaseDirectory(release.context.releaseId), scope, manifest)
          readPublishedRelease(scope, release.context.releaseId)
            ?: throw transactionError("旧 Release 物化后不可读取", "release_publish_failed")
        } finally {
          runCatching { cleanupRecursively(staging) }
        }
      }
      val oldState = readState(scope.lynxAppId)
      val oldCurrent = previous ?: resolveCurrentUnsafe(scope, oldState)
      writeStateAtomic(
        StateRecord(
          scope,
          (oldState?.generation ?: 0L) + 1L,
          ReleaseRef(RefKind.DOWNLOADED, installed.context.releaseId),
          oldCurrent?.let { referenceForRelease(scope, it) },
        ),
      )
      installed
    }
  }

  /** 新 runtime 的精确 Bundle 解析；bundleName 优先按完整 bundlePath 匹配。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun resolveBundle(scope: ReleaseScope, bundleName: String, verify: Boolean = true): File? {
    if (bundleName.isBlank() || bundleName.indexOf('\u0000') >= 0 || bundleName.contains('\\')) {
      throw transactionError("Bundle 名称不安全：$bundleName", "unsafe_bundle_path")
    }
    val release = current(scope) ?: return null
    val exact = release.bundles.filter { it.bundlePath == bundleName }
    val bundle = when {
      exact.size == 1 -> exact[0]
      exact.size > 1 -> throw transactionError("Bundle 路径重复：$bundleName", "duplicate_bundle_path")
      else -> {
        val matches = release.bundles.filter { it.bundlePath.substringAfterLast('/') == bundleName }
        if (matches.size == 1) matches[0] else return null
      }
    }
    val localPath = localPathFor(scope, release, bundle)
    if (!localPath.isFile) return null
    if (verify && !OtaIO.sha256(localPath).equals(bundle.bundleSha256, ignoreCase = true)) {
      throw transactionError("Bundle 校验失败：$bundleName", "bundle_checksum_failed")
    }
    return localPath
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun ensureBundleReady(scope: ReleaseScope, bundleName: String): File {
    return resolveBundle(scope, bundleName, verify = true)
      ?: throw transactionError("当前 release 找不到 Bundle：$bundleName", "bundle_not_found")
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun ensureBundleReady(lynxAppId: String, bundleName: String): File {
    val state = readState(lynxAppId)
    if (state != null) return ensureBundleReady(state.scope, bundleName)
    val path = currentBundle(lynxAppId, bundleName)
      ?: throw transactionError("当前 release 找不到 Bundle：$bundleName", "bundle_not_found")
    val release = current(lynxAppId) ?: throw transactionError("当前 release 不存在", "release_not_found")
    val canonicalPath = canonicalOrAbsolute(path).path
    val bundle = release.bundles.firstOrNull { canonicalOrAbsolute(File(it.localFilePath)).path == canonicalPath }
      ?: throw transactionError("当前 release 找不到 Bundle：$bundleName", "bundle_not_found")
    if (!OtaIO.sha256(path).equals(bundle.bundleSha256, ignoreCase = true)) {
      throw transactionError("Bundle 校验失败：$bundleName", "bundle_checksum_failed")
    }
    return path
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun currentTemplatePath(lynxAppId: String, pageId: Int): File? {
    val release = current(lynxAppId) ?: return null
    return release.bundles.firstOrNull { it.pageId == pageId }?.let { currentBundle(lynxAppId, it.bundlePath) }
  }

  private fun validateManifest(scope: ReleaseScope, manifest: OtaModels.ReleaseManifest) {
    validateReleaseId(manifest.releaseId)
    if (manifest.env != scope.env || manifest.hostApp != scope.hostApp ||
      manifest.lynxAppId != scope.lynxAppId || manifest.platform != scope.platform
    ) throw transactionError("Manifest scope 与请求不一致", "scope_mismatch")
    if (!manifest.platforms.contains(scope.platform)) throw transactionError("Manifest 未声明目标平台", "platform_mismatch")
    val seen = HashSet<String>()
    for (artifact in manifest.bundles) {
      if (!seen.add(validateBundlePath(artifact.bundlePath))) {
        throw transactionError("Manifest 中存在重复 Bundle 路径：${artifact.bundlePath}", "duplicate_bundle_path")
      }
      validateSha(artifact.bundleSha256)
      artifact.size?.let { if (it < 0) throw transactionError("Bundle size 不能为负数：${artifact.bundlePath}", "invalid_bundle_size") }
    }
  }

  private fun validateReleaseId(releaseId: String) {
    if (releaseId.isBlank() || releaseId == "." || releaseId == ".." || releaseId.contains('/') ||
      releaseId.contains('\\') || releaseId.indexOf('\u0000') >= 0
    ) throw transactionError("ReleaseId 不安全：$releaseId", "unsafe_release_id")
  }

  private fun validateBundlePath(bundlePath: String): String {
    if (bundlePath.isBlank() || bundlePath.startsWith('/') || bundlePath.contains('\\') ||
      Regex("^[A-Za-z]:($|/)").containsMatchIn(bundlePath) || bundlePath.indexOf('\u0000') >= 0
    ) throw transactionError("Bundle 路径不安全：$bundlePath", "unsafe_bundle_path")
    val segments = bundlePath.split('/')
    if (segments.any { it.isEmpty() || it == "." || it == ".." }) {
      throw transactionError("Bundle 路径不安全：$bundlePath", "unsafe_bundle_path")
    }
    return segments.joinToString("/")
  }

  private fun validateSha(value: String) {
    if (!SHA_PATTERN.matches(value)) throw transactionError("Bundle SHA-256 格式错误", "invalid_bundle_sha256")
  }

  private fun validateStreamResult(artifact: OtaModels.BundleArtifact, result: OtaIO.StreamResult) {
    artifact.size?.let { if (result.bytes != it.toLong()) throw transactionError("Bundle size 校验失败：${artifact.bundlePath}", "bundle_size_mismatch") }
    if (!result.sha256.equals(artifact.bundleSha256, ignoreCase = true)) {
      throw OtaSdkException.checksumMismatch(artifact.bundleSha256, result.sha256)
    }
  }

  private fun validateStreamResult(expectedSha: String, expectedSize: Long, result: OtaIO.StreamResult) {
    if (result.bytes != expectedSize || !result.sha256.equals(expectedSha, ignoreCase = true)) {
      throw OtaSdkException.checksumMismatch(expectedSha, result.sha256)
    }
  }

  private fun findReusableSource(current: OtaModels.InstalledRelease?, artifact: OtaModels.BundleArtifact): File? {
    val bundle = current?.bundles?.firstOrNull {
      it.bundlePath == artifact.bundlePath && it.bundleSha256.equals(artifact.bundleSha256, ignoreCase = true)
    } ?: return null
    val file = File(bundle.localFilePath)
    if (!file.isFile) return null
    return try { file.takeIf { OtaIO.sha256(it).equals(artifact.bundleSha256, ignoreCase = true) } } catch (_: IOException) { null }
  }

  /**
   * 在启动 worker 之前完成所有路径校验。
   *
   * 这样即使 manifest 中存在重复路径或路径穿越，也不会出现部分任务已经开始写入
   * staging 后才发现规划非法的情况。
   */
  private fun createBundleTransferPlans(
    manifest: OtaModels.ReleaseManifest,
    stagingDirectory: File,
  ): List<BundleTransferPlan> {
    val seenPaths = LinkedHashSet<String>()
    return manifest.bundles.mapIndexed { index, artifact ->
      val normalizedPath = validateBundlePath(artifact.bundlePath)
      if (!seenPaths.add(normalizedPath)) {
        throw transactionError("Manifest 中存在重复 Bundle 路径：${artifact.bundlePath}", "duplicate_bundle_path")
      }
      val finalStagedPath = resolveInside(stagingDirectory, normalizedPath)
      BundleTransferPlan(
        index = index,
        artifact = artifact,
        normalizedPath = normalizedPath,
        finalStagedPath = finalStagedPath,
        partPath = partPath(finalStagedPath),
      )
    }
  }

  /**
   * 对同一个 Release 的 Bundle 做固定上限并发。
   *
   * 任务只负责把已校验的数据写入各自的 `.part` 文件，返回结果后由事务线程按
   * manifest 顺序执行 atomicMove；current/previous/state 仍然只在所有任务完成后提交。
   */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  private fun transferBundlesConcurrently(
    plans: List<BundleTransferPlan>,
    previousRelease: OtaModels.InstalledRelease?,
  ): List<BundleTransferResult> {
    if (plans.isEmpty()) return emptyList()

    val workerCount = minOf(BUNDLE_DOWNLOAD_CONCURRENCY, plans.size)
    val executor = Executors.newFixedThreadPool(workerCount) { runnable ->
      Thread(runnable, "lynx-ota-bundle-transfer").apply { isDaemon = true }
    }
    val completion = ExecutorCompletionService<BundleTransferResult>(executor)
    val futures = ArrayList<java.util.concurrent.Future<BundleTransferResult>>(plans.size)

    try {
      for (plan in plans) {
        futures += completion.submit(Callable { transferBundle(plan, previousRelease) })
      }

      val results = arrayOfNulls<BundleTransferResult>(plans.size)
      repeat(plans.size) {
        val result = completion.take().get()
        results[result.index] = result
      }
      return results.mapIndexed { index, result ->
        result ?: throw IOException("Bundle 并发任务缺少结果：$index")
      }
    } catch (error: Exception) {
      // 任一 Bundle 失败时停止尚未开始的任务，并中断正在执行的任务；外层事务随后
      // 会删除整个 staging，绝不把部分 Release 发布成 current。
      futures.forEach { it.cancel(true) }
      throwTransferFailure(error)
    } finally {
      shutdownBundleExecutor(executor)
    }
  }

  private fun transferBundle(
    plan: BundleTransferPlan,
    previousRelease: OtaModels.InstalledRelease?,
  ): BundleTransferResult {
    try {
      val reusableSource = findReusableSource(previousRelease, plan.artifact)
      if (reusableSource != null) {
        try {
          val copied = OtaIO.copyAndHash(reusableSource, plan.partPath)
          validateStreamResult(plan.artifact, copied)
          return BundleTransferResult(
            index = plan.index,
            artifact = plan.artifact,
            normalizedPath = plan.normalizedPath,
            finalStagedPath = plan.finalStagedPath,
            partPath = plan.partPath,
            streamResult = copied,
            copiedFromPrevious = true,
          )
        } catch (error: InterruptedException) {
          throw error
        } catch (_: Exception) {
          // 旧文件缺失或校验失败时，删除本地 part 后回源 OSS 下载最新内容。
          runCatching { if (plan.partPath.exists()) plan.partPath.delete() }
        }
      }

      var lastError: Exception? = null
      for (attempt in 1..BUNDLE_TRANSFER_MAX_ATTEMPTS) {
        try {
          if (Thread.currentThread().isInterrupted) {
            throw InterruptedException("Bundle 下载任务已取消")
          }
          val downloaded = OtaIO.downloadAndHash(plan.artifact.bundleUrl, plan.partPath)
          validateStreamResult(plan.artifact, downloaded)
          return BundleTransferResult(
            index = plan.index,
            artifact = plan.artifact,
            normalizedPath = plan.normalizedPath,
            finalStagedPath = plan.finalStagedPath,
            partPath = plan.partPath,
            streamResult = downloaded,
            copiedFromPrevious = false,
          )
        } catch (error: InterruptedException) {
          throw error
        } catch (error: Exception) {
          lastError = error
          // 每次失败都删除 part，避免下一次重试把上一次的半截数据当成完整文件。
          runCatching { if (plan.partPath.exists()) plan.partPath.delete() }
          if (attempt < BUNDLE_TRANSFER_MAX_ATTEMPTS) {
            // 轻量退避，避免 OSS 或网络短暂抖动时 4 个 worker 立即重复打满请求。
            Thread.sleep(BUNDLE_RETRY_BASE_DELAY_MILLIS * attempt)
          }
        }
      }
      throw lastError ?: IOException("Bundle 下载失败：${plan.artifact.bundlePath}")
    } catch (error: Throwable) {
      // 外层会清理整个 staging；这里先移除当前任务的 part，避免失败重试看到半成品。
      runCatching { if (plan.partPath.exists()) plan.partPath.delete() }
      throw error
    }
  }

  private fun throwTransferFailure(error: Exception): Nothing {
    val cause = if (error is ExecutionException && error.cause != null) error.cause!! else error
    when (cause) {
      is IOException -> throw cause
      is InterruptedException -> throw cause
      is OtaSdkException -> throw cause
      else -> throw IOException("Bundle 并发传输失败", cause)
    }
  }

  private fun shutdownBundleExecutor(executor: ExecutorService) {
    executor.shutdownNow()
    try {
      executor.awaitTermination(BUNDLE_EXECUTOR_SHUTDOWN_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
    } catch (_: InterruptedException) {
      // 保留调用线程的中断标志；staging 清理由外层事务负责。
      Thread.currentThread().interrupt()
    }
  }

  private fun verifyInstalledRelease(
    installed: OtaModels.InstalledRelease,
    scope: ReleaseScope,
    manifest: OtaModels.ReleaseManifest,
  ): Boolean {
    if (!isUsableRelease(installed, scope) || installed.bundles.size != manifest.bundles.size) return false
    return manifest.bundles.all { artifact ->
      val bundle = installed.bundles.firstOrNull { it.bundlePath == artifact.bundlePath } ?: return@all false
      bundle.bundleSha256.equals(artifact.bundleSha256, ignoreCase = true) &&
        File(bundle.localFilePath).isFile &&
        OtaIO.sha256(File(bundle.localFilePath)).equals(artifact.bundleSha256, ignoreCase = true)
    }
  }

  private fun verifyStagedRelease(stagingDirectory: File, manifest: OtaModels.ReleaseManifest) {
    val listed = HashSet<String>()
    for (artifact in manifest.bundles) {
      val normalized = validateBundlePath(artifact.bundlePath)
      listed.add(normalized)
      val path = resolveInside(stagingDirectory, normalized)
      if (!path.isFile) throw transactionError("staging 缺少 Bundle：$normalized", "release_validate_failed")
      artifact.size?.let { if (path.length() != it.toLong()) throw transactionError("staging size 校验失败：$normalized", "bundle_size_mismatch") }
      if (!OtaIO.sha256(path).equals(artifact.bundleSha256, ignoreCase = true)) {
        throw transactionError("staging SHA 校验失败：$normalized", "bundle_checksum_failed")
      }
    }
    listFilesRecursively(stagingDirectory).forEach { path ->
      if (!path.isFile) return@forEach
      val relative = relativePath(stagingDirectory, path)
      if (relative == LOCAL_MANIFEST_NAME || relative.endsWith(".part")) return@forEach
      if (!listed.contains(relative)) throw transactionError("staging 存在未声明文件：$relative", "release_validate_failed")
    }
  }

  private fun publishReleaseDirectory(
    stagingDirectory: File,
    releaseDirectory: File,
    scope: ReleaseScope,
    manifest: OtaModels.ReleaseManifest,
  ) {
    if (releaseDirectory.exists()) {
      val existing = readPublishedRelease(scope, manifest.releaseId)
      if (existing != null && verifyInstalledRelease(existing, scope, manifest)) {
        runCatching { cleanupRecursively(stagingDirectory) }
        return
      }
      // 兼容旧 OtaReleaseStore：旧版本只把 Bundle 写在 releases/<id>，没有
      // release-manifest.json。新事务可以在完成校验后替换这类 legacy 目录；
      // 已有新 manifest 但内容不一致时仍拒绝覆盖，避免 releaseId 冲突污染。
      if (File(releaseDirectory, LOCAL_MANIFEST_NAME).isFile) {
        val existingReleaseId = readManifestReleaseId(File(releaseDirectory, LOCAL_MANIFEST_NAME))
        if (existingReleaseId != manifest.releaseId) {
          throw transactionError("同 releaseId 已存在不同内容，拒绝覆盖", "release_identity_conflict")
        }
        // 同一个 releaseId 但本地文件不完整/校验失败，直接删除旧目录后重新发布。
        // 不再改名生成长期 .incomplete/.delete 备份，避免失败重试不断占用磁盘。
        cleanupRecursively(releaseDirectory)
        atomicMove(stagingDirectory, releaseDirectory)
        return
      }
      // 旧 OtaReleaseStore 目录没有 manifest，也直接清理后发布新 layout。
      // 这里宁可让事务明确失败并下次重试，也不保留占磁盘的隐藏备份目录。
      cleanupRecursively(releaseDirectory)
      atomicMove(stagingDirectory, releaseDirectory)
      return
    }
    try {
      atomicMove(stagingDirectory, releaseDirectory)
    } catch (error: IOException) {
      throw OtaSdkException("Release 目录原子发布失败", error)
    }
  }

  private fun writeLocalManifestAtomic(stagingDirectory: File, manifest: OtaModels.ReleaseManifest) {
    val map = LinkedHashMap<String, Any?>(manifest.toJsonMap())
    map["schemaVersion"] = 1
    map["installedAt"] = clock.now().toString()
    map["bundles"] = manifest.bundles.map { artifact ->
      LinkedHashMap<String, Any?>(artifact.toJsonMap()).apply { this["remoteUrl"] = artifact.bundleUrl.toString() }
    }
    writeAtomic(File(stagingDirectory, LOCAL_MANIFEST_NAME), OtaJson.stringify(map))
  }

  /** 只读取本地 manifest 的 appId，用于按 appId 清理时识别目录归属。 */
  private fun readLocalManifestAppId(manifestPath: File): String? {
    if (!manifestPath.isFile) return null
    return try {
      val map = OtaJson.asObject(OtaJson.parse(manifestPath.readText(Charsets.UTF_8)), manifestPath.toString())
      OtaModels.optionalString(map["lynxAppId"], OtaModels.DEFAULT_LYNX_APP_ID)
    } catch (_: IOException) {
      null
    } catch (_: RuntimeException) {
      null
    }
  }

  private fun readPublishedRelease(scope: ReleaseScope, releaseId: String): OtaModels.InstalledRelease? {
    val releaseDirectory = releaseDirectory(releaseId)
    val manifestPath = File(releaseDirectory, LOCAL_MANIFEST_NAME)
    if (!manifestPath.isFile) return null
    return try {
      val map = OtaJson.asObject(OtaJson.parse(manifestPath.readText(Charsets.UTF_8)), manifestPath.toString())
      val manifest = OtaModels.ReleaseManifest.fromJsonMap(map)
      if (manifest.releaseId != releaseId) return null
      validateManifest(scope, manifest)
      val installedAt = (map["installedAt"] as? String)?.let { Instant.parse(it) } ?: Instant.EPOCH
      val bundles = manifest.bundles.map { artifact ->
        val path = resolveInside(releaseDirectory, validateBundlePath(artifact.bundlePath))
        // 读取 published release 时再次检查文件存在、大小和 SHA，避免不完整目录
        // 被写入 Active State，进而把损坏 Bundle 送入 LynxView。
        if (!path.isFile) return null
        artifact.size?.let { if (path.length() != it.toLong()) return null }
        if (!OtaIO.sha256(path).equals(artifact.bundleSha256, ignoreCase = true)) return null
        OtaModels.InstalledBundle(artifact.pageId, artifact.bundlePath, artifact.bundleSha256, artifact.bundleUrl, path.toString())
      }
      OtaModels.InstalledRelease(
        OtaModels.CurrentReleaseContext(manifest.env, manifest.hostApp, manifest.lynxAppId, manifest.releaseId, manifest.platform, OtaModels.ReleaseStatus.ACTIVE),
        installedAt,
        bundles,
      )
    } catch (_: IOException) {
      null
    } catch (_: RuntimeException) {
      null
    }
  }

  /** 读取已有本地 manifest 的 releaseId，用于区分“同版本残留损坏”与真正的身份冲突。 */
  private fun readManifestReleaseId(manifestPath: File): String? {
    return try {
      val map = OtaJson.asObject(OtaJson.parse(manifestPath.readText(Charsets.UTF_8)), manifestPath.toString())
      (map["releaseId"] as? String)?.takeIf { it.isNotBlank() }
    } catch (_: IOException) {
      null
    } catch (_: RuntimeException) {
      null
    }
  }

  private fun resolveDownloadedRelease(scope: ReleaseScope, releaseId: String): OtaModels.InstalledRelease? {
    validateReleaseId(releaseId)
    return readPublishedRelease(scope, releaseId)
  }

  private fun resolveEmbedded(scope: ReleaseScope): OtaModels.InstalledRelease? {
    val embedded = OtaReleaseStore(storageRoot).embeddedRelease(scope.lynxAppId) ?: return null
    return embedded.takeIf { matchesScope(scope, it) }
  }

  private fun resolveRef(scope: ReleaseScope, ref: ReleaseRef): OtaModels.InstalledRelease? {
    return when (ref.kind) {
      RefKind.EMBEDDED -> resolveEmbedded(scope)?.takeIf { it.context.releaseId == ref.releaseId }
      RefKind.DOWNLOADED -> resolveDownloadedRelease(scope, ref.releaseId)
    }
  }

  private fun resolveCurrentUnsafe(scope: ReleaseScope, state: StateRecord?): OtaModels.InstalledRelease? {
    if (state != null) return resolveRef(scope, state.current)
    val legacyStore = OtaReleaseStore(storageRoot)
    val current = legacyStore.currentRelease(scope.lynxAppId)
    if (current != null && matchesScope(scope, current)) return current
    return legacyStore.embeddedRelease(scope.lynxAppId)?.takeIf { matchesScope(scope, it) }
  }

  private fun isUsableRelease(release: OtaModels.InstalledRelease, scope: ReleaseScope): Boolean {
    if (!matchesScope(scope, release)) return false
    return release.bundles.all { bundle ->
      val file = File(bundle.localFilePath)
      file.isFile && tryShaMatches(file, bundle.bundleSha256)
    }
  }

  private fun tryShaMatches(file: File, expected: String): Boolean {
    return try { OtaIO.sha256(file).equals(expected, ignoreCase = true) } catch (_: IOException) { false }
  }

  private fun localPathFor(scope: ReleaseScope, release: OtaModels.InstalledRelease, bundle: OtaModels.InstalledBundle): File {
    val state = readState(scope.lynxAppId)
    return if (state?.current?.kind == RefKind.DOWNLOADED && state.current.releaseId == release.context.releaseId) {
      resolveInside(releaseDirectory(release.context.releaseId), validateBundlePath(bundle.bundlePath))
    } else {
      File(bundle.localFilePath)
    }
  }

  private fun matchesScope(scope: ReleaseScope, release: OtaModels.InstalledRelease): Boolean {
    return release.context.env == scope.env && release.context.hostApp == scope.hostApp &&
      release.context.lynxAppId == scope.lynxAppId && release.context.platform == scope.platform
  }

  private fun validateReleaseScope(scope: ReleaseScope, release: OtaModels.InstalledRelease) {
    if (!matchesScope(scope, release)) throw transactionError("Release scope 不一致", "scope_mismatch")
    validateReleaseId(release.context.releaseId)
    release.bundles.forEach { validateBundlePath(it.bundlePath); validateSha(it.bundleSha256) }
  }

  private fun releaseToManifest(release: OtaModels.InstalledRelease): OtaModels.ReleaseManifest {
    return OtaModels.ReleaseManifest(
      release.context.env,
      release.context.hostApp,
      release.context.lynxAppId,
      release.context.releaseId,
      release.context.platform,
      listOf(release.context.platform),
      release.bundles.map { bundle ->
        val source = File(bundle.localFilePath)
        OtaModels.BundleArtifact(bundle.pageId, bundle.bundlePath, bundle.bundleSha256, bundle.remoteUrl,
          if (source.isFile) source.length().coerceAtMost(Int.MAX_VALUE.toLong()).toInt() else null)
      },
    )
  }

  private fun referenceForRelease(scope: ReleaseScope, release: OtaModels.InstalledRelease): ReleaseRef {
    val embedded = resolveEmbedded(scope)
    return if (embedded?.context?.releaseId == release.context.releaseId) {
      ReleaseRef(RefKind.EMBEDDED, release.context.releaseId)
    } else {
      ReleaseRef(RefKind.DOWNLOADED, release.context.releaseId)
    }
  }

  private fun readState(lynxAppId: String): StateRecord? {
    val path = statePath(lynxAppId)
    if (!path.isFile) return null
    return try {
      val map = OtaJson.asObject(OtaJson.parse(path.readText(Charsets.UTF_8)), path.toString())
      val scopeValue = map["scope"]
      val scopeMap = if (scopeValue == null) map else OtaJson.asObject(scopeValue, "state.scope")
      val scope = ReleaseScope(
        OtaModels.Environment.fromWire(OtaModels.stringValue(scopeMap["env"])),
        OtaModels.HostApp.fromWire(OtaModels.stringValue(scopeMap["hostApp"])),
        OtaModels.stringValue(scopeMap["lynxAppId"]),
        OtaModels.Platform.fromWire(OtaModels.stringValue(scopeMap["platform"])),
      )
      val current = parseRef(OtaJson.asObject(map["current"], "state.current"))
      val previousValue = map["previous"]
      val previous = if (previousValue == null) null else parseRef(OtaJson.asObject(previousValue, "state.previous"))
      val generation = (map["generation"] as? Number)?.toLong() ?: OtaModels.stringValue(map["generation"]).toLong()
      StateRecord(scope, generation, current, previous)
    } catch (error: OtaSdkException) {
      throw error
    } catch (error: RuntimeException) {
      throw OtaSdkException("Active State 解析失败：$path", error, "storage_recovery_failed")
    }
  }

  private fun parseRef(map: Map<String, Any?>): ReleaseRef {
    val kind = when (OtaModels.stringValue(map["kind"]).lowercase()) {
      "embedded" -> RefKind.EMBEDDED
      "downloaded" -> RefKind.DOWNLOADED
      else -> throw transactionError("state 引用了未知 release kind", "storage_recovery_failed")
    }
    val releaseId = OtaModels.stringValue(map["releaseId"])
    validateReleaseId(releaseId)
    return ReleaseRef(kind, releaseId)
  }

  private fun ensureStateScope(state: StateRecord?, expected: ReleaseScope) {
    if (state != null && state.scope != expected) throw transactionError("Active State scope 与当前配置不一致", "scope_mismatch")
  }

  private fun writeStateAtomic(state: StateRecord) {
    ensureDirectories()
    val map = LinkedHashMap<String, Any?>()
    map["schemaVersion"] = 1
    map["generation"] = state.generation
    map["env"] = state.scope.env.wireValue
    map["hostApp"] = state.scope.hostApp.wireValue
    map["lynxAppId"] = state.scope.lynxAppId
    map["platform"] = state.scope.platform.wireValue
    map["scope"] = mapOf(
      "env" to state.scope.env.wireValue,
      "hostApp" to state.scope.hostApp.wireValue,
      "lynxAppId" to state.scope.lynxAppId,
      "platform" to state.scope.platform.wireValue,
    )
    map["current"] = state.current.toJsonMap()
    map["previous"] = state.previous?.toJsonMap()
    writeAtomic(statePath(state.scope.lynxAppId), OtaJson.stringify(map))
  }

  /**
   * java.io.File 没有 ATOMIC_MOVE；这里使用同目录临时文件 + renameTo，并在替换已有
   * pointer 时保留 backup，失败会尝试恢复。Release 目录本身只在目标不存在时发布。
   */
  private fun writeAtomic(target: File, raw: String) {
    target.parentFile?.let { ensureDirectory(it) }
    val temporary = File(target.parentFile ?: storageRoot, ".${target.name}.tmp-${UUID.randomUUID()}")
    try {
      FileOutputStream(temporary, false).use { output ->
        output.write(raw.toByteArray(Charsets.UTF_8))
        output.fd.sync()
      }
      atomicMove(temporary, target, replaceExisting = true)
    } finally {
      deleteRecursively(temporary)
    }
  }

  private fun atomicMove(source: File, target: File, replaceExisting: Boolean = false) {
    target.parentFile?.let { ensureDirectory(it) }
    if (!source.exists()) throw IOException("临时文件不存在：$source")
    if (!replaceExisting && target.exists()) throw IOException("目标文件已存在：$target")
    if (!replaceExisting) {
      if (!source.renameTo(target)) throw IOException("无法发布文件：$target")
      return
    }

    val backup = if (target.exists()) File(target.parentFile ?: storageRoot, ".${target.name}.bak-${UUID.randomUUID()}") else null
    if (backup != null && !target.renameTo(backup)) throw IOException("无法备份旧文件：$target")
    try {
      if (!source.renameTo(target)) throw IOException("无法替换文件：$target")
      backup?.let { deleteRecursively(it) }
    } catch (error: Throwable) {
      if (!target.exists()) backup?.renameTo(target)
      throw error
    }
  }

  private fun <T> withStorageLock(block: () -> T): T {
    val root = canonicalOrAbsolute(storageRoot)
    val processLock = PROCESS_LOCKS.computeIfAbsent(root.path) { ReentrantLock() }
    return processLock.withLock {
      ensureNoSymlink(root)
      val locks = File(root, "locks")
      ensureDirectory(locks)
      ensureNoSymlink(locks)
      val marker = File(locks, "storage.lock")
      val startedAt = System.currentTimeMillis()
      while (!marker.mkdir()) {
        if (!marker.exists()) continue
        val age = System.currentTimeMillis() - marker.lastModified()
        if (age > STALE_LOCK_MILLIS && marker.delete()) continue
        if (System.currentTimeMillis() - startedAt > LOCK_WAIT_MILLIS) {
          throw IOException("OTA storage 正在被其它事务占用")
        }
        try {
          Thread.sleep(25L)
        } catch (error: InterruptedException) {
          Thread.currentThread().interrupt()
          throw error
        }
      }
      marker.setLastModified(System.currentTimeMillis())
      try {
        block()
      } finally {
        deleteRecursively(marker)
      }
    }
  }

  private fun ensureDirectories() {
    val root = canonicalOrAbsolute(storageRoot)
    ensureNoSymlink(root)
    ensureDirectory(root)
    for (name in listOf("releases", ".staging", "states")) {
      val child = File(root, name)
      ensureNoSymlink(child)
      ensureDirectory(child)
    }
  }

  private fun recoverStaging() {
    val stagingRoot = File(storageRoot, ".staging")
    if (!stagingRoot.isDirectory) return
    stagingRoot.listFiles()?.forEach { cleanupRecursively(it) }
  }

  private fun stagingDirectory(releaseId: String, transactionId: String): File {
    validateReleaseId(releaseId)
    return File(File(storageRoot, ".staging"), "$releaseId.$transactionId")
  }

  private fun releaseDirectory(releaseId: String): File {
    validateReleaseId(releaseId)
    return File(File(storageRoot, "releases"), releaseId)
  }

  private fun statePath(lynxAppId: String): File {
    return File(File(storageRoot, "states"), "${OtaModels.safeFileName(lynxAppId)}.json")
  }

  private fun partPath(path: File): File = File(path.parentFile ?: storageRoot, "${path.name}.part")

  private fun resolveInside(root: File, relativePath: String): File {
    val normalizedRoot = canonicalOrAbsolute(root)
    val candidate = File(normalizedRoot, relativePath.replace('/', File.separatorChar))
    val normalizedCandidate = canonicalOrAbsolute(candidate)
    if (!isInside(normalizedRoot, normalizedCandidate)) throw transactionError("Bundle 路径越出 Release 目录", "unsafe_bundle_path")
    ensureNoSymlink(normalizedRoot)
    ensureNoSymlink(normalizedCandidate)
    var cursor = normalizedRoot
    val relative = normalizedCandidate.path.removePrefix(normalizedRoot.path).trimStart(File.separatorChar)
    if (relative.isNotEmpty()) {
      relative.split(File.separatorChar).forEach {
        cursor = File(cursor, it)
        ensureNoSymlink(cursor)
      }
    }
    return normalizedCandidate
  }

  private fun isInside(root: File, target: File): Boolean {
    val rootPath = root.path.trimEnd(File.separatorChar)
    return target.path == rootPath || target.path.startsWith("$rootPath${File.separatorChar}")
  }

  /** 对已经规范化的受控路径做 symlink 防护；删除递归使用下面的节点级判断。 */
  private fun ensureNoSymlink(path: File) {
    val absolute = path.absoluteFile
    val canonical = try {
      path.canonicalFile
    } catch (error: IOException) {
      throw transactionError("无法解析 OTA 存储路径：$path", "unsafe_storage_path")
    }
    if (absolute.path != canonical.path) {
      throw transactionError("OTA 路径包含 symlink：$path", "unsafe_storage_path")
    }
  }

  private fun canonicalOrAbsolute(file: File): File {
    return try {
      file.canonicalFile
    } catch (_: IOException) {
      file.absoluteFile
    }
  }

  private fun listFilesRecursively(root: File): List<File> {
    val result = ArrayList<File>()
    val children = root.listFiles() ?: return result
    for (child in children) {
      result.add(child)
      if (child.isDirectory && !isSymlink(child)) result.addAll(listFilesRecursively(child))
    }
    return result
  }

  private fun relativePath(root: File, child: File): String {
    val rootPath = canonicalOrAbsolute(root).path.trimEnd(File.separatorChar)
    return canonicalOrAbsolute(child).path.removePrefix("$rootPath${File.separatorChar}").replace(File.separatorChar, '/')
  }

  private fun isSymlink(file: File): Boolean {
    return try {
      // 不能直接比较 absolutePath 与 canonicalPath：macOS 的 /var、Android 某些
      // filesDir 别名会让“普通子文件”看起来像 symlink，进而跳过递归删除。
      // 只要 canonical 子路径仍等于 canonical 父目录 + 当前文件名，就说明当前节点
      // 本身不是 symlink；真正的 symlink 会解析到另一条路径。
      val absolute = file.absoluteFile
      val parent = absolute.parentFile ?: return false
      val canonicalParent = parent.canonicalFile
      val canonicalFile = absolute.canonicalFile
      canonicalFile.path != File(canonicalParent, absolute.name).path
    } catch (_: IOException) {
      false
    }
  }

  private fun ensureDirectory(directory: File) {
    if (directory.isDirectory) return
    if (!directory.mkdirs() && !directory.isDirectory) throw IOException("无法创建 OTA 目录：$directory")
  }

  private fun deleteRecursively(path: File) {
    if (!path.exists() && !isSymlink(path)) return
    if (path.isDirectory && !isSymlink(path)) path.listFiles()?.forEach { deleteRecursively(it) }
    if (path.exists() && !path.delete()) throw IOException("无法删除 OTA 临时文件：$path")
  }

  /** Android 文件系统偶发短暂占用时重试删除；失败时保留原路径并让事务返回失败。 */
  private fun cleanupRecursively(path: File) {
    if (!path.exists() && !isSymlink(path)) return
    var lastError: IOException? = null
    repeat(8) { attempt ->
      try {
        deleteRecursively(path)
        return
      } catch (error: IOException) {
        lastError = error
        if (attempt < 7) {
          try {
            Thread.sleep((25L * (attempt + 1)).coerceAtMost(250L))
          } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
            return
          }
        }
      }
    }
    if (path.exists() && lastError != null) throw lastError as IOException
  }

  private fun transactionError(message: String, code: String): OtaSdkException = OtaSdkException(message, null, code)

  private fun storageError(message: String, code: String, stage: StorageStage): OtaSdkException {
    return OtaSdkException("$message（stage=${stage.name}）", null, code)
  }

  private data class StateRecord(
    val scope: ReleaseScope,
    val generation: Long,
    val current: ReleaseRef,
    val previous: ReleaseRef?,
  )

  private data class ReleaseRef(val kind: RefKind, val releaseId: String) {
    fun toJsonMap(): Map<String, Any?> = mapOf("kind" to kind.wireValue, "releaseId" to releaseId)
  }

  private enum class RefKind(val wireValue: String) {
    EMBEDDED("embedded"),
    DOWNLOADED("downloaded"),
  }

  companion object {
    /** 一个 Release 内的 Bundle 下载并发上限；不同 appId 的事务仍由外层队列串行调度。 */
    private const val BUNDLE_DOWNLOAD_CONCURRENCY = 4
    /** 单个 Bundle 最多尝试 3 次：首次下载失败后再重试 2 次。 */
    private const val BUNDLE_TRANSFER_MAX_ATTEMPTS = 3
    private const val BUNDLE_RETRY_BASE_DELAY_MILLIS = 250L
    private const val BUNDLE_EXECUTOR_SHUTDOWN_TIMEOUT_MILLIS = 5_000L
    private const val LOCAL_MANIFEST_NAME = "release-manifest.json"
    private const val METADATA_ALLOWANCE_BYTES = 1024L * 1024L
    private const val SAFETY_RESERVE_BYTES = 32L * 1024L * 1024L
    private const val LOCK_WAIT_MILLIS = 30_000L
    private const val STALE_LOCK_MILLIS = 120_000L
    private val SHA_PATTERN = Regex("sha256:[0-9a-fA-F]{64}")
    private val PROCESS_LOCKS = ConcurrentHashMap<String, ReentrantLock>()
  }
}
