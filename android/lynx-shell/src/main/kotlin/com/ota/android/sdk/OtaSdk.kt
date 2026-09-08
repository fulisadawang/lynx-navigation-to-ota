package com.ota.android.sdk

import java.io.File
import java.io.IOException

class OtaSdk {
  private val configuration: OtaModels.Configuration
  private val userContext: OtaUserContextBox
  private val apiClient: OtaApiClient
  private val embeddedStore: EmbeddedReleaseStore
  private val releaseTransaction: OtaReleaseStore
  private val bundleRuntime: BundleRuntime

  constructor(configuration: OtaModels.Configuration) : this(
    configuration,
    OtaApiClient.server(
      configuration.apiBaseUri,
      configuration.otaClientToken,
      configuration.environment,
      configuration.allowLocalHTTPForTest,
    ),
  )

  @JvmOverloads constructor(configuration: OtaModels.Configuration, apiClient: OtaApiClient, faultInjector: ContentAddressedFaultInjecting = ContentAddressedFaultInjecting.NONE) {
    this.configuration = configuration
    this.userContext = OtaUserContextBox(configuration)
    this.apiClient = apiClient
    this.embeddedStore = EmbeddedReleaseStore(configuration.storageDirectory)
    this.releaseTransaction = when (configuration.storeVersion) {
      OtaModels.StoreVersion.V2 -> LegacyOtaReleaseStore(configuration.storageDirectory)
      OtaModels.StoreVersion.V3 -> ContentAddressedOtaStore(
        configuration.storageDirectory,
        faultInjector = faultInjector,
        allowLocalHTTPForTest = configuration.allowLocalHTTPForTest,
        environment = configuration.environment,
      ).also { it.bindUserContext(userContext) }
    }
    this.bundleRuntime = BundleRuntime(releaseTransaction)
  }

  val userIdentityEpoch: Long get() = userContext.identityEpoch
  fun registerUserId(userId: String?): Boolean = userContext.register(userId)
  fun invalidatePendingOperations() { userContext.invalidate() }

  fun <T> withUserIdentity(expectedIdentityEpoch: Long, operation: () -> T): T {
    val identity = userContext.operation()
    if (identity.identityEpoch != expectedIdentityEpoch) throw OtaSelectionException("stale_identity")
    return OtaOperationContext.withIdentity(identity) {
      val result = operation()
      try { userContext.validate(identity) }
      catch (error: Throwable) {
        if (result is AutoCloseable) runCatching { result.close() }
        throw error
      }
      result
    }
  }

  private fun <T> identityScope(operation: () -> T): T {
    if (userContext.enabled) requireSelectionStore()
    return withUserIdentity(userContext.operation().identityEpoch, operation)
  }

  fun reconcileUserContext() = identityScope { releaseTransaction.reconcileUserContext() }

  fun acquireCandidateTrialBundleLease(lynxAppId: String, bundleName: String): ReleaseTransaction.BundleLease? = identityScope {
    releaseTransaction.acquireCandidateTrialBundleLease(scopeFor(lynxAppId), bundleName)
  }

  @Throws(IOException::class)
  fun initializeEmbeddedRelease(release: OtaModels.InstalledRelease) {
    return identityScope {
      releaseTransaction.registerEmbeddedRelease(release)
    }
  }

