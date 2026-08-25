package com.ota.android.sdk

import java.io.File
import java.io.IOException
import java.time.Instant

class OtaSdk {
  private val configuration: OtaModels.Configuration
  private val apiClient: OtaApiClient
  private val store: OtaReleaseStore
  private val releaseTransaction: ReleaseTransaction
  private val bundleRuntime: BundleRuntime

  constructor(configuration: OtaModels.Configuration) : this(
    configuration,
    OtaApiClient.server(configuration.apiBaseUri, configuration.otaClientToken),
  )

  constructor(configuration: OtaModels.Configuration, apiClient: OtaApiClient) {
    this.configuration = configuration
    this.apiClient = apiClient
    this.store = OtaReleaseStore(configuration.storageDirectory)
    this.releaseTransaction = ReleaseTransaction(configuration.storageDirectory)
    this.bundleRuntime = BundleRuntime(releaseTransaction)
  }

  @Throws(IOException::class)
  fun initializeEmbeddedRelease(release: OtaModels.InstalledRelease) {
    store.saveEmbeddedRelease(release)
    // 新 state 与旧 pointer 同时写入，保证升级后的 runtime 可直接使用 embedded fallback。
    releaseTransaction.registerEmbeddedRelease(release)
  }

  /** 按 appId 直接删除磁盘中的全部下载 Bundle，保留 APK 内置 embedded 描述。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteDownloadedBundles(lynxAppId: String) {
    releaseTransaction.deleteDownloadedBundles(lynxAppId)
  }

  /** 直接删除磁盘中的全部 appId 下载 Bundle，保留 APK 内置 embedded 描述。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteAllDownloadedBundles() {
    releaseTransaction.deleteAllDownloadedBundles()
  }

  /** 兼容旧验收入口；语义仍然是直接删除全部下载内容。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun clearDownloadedBundles() = deleteAllDownloadedBundles()

  @Throws(IOException::class)
  fun getCurrentRelease(lynxAppId: String): OtaModels.InstalledRelease? {
    val current = store.currentRelease(lynxAppId)
    if (current != null) {
      return current
    }
    return store.embeddedRelease(lynxAppId)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun checkForUpdate(request: OtaModels.PolicyMatchRequest): OtaModels.PolicyMatchResponse {
    return apiClient.checkForUpdate(request)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun fetchManifest(
    releaseId: String,
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    lynxAppId: String,
    platform: OtaModels.Platform,
  ): OtaModels.ReleaseManifest {
    return apiClient.fetchManifest(releaseId, env, hostApp, lynxAppId, platform)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun reportEvent(payload: OtaModels.ReportPayload) {
    apiClient.reportEvent(payload)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun syncLatestBundleLists(): OtaModels.HostBundleListSyncResult {
    val latestGroup: OtaModels.HostLatestBundleLists = try {
      apiClient.fetchLatestBundleLists(
        configuration.environment,
        configuration.hostApp,
        configuration.platform,
      )
    } catch (error: OtaSdkException) {
      if (error.message != null && error.message!!.startsWith("服务端响应异常：404")) {
        return OtaModels.HostBundleListSyncResult(LinkedHashMap())
      }
      reportLatestBundleListFailure(configuration.lynxAppId, error, OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_FETCH_FAILED)
      throw error
    } catch (error: IOException) {
      reportLatestBundleListFailure(configuration.lynxAppId, error, OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_FETCH_FAILED)
      throw error
    } catch (error: RuntimeException) {
      reportLatestBundleListFailure(configuration.lynxAppId, error, OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_DECODE_FAILED)
      throw error
    }

    val results = LinkedHashMap<String, OtaModels.LatestBundleListUpdateResult>()
    for (latest in latestGroup.bundleLists) {
      results[latest.lynxAppId] = updateToLatestBundleList(latest)
    }
    return OtaModels.HostBundleListSyncResult(results)
  }

  /**
   * 只同步一个 lynxAppId 的最新 Release。
   *
   * latest-bundle-list 接口支持带 lynxAppId 查询参数。页面打开时必须走这个入口，
   * 避免一个页面缺包就把宿主下所有 appId 都下载一遍；Application 启动或回前台
   * 才调用上面的全量 syncLatestBundleLists()。
   */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun syncLatestBundleList(lynxAppId: String): OtaModels.LatestBundleListUpdateResult {
    val latest = try {
      apiClient.fetchLatestBundleList(
        configuration.environment,
        configuration.hostApp,
        lynxAppId,
        configuration.platform,
      )
    } catch (error: OtaSdkException) {
      if (error.message != null && error.message!!.startsWith("服务端响应异常：404")) {
        throw OtaSdkException("最新 bundle-list 中不存在 lynxAppId：$lynxAppId", error)
      }
      reportLatestBundleListFailure(lynxAppId, error, OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_FETCH_FAILED)
      throw error
    } catch (error: IOException) {
      reportLatestBundleListFailure(lynxAppId, error, OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_FETCH_FAILED)
      throw error
    } catch (error: RuntimeException) {
      reportLatestBundleListFailure(lynxAppId, error, OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_DECODE_FAILED)
      throw error
    }

    if (latest.lynxAppId != lynxAppId) {
      throw OtaSdkException("服务端返回了错误的 lynxAppId：${latest.lynxAppId}")
    }
    return updateToLatestBundleList(latest)
  }

