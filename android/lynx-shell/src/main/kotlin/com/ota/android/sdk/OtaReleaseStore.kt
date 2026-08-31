package com.ota.android.sdk

import java.io.File
import java.io.IOException

/**
 * OTA Store 的稳定后端边界。
 *
 * v2 的 ReleaseTransaction 继续作为低层兼容实现；宿主配置切到 Store v3 后由
 * ContentAddressedOtaStore 接管。路由只依赖这组语义，不依赖磁盘布局。
 */
interface OtaReleaseStore {
  @Throws(IOException::class, OtaSdkException::class)
  fun registerEmbeddedRelease(release: OtaModels.InstalledRelease)

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun install(request: ReleaseTransaction.InstallRequest): ReleaseTransaction.InstallOutcome

  @Throws(IOException::class, OtaSdkException::class)
  fun current(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease?

  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String): OtaModels.InstalledRelease?

  @Throws(IOException::class, OtaSdkException::class)
  fun candidate(scope: ReleaseTransaction.ReleaseScope): OtaModels.CandidateSnapshot?

  @Throws(IOException::class, OtaSdkException::class)
  fun beginCandidateTrial(scope: ReleaseTransaction.ReleaseScope): OtaModels.CandidateSnapshot

  @Throws(IOException::class, OtaSdkException::class)
  fun confirmCandidate(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease

  @Throws(IOException::class, OtaSdkException::class)
  fun discardCandidate(scope: ReleaseTransaction.ReleaseScope)

  @Throws(IOException::class, OtaSdkException::class)
  fun recoverInterruptedCandidate(scope: ReleaseTransaction.ReleaseScope)

  @Throws(IOException::class, OtaSdkException::class)
  fun candidateBundle(scope: ReleaseTransaction.ReleaseScope, bundleName: String): File?

  @Throws(IOException::class, OtaSdkException::class)
  fun acquireCurrentBundleLease(
    scope: ReleaseTransaction.ReleaseScope,
    bundleName: String,
  ): ReleaseTransaction.BundleLease?

  @Throws(IOException::class, OtaSdkException::class)
  fun acquireCandidateBundleLease(
    scope: ReleaseTransaction.ReleaseScope,
    bundleName: String,
  ): ReleaseTransaction.BundleLease?

  /** 路由 NavigationSnapshot 按已固定 releaseId 读取，不随 current 指针漂移。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun acquireBundleLeaseForRelease(
    scope: ReleaseTransaction.ReleaseScope,
    releaseId: String,
    bundleName: String,
  ): ReleaseTransaction.BundleLease?

  @Throws(IOException::class, OtaSdkException::class)
  fun currentBundle(scope: ReleaseTransaction.ReleaseScope, bundleName: String): File?

  @Throws(IOException::class, OtaSdkException::class)
  fun currentBundle(lynxAppId: String, bundleName: String): File?

  @Throws(IOException::class, OtaSdkException::class)
  fun rollback(scope: ReleaseTransaction.ReleaseScope): OtaModels.InstalledRelease?

  @Throws(IOException::class, OtaSdkException::class)
  fun deleteDownloadedBundles(lynxAppId: String)

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteAllDownloadedBundles()

  @Throws(IOException::class, OtaSdkException::class)
  fun pruneAllUnreferencedReleases()

  fun storageSnapshot(maxFilesPerTree: Int): OtaStorageSnapshot

  @Throws(IOException::class, OtaSdkException::class)
  fun ensureBundleReady(scope: ReleaseTransaction.ReleaseScope, bundleName: String): File

  @Throws(IOException::class, OtaSdkException::class)
  fun ensureBundleReady(lynxAppId: String, bundleName: String): File

  @Throws(IOException::class, OtaSdkException::class)
  fun currentTemplatePath(lynxAppId: String, pageId: Int): File?
}

/** 将旧 Store 实现适配到新后端边界；只有直接使用 v2 的调用会走这里。 */
internal class LegacyOtaReleaseStore(
  storageRoot: File,
) : OtaReleaseStore {
  private val delegate = ReleaseTransaction(storageRoot)

  override fun registerEmbeddedRelease(release: OtaModels.InstalledRelease) = delegate.registerEmbeddedRelease(release)
  override fun install(request: ReleaseTransaction.InstallRequest) = delegate.install(request)
  override fun current(scope: ReleaseTransaction.ReleaseScope) = delegate.current(scope)
  override fun current(lynxAppId: String) = delegate.current(lynxAppId)
  override fun candidate(scope: ReleaseTransaction.ReleaseScope) = delegate.candidate(scope)
  override fun beginCandidateTrial(scope: ReleaseTransaction.ReleaseScope) = delegate.beginCandidateTrial(scope)
  override fun confirmCandidate(scope: ReleaseTransaction.ReleaseScope) = delegate.confirmCandidate(scope)
  override fun discardCandidate(scope: ReleaseTransaction.ReleaseScope) = delegate.discardCandidate(scope)
  override fun recoverInterruptedCandidate(scope: ReleaseTransaction.ReleaseScope) = delegate.recoverInterruptedCandidate(scope)
  override fun candidateBundle(scope: ReleaseTransaction.ReleaseScope, bundleName: String) = delegate.candidateBundle(scope, bundleName)
  override fun acquireCurrentBundleLease(scope: ReleaseTransaction.ReleaseScope, bundleName: String) = delegate.acquireCurrentBundleLease(scope, bundleName)
  override fun acquireCandidateBundleLease(scope: ReleaseTransaction.ReleaseScope, bundleName: String) = delegate.acquireCandidateBundleLease(scope, bundleName)
  override fun acquireBundleLeaseForRelease(scope: ReleaseTransaction.ReleaseScope, releaseId: String, bundleName: String): ReleaseTransaction.BundleLease? {
    val current = delegate.current(scope)
    if (current?.context?.releaseId == releaseId) {
      return delegate.acquireCurrentBundleLease(scope, bundleName)
    }
    val candidate = delegate.candidate(scope)?.release
    if (candidate?.context?.releaseId == releaseId) {
      return delegate.acquireCandidateBundleLease(scope, bundleName)
    }
    return null
  }
  override fun currentBundle(scope: ReleaseTransaction.ReleaseScope, bundleName: String) = delegate.currentBundle(scope, bundleName)
  override fun currentBundle(lynxAppId: String, bundleName: String) = delegate.currentBundle(lynxAppId, bundleName)
  override fun rollback(scope: ReleaseTransaction.ReleaseScope) = delegate.rollback(scope)
  override fun deleteDownloadedBundles(lynxAppId: String) = delegate.deleteDownloadedBundles(lynxAppId)
  override fun deleteAllDownloadedBundles() = delegate.deleteAllDownloadedBundles()
  override fun pruneAllUnreferencedReleases() = delegate.pruneAllUnreferencedReleases()
  override fun storageSnapshot(maxFilesPerTree: Int) = delegate.storageSnapshot(maxFilesPerTree)
  override fun ensureBundleReady(scope: ReleaseTransaction.ReleaseScope, bundleName: String) = delegate.ensureBundleReady(scope, bundleName)
  override fun ensureBundleReady(lynxAppId: String, bundleName: String) = delegate.ensureBundleReady(lynxAppId, bundleName)
  override fun currentTemplatePath(lynxAppId: String, pageId: Int) = delegate.currentTemplatePath(lynxAppId, pageId)
}