  /** 按 appId 直接删除磁盘中的全部下载 Bundle，保留 APK 内置 embedded 描述。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteDownloadedBundles(lynxAppId: String) {
    return identityScope {
      releaseTransaction.deleteDownloadedBundles(lynxAppId)
    }
  }

  /** 直接删除磁盘中的全部 appId 下载 Bundle，保留 APK 内置 embedded 描述。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun deleteAllDownloadedBundles() {
    return identityScope {
      releaseTransaction.deleteAllDownloadedBundles()
    }
  }

  /** 兼容旧验收入口；语义仍然是直接删除全部下载内容。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun clearDownloadedBundles() = deleteAllDownloadedBundles()

  /** 冷启动维护，不联网；清理不再被 state/candidate/lease 引用的目录。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun pruneUnreferencedBundles() {
    return identityScope {
      releaseTransaction.pruneAllUnreferencedReleases()
    }
  }

  @Throws(IOException::class)
  fun getCurrentRelease(lynxAppId: String): OtaModels.InstalledRelease? {
    return identityScope {
      if (userContext.enabled && configuration.storeVersion != OtaModels.StoreVersion.V3) throw OtaSelectionException("requires_store_v3")
      val current = releaseTransaction.current(scopeFor(lynxAppId))
      return@identityScope if (userContext.enabled) current else current ?: embeddedStore.embeddedRelease(lynxAppId)
    }
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun checkForUpdate(request: OtaModels.PolicyMatchRequest): OtaModels.PolicyMatchResponse {
    return identityScope {
      return@identityScope apiClient.checkForUpdate(request)
    }
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun fetchManifest(
    releaseId: String,
    env: OtaModels.Environment,
    hostApp: OtaModels.HostApp,
    lynxAppId: String,
    platform: OtaModels.Platform,
  ): OtaModels.ReleaseManifest {
    return identityScope {
      return@identityScope apiClient.fetchManifest(releaseId, env, hostApp, lynxAppId, platform)
    }
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun reportEvent(payload: OtaModels.ReportPayload) {
    return identityScope {
      val identity = userContext.operation()
      apiClient.reportEvent(if (identity.selectionEnabled) payload.copy(userId = identity.userId,
        versioncode = identity.versionCode, lynxSdkVersion = identity.lynxSdkVersion) else payload)
    }
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun syncLatestBundleLists(): OtaModels.HostBundleListSyncResult {
    return identityScope {
      if (userContext.enabled) return@identityScope syncSelectedBundleLists()
      val latestGroup: OtaModels.HostLatestBundleLists = try {
        apiClient.fetchLatestBundleLists(
          configuration.environment,
          configuration.hostApp,
          configuration.platform,
        )
      } catch (error: OtaSdkException) {
        if (error.message != null && error.message!!.startsWith("服务端响应异常：404")) {
          return@identityScope OtaModels.HostBundleListSyncResult(LinkedHashMap())
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
      return@identityScope OtaModels.HostBundleListSyncResult(results)
    }
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
    return identityScope {
      if (userContext.enabled) return@identityScope syncSelectedBundleList(lynxAppId)
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
      return@identityScope updateToLatestBundleList(latest)
    }
  }

  @Throws(IOException::class)
  fun currentTemplatePath(lynxAppId: String, pageId: Int): File? {
    return identityScope {
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
            return@identityScope resolved
          }
        }
      }
      val current = getCurrentRelease(lynxAppId) ?: return@identityScope null
      for (bundle in current.bundles) {
        if (bundle.pageId == pageId) {
          return@identityScope File(bundle.localFilePath)
        }
      }
      return@identityScope null
    }
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun reportPageOpen(pageId: Int, lynxAppId: String?, bundlePath: String?) {
    return identityScope {
      val scopedLynxAppId = lynxAppId ?: configuration.lynxAppId ?: return@identityScope
      val current = getCurrentRelease(scopedLynxAppId) ?: return@identityScope
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
  }

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun rollback(reason: String): OtaModels.InstalledRelease? {
    return identityScope {
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
      return@identityScope restored
    }
  }

  /** 按 lynxAppId + bundleName 精确读取已提交 current 的 Bundle。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String, bundleName: String): File? {
    return identityScope {
      return@identityScope bundleRuntime.current(scopeFor(lynxAppId), bundleName)
    }
  }

  /** 为活体容器原子解析 current Bundle，并持有到容器销毁。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun acquireCurrentBundleLease(
    lynxAppId: String,
    bundleName: String,
  ): ReleaseTransaction.BundleLease? {
    return identityScope {
      return@identityScope releaseTransaction.acquireCurrentBundleLease(scopeFor(lynxAppId), bundleName)
    }
  }

  /** 读取指定 appId 的 Store v2 current；无 state 时回退 embedded 描述。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun current(lynxAppId: String): OtaModels.InstalledRelease? {
    return identityScope {
      return@identityScope releaseTransaction.current(scopeFor(lynxAppId)) ?: getCurrentRelease(lynxAppId)
    }
  }

  /** 返回持久化 candidate；current 读取入口不会消费候选版本。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun candidate(lynxAppId: String): OtaModels.CandidateSnapshot? {
    return identityScope {
      return@identityScope releaseTransaction.candidate(scopeFor(lynxAppId))
    }
  }

  /** 页面真正使用 candidate 时进入 trial；重复调用保持幂等。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun beginCandidateTrial(lynxAppId: String): OtaModels.CandidateSnapshot {
    return identityScope {
      return@identityScope releaseTransaction.beginCandidateTrial(scopeFor(lynxAppId))
    }
  }

  /** 健康确认后原子 promote candidate，并把旧 current 写入 previous。 */
  @Throws(IOException::class, OtaSdkException::class)
  @JvmOverloads
  fun confirmCandidateHealthy(lynxAppId: String, expectedReleaseId: String? = null, expectedIdentityEpoch: Long? = null): OtaModels.InstalledRelease {
    return identityScope {
      val identity = userContext.operation()
      if (expectedIdentityEpoch != null && expectedIdentityEpoch != identity.identityEpoch) throw OtaSelectionException("stale_identity")
      val confirmed = OtaOperationContext.withCandidate(expectedReleaseId) { releaseTransaction.confirmCandidate(scopeFor(lynxAppId)) }
      if (userContext.enabled) runCatching {
        report(OtaModels.ReportEvent.ACTIVATE, confirmed.context.releaseId, lynxAppId, null, null, null, null,
          ReportDetails(OtaModels.ReportEventStage.ACTIVATE, OtaModels.ReportEventResult.SUCCESS, null, null, null, null, null, "candidate_confirmed_healthy"))
      }
      return@identityScope confirmed
    }
  }