  @Throws(IOException::class)
  fun currentTemplatePath(lynxAppId: String, pageId: Int): File? {
    val scoped = releaseTransaction.current(
      ReleaseTransaction.ReleaseScope(
        configuration.environment,
        configuration.hostApp,
        lynxAppId,
        configuration.platform,
      ),
    )
    if (scoped != null) {
      val bundle = scoped.bundles.firstOrNull { it.pageId == pageId }
      if (bundle != null) {
        val resolved = bundleRuntime.current(
          ReleaseTransaction.ReleaseScope(
            configuration.environment,
            configuration.hostApp,
            lynxAppId,
            configuration.platform,
          ),
          bundle.bundlePath,
        )
        if (resolved != null) {
          return resolved
        }
      }
    }
    val current = getCurrentRelease(lynxAppId) ?: return null
    for (bundle in current.bundles) {
      if (bundle.pageId == pageId) {
        return File(bundle.localFilePath)
      }
    }
    return null
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun reportPageOpen(pageId: Int, lynxAppId: String?, bundlePath: String?) {
    val scopedLynxAppId = lynxAppId ?: configuration.lynxAppId ?: return
    val current = getCurrentRelease(scopedLynxAppId) ?: return
    var matchedBundle: OtaModels.InstalledBundle? = null
    for (bundle in current.bundles) {
      if (bundle.pageId == pageId || (bundlePath != null && bundle.bundlePath == bundlePath)) {
        matchedBundle = bundle
        break
      }
    }
    report(
      OtaModels.ReportEvent.PAGE_OPEN,
      current.context.releaseId,
      current.context.lynxAppId,
      pageId,
      matchedBundle?.bundlePath ?: bundlePath,
      matchedBundle?.bundleSha256,
      null,
      ReportDetails(
        OtaModels.ReportEventStage.PAGE_OPEN,
        OtaModels.ReportEventResult.SUCCESS,
        null,
        null,
        null,
        null,
        null,
        "page_open",
      ),
    )
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun rollback(reason: String): OtaModels.InstalledRelease? {
    val configuredLynxAppId = configuration.lynxAppId
      ?: throw OtaSdkException("rollback(reason) 需要明确的 lynxAppId；全量 OTA 配置不提供默认 App ID")
    val current = getCurrentRelease(configuredLynxAppId)
    val scope = ReleaseTransaction.ReleaseScope(
      configuration.environment,
      configuration.hostApp,
      configuredLynxAppId,
      configuration.platform,
    )
    val restored = releaseTransaction.rollback(scope)
    if (restored != null) {
      // 保留旧 pageId facade 的可读性；真正提交顺序由 ReleaseTransaction 保证。
      store.writeCurrentRelease(restored)
    }
    if (restored != null) {
      report(
        OtaModels.ReportEvent.ROLLBACK,
        current?.context?.releaseId ?: restored.context.releaseId,
        restored.context.lynxAppId,
        null,
        null,
        null,
        null,
        ReportDetails(
          OtaModels.ReportEventStage.ROLLBACK,
          OtaModels.ReportEventResult.SUCCESS,
          OtaModels.ReasonCodes.MANUAL_ROLLBACK,
          reason,
          current?.context?.releaseId,
          restored.context.releaseId,
          null,
          reason,
        ),
      )
    }
    return restored
  }

  /** 按 lynxAppId + bundleName 精确读取已提交 current 的 Bundle。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String, bundleName: String): File? {
    return bundleRuntime.current(scopeFor(lynxAppId), bundleName)
  }

  /** 读取指定 appId 的新 runtime current；无新 state 时回退旧 pointer。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String): OtaModels.InstalledRelease? {
    return releaseTransaction.current(scopeFor(lynxAppId)) ?: getCurrentRelease(lynxAppId)
  }

  /** 路由进入 Lynx 容器前的 Bundle 门禁，失败不会读取 staging/part 文件。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun ensureBundleReady(lynxAppId: String, bundleName: String): File {
    val scope = scopeFor(lynxAppId)
    try {
      // 热路径只读已提交 current；命中时不会因为一次页面跳转重复请求 Manifest。
      return bundleRuntime.ensureBundleReady(scope, bundleName)
    } catch (error: OtaSdkException) {
      // 缺包或 SHA 不一致都进入当前 appId 的 latest snapshot 修复；其它编程/路径错误原样抛出。
      val repairable = error.reasonCode == "bundle_not_found" ||
        error.reasonCode == "bundle_checksum_failed"
      if (!repairable) throw error
    }

    // 页面打开只请求当前 appId 的 latest 列表；全量同步只由 Application 启动/前台触发。
    syncLatestBundleList(lynxAppId)
    return bundleRuntime.ensureBundleReady(scope, bundleName)
  }

  /** 新增按 appId 的 rollback 入口，旧 rollback(reason) 继续保留。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun rollback(lynxAppId: String, reason: String): OtaModels.InstalledRelease? {
    if (configuration.lynxAppId != null && lynxAppId == configuration.lynxAppId) {
      return rollback(reason)
    }
    val restored = releaseTransaction.rollback(scopeFor(lynxAppId))
    if (restored != null) {
      OtaReleaseStore(configuration.storageDirectory).writeCurrentRelease(restored)
    }
    return restored
  }

  private fun scopeFor(lynxAppId: String): ReleaseTransaction.ReleaseScope {
    return ReleaseTransaction.ReleaseScope(
      configuration.environment,
      configuration.hostApp,
      lynxAppId,
      configuration.platform,
    )
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  private fun updateToLatestBundleList(latest: OtaModels.LatestBundleList): OtaModels.LatestBundleListUpdateResult {
    val current = getCurrentRelease(latest.lynxAppId)
    if (latest.status != OtaModels.ReleaseStatus.ACTIVE) {
      val reasonCode = when (latest.status) {
        OtaModels.ReleaseStatus.DISABLED -> OtaModels.ReasonCodes.RELEASE_DISABLED
        OtaModels.ReleaseStatus.ROLLED_BACK -> OtaModels.ReasonCodes.RELEASE_ROLLED_BACK
        else -> OtaModels.ReasonCodes.INVALID_RELEASE_STATUS
      }
      runCatching {
        report(
          OtaModels.ReportEvent.CHECK_RESULT,
          latest.releaseId,
          latest.lynxAppId,
          null,
          null,
          null,
          null,
          ReportDetails(
            OtaModels.ReportEventStage.CHECK,
            OtaModels.ReportEventResult.SKIPPED,
            reasonCode,
            "Release 状态不可激活：${latest.status.wireValue}",
            null,
            null,
            null,
            reasonCode,
          ),
        )
      }
      return OtaModels.LatestBundleListUpdateResult.skipped(
        current,
        "Release 状态不可激活：${latest.status.wireValue}",
      )
    }
    if (current != null && current.context.releaseId == latest.releaseId) {
      if (hasAllLocalBundles(current)) {
        return OtaModels.LatestBundleListUpdateResult.alreadyActive(current)
      }
      report(
        OtaModels.ReportEvent.CHECK_RESULT,
        latest.releaseId,
        latest.lynxAppId,
        null,
        null,
        null,
        null,
        ReportDetails(
          OtaModels.ReportEventStage.CHECK,
          OtaModels.ReportEventResult.FAILED,
          OtaModels.ReasonCodes.LOCAL_BUNDLE_MISSING,
          "当前 release 的本地 bundle 缺失，准备重新下载",
          null,
          null,
          null,
          OtaModels.ReasonCodes.LOCAL_BUNDLE_MISSING,
        ),
      )
    }

    val skipMessage = versionMismatchMessage(latest)
    if (skipMessage != null) {
      report(
        OtaModels.ReportEvent.CHECK_RESULT,
        latest.releaseId,
        latest.lynxAppId,
        null,
        null,
        null,
        null,
        ReportDetails(
          OtaModels.ReportEventStage.CHECK,
          OtaModels.ReportEventResult.SKIPPED,
          OtaModels.ReasonCodes.BASELINE_BLOCKED,
          skipMessage,
          null,
          null,
          null,
          skipMessage,
        ),
      )
      return OtaModels.LatestBundleListUpdateResult.skipped(current, skipMessage)
    }

    val manifest = latest.asManifest()
    val scope = ReleaseTransaction.ReleaseScope.fromManifest(manifest)
    val transaction = try {
      // 所有新下载都经过同一个 Release 事务：Bundle 写入 staging，完整校验后再
      // 原子发布并提交 current/previous state。旧 pointer 只作为兼容读取和写回 facade。
      releaseTransaction.install(
        ReleaseTransaction.InstallRequest(
          scope = scope,
          targetManifest = manifest,
          embeddedDescriptor = store.embeddedRelease(latest.lynxAppId),
        ),
      )
    } catch (error: Exception) {
      if (error is IOException || error is OtaSdkException) {
        report(
          OtaModels.ReportEvent.ACTIVATE,
          manifest.releaseId,
          manifest.lynxAppId,
          null,
          null,
          null,
          null,
          ReportDetails(
            OtaModels.ReportEventStage.ACTIVATE,
            OtaModels.ReportEventResult.FAILED,
            OtaModels.ReasonCodes.RELEASE_ACTIVATE_FAILED,
            error.message,
            null,
            null,
            null,
            OtaModels.ReasonCodes.RELEASE_ACTIVATE_FAILED,
          ),
        )
      }
      throw error
    }
    val activated = transaction.installed
      ?: return OtaModels.LatestBundleListUpdateResult.noRelease(transaction.current)
    // 兼容旧 pageId facade；Router 的实际读取优先使用 states/<appId>.json。
    store.writeCurrentRelease(activated)
    val outcome = OtaModels.BundleSyncSummary(
      manifest.releaseId,
      manifest.bundles.size,
      transaction.downloadedBundleCount,
      transaction.copiedBundleCount,
    )
    report(
      OtaModels.ReportEvent.ACTIVATE,
      activated.context.releaseId,
      activated.context.lynxAppId,
      null,
      null,
      null,
      null,
      ReportDetails(
        OtaModels.ReportEventStage.ACTIVATE,
        OtaModels.ReportEventResult.SUCCESS,
        null,
        null,
        null,
        null,
        null,
        "release_activated",
      ),
    )
    report(
      OtaModels.ReportEvent.CHECK_RESULT,
      manifest.releaseId,
      manifest.lynxAppId,
      null,
      null,
      null,
      null,
      ReportDetails(
        OtaModels.ReportEventStage.CHECK,
        OtaModels.ReportEventResult.SUCCESS,
        null,
        null,
        null,
        null,
        null,
        "latest_bundle_list_updated",
      ),
    )
    return OtaModels.LatestBundleListUpdateResult.updated(current, activated, outcome)
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  private fun downloadAndValidate(
    manifest: OtaModels.ReleaseManifest,
    reusableRelease: OtaModels.InstalledRelease?,
  ): DownloadOutcome {
    val installedBundles = ArrayList<OtaModels.InstalledBundle>()
    var downloadedBundleCount = 0
    var reusedBundleCount = 0

    for (artifact in manifest.bundles) {
      val reusable = reusableInstalledBundle(artifact, reusableRelease)
      if (reusable != null) {
        reusedBundleCount += 1
        installedBundles.add(
          OtaModels.InstalledBundle(
            artifact.pageId,
            artifact.bundlePath,
            artifact.bundleSha256,
            artifact.bundleUrl,
            reusable.localFilePath,
          ),
        )
        continue
      }

      val localPath = store.localBundlePath(manifest.releaseId, artifact.bundlePath)
      val downloadStartedAt = System.currentTimeMillis()
      try {
        OtaIO.download(artifact.bundleUrl, localPath)
      } catch (error: IOException) {
        report(
          OtaModels.ReportEvent.DOWNLOAD_SUCCESS,
          manifest.releaseId,
          manifest.lynxAppId,
          artifact.pageId,
          artifact.bundlePath,
          artifact.bundleSha256,
          artifact.size,
          ReportDetails(
            OtaModels.ReportEventStage.DOWNLOAD,
            OtaModels.ReportEventResult.FAILED,
            OtaModels.ReasonCodes.BUNDLE_DOWNLOAD_FAILED,
            error.message,
            null,
            null,
            elapsedMillis(downloadStartedAt),
            OtaModels.ReasonCodes.BUNDLE_DOWNLOAD_FAILED,
          ),
        )
        throw error
      }

      val actualSha256 = OtaIO.sha256(localPath)
      if (!actualSha256.equals(artifact.bundleSha256, ignoreCase = true)) {
        report(
          OtaModels.ReportEvent.DOWNLOAD_SUCCESS,
          manifest.releaseId,
          manifest.lynxAppId,
          artifact.pageId,
          artifact.bundlePath,
          artifact.bundleSha256,
          artifact.size,
          ReportDetails(
            OtaModels.ReportEventStage.DOWNLOAD,
            OtaModels.ReportEventResult.FAILED,
            OtaModels.ReasonCodes.BUNDLE_CHECKSUM_FAILED,
            "expected=${artifact.bundleSha256}, actual=$actualSha256",
            null,
            null,
            elapsedMillis(downloadStartedAt),
            OtaModels.ReasonCodes.BUNDLE_CHECKSUM_FAILED,
          ),
        )
        throw OtaSdkException.checksumMismatch(artifact.bundleSha256, actualSha256)
      }
      downloadedBundleCount += 1
      installedBundles.add(
        OtaModels.InstalledBundle(
          artifact.pageId,
          artifact.bundlePath,
          artifact.bundleSha256,
          artifact.bundleUrl,
          localPath.toString(),
        ),
      )
      report(
        OtaModels.ReportEvent.DOWNLOAD_SUCCESS,
        manifest.releaseId,
        manifest.lynxAppId,
        artifact.pageId,
        artifact.bundlePath,
        artifact.bundleSha256,
        artifact.size,
        ReportDetails(
          OtaModels.ReportEventStage.DOWNLOAD,
          OtaModels.ReportEventResult.SUCCESS,
          null,
          null,
          null,
          null,
          elapsedMillis(downloadStartedAt),
          "bundle_downloaded",
        ),
      )
    }

    val installed = OtaModels.InstalledRelease(
      OtaModels.CurrentReleaseContext(
        manifest.env,
        manifest.hostApp,
        manifest.lynxAppId,
        manifest.releaseId,
        manifest.platform,
        OtaModels.ReleaseStatus.ACTIVE,
      ),
      Instant.now(),
      installedBundles,
    )
    return DownloadOutcome(
      installed,
      OtaModels.BundleSyncSummary(
        manifest.releaseId,
        manifest.bundles.size,
        downloadedBundleCount,
        reusedBundleCount,
      ),
    )
  }

  @Throws(IOException::class)
  private fun reusableReleaseSnapshot(
    current: OtaModels.InstalledRelease?,
    lynxAppId: String,
  ): OtaModels.InstalledRelease? {
    val embedded = store.embeddedRelease(lynxAppId)
    val candidates = ArrayList<OtaModels.InstalledRelease>()
    if (current != null) {
      candidates.add(current)
    }
    if (embedded != null) {
      candidates.add(embedded)
    }
    if (candidates.isEmpty()) {
      return null
    }

    val reusableBundles = LinkedHashMap<String, OtaModels.InstalledBundle>()
    for (release in candidates) {
      for (bundle in release.bundles) {
        if (!File(bundle.localFilePath).isFile) {
          continue
        }
        reusableBundles.putIfAbsent("${bundle.bundlePath}#${bundle.bundleSha256.lowercase()}", bundle)
      }
    }
    if (reusableBundles.isEmpty()) {
      return null
    }
    val basis = current ?: embedded!!
    return OtaModels.InstalledRelease(basis.context, Instant.now(), ArrayList(reusableBundles.values))
  }

  private fun reusableInstalledBundle(
    artifact: OtaModels.BundleArtifact,
    release: OtaModels.InstalledRelease?,
  ): OtaModels.InstalledBundle? {
    if (release == null) {
      return null
    }
    for (bundle in release.bundles) {
      if (bundle.bundlePath != artifact.bundlePath) {
        continue
      }
      if (!bundle.bundleSha256.equals(artifact.bundleSha256, ignoreCase = true)) {
        continue
      }
      if (!File(bundle.localFilePath).isFile) {
        continue
      }
      return bundle
    }
    return null
  }

  private fun versionMismatchMessage(latest: OtaModels.LatestBundleList): String? {
    val appVersionMessage = mismatchMessage("App 版本", configuration.appVersion, latest.minAppVersion, latest.maxAppVersion)
    if (appVersionMessage != null) {
      return appVersionMessage
    }
    val lynxBaselineMessage = mismatchMessage("Lynx 基线版本", configuration.lynxSdkVersion, latest.lynxSdkRange)
    if (lynxBaselineMessage != null) {
      return lynxBaselineMessage
    }
    return mismatchMessage("Native 协议版本", configuration.nativeProtocolVersion, latest.nativeProtocolVersionRange)
  }

  private fun mismatchMessage(label: String, version: String?, range: OtaModels.ReleaseVersionRange?): String? {
    if (range == null) {
      return null
    }
    return mismatchMessage(label, version, range.min, range.max)
  }

  private fun mismatchMessage(label: String, version: String?, minVersion: String?, maxVersion: String?): String? {
    if (minVersion.isNullOrBlank() && maxVersion.isNullOrBlank()) {
      return null
    }
    if (version.isNullOrBlank()) {
      return "跳过热更：${label}未上报，要求范围 ${describeRange(minVersion, maxVersion)}"
    }
    if (!minVersion.isNullOrBlank()) {
      val compared = compareVersion(version, minVersion)
      if (compared == null) {
        return "跳过热更：$label $version 无法参与版本比较，要求范围 ${describeRange(minVersion, maxVersion)}"
      }
      if (compared < 0) {
        return "跳过热更：$label $version 低于要求范围 ${describeRange(minVersion, maxVersion)}"
      }
    }
    if (!maxVersion.isNullOrBlank()) {
      val compared = compareVersion(version, maxVersion)
      if (compared == null) {
        return "跳过热更：$label $version 无法参与版本比较，要求范围 ${describeRange(minVersion, maxVersion)}"
      }
      if (compared > 0) {
        return "跳过热更：$label $version 高于要求范围 ${describeRange(minVersion, maxVersion)}"
      }
    }
    return null
  }

  private fun describeRange(minVersion: String?, maxVersion: String?): String {
    val min = if (minVersion.isNullOrBlank()) "*" else minVersion
    val max = if (maxVersion.isNullOrBlank()) "*" else maxVersion
    return "[$min, $max]"
  }

  private fun compareVersion(left: String, right: String): Int? {
    val leftParts = left.split(".")
    val rightParts = right.split(".")
    val length = maxOf(leftParts.size, rightParts.size)
    for (index in 0 until length) {
      val leftPart = if (index < leftParts.size) leftParts[index] else "0"
      val rightPart = if (index < rightParts.size) rightParts[index] else "0"
      val compared = compareVersionPart(leftPart, rightPart) ?: return null
      if (compared != 0) {
        return compared
      }
    }
    return 0
  }

  private fun compareVersionPart(left: String, right: String): Int? {
    val leftNumber = parseVersionNumber(left)
    val rightNumber = parseVersionNumber(right)
    if (leftNumber == null || rightNumber == null) {
      return null
    }
    return leftNumber.compareTo(rightNumber)
  }

  private fun parseVersionNumber(raw: String?): Int? {
    if (raw.isNullOrBlank()) {
      return 0
    }
    if (!raw.all { it.isDigit() }) {
      return null
    }
    return try {
      raw.toInt()
    } catch (error: NumberFormatException) {
      null
    }
  }

  private fun hasAllLocalBundles(release: OtaModels.InstalledRelease): Boolean {
    for (bundle in release.bundles) {
      val file = File(bundle.localFilePath)
      if (!file.isFile) {
        return false
      }
      if (!runCatching { OtaIO.sha256(file) }
          .getOrNull()
          .equals(bundle.bundleSha256, ignoreCase = true)
      ) {
        return false
      }
    }
    return true
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  private fun reportLatestBundleListFailure(lynxAppId: String?, error: Throwable, reasonCode: String) {
    report(
      OtaModels.ReportEvent.CHECK_RESULT,
      null,
      lynxAppId,
      null,
      null,
      null,
      null,
      ReportDetails(
        OtaModels.ReportEventStage.CHECK,
        OtaModels.ReportEventResult.FAILED,
        reasonCode,
        error.message,
        null,
        null,
        null,
        reasonCode,
      ),
    )
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  private fun report(
    event: OtaModels.ReportEvent,
    releaseId: String?,
    lynxAppId: String?,
    pageId: Int?,
    bundlePath: String?,
    bundleSha256: String?,
    bundleSize: Int?,
    details: ReportDetails?,
  ) {
    apiClient.reportEvent(
      OtaModels.ReportPayload(
        configuration.environment,
        configuration.hostApp,
        lynxAppId ?: configuration.lynxAppId,
        releaseId,
        configuration.platform,
        event,
        pageId,
        configuration.userId,
        configuration.deviceId,
        configuration.deviceModel,
        configuration.appVersion,
        configuration.buildNumber,
        configuration.osVersion,
        configuration.channel,
        configuration.region,
        configuration.nativeProtocolVersion,
        configuration.lynxSdkVersion,
        bundlePath,
        bundleSha256,
        bundleSize,
        details?.eventStage,
        details?.eventResult,
        details?.reasonCode,
        details?.reasonMessage,
        details?.fromReleaseId,
        details?.toReleaseId,
        details?.latencyMs,
        details?.message,
      ),
    )
  }

  private fun elapsedMillis(startedAt: Long): Int {
    var elapsed = System.currentTimeMillis() - startedAt
    if (elapsed < 0) {
      elapsed = 0
    }
    return elapsed.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
  }

  private data class DownloadOutcome(
    val installed: OtaModels.InstalledRelease,
    val summary: OtaModels.BundleSyncSummary,
  )

  private data class ReportDetails(
    val eventStage: OtaModels.ReportEventStage?,
    val eventResult: OtaModels.ReportEventResult?,
    val reasonCode: String?,
    val reasonMessage: String?,
    val fromReleaseId: String?,
    val toReleaseId: String?,
    val latencyMs: Int?,
    val message: String?,
  )
}
