package com.ota.android.sdk

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.URI
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Store v3 的故障注入点；只用于 JVM/集成测试，不改变生产调用契约。 */
enum class ContentAddressedFaultPoint {
  BEFORE_OBJECT_PUBLISH,
  BEFORE_MANIFEST_COMMIT,
  BEFORE_STATE_COMMIT,
  AFTER_STATE_COMMIT,
  BEFORE_ROLLBACK_COMMIT,
  AFTER_ROLLBACK_COMMIT,
}

fun interface ContentAddressedFaultInjecting {
  fun check(point: ContentAddressedFaultPoint)

  companion object {
    @JvmField
    val NONE: ContentAddressedFaultInjecting = ContentAddressedFaultInjecting { }
  }
}

/** 一次 v3 安装的可观察增量结果。 */
data class ContentAddressedOperationMetrics(
  @JvmField val operation: String,
  @JvmField val releaseId: String?,
  @JvmField val downloadedBundleCount: Int,
  @JvmField val downloadedBytes: Long,
  @JvmField val reusedBundleCount: Int,
  @JvmField val reusedBytes: Long,
  @JvmField val objectWriteCount: Int,
  @JvmField val objectWriteBytes: Long,
  @JvmField val manifestWriteCount: Int,
  @JvmField val result: String,
)

/**
 * Android Store v3：完整 Manifest 快照 + App ID 隔离 SHA-256 CAS 对象库。
 *
 * 物理结构：
 *
 * ```text
 * files/lynx-ota-store/apps/<lynxAppId>/
 *   state.json                         # current/previous/candidate 原子指针
 *   embedded.json                      # 仅内置 Release 元数据，不复制 APK asset bytes
 *   manifests/<manifestId>.json        # 完整 Manifest 快照
 *   objects/<sha 前两位>/<sha>.lynx.bundle
 *   transactions/<tx>/                 # 临时下载和事务日志
 * ```
 *
 * 新 Release 只写入 Manifest 中缺失的对象；未变化 Bundle 只复用同一 CAS 文件，不复制。
 * current/previous/candidate 和活体 lease 是 GC 根，state 最后原子提交。
 */