  @Throws(IOException::class, OtaSdkException::class)
  @JvmOverloads
  fun discardCandidate(lynxAppId: String, expectedReleaseId: String? = null, expectedIdentityEpoch: Long? = null) {
    return identityScope {
      val identity = userContext.operation()
      if (expectedIdentityEpoch != null && expectedIdentityEpoch != identity.identityEpoch) throw OtaSelectionException("stale_identity")
      OtaOperationContext.withCandidate(expectedReleaseId) { releaseTransaction.discardCandidate(scopeFor(lynxAppId)) }
    }
  }

  @Throws(IOException::class, OtaSdkException::class)
  fun recoverInterruptedCandidate(lynxAppId: String) {
    return identityScope {
      releaseTransaction.recoverInterruptedCandidate(scopeFor(lynxAppId))
    }
  }

  /** 按 candidate 的 Release 精确读取 Bundle，不改变 current。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun candidateBundle(lynxAppId: String, bundleName: String): File? {
    return identityScope {
      return@identityScope releaseTransaction.candidateBundle(scopeFor(lynxAppId), bundleName)
    }
  }

  /** 为 candidate trial 页面原子解析 Bundle，并持有到容器销毁。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun acquireCandidateBundleLease(
    lynxAppId: String,
    bundleName: String,
  ): ReleaseTransaction.BundleLease? {
    return identityScope {
      return@identityScope releaseTransaction.acquireCandidateBundleLease(scopeFor(lynxAppId), bundleName)
    }
  }

  /** NavigationSnapshot 按固定 releaseId 解析 Bundle，防止路由中途切换到新 current。 */
  @Throws(IOException::class, OtaSdkException::class)
  fun acquireBundleLeaseForRelease(
    lynxAppId: String,
    releaseId: String,
    bundleName: String,
  ): ReleaseTransaction.BundleLease? {
    return identityScope {
      return@identityScope releaseTransaction.acquireBundleLeaseForRelease(scopeFor(lynxAppId), releaseId, bundleName)
    }
  }

