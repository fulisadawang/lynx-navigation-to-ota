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
import java.util.concurrent.atomic.AtomicBoolean
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
  private val faultInjector: TransactionFaultInjecting = TransactionFaultInjecting.NONE,
) {
  /** 只保存本进程已经完成的 Bundle SHA 校验结果，不保存 Bundle 内容。 */
  private val bundleValidationCache = BundleValidationCache()

  /** 一个宿主内的唯一存储作用域；appId 不能跨环境/宿主/平台复用状态。 */
  data class ReleaseScope(
    @JvmField val env: OtaModels.Environment,
    @JvmField val hostApp: OtaModels.HostApp,
    @JvmField val lynxAppId: String,
    @JvmField val platform: OtaModels.Platform,
  ) {
    init {
      OtaModels.requireLynxAppId(lynxAppId)
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
    /** true 时只发布 release 目录并写 candidate，不修改 current/previous。 */
    @JvmField val stageAsCandidate: Boolean = false,
  ) {
    constructor(scope: ReleaseScope, targetManifest: OtaModels.ReleaseManifest) : this(scope, targetManifest, null)
  }

  enum class TransactionFaultPoint {
    BEFORE_STATE_COMMIT,
    AFTER_STATE_COMMIT,
    BEFORE_ROLLBACK_COMMIT,
    AFTER_ROLLBACK_COMMIT,
  }

  fun interface TransactionFaultInjecting {
    fun check(point: TransactionFaultPoint)

    companion object {
      @JvmField
      val NONE: TransactionFaultInjecting = TransactionFaultInjecting { }
    }
  }

  enum class InstallResultType {
    UPDATED,
    ALREADY_ACTIVE,
    SKIPPED,
    CANDIDATE,
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
    /** Store v3 命中已有 CAS 对象的数量；没有发生文件复制。 */
    @JvmField val reusedBundleCount: Int = 0,
    @JvmField val reusedBytes: Long = 0,
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

  /**
   * 活体页面对一个已解析 Bundle 的进程内租约。
   *
   * close 幂等；只有 downloaded Release 会计入保留集合，embedded 只返回无状态租约。
   */
  class BundleLease internal constructor(
    @JvmField val release: OtaModels.InstalledRelease,
    @JvmField val bundle: OtaModels.InstalledBundle,
    @JvmField val file: File,
    private val onClose: () -> Unit,
  ) : AutoCloseable {
    private val closed = AtomicBoolean(false)

    override fun close() {
      if (closed.compareAndSet(false, true)) onClose()
    }
  }

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
      ensureAppDirectories(scope.lynxAppId)
      EmbeddedReleaseStore(storageRoot).saveEmbeddedRelease(release)
      val state = readState(scope.lynxAppId)
      if (state == null) {
        writeStateAtomic(
          StateRecord(
            scope,
            1L,
            ReleaseRef(RefKind.EMBEDDED, release.context.releaseId),
            null,
          ),
        )
      }
      pruneUnreferencedReleases(scope)
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
      ensureAppDirectories(request.scope.lynxAppId)
      recoverStaging(request.scope.lynxAppId)
      request.embeddedDescriptor?.let { EmbeddedReleaseStore(storageRoot).saveEmbeddedRelease(it) }

      val oldState = readState(request.scope.lynxAppId)
      ensureStateScope(oldState, request.scope)
      val oldCurrent = resolveCurrentUnsafe(request.scope, oldState)
      // 如果损坏的旧 current 与目标 releaseId 相同，不能把同一个 release 再写成
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

      // 先释放不再被 state/candidate/活体页面引用的历史版本，再做容量预检。
      pruneUnreferencedReleases(request.scope)
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
      val stagingDirectory = stagingDirectory(
        request.scope.lynxAppId,
        request.targetManifest.releaseId,
        transactionId,
      )
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
        val targetDirectory = releaseDirectory(request.scope.lynxAppId, request.targetManifest.releaseId)
        publishReleaseDirectory(stagingDirectory, targetDirectory, request.scope, request.targetManifest)
        val installed = readPublishedRelease(request.scope, request.targetManifest.releaseId)
          ?: throw transactionError("发布后的 Release Manifest 不可读", "release_publish_failed")
        if (request.stageAsCandidate) {
          writeCandidateAtomic(
            CandidateRecord(
              scope = request.scope,
              release = ReleaseRef(RefKind.DOWNLOADED, request.targetManifest.releaseId),
              status = OtaModels.CandidateStatus.PENDING,
              failureCount = 0,
              createdAt = clock.now(),
              trialStartedAt = null,
            ),
          )
          pruneUnreferencedReleases(request.scope)
          return@withStorageLock InstallOutcome(
            InstallResultType.CANDIDATE,
            oldCurrent,
            installed,
            fromReleaseId = oldCurrent?.context?.releaseId,
            toReleaseId = installed.context.releaseId,
            copiedBundleCount = copiedBundleCount,
            copiedBytes = copiedBytes,
            downloadedBundleCount = downloadedBundleCount,
            downloadedBytes = downloadedBytes,
            reusedBundleCount = copiedBundleCount,
            reusedBytes = copiedBytes,
            writtenBytes = writtenBytes,
          )
        }
        faultInjector.check(TransactionFaultPoint.BEFORE_STATE_COMMIT)
        writeStateAtomic(
          StateRecord(
            request.scope,
            (oldState?.generation ?: 0L) + 1L,
            ReleaseRef(RefKind.DOWNLOADED, request.targetManifest.releaseId),
            oldCurrentRef,
          ),
        )
        faultInjector.check(TransactionFaultPoint.AFTER_STATE_COMMIT)
        pruneUnreferencedReleases(request.scope)
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
          reusedBundleCount = copiedBundleCount,
          reusedBytes = copiedBytes,
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

  /** 读取 Store v2 Active State；没有 state 时回退到 embedded 描述。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(scope: ReleaseScope): OtaModels.InstalledRelease? {
    val state = readState(scope.lynxAppId)
    ensureStateScope(state, scope)
    return resolveCurrentUnsafe(scope, state)
  }

  /** 仅按 appId 读取 state，供已有宿主尚未持有完整 scope 时诊断使用。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String): OtaModels.InstalledRelease? {
    OtaModels.requireLynxAppId(lynxAppId)
    val state = readState(lynxAppId)
    return if (state != null) resolveCurrentUnsafe(state.scope, state) else EmbeddedReleaseStore(storageRoot).embeddedRelease(lynxAppId)
  }

  /** 读取持久化 candidate；不会改变 current，也不会把 pending 自动变成 trial。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun candidate(scope: ReleaseScope): OtaModels.CandidateSnapshot? {
    val record = readCandidate(scope.lynxAppId) ?: return null
    ensureCandidateScope(record, scope)
    val release = resolveRef(scope, record.release) ?: return null
    if (!isUsableRelease(release, scope)) return null
    return candidateSnapshot(record, release)
  }

  /** 页面真正使用候选版本时才进入 trial；重复调用保持幂等。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun beginCandidateTrial(scope: ReleaseScope): OtaModels.CandidateSnapshot {
    return withStorageLock {
      ensureDirectories()
      val record = readCandidate(scope.lynxAppId)
        ?: throw transactionError("当前没有可用 candidate", "candidate_missing")
      ensureCandidateScope(record, scope)
      val release = resolveRef(scope, record.release)
        ?: throw transactionError("candidate Release 不存在", "candidate_missing")
      if (!isUsableRelease(release, scope)) {
        throw transactionError("candidate Release 不可用", "candidate_invalid")
      }
      if (record.status == OtaModels.CandidateStatus.TRIAL) {
        return@withStorageLock candidateSnapshot(record, release)
      }
      val trial = record.copy(
        status = OtaModels.CandidateStatus.TRIAL,
        trialStartedAt = clock.now(),
      )
      writeCandidateAtomic(trial)
      candidateSnapshot(trial, release)
    }
  }

  /** 健康确认后原子 promote：candidate -> current，旧 current -> previous。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun confirmCandidate(scope: ReleaseScope): OtaModels.InstalledRelease {
    return withStorageLock {
      ensureDirectories()
      val record = readCandidate(scope.lynxAppId)
        ?: throw transactionError("当前没有可确认的 candidate", "candidate_missing")
      ensureCandidateScope(record, scope)
      if (record.status != OtaModels.CandidateStatus.TRIAL) {
        throw transactionError("candidate 尚未进入 trial", "candidate_not_in_trial")
      }
      val candidate = resolveRef(scope, record.release)
        ?: throw transactionError("candidate Release 不存在", "candidate_missing")
      if (!isUsableRelease(candidate, scope)) {
        throw transactionError("candidate Release 不可用", "candidate_invalid")
      }
      val oldState = readState(scope.lynxAppId)
      ensureStateScope(oldState, scope)
      val oldCurrent = resolveCurrentUnsafe(scope, oldState)
      val previous = oldCurrent?.let { referenceForRelease(scope, it) }
        ?: resolveEmbedded(scope)?.let { referenceForRelease(scope, it) }
      val next = StateRecord(
        scope = scope,
        generation = (oldState?.generation ?: 0L) + 1L,
        current = record.release,
        previous = previous?.takeUnless { it == record.release },
      )
      faultInjector.check(TransactionFaultPoint.BEFORE_STATE_COMMIT)
      writeStateAtomic(next)
      faultInjector.check(TransactionFaultPoint.AFTER_STATE_COMMIT)
      removeCandidateAtomic(scope.lynxAppId)
      pruneUnreferencedReleases(scope)
      candidate
    }
  }

  /** 丢弃 candidate；若它未被 current/previous 引用，同时清理其下载目录。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun discardCandidate(scope: ReleaseScope) {
    withStorageLock {
      ensureDirectories()
      val record = readCandidate(scope.lynxAppId) ?: return@withStorageLock
      ensureCandidateScope(record, scope)
      val currentState = readState(scope.lynxAppId)
      ensureStateScope(currentState, scope)
      removeCandidateAtomic(scope.lynxAppId)
      pruneUnreferencedReleases(scope)
    }
  }

  /** 进程重启时清理未完成的 trial；pending candidate 仍可等待页面首次访问。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun recoverInterruptedCandidate(scope: ReleaseScope) {
    val record = readCandidate(scope.lynxAppId) ?: return
    ensureCandidateScope(record, scope)
    if (record.status == OtaModels.CandidateStatus.TRIAL) {
      discardCandidate(scope)
    }
  }

  /** 按 candidate 的 Release 读取指定 Bundle，不消费 current。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun candidateBundle(scope: ReleaseScope, bundleName: String): File? {
    if (bundleName.isBlank() || bundleName.indexOf('\u0000') >= 0 || bundleName.contains('\\')) {
      throw transactionError("Bundle 名称不安全：$bundleName", "unsafe_bundle_path")
    }
    val record = readCandidate(scope.lynxAppId) ?: return null
    ensureCandidateScope(record, scope)
    val release = resolveRef(scope, record.release) ?: return null
    if (!isUsableRelease(release, scope)) return null
    return resolveBundleFromRelease(scope, release, bundleName, verify = true)
  }

  /** 原子解析 current 并在返回前登记 lease，避免解析与 prune 之间出现竞态。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun acquireCurrentBundleLease(scope: ReleaseScope, bundleName: String): BundleLease? {
    return withStorageLock {
      val state = readState(scope.lynxAppId)
      ensureStateScope(state, scope)
      val ref = state?.current
        ?: resolveEmbedded(scope)?.let { referenceForRelease(scope, it) }
        ?: return@withStorageLock null
      acquireBundleLease(scope, ref, bundleName)
    }
  }

  /** 原子解析 candidate 并登记 lease；不改变 pending/trial 状态。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun acquireCandidateBundleLease(scope: ReleaseScope, bundleName: String): BundleLease? {
    return withStorageLock {
      val record = readCandidate(scope.lynxAppId) ?: return@withStorageLock null
      ensureCandidateScope(record, scope)
      acquireBundleLease(scope, record.release, bundleName)
    }
  }

  @Throws(IOException::class, OtaSdkException::class)
  /**
   * 路由热路径也必须验证 SHA；否则损坏的 current 会先进入 LynxView，再依赖渲染失败回滚，
   * 用户会看到白屏或黑屏。校验只读取本地文件，不会触发网络请求。
   */
  fun currentBundle(scope: ReleaseScope, bundleName: String): File? {
    return try {
      resolveBundle(scope, bundleName, verify = true)
    } catch (error: OtaSdkException) {
      if (error.reasonCode == "bundle_checksum_failed") null else throw error
    }
  }

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
      if (state == null) return@withStorageLock null
      val previous = state.previous?.let { resolveRef(scope, it) }
      val embedded = resolveEmbedded(scope)
      val restored = when {
        previous != null && isUsableRelease(previous, scope) -> previous
        embedded != null &&
          isUsableRelease(embedded, scope) &&
          (state.current.kind != RefKind.EMBEDDED || state.current.releaseId != embedded.context.releaseId) -> embedded
        else -> return@withStorageLock null
      }
      faultInjector.check(TransactionFaultPoint.BEFORE_ROLLBACK_COMMIT)
      writeStateAtomic(
        state.copy(
          generation = state.generation + 1L,
          current = referenceForRelease(scope, restored),
          previous = null,
        ),
      )
      faultInjector.check(TransactionFaultPoint.AFTER_ROLLBACK_COMMIT)
      pruneUnreferencedReleases(scope)
      restored
    }
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun rollback(lynxAppId: String): OtaModels.InstalledRelease? {
    val state = readState(lynxAppId)
    return if (state != null) rollback(state.scope) else null
  }

  /**
   * 直接删除指定 appId 的所有已下载 Bundle。
   *
   * Store v2 的物理目录已经按 appId 隔离。state/candidate 先清除，未被活体页面
   * lease 的 Release 立即删除；被 lease 的目录在最后一个 lease 释放后删除。
   */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteDownloadedBundles(lynxAppId: String) {
    OtaModels.requireLynxAppId(lynxAppId)
    withStorageLock {
      ensureAppDirectories(lynxAppId)
      cleanupRecursively(statePath(lynxAppId))
      cleanupRecursively(candidatePath(lynxAppId))
      cleanupRecursively(stagingRoot(lynxAppId))
      pruneDownloadedDirectories(lynxAppId, emptySet())
      bundleValidationCache.clear()
    }
  }

  /** 直接删除所有 appId 的已下载 Bundle，保留 embedded 描述和 APK assets。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteAllDownloadedBundles() {
    withStorageLock {
      ensureDirectories()
      appsRoot().listFiles()?.filter(File::isDirectory)?.forEach { appDirectory ->
        val appId = appDirectory.name
        if (!APP_ID_PATTERN.matches(appId)) return@forEach
        cleanupRecursively(statePath(appId))
        cleanupRecursively(candidatePath(appId))
        cleanupRecursively(stagingRoot(appId))
        pruneDownloadedDirectories(appId, emptySet())
      }
      bundleValidationCache.clear()
    }
  }

  /** 旧诊断入口的兼容别名；语义仍然是直接删除全部下载内容。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun clearDownloadedBundles() = deleteAllDownloadedBundles()

  /**
   * 冷启动维护：按各 App 的 state/candidate/当前进程 lease 回收 orphan 和残留 staging。
   * 状态文件损坏时跳过该 App，宁可保留文件也不猜测删除。
   */
  @Throws(IOException::class, OtaSdkException::class)
  fun pruneAllUnreferencedReleases() {
    withStorageLock {
      if (!appsRoot().isDirectory) return@withStorageLock
      appsRoot().listFiles().orEmpty()
        .filter { it.isDirectory && APP_ID_PATTERN.matches(it.name) }
        .forEach { app ->
          val appId = app.name
          val state = try {
            readState(appId)
          } catch (_: Exception) {
            return@forEach
          }
          val candidate = try {
            readCandidate(appId)
          } catch (_: Exception) {
            return@forEach
          }
          val retained = linkedSetOf<String>()
          state?.current?.takeIf { it.kind == RefKind.DOWNLOADED }?.let { retained += it.releaseId }
          state?.previous?.takeIf { it.kind == RefKind.DOWNLOADED }?.let { retained += it.releaseId }
          candidate?.release?.takeIf { it.kind == RefKind.DOWNLOADED }?.let { retained += it.releaseId }
          recoverStaging(appId)
          pruneDownloadedDirectories(appId, retained)
        }
    }
  }

  /** 与写事务共用进程锁的只读磁盘快照；不创建目录、不清理 orphan、不计算 Bundle SHA。 */
  internal fun storageSnapshot(maxFilesPerTree: Int): OtaStorageSnapshot {
    return withStorageLock {
      val root = canonicalOrAbsolute(storageRoot)
      val rootScan = scanTree(root, maxFilesPerTree)
      val apps = if (!appsRoot().isDirectory) {
        emptyList()
      } else {
        appsRoot().listFiles().orEmpty()
          .filter { it.isDirectory && APP_ID_PATTERN.matches(it.name) }
          .sortedBy(File::getName)
          .map { snapshotApp(it.name, maxFilesPerTree) }
      }
      OtaStorageSnapshot(
        rootPath = root.path,
        totalBytes = rootScan.totalBytes,
        fileCount = rootScan.fileCount,
        generatedAt = clock.now(),
        apps = apps,
      )
    }
  }

  private fun snapshotApp(lynxAppId: String, maxFilesPerTree: Int): OtaStorageAppSnapshot {
    val state = runCatching { readState(lynxAppId) }.getOrNull()
    val candidate = runCatching { readCandidate(lynxAppId) }.getOrNull()
    val leased = activeLeasedReleaseIds(lynxAppId)
    val releaseSnapshots = releasesRoot(lynxAppId).listFiles().orEmpty()
      .filter(File::isDirectory)
      .sortedBy(File::getName)
      .map { releaseDirectory ->
        val releaseId = releaseDirectory.name
        val roles = linkedSetOf<OtaStorageReleaseRole>()
        if (state?.current?.kind == RefKind.DOWNLOADED && state.current.releaseId == releaseId) {
          roles += OtaStorageReleaseRole.CURRENT
        }
        if (state?.previous?.kind == RefKind.DOWNLOADED && state.previous.releaseId == releaseId) {
          roles += OtaStorageReleaseRole.PREVIOUS
        }
        if (candidate?.release?.kind == RefKind.DOWNLOADED && candidate.release.releaseId == releaseId) {
          roles += OtaStorageReleaseRole.CANDIDATE
        }
        if (releaseId in leased) roles += OtaStorageReleaseRole.LEASED
        if (roles.isEmpty()) roles += OtaStorageReleaseRole.ORPHAN
        val scan = scanTree(releaseDirectory, maxFilesPerTree)
        OtaStorageReleaseSnapshot(
          releaseId = releaseId,
          roles = roles,
          totalBytes = scan.totalBytes,
          fileCount = scan.fileCount,
          manifestValid = isManifestStructurallyValid(lynxAppId, releaseId, releaseDirectory),
          files = scan.files,
          truncated = scan.truncated,
        )
      }
    val stagingSnapshots = stagingRoot(lynxAppId).listFiles().orEmpty()
      .filter(File::isDirectory)
      .sortedBy(File::getName)
      .map { transactionDirectory ->
        val scan = scanTree(transactionDirectory, maxFilesPerTree)
        OtaStorageStagingSnapshot(
          transactionName = transactionDirectory.name,
          totalBytes = scan.totalBytes,
          fileCount = scan.fileCount,
          files = scan.files,
          truncated = scan.truncated,
        )
      }
    val appScan = scanTree(appDirectory(lynxAppId), maxFilesPerTree)
    return OtaStorageAppSnapshot(
      appId = lynxAppId,
      state = state?.let {
        OtaStorageStateSnapshot(
          generation = it.generation,
          currentReleaseId = it.current.releaseId,
          currentKind = it.current.kind.wireValue,
          previousReleaseId = it.previous?.releaseId,
          previousKind = it.previous?.kind?.wireValue,
        )
      },
      candidate = candidate?.let {
        OtaStorageCandidateSnapshot(
          releaseId = it.release.releaseId,
          status = it.status.wireValue,
          failureCount = it.failureCount,
        )
      },
      releases = releaseSnapshots,
      staging = stagingSnapshots,
      totalBytes = appScan.totalBytes,
      fileCount = appScan.fileCount,
    )
  }

  private fun isManifestStructurallyValid(
    lynxAppId: String,
    releaseId: String,
    releaseDirectory: File,
  ): Boolean {
    val manifestPath = File(releaseDirectory, LOCAL_MANIFEST_NAME)
    if (!manifestPath.isFile) return false
    return runCatching {
      val map = OtaJson.asObject(OtaJson.parse(manifestPath.readText(Charsets.UTF_8)), manifestPath.toString())
      val manifest = OtaModels.ReleaseManifest.fromJsonMap(map)
      manifest.lynxAppId == lynxAppId && manifest.releaseId == releaseId
    }.getOrDefault(false)
  }

  private fun scanTree(root: File, maxFiles: Int): TreeScan {
    if (!root.exists()) return TreeScan(0L, 0, emptyList(), false)
    var totalBytes = 0L
    var fileCount = 0
    var truncated = false
    val snapshots = ArrayList<OtaStorageFileSnapshot>(minOf(maxFiles, 64))
    fun visit(directory: File, depth: Int) {
      if (depth > DIAGNOSTIC_MAX_DEPTH) {
        truncated = true
        return
      }
      directory.listFiles().orEmpty().sortedBy(File::getName).forEach { child ->
        when {
          child.isDirectory && !isSymlink(child) -> visit(child, depth + 1)
          child.isFile -> {
            val byteCount = child.length()
            totalBytes += byteCount
            fileCount += 1
            if (snapshots.size < maxFiles) {
              snapshots += OtaStorageFileSnapshot(
                relativePath = relativePath(root, child),
                byteCount = byteCount,
                modifiedAt = Instant.ofEpochMilli(child.lastModified()),
              )
            } else {
              truncated = true
            }
          }
        }
      }
    }
    visit(root, 0)
    return TreeScan(
      totalBytes = totalBytes,
      fileCount = fileCount,
      files = snapshots,
      truncated = truncated,
    )
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun rollbackOutcome(scope: ReleaseScope): RollbackOutcome {
    val before = current(scope)?.context?.releaseId
    val restored = rollback(scope)
    return RollbackOutcome(restored, before, restored?.context?.releaseId)
  }

  /** 新 runtime 的精确 Bundle 解析；bundleName 优先按完整 bundlePath 匹配。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun resolveBundle(scope: ReleaseScope, bundleName: String, verify: Boolean = true): File? {
    if (bundleName.isBlank() || bundleName.indexOf('\u0000') >= 0 || bundleName.contains('\\')) {
      throw transactionError("Bundle 名称不安全：$bundleName", "unsafe_bundle_path")
    }
    val release = current(scope) ?: return null
    return resolveBundleFromRelease(scope, release, bundleName, verify)
  }

  private fun resolveBundleFromRelease(
    scope: ReleaseScope,
    release: OtaModels.InstalledRelease,
    bundleName: String,
    verify: Boolean,
  ): File? {
    val bundle = findBundle(release, bundleName) ?: return null
    val localPath = localPathFor(scope, release, bundle)
    if (!localPath.isFile) return null
    if (verify) {
      val cacheKey = BundleValidationCache.Key(
        scope = validationScopeKey(scope),
        releaseId = release.context.releaseId,
        bundlePath = bundle.bundlePath,
        expectedSha256 = bundle.bundleSha256,
        fileSize = localPath.length(),
        lastModifiedMillis = localPath.lastModified(),
      )
      if (!bundleValidationCache.contains(cacheKey)) {
        if (!OtaIO.sha256(localPath).equals(bundle.bundleSha256, ignoreCase = true)) {
          bundleValidationCache.remove(cacheKey)
          throw transactionError("Bundle 校验失败：$bundleName", "bundle_checksum_failed")
        }
        bundleValidationCache.put(cacheKey)
      }
    }
    return localPath
  }

  private fun findBundle(
    release: OtaModels.InstalledRelease,
    bundleName: String,
  ): OtaModels.InstalledBundle? {
    val exact = release.bundles.filter { it.bundlePath == bundleName }
    return when {
      exact.size == 1 -> exact[0]
      exact.size > 1 -> throw transactionError("Bundle 路径重复：$bundleName", "duplicate_bundle_path")
      else -> {
        val matches = release.bundles.filter { it.bundlePath.substringAfterLast('/') == bundleName }
        if (matches.size == 1) matches[0] else null
      }
    }
  }

  private fun acquireBundleLease(
    scope: ReleaseScope,
    ref: ReleaseRef,
    bundleName: String,
  ): BundleLease? {
    val release = resolveRef(scope, ref) ?: return null
    val bundle = findBundle(release, bundleName) ?: return null
    val file = resolveBundleFromRelease(scope, release, bundleName, verify = true) ?: return null
    if (ref.kind == RefKind.DOWNLOADED) incrementLease(scope.lynxAppId, ref.releaseId)
    return BundleLease(release, bundle, file) {
      if (ref.kind == RefKind.DOWNLOADED) releaseLease(scope, ref.releaseId)
    }
  }

  private fun incrementLease(lynxAppId: String, releaseId: String) {
    val key = leaseKey(lynxAppId, releaseId)
    LEASE_COUNTS[key] = (LEASE_COUNTS[key] ?: 0) + 1
  }

  private fun releaseLease(scope: ReleaseScope, releaseId: String) {
    withStorageLock {
      val key = leaseKey(scope.lynxAppId, releaseId)
      val remaining = (LEASE_COUNTS[key] ?: 0) - 1
      if (remaining > 0) LEASE_COUNTS[key] = remaining else LEASE_COUNTS.remove(key)
      pruneUnreferencedReleases(scope)
    }
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
    when (manifest.status) {
      OtaModels.ReleaseStatus.ACTIVE -> Unit
      OtaModels.ReleaseStatus.DISABLED ->
        throw transactionError("Release 已禁用：${manifest.releaseId}", OtaModels.ReasonCodes.RELEASE_DISABLED)
      OtaModels.ReleaseStatus.ROLLED_BACK ->
        throw transactionError("Release 已回滚：${manifest.releaseId}", OtaModels.ReasonCodes.RELEASE_ROLLED_BACK)
      else ->
        throw transactionError("Release 状态不可激活：${manifest.status.wireValue}", OtaModels.ReasonCodes.INVALID_RELEASE_STATUS)
    }
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
      val size = artifact.size
        ?: throw transactionError("Bundle size 不能为空：${artifact.bundlePath}", OtaModels.ReasonCodes.MISSING_BUNDLE_SIZE)
      if (size <= 0) {
        throw transactionError("Bundle size 必须大于 0：${artifact.bundlePath}", OtaModels.ReasonCodes.INVALID_BUNDLE_SIZE)
      }
      if (size > OtaModels.MAX_BUNDLE_BYTES) {
        throw transactionError("Bundle 超过 ${OtaModels.MAX_BUNDLE_BYTES} 字节：${artifact.bundlePath}", OtaModels.ReasonCodes.BUNDLE_TOO_LARGE)
      }
      val bundleUri = artifact.bundleUrl
      if (!bundleUri.scheme.equals("https", ignoreCase = true) || bundleUri.host.isNullOrBlank() ||
        bundleUri.userInfo != null || bundleUri.fragment != null
      ) {
        throw transactionError("Bundle URL 必须使用 HTTPS：${artifact.bundlePath}", OtaModels.ReasonCodes.INVALID_BUNDLE_URL)
      }
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
          val copied = OtaIO.copyAndHash(
            reusableSource,
            plan.partPath,
            plan.artifact.size?.toLong(),
            OtaModels.MAX_BUNDLE_BYTES.toLong(),
          )
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
          val downloaded = OtaIO.downloadAndHash(
            plan.artifact.bundleUrl,
            plan.partPath,
            plan.artifact.size?.toLong(),
            OtaModels.MAX_BUNDLE_BYTES.toLong(),
          )
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
      // 已有 manifest 但身份不一致时拒绝覆盖；身份一致但文件损坏时允许同版本修复。
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
      // 没有 manifest 的目录属于未完成/损坏发布，直接清理后重新发布。
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

  private fun readPublishedRelease(scope: ReleaseScope, releaseId: String): OtaModels.InstalledRelease? {
    val releaseDirectory = releaseDirectory(scope.lynxAppId, releaseId)
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
        // 元数据解析只检查文件存在与声明 size。页面热路径随后仅校验实际要打开的
        // Bundle，并使用进程内 fingerprint 缓存；全量 SHA 校验保留在安装、同步和回滚门禁。
        if (!path.isFile) return null
        artifact.size?.let { if (path.length() != it.toLong()) return null }
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
    val embedded = EmbeddedReleaseStore(storageRoot).embeddedRelease(scope.lynxAppId) ?: return null
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
    return resolveEmbedded(scope)
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
      resolveInside(releaseDirectory(scope.lynxAppId, release.context.releaseId), validateBundlePath(bundle.bundlePath))
    } else {
      File(bundle.localFilePath)
    }
  }

  private fun matchesScope(scope: ReleaseScope, release: OtaModels.InstalledRelease): Boolean {
    return release.context.env == scope.env && release.context.hostApp == scope.hostApp &&
      release.context.lynxAppId == scope.lynxAppId && release.context.platform == scope.platform
  }

  private fun validationScopeKey(scope: ReleaseScope): String = listOf(
    scope.env.wireValue,
    scope.hostApp.wireValue,
    scope.platform.wireValue,
    scope.lynxAppId,
  ).joinToString("|")

  private fun referenceForRelease(scope: ReleaseScope, release: OtaModels.InstalledRelease): ReleaseRef {
    val embedded = resolveEmbedded(scope)
    return if (embedded?.context?.releaseId == release.context.releaseId) {
      ReleaseRef(RefKind.EMBEDDED, release.context.releaseId)
    } else {
      ReleaseRef(RefKind.DOWNLOADED, release.context.releaseId)
    }
  }

  private fun candidateSnapshot(
    record: CandidateRecord,
    release: OtaModels.InstalledRelease,
  ): OtaModels.CandidateSnapshot = OtaModels.CandidateSnapshot(
    release = release,
    status = record.status,
    failureCount = record.failureCount,
    createdAt = record.createdAt,
    trialStartedAt = record.trialStartedAt,
  )

  private fun candidatePath(lynxAppId: String): File {
    return File(appDirectory(lynxAppId), "candidate.json")
  }

  private fun readCandidate(lynxAppId: String): CandidateRecord? {
    val path = candidatePath(lynxAppId)
    if (!path.isFile) return null
    return try {
      val map = OtaJson.asObject(OtaJson.parse(path.readText(Charsets.UTF_8)), path.toString())
      if ((map["schemaVersion"] as? Number)?.toInt() != STORE_SCHEMA_VERSION) {
        throw transactionError("candidate schemaVersion 不支持", "storage_recovery_failed")
      }
      val scopeMap = OtaJson.asObject(map["scope"], "candidate.scope")
      CandidateRecord(
        scope = ReleaseScope(
          OtaModels.Environment.fromWire(OtaModels.stringValue(scopeMap["env"])),
          OtaModels.HostApp.fromWire(OtaModels.stringValue(scopeMap["hostApp"])),
          OtaModels.stringValue(scopeMap["lynxAppId"]),
          OtaModels.Platform.fromWire(OtaModels.stringValue(scopeMap["platform"])),
        ),
        release = parseRef(OtaJson.asObject(map["release"], "candidate.release")),
        status = OtaModels.CandidateStatus.fromWire(OtaModels.stringValue(map["status"])),
        failureCount = (map["failureCount"] as? Number)?.toInt() ?: 0,
        createdAt = Instant.parse(OtaModels.stringValue(map["createdAt"])),
        trialStartedAt = (map["trialStartedAt"] as? String)?.let(Instant::parse),
      )
    } catch (error: OtaSdkException) {
      throw error
    } catch (error: RuntimeException) {
      throw OtaSdkException("candidate 状态解析失败：$path", error, "storage_recovery_failed")
    }
  }

  private fun writeCandidateAtomic(record: CandidateRecord) {
    val map = linkedMapOf<String, Any?>(
      "schemaVersion" to STORE_SCHEMA_VERSION,
      "scope" to mapOf(
        "env" to record.scope.env.wireValue,
        "hostApp" to record.scope.hostApp.wireValue,
        "lynxAppId" to record.scope.lynxAppId,
        "platform" to record.scope.platform.wireValue,
      ),
      "release" to record.release.toJsonMap(),
      "status" to record.status.wireValue,
      "failureCount" to record.failureCount,
      "createdAt" to record.createdAt.toString(),
      "trialStartedAt" to record.trialStartedAt?.toString(),
    )
    writeAtomic(candidatePath(record.scope.lynxAppId), OtaJson.stringify(map))
  }

  private fun removeCandidateAtomic(lynxAppId: String) {
    cleanupRecursively(candidatePath(lynxAppId))
  }

  private fun ensureCandidateScope(record: CandidateRecord, expected: ReleaseScope) {
    if (record.scope != expected) {
      throw transactionError("candidate scope 与当前配置不一致", "scope_mismatch")
    }
  }

  private fun readState(lynxAppId: String): StateRecord? {
    val path = statePath(lynxAppId)
    if (!path.isFile) return null
    return try {
      val map = OtaJson.asObject(OtaJson.parse(path.readText(Charsets.UTF_8)), path.toString())
      if ((map["schemaVersion"] as? Number)?.toInt() != STORE_SCHEMA_VERSION) {
        throw transactionError("Active State schemaVersion 不支持", "storage_recovery_failed")
      }
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
    map["schemaVersion"] = STORE_SCHEMA_VERSION
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
      block()
    }
  }

  /** state/candidate/活体 lease 是唯一保留来源；其它远程 Release 都是可回收 orphan。 */
  private fun pruneUnreferencedReleases(scope: ReleaseScope) {
    val state = readState(scope.lynxAppId)
    ensureStateScope(state, scope)
    val candidate = readCandidate(scope.lynxAppId)
    if (candidate != null) ensureCandidateScope(candidate, scope)
    val retained = linkedSetOf<String>()
    state?.current?.takeIf { it.kind == RefKind.DOWNLOADED }?.let { retained += it.releaseId }
    state?.previous?.takeIf { it.kind == RefKind.DOWNLOADED }?.let { retained += it.releaseId }
    candidate?.release?.takeIf { it.kind == RefKind.DOWNLOADED }?.let { retained += it.releaseId }
    pruneDownloadedDirectories(scope.lynxAppId, retained)
  }

  private fun pruneDownloadedDirectories(lynxAppId: String, retainedReleaseIds: Set<String>) {
    val retained = retainedReleaseIds + activeLeasedReleaseIds(lynxAppId)
    var deleted = false
    releasesRoot(lynxAppId).listFiles()?.forEach { release ->
      if (release.name !in retained) {
        cleanupRecursively(release)
        deleted = true
      }
    }
    if (deleted) bundleValidationCache.clear()
  }

  private fun activeLeasedReleaseIds(lynxAppId: String): Set<String> {
    val rootPath = canonicalOrAbsolute(storageRoot).path
    return LEASE_COUNTS.entries.asSequence()
      .filter { (key, count) -> key.rootPath == rootPath && key.lynxAppId == lynxAppId && count > 0 }
      .map { it.key.releaseId }
      .toSet()
  }

  private fun leaseKey(lynxAppId: String, releaseId: String): LeaseKey {
    return LeaseKey(canonicalOrAbsolute(storageRoot).path, lynxAppId, releaseId)
  }

  private fun ensureDirectories() {
    val root = canonicalOrAbsolute(storageRoot)
    ensureNoSymlink(root)
    ensureDirectory(root)
    val apps = File(root, "apps")
    ensureNoSymlink(apps)
    ensureDirectory(apps)
  }

  private fun ensureAppDirectories(lynxAppId: String) {
    ensureDirectories()
    val app = appDirectory(lynxAppId)
    ensureNoSymlink(app)
    ensureDirectory(app)
    for (child in listOf(releasesRoot(lynxAppId), stagingRoot(lynxAppId))) {
      ensureNoSymlink(child)
      ensureDirectory(child)
    }
  }

  private fun recoverStaging(lynxAppId: String) {
    val staging = stagingRoot(lynxAppId)
    if (!staging.isDirectory) return
    staging.listFiles()?.forEach { cleanupRecursively(it) }
  }

  private fun stagingDirectory(lynxAppId: String, releaseId: String, transactionId: String): File {
    validateReleaseId(releaseId)
    return File(stagingRoot(lynxAppId), "$releaseId.$transactionId")
  }

  private fun releaseDirectory(lynxAppId: String, releaseId: String): File {
    validateReleaseId(releaseId)
    return File(releasesRoot(lynxAppId), releaseId)
  }

  private fun statePath(lynxAppId: String): File {
    return File(appDirectory(lynxAppId), "state.json")
  }

  private fun appsRoot(): File = File(canonicalOrAbsolute(storageRoot), "apps")

  private fun appDirectory(lynxAppId: String): File = File(appsRoot(), OtaModels.requireLynxAppId(lynxAppId))

  private fun releasesRoot(lynxAppId: String): File = File(appDirectory(lynxAppId), "releases")

  private fun stagingRoot(lynxAppId: String): File = File(appDirectory(lynxAppId), ".staging")

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

  private data class CandidateRecord(
    val scope: ReleaseScope,
    val release: ReleaseRef,
    val status: OtaModels.CandidateStatus,
    val failureCount: Int,
    val createdAt: Instant,
    val trialStartedAt: Instant?,
  )

  private data class TreeScan(
    val totalBytes: Long,
    val fileCount: Int,
    val files: List<OtaStorageFileSnapshot>,
    val truncated: Boolean,
  )

  private data class ReleaseRef(val kind: RefKind, val releaseId: String) {
    fun toJsonMap(): Map<String, Any?> = mapOf("kind" to kind.wireValue, "releaseId" to releaseId)
  }

  private data class LeaseKey(
    val rootPath: String,
    val lynxAppId: String,
    val releaseId: String,
  )

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
    private const val STORE_SCHEMA_VERSION = 2
    private const val DIAGNOSTIC_MAX_DEPTH = 32
    private const val LOCAL_MANIFEST_NAME = "release-manifest.json"
    private const val METADATA_ALLOWANCE_BYTES = 1024L * 1024L
    private const val SAFETY_RESERVE_BYTES = 32L * 1024L * 1024L
    private val SHA_PATTERN = Regex("sha256:[0-9a-fA-F]{64}")
    private val APP_ID_PATTERN = Regex("^[0-9]{8}$")
    private val PROCESS_LOCKS = ConcurrentHashMap<String, ReentrantLock>()
    private val LEASE_COUNTS = ConcurrentHashMap<LeaseKey, Int>()
  }
}