class ContentAddressedOtaStore @JvmOverloads constructor(
  private val storageRoot: File,
  private val capacityProbe: ReleaseTransaction.CapacityProbe = ReleaseTransaction.CapacityProbe.FILE_STORE,
  private val clock: ReleaseTransaction.Clock = ReleaseTransaction.Clock.SYSTEM,
  private val faultInjector: ContentAddressedFaultInjecting = ContentAddressedFaultInjecting.NONE,
  private val allowLocalHTTPForTest: Boolean = false,
  private val environment: OtaModels.Environment = OtaModels.Environment.TEST,
) : OtaReleaseStore {
  private val validationCache = ConcurrentHashMap<ValidationKey, Unit>()
  @Volatile
  private var latestMetrics = ContentAddressedOperationMetrics(
    operation = "none",
    releaseId = null,
    downloadedBundleCount = 0,
    downloadedBytes = 0,
    reusedBundleCount = 0,
    reusedBytes = 0,
    objectWriteCount = 0,
    objectWriteBytes = 0,
    manifestWriteCount = 0,
    result = "none",
  )

  override fun registerEmbeddedRelease(release: OtaModels.InstalledRelease) {
    val scope = ReleaseTransaction.ReleaseScope.fromRelease(release)
    withStorageLock {
      ensureAppDirectories(scope.lynxAppId)
      // 这里只落 descriptor；真正的 bytes 始终从 APK AssetManager 读取。
      EmbeddedReleaseStore(storageRoot).saveEmbeddedRelease(release)
      val state = readState(scope.lynxAppId)
      if (state == null) {
        writeStateAtomic(
          StateRecord(
            scope = scope,
            generation = 1L,
            current = Ref(RefKind.EMBEDDED, release.context.releaseId, null),
            previous = null,
            candidate = null,
          ),
        )
      } else {
        ensureStateScope(state, scope)
      }
      pruneApp(scope.lynxAppId)
    }
  }

  override fun install(request: ReleaseTransaction.InstallRequest): ReleaseTransaction.InstallOutcome {
    validateManifest(request.scope, request.targetManifest)
    request.embeddedDescriptor?.let {
      requireScope(ReleaseTransaction.ReleaseScope.fromRelease(it), request.scope, "embedded 描述")
    }

    return withStorageLock {
      ensureAppDirectories(request.scope.lynxAppId)
      recoverTransactions(request.scope.lynxAppId)
      request.embeddedDescriptor?.let { EmbeddedReleaseStore(storageRoot).saveEmbeddedRelease(it) }
      val oldState = readState(request.scope.lynxAppId)
      ensureStateScope(oldState, request.scope)
      val oldCurrent = oldState?.let { resolveRef(request.scope, it.current) }
        ?: resolveEmbedded(request.scope)
      val currentManifestId = oldState?.current?.manifestId
      val targetManifestId = manifestId(request.targetManifest)

      if (oldCurrent?.context?.releaseId == request.targetManifest.releaseId &&
        oldState?.current?.kind == RefKind.DOWNLOADED &&
        currentManifestId == targetManifestId &&
        manifestObjectsUsable(request.scope.lynxAppId, request.targetManifest)
      ) {
        setMetrics(
          ContentAddressedOperationMetrics(
            "install", request.targetManifest.releaseId, 0, 0, request.targetManifest.bundles.size,
            request.targetManifest.bundles.sumOf { it.size?.toLong() ?: 0L }, 0, 0, 0, "already_active",
          ),
        )
        return@withStorageLock ReleaseTransaction.InstallOutcome(
          type = ReleaseTransaction.InstallResultType.ALREADY_ACTIVE,
          current = oldCurrent,
          installed = oldCurrent,
          fromReleaseId = oldCurrent.context.releaseId,
          toReleaseId = oldCurrent.context.releaseId,
          reusedBundleCount = request.targetManifest.bundles.size,
          reusedBytes = request.targetManifest.bundles.sumOf { it.size?.toLong() ?: 0L },
        )
      }

      // GC 在预检前运行，预检只按“缺少的 CAS 对象”计算增量空间。
      pruneApp(request.scope.lynxAppId)
      val missingBytes = request.targetManifest.bundles
        .filterNot { hasUsableObject(request.scope.lynxAppId, it.bundleSha256, it.size) }
        .sumOf { it.size?.toLong() ?: 0L }
      val requiredBytes = missingBytes + METADATA_ALLOWANCE_BYTES + maxOf(SAFETY_RESERVE_BYTES, (missingBytes + 9L) / 10L)
      val availableBytes = capacityProbe.usableSpace(storageRoot)
      if (availableBytes >= 0L && availableBytes < requiredBytes) {
        throw OtaSdkException(
          "OTA v3 预检空间不足：需要 $requiredBytes bytes，可用 $availableBytes bytes",
          null,
          "insufficient_storage",
        )
      }

      val transactionID = UUID.randomUUID().toString()
      val transactionDirectory = transactionDirectory(request.scope.lynxAppId, transactionID)
      ensureDirectory(transactionDirectory)
      val plannedObjects = request.targetManifest.bundles.map { it.bundleSha256 }.distinct()
      writeAtomic(
        File(transactionDirectory, TRANSACTION_META_NAME),
        OtaJson.stringify(
          mapOf(
            "schemaVersion" to STORE_SCHEMA_VERSION,
            "lynxAppId" to request.scope.lynxAppId,
            "releaseId" to request.targetManifest.releaseId,
            "objectIds" to plannedObjects,
          ),
        ),
      )

      var downloadedCount = 0
      var downloadedBytes = 0L
      var reusedCount = 0
      var reusedBytes = 0L
      var objectWriteCount = 0
      var objectWriteBytes = 0L
      var manifestWriteCount = 0
      try {
        request.targetManifest.bundles.forEachIndexed { index, artifact ->
          if (hasUsableObject(request.scope.lynxAppId, artifact.bundleSha256, artifact.size)) {
            reusedCount += 1
            reusedBytes += artifact.size?.toLong() ?: 0L
            return@forEachIndexed
          }

          val part = File(transactionDirectory, "object-$index.part")
          val streamResult = OtaIO.downloadAndHash(
            artifact.bundleUrl,
            part,
            artifact.size?.toLong(),
            OtaModels.MAX_BUNDLE_BYTES.toLong(),
            allowLocalHTTPForTest = allowLocalHTTPForTest,
            environment = environment,
          )
          validateStreamResult(artifact, streamResult)
          val objectPath = objectPath(request.scope.lynxAppId, artifact.bundleSha256)
          if (hasUsableObject(request.scope.lynxAppId, artifact.bundleSha256, artifact.size)) {
            cleanup(part)
            reusedCount += 1
            reusedBytes += artifact.size?.toLong() ?: 0L
          } else {
            faultInjector.check(ContentAddressedFaultPoint.BEFORE_OBJECT_PUBLISH)
            ensureDirectory(objectPath.parentFile ?: storageRoot)
            atomicMove(part, objectPath)
            objectWriteCount += 1
            objectWriteBytes += streamResult.bytes
            downloadedCount += 1
            downloadedBytes += streamResult.bytes
          }
        }

        faultInjector.check(ContentAddressedFaultPoint.BEFORE_MANIFEST_COMMIT)
        writeManifestAtomic(request.scope, request.targetManifest, targetManifestId)
        manifestWriteCount += 1
        val installed = readManifestRelease(request.scope, request.targetManifest, targetManifestId)
          ?: throw OtaSdkException("OTA v3 Manifest 发布后不可读", null, "manifest_publish_failed")

        val oldCurrentRef = oldState?.current
          ?: resolveEmbedded(request.scope)?.let { Ref(RefKind.EMBEDDED, it.context.releaseId, null) }
        val previous = oldCurrentRef?.takeUnless {
          it.kind == RefKind.DOWNLOADED && it.manifestId == targetManifestId
        }
        val nextState = if (request.stageAsCandidate) {
          StateRecord(
            request.scope,
            (oldState?.generation ?: 0L) + 1L,
            oldState?.current ?: Ref(RefKind.EMBEDDED, resolveEmbedded(request.scope)?.context?.releaseId ?: "embedded", null),
            oldState?.previous,
            CandidateRecord(
              Ref(RefKind.DOWNLOADED, request.targetManifest.releaseId, targetManifestId),
              OtaModels.CandidateStatus.PENDING,
              0,
              clock.now(),
              null,
            ),
          )
        } else {
          StateRecord(
            request.scope,
            (oldState?.generation ?: 0L) + 1L,
            Ref(RefKind.DOWNLOADED, request.targetManifest.releaseId, targetManifestId),
            previous,
            null,
          )
        }
        faultInjector.check(ContentAddressedFaultPoint.BEFORE_STATE_COMMIT)
        writeStateAtomic(nextState)
        faultInjector.check(ContentAddressedFaultPoint.AFTER_STATE_COMMIT)
        pruneApp(request.scope.lynxAppId)
        cleanup(transactionDirectory)

        val outcomeType = if (request.stageAsCandidate) {
          ReleaseTransaction.InstallResultType.CANDIDATE
        } else {
          ReleaseTransaction.InstallResultType.UPDATED
        }
        setMetrics(
          ContentAddressedOperationMetrics(
            "install", request.targetManifest.releaseId, downloadedCount, downloadedBytes,
            reusedCount, reusedBytes, objectWriteCount, objectWriteBytes, manifestWriteCount,
            outcomeType.name.lowercase(),
          ),
        )
        return@withStorageLock ReleaseTransaction.InstallOutcome(
          type = outcomeType,
          current = oldCurrent,
          installed = installed,
          fromReleaseId = oldCurrent?.context?.releaseId,
          toReleaseId = installed.context.releaseId,
          downloadedBundleCount = downloadedCount,
          downloadedBytes = downloadedBytes,
          reusedBundleCount = reusedCount,
          reusedBytes = reusedBytes,
          writtenBytes = objectWriteBytes,
        )
      } catch (error: Throwable) {
        cleanup(transactionDirectory)
        setMetrics(
          ContentAddressedOperationMetrics(
            "install", request.targetManifest.releaseId, downloadedCount, downloadedBytes,
            reusedCount, reusedBytes, objectWriteCount, objectWriteBytes, manifestWriteCount,
            "failed",
          ),
        )
        when (error) {
          is IOException, is InterruptedException, is OtaSdkException -> throw error
          else -> throw IOException("OTA v3 Release 事务失败", error)
        }
      }
    }
  }

  override fun current(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease? {
    val state = readState(scope.lynxAppId) ?: return resolveEmbedded(scope)
    ensureStateScope(state, scope)
    return resolveRef(scope, state.current)
  }

  override fun current(lynxAppId: String): OtaModels.InstalledRelease? {
    val appId = OtaModels.requireLynxAppId(lynxAppId)
    val state = readState(appId)
    return if (state == null) {
      EmbeddedReleaseStore(storageRoot).embeddedRelease(appId)
    } else {
      resolveRef(state.scope, state.current)
    }
  }

  override fun candidate(scope: ReleaseTransaction.ReleaseScope): OtaModels.CandidateSnapshot? {
    val state = readState(scope.lynxAppId) ?: return null
    ensureStateScope(state, scope)
    val candidate = state.candidate ?: return null
    val release = resolveRef(scope, candidate.release) ?: return null
    return OtaModels.CandidateSnapshot(
      release,
      candidate.status,
      candidate.failureCount,
      candidate.createdAt,
      candidate.trialStartedAt,
    )
  }

  override fun beginCandidateTrial(scope: ReleaseTransaction.ReleaseScope): OtaModels.CandidateSnapshot {
    return withStorageLock {
      val state = readState(scope.lynxAppId) ?: throw transactionError("当前没有 candidate", "candidate_missing")
      ensureStateScope(state, scope)
      val candidate = state.candidate ?: throw transactionError("当前没有 candidate", "candidate_missing")
      val release = resolveRef(scope, candidate.release)
        ?: throw transactionError("candidate Release 不存在", "candidate_missing")
      if (candidate.status == OtaModels.CandidateStatus.TRIAL) {
        return@withStorageLock OtaModels.CandidateSnapshot(
          release, candidate.status, candidate.failureCount, candidate.createdAt, candidate.trialStartedAt,
        )
      }
      val nextCandidate = candidate.copy(
        status = OtaModels.CandidateStatus.TRIAL,
        trialStartedAt = clock.now(),
      )
      writeStateAtomic(state.copy(generation = state.generation + 1L, candidate = nextCandidate))
      OtaModels.CandidateSnapshot(
        release, nextCandidate.status, nextCandidate.failureCount, nextCandidate.createdAt, nextCandidate.trialStartedAt,
      )
    }
  }

  override fun confirmCandidate(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease {
    return withStorageLock {
      val state = readState(scope.lynxAppId) ?: throw transactionError("当前没有 candidate", "candidate_missing")
      ensureStateScope(state, scope)
      val candidate = state.candidate ?: throw transactionError("当前没有 candidate", "candidate_missing")
      if (candidate.status != OtaModels.CandidateStatus.TRIAL) {
        throw transactionError("candidate 尚未进入 trial", "candidate_not_in_trial")
      }
      val release = resolveRef(scope, candidate.release)
        ?: throw transactionError("candidate Release 不存在", "candidate_missing")
      val previous = state.current.takeUnless { it == candidate.release }
      val next = state.copy(
        generation = state.generation + 1L,
        current = candidate.release,
        previous = previous,
        candidate = null,
      )
      faultInjector.check(ContentAddressedFaultPoint.BEFORE_STATE_COMMIT)
      writeStateAtomic(next)
      faultInjector.check(ContentAddressedFaultPoint.AFTER_STATE_COMMIT)
      pruneApp(scope.lynxAppId)
      setMetrics(latestMetrics.copy(operation = "confirm_candidate", releaseId = release.context.releaseId, result = "success"))
      release
    }
  }

  override fun discardCandidate(scope: ReleaseTransaction.ReleaseScope) {
    withStorageLock {
      val state = readState(scope.lynxAppId) ?: return@withStorageLock
      ensureStateScope(state, scope)
      if (state.candidate == null) return@withStorageLock
      writeStateAtomic(state.copy(generation = state.generation + 1L, candidate = null))
      pruneApp(scope.lynxAppId)
    }
  }

  override fun recoverInterruptedCandidate(scope: ReleaseTransaction.ReleaseScope) {
    val candidate = candidate(scope) ?: return
    if (candidate.status == OtaModels.CandidateStatus.TRIAL) discardCandidate(scope)
  }

  override fun candidateBundle(scope: ReleaseTransaction.ReleaseScope, bundleName: String): File? {
    val state = readState(scope.lynxAppId) ?: return null
    ensureStateScope(state, scope)
    val candidate = state.candidate ?: return null
    return resolveBundle(scope, candidate.release, bundleName)
  }

  override fun acquireCurrentBundleLease(
    scope: ReleaseTransaction.ReleaseScope,
    bundleName: String,
  ): ReleaseTransaction.BundleLease? {
    return withStorageLock {
      val state = readState(scope.lynxAppId) ?: return@withStorageLock null
      ensureStateScope(state, scope)
      if (state.current.kind != RefKind.DOWNLOADED) return@withStorageLock null
      acquireLease(scope, state.current, bundleName)
    }
  }

  override fun acquireCandidateBundleLease(
    scope: ReleaseTransaction.ReleaseScope,
    bundleName: String,
  ): ReleaseTransaction.BundleLease? {
    return withStorageLock {
      val state = readState(scope.lynxAppId) ?: return@withStorageLock null
      ensureStateScope(state, scope)
      val candidate = state.candidate ?: return@withStorageLock null
      acquireLease(scope, candidate.release, bundleName)
    }
  }

  override fun acquireBundleLeaseForRelease(
    scope: ReleaseTransaction.ReleaseScope,
    releaseId: String,
    bundleName: String,
  ): ReleaseTransaction.BundleLease? {
    return withStorageLock {
      val state = readState(scope.lynxAppId) ?: return@withStorageLock null
      ensureStateScope(state, scope)
      val ref = listOfNotNull(state.current, state.previous, state.candidate?.release)
        .firstOrNull { it.releaseId == releaseId }
        ?: return@withStorageLock null
      acquireLease(scope, ref, bundleName)
    }
  }

  override fun currentBundle(scope: ReleaseTransaction.ReleaseScope, bundleName: String): File? {
    val state = readState(scope.lynxAppId) ?: return null
    ensureStateScope(state, scope)
    if (state.current.kind != RefKind.DOWNLOADED) return null
    return resolveBundle(scope, state.current, bundleName)
  }

  override fun currentBundle(lynxAppId: String, bundleName: String): File? {
    val state = readState(lynxAppId) ?: return null
    return currentBundle(state.scope, bundleName)
  }

  override fun rollback(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease? {
    return withStorageLock {
      val state = readState(scope.lynxAppId) ?: return@withStorageLock null
      ensureStateScope(state, scope)
      val previous = state.previous ?: return@withStorageLock null
      val restored = resolveRef(scope, previous) ?: return@withStorageLock null
      if (!isUsableRelease(scope, restored)) return@withStorageLock null
      faultInjector.check(ContentAddressedFaultPoint.BEFORE_ROLLBACK_COMMIT)
      writeStateAtomic(state.copy(generation = state.generation + 1L, current = previous, previous = null, candidate = null))
      faultInjector.check(ContentAddressedFaultPoint.AFTER_ROLLBACK_COMMIT)
      pruneApp(scope.lynxAppId)
      setMetrics(latestMetrics.copy(operation = "rollback", releaseId = restored.context.releaseId, result = "success"))
      restored
    }
  }

  override fun deleteDownloadedBundles(lynxAppId: String) {
    val appId = OtaModels.requireLynxAppId(lynxAppId)
    withStorageLock {
      ensureAppDirectories(appId)
      cleanup(statePath(appId))
      cleanup(transactionRoot(appId))
      pruneApp(appId)
      validationCache.clear()
      setMetrics(latestMetrics.copy(operation = "delete", releaseId = null, result = "success"))
    }
  }

  override fun deleteAllDownloadedBundles() {
    withStorageLock {
      appsRoot().listFiles().orEmpty()
        .filter { it.isDirectory && APP_ID_PATTERN.matches(it.name) }
        .forEach { app ->
          cleanup(statePath(app.name))
          cleanup(transactionRoot(app.name))
          pruneApp(app.name)
        }
      validationCache.clear()
    }
  }

  override fun pruneAllUnreferencedReleases() {
    withStorageLock {
      appsRoot().listFiles().orEmpty()
        .filter { it.isDirectory && APP_ID_PATTERN.matches(it.name) }
        .forEach { pruneApp(it.name) }
    }
  }

  override fun storageSnapshot(maxFilesPerTree: Int): OtaStorageSnapshot {
    require(maxFilesPerTree > 0) { "maxFilesPerTree 必须大于 0" }
    return withStorageLock {
      val root = canonicalOrAbsolute(storageRoot)
      val rootScan = scanTree(root, maxFilesPerTree)
      val apps = appsRoot().listFiles().orEmpty()
        .filter { it.isDirectory && APP_ID_PATTERN.matches(it.name) }
        .sortedBy(File::getName)
        .map { snapshotApp(it.name, maxFilesPerTree) }
      OtaStorageSnapshot(root.path, rootScan.bytes, rootScan.count, clock.now(), apps)
    }
  }

  /** v3 增量下载/对象写入的最近一次结果，供报告和诊断页读取。 */
  fun operationMetrics(): ContentAddressedOperationMetrics = latestMetrics

  override fun ensureBundleReady(scope: ReleaseTransaction.ReleaseScope, bundleName: String): File {
    return currentBundle(scope, bundleName)
      ?: throw transactionError("当前 release 找不到 Bundle：$bundleName", "bundle_not_found")
  }

  override fun ensureBundleReady(lynxAppId: String, bundleName: String): File {
    return currentBundle(lynxAppId, bundleName)
      ?: throw transactionError("当前 release 找不到 Bundle：$bundleName", "bundle_not_found")
  }

  override fun currentTemplatePath(lynxAppId: String, pageId: Int): File? {
    val state = readState(lynxAppId) ?: return null
    val release = resolveRef(state.scope, state.current) ?: return null
    val bundle = release.bundles.firstOrNull { it.pageId == pageId } ?: return null
    return currentBundle(lynxAppId, bundle.bundlePath)
  }

  private fun acquireLease(
    scope: ReleaseTransaction.ReleaseScope,
    ref: Ref,
    bundleName: String,
  ): ReleaseTransaction.BundleLease? {
    val release = resolveRef(scope, ref) ?: return null
    val bundle = findBundle(release, bundleName) ?: return null
    val file = resolveBundle(scope, ref, bundleName) ?: return null
    val key = LeaseKey(canonicalOrAbsolute(storageRoot).path, scope.lynxAppId, ref.manifestId ?: ref.releaseId)
    LEASE_COUNTS[key] = (LEASE_COUNTS[key] ?: 0) + 1
    return ReleaseTransaction.BundleLease(release, bundle, file) {
      withStorageLock {
        val remaining = (LEASE_COUNTS[key] ?: 0) - 1
        if (remaining > 0) LEASE_COUNTS[key] = remaining else LEASE_COUNTS.remove(key)
        pruneApp(scope.lynxAppId)
      }
    }
  }

  private fun resolveBundle(
    scope: ReleaseTransaction.ReleaseScope,
    ref: Ref,
    bundleName: String,
  ): File? {
    validateBundleLookup(bundleName)
    val record = (if (ref.kind == RefKind.DOWNLOADED) readManifest(scope.lynxAppId, ref.manifestId) else null)
      ?: return null
    val artifact = findBundle(record.manifest, bundleName) ?: return null
    val objectPath = objectPath(scope.lynxAppId, artifact.bundleSha256)
    if (!objectPath.isFile || artifact.size == null || objectPath.length() != artifact.size.toLong()) return null
    val key = ValidationKey(scope.lynxAppId, ref.manifestId.orEmpty(), artifact.bundlePath, artifact.bundleSha256, objectPath.length(), objectPath.lastModified())
    if (!validationCache.containsKey(key)) {
      if (!OtaIO.sha256(objectPath).equals(artifact.bundleSha256, ignoreCase = true)) {
        validationCache.remove(key)
        throw transactionError("Bundle 校验失败：$bundleName", "bundle_checksum_failed")
      }
      validationCache[key] = Unit
    }
    return objectPath
  }

  private fun resolveRef(scope: ReleaseTransaction.ReleaseScope, ref: Ref): OtaModels.InstalledRelease? {
    return when (ref.kind) {
      RefKind.EMBEDDED -> resolveEmbedded(scope)?.takeIf { it.context.releaseId == ref.releaseId }
      RefKind.DOWNLOADED -> {
        val record = readManifest(scope.lynxAppId, ref.manifestId) ?: return null
        if (record.manifest.releaseId != ref.releaseId) return null
        readManifestRelease(scope, record.manifest, ref.manifestId!!)
      }
    }
  }

  private fun resolveEmbedded(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease? {
    return EmbeddedReleaseStore(storageRoot).embeddedRelease(scope.lynxAppId)
      ?.takeIf {
        it.context.env == scope.env && it.context.hostApp == scope.hostApp &&
          it.context.lynxAppId == scope.lynxAppId && it.context.platform == scope.platform
      }
  }

  private fun isUsableRelease(
    scope: ReleaseTransaction.ReleaseScope,
    release: OtaModels.InstalledRelease,
  ): Boolean {
    val embedded = resolveEmbedded(scope)
    if (embedded?.context?.releaseId == release.context.releaseId) return true
    if (release.context.lynxAppId != scope.lynxAppId || release.context.platform != scope.platform) return false
    return release.bundles.all { bundle ->
      val path = objectPath(scope.lynxAppId, bundle.bundleSha256)
      path.isFile && runCatching { OtaIO.sha256(path).equals(bundle.bundleSha256, ignoreCase = true) }.getOrDefault(false)
    }
  }

  private fun readManifestRelease(
    scope: ReleaseTransaction.ReleaseScope,
    manifest: OtaModels.ReleaseManifest,
    manifestID: String,
  ): OtaModels.InstalledRelease? {
    if (!manifestObjectsUsable(scope.lynxAppId, manifest)) return null
    val installedAt = readManifest(scope.lynxAppId, manifestID)?.installedAt ?: clock.now()
    val bundles = manifest.bundles.map { artifact ->
      OtaModels.InstalledBundle(
        artifact.pageId,
        artifact.bundlePath,
        artifact.bundleSha256,
        artifact.bundleUrl,
        objectPath(scope.lynxAppId, artifact.bundleSha256).toString(),
      )
    }
    return OtaModels.InstalledRelease(
      OtaModels.CurrentReleaseContext(
        manifest.env,
        manifest.hostApp,
        manifest.lynxAppId,
        manifest.releaseId,
        manifest.platform,
        OtaModels.ReleaseStatus.ACTIVE,
      ),
      installedAt,
      bundles,
    )
  }

  private fun readManifest(appId: String, manifestID: String?): ManifestRecord? {
    if (manifestID.isNullOrBlank()) return null
    validateManifestId(manifestID)
    val path = File(manifestsRoot(appId), "$manifestID.json")
    if (!path.isFile) return null
    return try {
      val map = OtaJson.asObject(OtaJson.parse(path.readText(Charsets.UTF_8)), path.toString())
      if ((map["schemaVersion"] as? Number)?.toInt() != STORE_SCHEMA_VERSION) return null
      if (OtaModels.stringValue(map["manifestId"]) != manifestID) return null
      val manifest = OtaModels.ReleaseManifest.fromJsonMap(map, requireStatus = true)
      val bundles = OtaJson.asArray(map["bundles"], "manifest.bundles")
      val objectIds = LinkedHashMap<String, String>()
      for (item in bundles) {
        val bundle = OtaJson.asObject(item, "manifest.bundle")
        val pathValue = OtaModels.stringValue(bundle["bundlePath"])
        objectIds[pathValue] = OtaModels.stringValue(bundle["objectId"] ?: bundle["bundleSha256"])
      }
      ManifestRecord(
        manifest = manifest,
        manifestId = manifestID,
        objectIds = objectIds,
        installedAt = (map["installedAt"] as? String)?.let(Instant::parse) ?: Instant.EPOCH,
      )
    } catch (_: Exception) {
      null
    }
  }

  private fun writeManifestAtomic(
    scope: ReleaseTransaction.ReleaseScope,
    manifest: OtaModels.ReleaseManifest,
    manifestID: String,
  ) {
    val map = LinkedHashMap<String, Any?>(manifest.toJsonMap())
    map["schemaVersion"] = STORE_SCHEMA_VERSION
    map["manifestId"] = manifestID
    map["installedAt"] = clock.now().toString()
    map["bundles"] = manifest.bundles.map { artifact ->
      LinkedHashMap<String, Any?>(artifact.toJsonMap()).apply {
        this["objectId"] = artifact.bundleSha256
      }
    }
    writeAtomic(File(manifestsRoot(scope.lynxAppId), "$manifestID.json"), OtaJson.stringify(map))
  }

  private fun manifestObjectsUsable(appId: String, manifest: OtaModels.ReleaseManifest): Boolean {
    return manifest.bundles.all { hasUsableObject(appId, it.bundleSha256, it.size) }
  }

  private fun hasUsableObject(appId: String, objectID: String, expectedSize: Int?): Boolean {
    val path = objectPath(appId, objectID)
    if (!path.isFile || expectedSize == null || path.length() != expectedSize.toLong()) return false
    val key = ValidationKey(appId, "object", path.name, objectID, path.length(), path.lastModified())
    if (validationCache.containsKey(key)) return true
    return try {
      val matches = OtaIO.sha256(path).equals(objectID, ignoreCase = true)
      if (matches) validationCache[key] = Unit
      matches
    } catch (_: IOException) {
      false
    }
  }

  private fun validateManifest(scope: ReleaseTransaction.ReleaseScope, manifest: OtaModels.ReleaseManifest) {
    validateReleaseId(manifest.releaseId)
    if (manifest.status != OtaModels.ReleaseStatus.ACTIVE) {
      throw transactionError("Release 状态不可激活：${manifest.status.wireValue}", OtaModels.ReasonCodes.INVALID_RELEASE_STATUS)
    }
    if (manifest.env != scope.env || manifest.hostApp != scope.hostApp ||
      manifest.lynxAppId != scope.lynxAppId || manifest.platform != scope.platform ||
      !manifest.platforms.contains(scope.platform)
    ) throw transactionError("Manifest scope 与请求不一致", "scope_mismatch")
    val seen = HashSet<String>()
    manifest.bundles.forEach { artifact ->
      if (!seen.add(validateBundlePath(artifact.bundlePath))) {
        throw transactionError("Manifest 中存在重复 Bundle 路径：${artifact.bundlePath}", "duplicate_bundle_path")
      }
      if (!SHA_PATTERN.matches(artifact.bundleSha256)) {
        throw transactionError("Bundle SHA-256 格式错误", "invalid_bundle_sha256")
      }
      val size = artifact.size
        ?: throw transactionError("Bundle size 不能为空：${artifact.bundlePath}", OtaModels.ReasonCodes.MISSING_BUNDLE_SIZE)
      if (size <= 0) throw transactionError("Bundle size 必须大于 0：${artifact.bundlePath}", OtaModels.ReasonCodes.INVALID_BUNDLE_SIZE)
      if (size > OtaModels.MAX_BUNDLE_BYTES) throw transactionError("Bundle 超过允许大小", OtaModels.ReasonCodes.BUNDLE_TOO_LARGE)
      if (!OtaURLPolicy.isAllowed(artifact.bundleUrl, environment, allowLocalHTTPForTest) || artifact.bundleUrl.userInfo != null || artifact.bundleUrl.fragment != null) {
        throw transactionError("Bundle URL 不允许：${artifact.bundlePath}", OtaModels.ReasonCodes.INVALID_BUNDLE_URL)
      }
    }
  }

  private fun validateStreamResult(artifact: OtaModels.BundleArtifact, result: OtaIO.StreamResult) {
    if (artifact.size != null && result.bytes != artifact.size.toLong()) {
      throw transactionError("Bundle size 校验失败：${artifact.bundlePath}", OtaModels.ReasonCodes.BUNDLE_SIZE_MISMATCH)
    }
    if (!result.sha256.equals(artifact.bundleSha256, ignoreCase = true)) {
      throw OtaSdkException.checksumMismatch(artifact.bundleSha256, result.sha256)
    }
  }

  private fun findBundle(manifest: OtaModels.ReleaseManifest, bundleName: String): OtaModels.BundleArtifact? {
    validateBundleLookup(bundleName)
    val exact = manifest.bundles.filter { it.bundlePath == bundleName }
    if (exact.size == 1) return exact[0]
    if (exact.size > 1) throw transactionError("Bundle 路径重复：$bundleName", "duplicate_bundle_path")
    val short = manifest.bundles.filter { it.bundlePath.substringAfterLast('/') == bundleName }
    return short.singleOrNull()
  }

  private fun findBundle(release: OtaModels.InstalledRelease, bundleName: String): OtaModels.InstalledBundle? {
    validateBundleLookup(bundleName)
    val exact = release.bundles.filter { it.bundlePath == bundleName }
    if (exact.size == 1) return exact[0]
    if (exact.size > 1) throw transactionError("Bundle 路径重复：$bundleName", "duplicate_bundle_path")
    return release.bundles.singleOrNull { it.bundlePath.substringAfterLast('/') == bundleName }
  }

  private fun validateBundleLookup(bundleName: String) {
    if (bundleName.isBlank() || bundleName.contains('\\') || bundleName.indexOf('\u0000') >= 0) {
      throw transactionError("Bundle 名称不安全：$bundleName", "unsafe_bundle_path")
    }
  }

  private fun validateBundlePath(bundlePath: String): String {
    if (bundlePath.isBlank() || bundlePath.startsWith('/') || bundlePath.contains('\\') || bundlePath.indexOf('\u0000') >= 0) {
      throw transactionError("Bundle 路径不安全：$bundlePath", "unsafe_bundle_path")
    }
    val segments = bundlePath.split('/')
    if (segments.any { it.isBlank() || it == "." || it == ".." }) {
      throw transactionError("Bundle 路径不安全：$bundlePath", "unsafe_bundle_path")
    }
    return segments.joinToString("/")
  }

  private fun manifestId(manifest: OtaModels.ReleaseManifest): String = sha256Bytes(OtaJson.stringify(manifest.toJsonMap()).toByteArray(Charsets.UTF_8))

  private fun sha256Bytes(bytes: ByteArray): String {
    val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
    return "sha256:" + digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
  }

  private fun validateManifestId(value: String) {
    if (!SHA_PATTERN.matches(value)) throw transactionError("Manifest ID 格式错误", "storage_recovery_failed")
  }

  private fun validateReleaseId(value: String) {
    if (value.isBlank() || value == "." || value == ".." || value.contains('/') || value.contains('\\') || value.indexOf('\u0000') >= 0) {
      throw transactionError("ReleaseId 不安全：$value", "unsafe_release_id")
    }
  }

  private fun requireScope(actual: ReleaseTransaction.ReleaseScope, expected: ReleaseTransaction.ReleaseScope, label: String) {
    if (actual != expected) throw transactionError("$label scope 与目标不一致", "scope_mismatch")
  }

  private fun readState(appId: String): StateRecord? {
    val path = statePath(appId)
    if (!path.isFile) return null
    return try {
      val map = OtaJson.asObject(OtaJson.parse(path.readText(Charsets.UTF_8)), path.toString())
      if ((map["schemaVersion"] as? Number)?.toInt() != STORE_SCHEMA_VERSION) {
        throw transactionError("Store v3 state schemaVersion 不支持", "storage_recovery_failed")
      }
      val scopeMap = OtaJson.asObject(map["scope"], "state.scope")
      val scope = ReleaseTransaction.ReleaseScope(
        OtaModels.Environment.fromWire(OtaModels.stringValue(scopeMap["env"])),
        OtaModels.HostApp.fromWire(OtaModels.stringValue(scopeMap["hostApp"])),
        OtaModels.stringValue(scopeMap["lynxAppId"]),
        OtaModels.Platform.fromWire(OtaModels.stringValue(scopeMap["platform"])),
      )
      val candidateValue = map["candidate"]
      StateRecord(
        scope,
        (map["generation"] as? Number)?.toLong() ?: 0L,
        parseRef(OtaJson.asObject(map["current"], "state.current")),
        (map["previous"] as? Map<*, *>)?.let { parseRef(OtaJson.asObject(it, "state.previous")) },
        if (candidateValue == null) null else parseCandidate(OtaJson.asObject(candidateValue, "state.candidate")),
      )
    } catch (error: OtaSdkException) {
      throw error
    } catch (error: Exception) {
      throw OtaSdkException("Store v3 state 解析失败：$path", error, "storage_recovery_failed")
    }
  }

  private fun parseCandidate(map: Map<String, Any?>): CandidateRecord {
    return CandidateRecord(
      parseRef(OtaJson.asObject(map["release"], "candidate.release")),
      OtaModels.CandidateStatus.fromWire(OtaModels.stringValue(map["status"])),
      (map["failureCount"] as? Number)?.toInt() ?: 0,
      Instant.parse(OtaModels.stringValue(map["createdAt"])),
      (map["trialStartedAt"] as? String)?.let(Instant::parse),
    )
  }

  private fun parseRef(map: Map<String, Any?>): Ref {
    val kind = when (OtaModels.stringValue(map["kind"]).lowercase()) {
      "embedded" -> RefKind.EMBEDDED
      "downloaded" -> RefKind.DOWNLOADED
      else -> throw transactionError("state 引用了未知 kind", "storage_recovery_failed")
    }
    val releaseID = OtaModels.stringValue(map["releaseId"])
    validateReleaseId(releaseID)
    val manifestID = (map["manifestId"] as? String)?.also(::validateManifestId)
    if (kind == RefKind.DOWNLOADED && manifestID == null) {
      throw transactionError("downloaded ref 缺少 manifestId", "storage_recovery_failed")
    }
    return Ref(kind, releaseID, manifestID)
  }

  private fun writeStateAtomic(state: StateRecord) {
    ensureAppDirectories(state.scope.lynxAppId)
    val scope = mapOf(
      "env" to state.scope.env.wireValue,
      "hostApp" to state.scope.hostApp.wireValue,
      "lynxAppId" to state.scope.lynxAppId,
      "platform" to state.scope.platform.wireValue,
    )
    val map = linkedMapOf<String, Any?>(
      "schemaVersion" to STORE_SCHEMA_VERSION,
      "generation" to state.generation,
      "scope" to scope,
      "current" to state.current.toJsonMap(),
      "previous" to state.previous?.toJsonMap(),
      "candidate" to state.candidate?.toJsonMap(),
    )
    writeAtomic(statePath(state.scope.lynxAppId), OtaJson.stringify(map))
  }

  private fun ensureStateScope(state: StateRecord?, expected: ReleaseTransaction.ReleaseScope) {
    if (state != null) requireScope(state.scope, expected, "state")
  }

  private fun snapshotApp(appId: String, maxFiles: Int): OtaStorageAppSnapshot {
    val state = runCatching { readState(appId) }.getOrNull()
    val candidate = state?.candidate
    val leased = activeLeaseIds(appId)
    val manifestFiles = manifestsRoot(appId).listFiles().orEmpty().filter { it.isFile && it.name.endsWith(".json") }
    val releases = manifestFiles.sortedBy(File::getName).mapNotNull { path ->
      val manifestID = path.name.removeSuffix(".json")
      val record = readManifest(appId, manifestID) ?: return@mapNotNull null
      val roles = linkedSetOf<OtaStorageReleaseRole>()
      if (state?.current?.manifestId == manifestID) roles += OtaStorageReleaseRole.CURRENT
      if (state?.previous?.manifestId == manifestID) roles += OtaStorageReleaseRole.PREVIOUS
      if (candidate?.release?.manifestId == manifestID) roles += OtaStorageReleaseRole.CANDIDATE
      if (manifestID in leased) roles += OtaStorageReleaseRole.LEASED
      if (roles.isEmpty()) roles += OtaStorageReleaseRole.ORPHAN
      val scan = scanTree(path.parentFile ?: path, maxFiles)
      OtaStorageReleaseSnapshot(
        releaseId = record.manifest.releaseId,
        roles = roles,
        totalBytes = path.length(),
        fileCount = 1,
        manifestValid = true,
        files = listOf(
          OtaStorageFileSnapshot(path.name, path.length(), Instant.ofEpochMilli(path.lastModified())),
        ),
        truncated = false,
        manifestId = manifestID,
        bundleCount = record.manifest.bundles.size,
        objectIds = record.manifest.bundles.map { it.bundleSha256 }.toSet(),
      )
    }
    val appScan = scanTree(appDirectory(appId), maxFiles)
    val objectFiles = objectRoot(appId).walkTopDown().filter(File::isFile).toList()
    val manifestBytes = manifestFiles.sumOf(File::length)
    return OtaStorageAppSnapshot(
      appId = appId,
      state = state?.let {
        OtaStorageStateSnapshot(
          generation = it.generation,
          currentReleaseId = it.current.releaseId,
          currentKind = it.current.kind.wireValue,
          previousReleaseId = it.previous?.releaseId,
          previousKind = it.previous?.kind?.wireValue,
          currentManifestId = it.current.manifestId,
          previousManifestId = it.previous?.manifestId,
        )
      },
      candidate = candidate?.let {
        OtaStorageCandidateSnapshot(it.release.releaseId, it.status.wireValue, it.failureCount)
      },
      releases = releases,
      staging = emptyList(),
      totalBytes = appScan.bytes,
      fileCount = appScan.count,
      objectCount = objectFiles.size,
      objectBytes = objectFiles.sumOf(File::length),
      manifestBytes = manifestBytes,
      lastOperation = latestMetrics.operation,
    )
  }

  private fun pruneApp(appId: String) {
    val app = appDirectory(appId)
    if (!app.isDirectory) return
    val state = try { readState(appId) } catch (_: Exception) { return }
    val retainedManifests = linkedSetOf<String>()
    val retainedObjects = linkedSetOf<String>()
    fun retain(ref: Ref?) {
      if (ref?.kind != RefKind.DOWNLOADED || ref.manifestId == null) return
      retainedManifests += ref.manifestId
      readManifest(appId, ref.manifestId)?.manifest?.bundles?.forEach { retainedObjects += it.bundleSha256 }
    }
    retain(state?.current)
    retain(state?.previous)
    retain(state?.candidate?.release)
    activeLeaseIds(appId).forEach { manifestID ->
      retainedManifests += manifestID
      readManifest(appId, manifestID)?.manifest?.bundles?.forEach { retainedObjects += it.bundleSha256 }
    }
    transactionRoot(appId).listFiles().orEmpty().filter(File::isDirectory).forEach { transaction ->
      val meta = File(transaction, TRANSACTION_META_NAME)
      runCatching {
        val map = OtaJson.asObject(OtaJson.parse(meta.readText(Charsets.UTF_8)), meta.toString())
        OtaJson.asArray(map["objectIds"], "transaction.objectIds").forEach { retainedObjects += OtaModels.stringValue(it) }
      }
    }
    manifestsRoot(appId).listFiles().orEmpty().filter(File::isFile).forEach { path ->
      if (path.name.removeSuffix(".json") !in retainedManifests) cleanup(path)
    }
    objectRoot(appId).walkTopDown().filter(File::isFile).forEach { path ->
      val objectID = path.name.removeSuffix(".lynx.bundle")
      val normalized = if (objectID.startsWith("sha256:")) objectID else "sha256:$objectID"
      if (normalized !in retainedObjects) cleanup(path)
    }
    objectRoot(appId).walkBottomUp().filter { it.isDirectory && it != objectRoot(appId) && it.listFiles().isNullOrEmpty() }.forEach(::cleanup)
  }

  private fun activeLeaseIds(appId: String): Set<String> {
    val rootPath = canonicalOrAbsolute(storageRoot).path
    return LEASE_COUNTS.entries.asSequence()
      .filter { (key, value) -> key.rootPath == rootPath && key.appId == appId && value > 0 }
      .map { it.key.manifestID }
      .toSet()
  }

  private fun recoverTransactions(appId: String) {
    // 未完成事务不参与 current 解析；保留其目录直到本次安装结束，下一次调用会清掉。
    transactionRoot(appId).listFiles().orEmpty().filter(File::isDirectory).forEach(::cleanup)
  }

  private fun setMetrics(value: ContentAddressedOperationMetrics) {
    latestMetrics = value
  }

  private fun <T> withStorageLock(block: () -> T): T {
    val root = canonicalOrAbsolute(storageRoot)
    val lock = PROCESS_LOCKS.computeIfAbsent(root.path) { ReentrantLock() }
    lock.withLock {
      ensureNoSymlink(root)
      return block()
    }
  }

  private fun ensureAppDirectories(appId: String) {
    ensureDirectory(storageRoot)
    ensureDirectory(appsRoot())
    ensureDirectory(appDirectory(appId))
    ensureDirectory(manifestsRoot(appId))
    ensureDirectory(objectRoot(appId))
    ensureDirectory(transactionRoot(appId))
  }

  private fun appDirectory(appId: String): File = File(File(canonicalOrAbsolute(storageRoot), "apps"), OtaModels.requireLynxAppId(appId))
  private fun appsRoot(): File = File(canonicalOrAbsolute(storageRoot), "apps")
  private fun statePath(appId: String): File = File(appDirectory(appId), "state.json")
  private fun manifestsRoot(appId: String): File = File(appDirectory(appId), "manifests")
  private fun objectRoot(appId: String): File = File(appDirectory(appId), "objects")
  private fun transactionRoot(appId: String): File = File(appDirectory(appId), "transactions")

  private fun transactionDirectory(appId: String, transactionID: String): File {
    return File(transactionRoot(appId), transactionID)
  }

  private fun objectPath(appId: String, objectID: String): File {
    if (!SHA_PATTERN.matches(objectID)) throw transactionError("对象 ID 格式错误", "invalid_bundle_sha256")
    val hex = objectID.removePrefix("sha256:")
    return File(File(objectRoot(appId), hex.substring(0, 2)), "$hex.lynx.bundle")
  }

  private fun ensureDirectory(directory: File) {
    if (directory.isDirectory) return
    if (!directory.mkdirs() && !directory.isDirectory) throw IOException("无法创建 OTA 目录：$directory")
  }

  private fun writeAtomic(target: File, raw: String) {
    target.parentFile?.let(::ensureDirectory)
    val temporary = File(target.parentFile ?: storageRoot, ".${target.name}.tmp-${UUID.randomUUID()}")
    try {
      FileOutputStream(temporary, false).use { output ->
        output.write(raw.toByteArray(Charsets.UTF_8))
        output.fd.sync()
      }
      atomicMove(temporary, target, replaceExisting = true)
    } finally {
      cleanup(temporary)
    }
  }

  private fun atomicMove(source: File, target: File, replaceExisting: Boolean = false) {
    target.parentFile?.let(::ensureDirectory)
    if (!source.isFile) throw IOException("临时文件不存在：$source")
    if (!replaceExisting && target.exists()) throw IOException("目标文件已存在：$target")
    if (!replaceExisting) {
      if (!source.renameTo(target)) throw IOException("无法发布文件：$target")
      return
    }
    val backup = if (target.exists()) File(target.parentFile ?: storageRoot, ".${target.name}.bak-${UUID.randomUUID()}") else null
    if (backup != null && !target.renameTo(backup)) throw IOException("无法备份旧文件：$target")
    try {
      if (!source.renameTo(target)) throw IOException("无法替换文件：$target")
      backup?.let(::cleanup)
    } catch (error: Throwable) {
      if (!target.exists()) backup?.renameTo(target)
      throw error
    }
  }

  private fun cleanup(path: File) {
    if (!path.exists()) return
    if (path.isDirectory) path.listFiles().orEmpty().forEach(::cleanup)
    path.delete()
  }

  private fun ensureNoSymlink(path: File) {
    val absolute = path.absoluteFile
    val canonical = path.canonicalFile
    if (absolute.path != canonical.path) throw transactionError("OTA 路径包含 symlink：$path", "unsafe_storage_path")
  }

  private fun canonicalOrAbsolute(file: File): File = runCatching { file.canonicalFile }.getOrElse { file.absoluteFile }

  private fun scanTree(root: File, maxFiles: Int): TreeScan {
    if (!root.exists()) return TreeScan(0, 0)
    var bytes = 0L
    var count = 0
    fun visit(file: File) {
      if (file.isFile) {
        bytes += file.length()
        count += 1
      } else if (file.isDirectory) file.listFiles().orEmpty().forEach(::visit)
    }
    visit(root)
    return TreeScan(bytes, count)
  }

  private fun transactionError(message: String, code: String): OtaSdkException = OtaSdkException(message, null, code)

  private data class StateRecord(
    val scope: ReleaseTransaction.ReleaseScope,
    val generation: Long,
    val current: Ref,
    val previous: Ref?,
    val candidate: CandidateRecord?,
  )

  private data class CandidateRecord(
    val release: Ref,
    val status: OtaModels.CandidateStatus,
    val failureCount: Int,
    val createdAt: Instant,
    val trialStartedAt: Instant?,
  ) {
    fun toJsonMap(): Map<String, Any?> = mapOf(
      "release" to release.toJsonMap(),
      "status" to status.wireValue,
      "failureCount" to failureCount,
      "createdAt" to createdAt.toString(),
      "trialStartedAt" to trialStartedAt?.toString(),
    )
  }

  private data class Ref(val kind: RefKind, val releaseId: String, val manifestId: String?) {
    fun toJsonMap(): Map<String, Any?> = mapOf(
      "kind" to kind.wireValue,
      "releaseId" to releaseId,
      "manifestId" to manifestId,
    )
  }

  private data class ManifestRecord(
    val manifest: OtaModels.ReleaseManifest,
    val manifestId: String,
    val objectIds: Map<String, String>,
    val installedAt: Instant,
  )

  private data class ValidationKey(
    val appId: String,
    val releaseOrObject: String,
    val bundlePath: String,
    val sha256: String,
    val length: Long,
    val modifiedAt: Long,
  )

  private data class LeaseKey(val rootPath: String, val appId: String, val manifestID: String)
  private data class TreeScan(val bytes: Long, val count: Int)
  private enum class RefKind(val wireValue: String) { EMBEDDED("embedded"), DOWNLOADED("downloaded") }

  private companion object {
    const val STORE_SCHEMA_VERSION = 3
    const val TRANSACTION_META_NAME = "transaction.json"
    const val METADATA_ALLOWANCE_BYTES = 1024L * 1024L
    const val SAFETY_RESERVE_BYTES = 32L * 1024L * 1024L
    val SHA_PATTERN = Regex("^sha256:[0-9a-fA-F]{64}$")
    val APP_ID_PATTERN = Regex("^[0-9]{8}$")
    val PROCESS_LOCKS = ConcurrentHashMap<String, ReentrantLock>()
    val LEASE_COUNTS = ConcurrentHashMap<LeaseKey, Int>()
  }
}