  /** 路由进入 Lynx 容器前的 Bundle 门禁，失败不会读取 staging/part 文件。 */
  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  fun ensureBundleReady(lynxAppId: String, bundleName: String): File {
    return identityScope {
      val scope = scopeFor(lynxAppId)
      try {
        // 热路径只读已提交 current；命中时不会因为一次页面跳转重复请求 Manifest。
        return@identityScope bundleRuntime.ensureBundleReady(scope, bundleName)
      } catch (error: OtaSdkException) {
        // 缺包或 SHA 不一致都进入当前 appId 的 latest snapshot 修复；其它编程/路径错误原样抛出。
        val repairable = error.reasonCode == "bundle_not_found" ||
          error.reasonCode == "bundle_checksum_failed"
        if (!repairable) throw error
      }

      // 页面打开只请求当前 appId 的 latest 列表；全量同步只由 Application 启动/前台触发。
      syncLatestBundleList(lynxAppId)
      return@identityScope bundleRuntime.ensureBundleReady(scope, bundleName)
    }
  }

  /** 新增按 appId 的 rollback 入口，旧 rollback(reason) 继续保留。 */
  @Throws(IOException::class, OtaSdkException::class)
  @JvmOverloads
  fun rollback(lynxAppId: String, reason: String, expectedReleaseId: String? = null, expectedIdentityEpoch: Long? = null): OtaModels.InstalledRelease? {
    return identityScope {
      val identity = userContext.operation()
      if (expectedIdentityEpoch != null && expectedIdentityEpoch != identity.identityEpoch) throw OtaSelectionException("stale_identity")
      return@identityScope OtaOperationContext.withCurrentRelease(expectedReleaseId) {
        if (lynxAppId == configuration.lynxAppId) rollback(reason) else releaseTransaction.rollback(scopeFor(lynxAppId))
      }
    }
  }

  private fun scopeFor(lynxAppId: String): ReleaseTransaction.ReleaseScope {
    return ReleaseTransaction.ReleaseScope(
      configuration.environment,
      configuration.hostApp,
      lynxAppId,
      configuration.platform,
    )
  }

  private fun syncSelectedBundleList(lynxAppId: String): OtaModels.LatestBundleListUpdateResult {
    requireSelectionStore()
    val identity = userContext.operation()
    val response = try {
      apiClient.fetchLatestBundleList(configuration.environment, configuration.hostApp, lynxAppId, configuration.platform, identity)
    } catch (error: Exception) { reportSelectionFailure(lynxAppId, null, queryFailureCode(error)); throw error }
    userContext.validate(identity)
    val selection = try {
      when (response) {
        is OtaLatestSelection.Release -> {
          if (response.bundleList.lynxAppId != lynxAppId) throw OtaSelectionException("invalid_selection_metadata")
          OtaStoredSelection.fromLatest(response.bundleList, identity)
        }
        is OtaLatestSelection.Directive -> {
          if (response.directive.lynxAppId != lynxAppId) throw OtaSelectionException("invalid_selection_metadata")
          response.directive.validate(); null
        }
      }
    } catch (error: Exception) { reportSelectionFailure(lynxAppId, null, OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_DECODE_FAILED); throw error }
    return when (response) {
      is OtaLatestSelection.Directive -> applyDirective(response.directive, identity)
      is OtaLatestSelection.Release -> try {
        recordSelected(response.bundleList, selection!!, identity)
        applySelected(response.bundleList, selection, identity)
      } catch (error: Exception) {
        if (!obsolete(error)) reportSelectionFailure(lynxAppId, response.bundleList.releaseId, updateFailureCode(error))
        throw error
      }
    }
  }

  private fun syncSelectedBundleLists(): OtaModels.HostBundleListSyncResult {
    requireSelectionStore()
    val identity = userContext.operation()
    val group = try {
      apiClient.fetchLatestBundleLists(configuration.environment, configuration.hostApp, configuration.platform, identity)
    } catch (error: Exception) { reportSelectionFailure(configuration.lynxAppId, null, queryFailureCode(error)); throw error }
    userContext.validate(identity)
    val selections = try {
      if (group.selectionSchemaVersion != 1 || group.env != identity.env || group.hostApp != identity.hostApp || group.platform != identity.platform) throw OtaSelectionException("missing_selection_metadata")
      val ids = group.bundleLists.map { it.lynxAppId } + group.directives.map { it.lynxAppId }
      if (ids.toSet().size != ids.size) throw OtaSelectionException("invalid_selection_metadata")
      group.directives.forEach { it.validate() }
      group.bundleLists.associate { it.lynxAppId to OtaStoredSelection.fromLatest(it, identity) }
    } catch (error: Exception) { reportSelectionFailure(configuration.lynxAppId, null, OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_DECODE_FAILED); throw error }
    val results = LinkedHashMap<String, OtaModels.LatestBundleListUpdateResult>()
    val failures = LinkedHashMap<String, OtaAppBundleListSyncFailure>()
    fun failed(appId: String, stage: OtaAppBundleListSyncFailure.Stage, error: Exception) {
      userContext.validate(identity)
      if (error is InterruptedException || Thread.currentThread().isInterrupted) throw error
      failures[appId] = OtaAppBundleListSyncFailure(stage, error)
    }
    group.directives.forEach { directive ->
      try { results[directive.lynxAppId] = applyDirective(directive, identity) }
      catch (error: Exception) { failed(directive.lynxAppId, OtaAppBundleListSyncFailure.Stage.DECISION, error) }
    }
    group.bundleLists.forEach { latest ->
      try { recordSelected(latest, selections.getValue(latest.lynxAppId), identity) }
      catch (error: Exception) { failed(latest.lynxAppId, OtaAppBundleListSyncFailure.Stage.DECISION, error) }
    }
    group.bundleLists.filter { it.lynxAppId !in failures }.forEach { latest ->
      try { results[latest.lynxAppId] = applySelected(latest, selections.getValue(latest.lynxAppId), identity) }
      catch (error: Exception) {
        failed(latest.lynxAppId, OtaAppBundleListSyncFailure.Stage.UPDATE, error)
        if (!obsolete(error)) reportSelectionFailure(latest.lynxAppId, latest.releaseId, updateFailureCode(error))
      }
    }
    userContext.validate(identity)
    val result = OtaModels.HostBundleListSyncResult(results)
    if (failures.isNotEmpty()) throw OtaHostBundleListSyncException(result, failures.toMap())
    return result
  }

  private fun requireSelectionStore() {
    if (configuration.storeVersion != OtaModels.StoreVersion.V3) throw OtaSelectionException("requires_store_v3")
  }

  private fun recordSelected(latest: OtaModels.LatestBundleList, selection: OtaStoredSelection, identity: OtaUserContext) {
    releaseTransaction.recordDecision(scopeFor(latest.lynxAppId),
      OtaLastDecision(identity.audienceKey, identity.clientContextKey, selection.policyRevision, OtaSelectionAction.USE_RELEASE, latest.releaseId, latest.selection!!.reason), selection)
  }

  private fun applyDirective(directive: OtaSelectionDirective, identity: OtaUserContext): OtaModels.LatestBundleListUpdateResult {
    directive.validate()
    releaseTransaction.recordDecision(scopeFor(directive.lynxAppId),
      OtaLastDecision(identity.audienceKey, identity.clientContextKey, directive.policyRevision, directive.action, null, directive.reason), null)
    return OtaModels.LatestBundleListUpdateResult.noRelease(getCurrentRelease(directive.lynxAppId))
  }

  private fun applySelected(latest: OtaModels.LatestBundleList, selection: OtaStoredSelection, identity: OtaUserContext): OtaModels.LatestBundleListUpdateResult {
    userContext.validate(identity)
    if (!selection.compatible(identity)) throw OtaSelectionException("incompatible_release")
    return OtaOperationContext.withSelection(selection) {
      val outcome = releaseTransaction.install(ReleaseTransaction.InstallRequest(scopeFor(latest.lynxAppId), latest.asManifest(),
        embeddedStore.embeddedRelease(latest.lynxAppId), configuration.candidateActivationEnabled, selection))
      userContext.validate(identity)
      val installed = outcome.installed ?: throw OtaSelectionException("missing_selection_metadata")
      val summary = OtaModels.BundleSyncSummary(latest.releaseId, latest.changedBundles.size, outcome.downloadedBundleCount, outcome.reusedBundleCount, outcome.copiedBundleCount)
      val result = when (outcome.type) {
        ReleaseTransaction.InstallResultType.ALREADY_ACTIVE -> OtaModels.LatestBundleListUpdateResult.alreadyActive(installed)
        ReleaseTransaction.InstallResultType.CANDIDATE -> {
          val candidate = releaseTransaction.candidate(scopeFor(latest.lynxAppId)) ?: throw OtaSelectionException("stale_candidate")
          OtaModels.LatestBundleListUpdateResult.candidate(outcome.current, candidate, summary)
        }
        else -> OtaModels.LatestBundleListUpdateResult.updated(outcome.current, installed, summary)
      }
      if (outcome.downloadedBundleCount > 0) selectionReport(OtaModels.ReportEvent.DOWNLOAD_SUCCESS, latest, OtaModels.ReportEventStage.DOWNLOAD, "bundle_downloaded")
      if (outcome.type == ReleaseTransaction.InstallResultType.UPDATED) selectionReport(OtaModels.ReportEvent.ACTIVATE, latest, OtaModels.ReportEventStage.ACTIVATE, "release_activated")
      selectionReport(OtaModels.ReportEvent.CHECK_RESULT, latest, OtaModels.ReportEventStage.CHECK,
        if (outcome.type == ReleaseTransaction.InstallResultType.CANDIDATE) "candidate_staged" else "latest_bundle_list_checked")
      userContext.validate(identity)
      result
    }
  }

  private fun selectionReport(event: OtaModels.ReportEvent, latest: OtaModels.LatestBundleList, stage: OtaModels.ReportEventStage, message: String) {
    runCatching { report(event, latest.releaseId, latest.lynxAppId, null, null, null, null,
      ReportDetails(stage, OtaModels.ReportEventResult.SUCCESS, null, null, null, null, null, message)) }
  }

  private fun reportSelectionFailure(appId: String?, releaseId: String?, code: String) {
    runCatching { report(OtaModels.ReportEvent.CHECK_RESULT, releaseId, appId, null, null, null, null,
      ReportDetails(OtaModels.ReportEventStage.CHECK, OtaModels.ReportEventResult.FAILED, code, code, null, null, null, code)) }
  }
  private fun queryFailureCode(error: Exception): String = if (error is OtaSelectionException || error is IllegalArgumentException) OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_DECODE_FAILED else OtaModels.ReasonCodes.LATEST_BUNDLE_LIST_FETCH_FAILED
  private fun updateFailureCode(error: Exception): String = if ((error as? OtaSdkException)?.reasonCode == "incompatible_release") OtaModels.ReasonCodes.BASELINE_BLOCKED else (error as? OtaSdkException)?.reasonCode ?: OtaModels.ReasonCodes.RELEASE_ACTIVATE_FAILED
  private fun obsolete(error: Exception): Boolean = error is InterruptedException || (error as? OtaSdkException)?.reasonCode in setOf("stale_identity", "stale_decision", "stale_candidate")

  @Throws(IOException::class, InterruptedException::class, OtaSdkException::class)
  private fun updateToLatestBundleList(latest: OtaModels.LatestBundleList): OtaModels.LatestBundleListUpdateResult {
    val latestScope = ReleaseTransaction.ReleaseScope.fromManifest(latest.asManifest())
    if (configuration.candidateActivationEnabled) {
      // trial 只允许由真正打开页面的路径消费；进程重启时未完成 trial 必须清理，
      // 但 pending candidate 可以保留，等待页面首次访问后再进入 trial。
      runCatching { releaseTransaction.recoverInterruptedCandidate(latestScope) }
    }
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

    if (configuration.candidateActivationEnabled) {
      val existingCandidate = runCatching { releaseTransaction.candidate(latestScope) }.getOrNull()
      if (existingCandidate != null && existingCandidate.release.context.releaseId != latest.releaseId) {
        runCatching { releaseTransaction.discardCandidate(latestScope) }
      } else if (existingCandidate != null && existingCandidate.release.context.releaseId == latest.releaseId) {
        return OtaModels.LatestBundleListUpdateResult.candidate(
          previous = current,
          candidate = existingCandidate,
          summary = OtaModels.BundleSyncSummary(
            latest.releaseId,
            latest.changedBundles.size,
            0,
            latest.changedBundles.size,
            0,
          ),
        )
      }
    }

    val manifest = latest.asManifest()
    val scope = ReleaseTransaction.ReleaseScope.fromManifest(manifest)
    val transaction = try {
      // 所有新下载都经过同一个 Release 事务：Bundle 写入 appId staging，完整校验后再
      // 原子发布并提交 current/previous state。
      releaseTransaction.install(
        ReleaseTransaction.InstallRequest(
          scope = scope,
          targetManifest = manifest,
          embeddedDescriptor = embeddedStore.embeddedRelease(latest.lynxAppId),
          stageAsCandidate = configuration.candidateActivationEnabled,
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
    if (configuration.candidateActivationEnabled) {
      val candidate = releaseTransaction.candidate(scope)
      if (candidate == null) {
        /*
         * 页面可以在 install 返回后立即消费 candidate：首屏健康会 promote，
         * 首屏失败会 discard。后台同步此时再次读取 candidate 看到 null 是一个
         * 合法的并发结果，不能把它误报成激活失败，也不能覆盖页面已经保留的 current。
         */
        val currentAfterCandidateConsumption = getCurrentRelease(latest.lynxAppId)
        return if (
          currentAfterCandidateConsumption != null &&
          currentAfterCandidateConsumption.context.releaseId == manifest.releaseId &&
          hasAllLocalBundles(currentAfterCandidateConsumption)
        ) {
          OtaModels.LatestBundleListUpdateResult.alreadyActive(currentAfterCandidateConsumption)
        } else {
          OtaModels.LatestBundleListUpdateResult.noRelease(currentAfterCandidateConsumption ?: current)
        }
      }
      return OtaModels.LatestBundleListUpdateResult.candidate(
        previous = current,
        candidate = candidate,
        summary = OtaModels.BundleSyncSummary(
          manifest.releaseId,
          manifest.bundles.size,
          transaction.downloadedBundleCount,
          transaction.reusedBundleCount,
          transaction.copiedBundleCount,
        ),
      )
    }
    val outcome = OtaModels.BundleSyncSummary(
      manifest.releaseId,
      manifest.bundles.size,
      transaction.downloadedBundleCount,
      transaction.reusedBundleCount,
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
    // embedded descriptor 的 localFilePath 是受控 asset URI，不是 filesDir 普通文件；它的
    // 内容由宿主 EmbeddedBundleRegistry 在真正交付 LynxView 时从 APK AssetManager 校验。
    if (embeddedStore.embeddedRelease(release.context.lynxAppId)?.context?.releaseId == release.context.releaseId) {
      return true
    }
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
        (OtaOperationContext.identity ?: userContext.capture()).userId,
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
        (OtaOperationContext.identity ?: userContext.capture()).versionCode,
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
