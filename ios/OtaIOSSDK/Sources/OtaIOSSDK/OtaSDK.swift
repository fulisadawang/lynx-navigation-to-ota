import Foundation

/// 进程内 Bundle 完整性校验结果缓存；不保存 Bundle bytes，也不写入磁盘。
struct OtaBundleValidationCache<Key: Hashable & Sendable>: Sendable {
    private let maxEntries: Int
    private var entries: [Key: UInt64] = [:]
    private var accessCounter: UInt64 = 0

    init(maxEntries: Int = 128) {
        precondition(maxEntries > 0, "Bundle 校验缓存容量必须大于 0")
        self.maxEntries = maxEntries
    }

    mutating func contains(_ key: Key) -> Bool {
        guard entries[key] != nil else { return false }
        accessCounter &+= 1
        entries[key] = accessCounter
        return true
    }

    mutating func insert(_ key: Key) {
        accessCounter &+= 1
        entries[key] = accessCounter
        trimIfNeeded()
    }

    mutating func remove(_ key: Key) {
        entries.removeValue(forKey: key)
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        entries.keys.filter(shouldRemove).forEach { entries.removeValue(forKey: $0) }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    var count: Int { entries.count }

    private mutating func trimIfNeeded() {
        while entries.count > maxEntries {
            guard let oldest = entries.min(by: { $0.value < $1.value })?.key else { return }
            entries.removeValue(forKey: oldest)
        }
    }
}

public actor OtaSDK {
    private struct BundleValidationKey: Hashable, Sendable {
        let app: String
        let lynxAppId: String
        let releaseId: String
        let bundleName: String
        let expectedSha256: String
        let fileSize: Int64
        let modificationTime: TimeInterval
        let fileIdentifier: UInt64
    }

    private struct DownloadOutcome: Sendable {
        let installed: OtaInstalledRelease
        let summary: OtaBundleSyncSummary
        let temporaryDirectory: URL?
    }

    private let configuration: OtaSDKConfiguration
    private let apiClient: OtaAPIClientProtocol
    private let releaseTransaction: ReleaseTransaction
    private let bundleRuntime: BundleRuntime
    private let downloader: OtaBundleDownloading
    private let checksumValidator: OtaChecksumValidating
    private var validatedBundleCache = OtaBundleValidationCache<BundleValidationKey>()

    private var lifecycleState: OtaLifecycleState = .idle(current: nil)

    public init(
        configuration: OtaSDKConfiguration,
        apiClient: OtaAPIClientProtocol? = nil,
        store: FileOtaReleaseStore? = nil,
        downloader: OtaBundleDownloading? = nil,
        checksumValidator: OtaChecksumValidating = SHA256ChecksumValidator()
    ) {
        self.init(
            configuration: configuration,
            apiClient: apiClient,
            store: store,
            downloader: downloader,
            checksumValidator: checksumValidator,
            transactionFaultInjectorOptional: nil
        )
    }

#if DEBUG
    /** 仅供同一 Debug Target 的 XCUITest 进程中断恢复 harness 使用。 */
    init(
        configuration: OtaSDKConfiguration,
        apiClient: OtaAPIClientProtocol? = nil,
        store: FileOtaReleaseStore? = nil,
        downloader: OtaBundleDownloading? = nil,
        checksumValidator: OtaChecksumValidating = SHA256ChecksumValidator(),
        transactionFaultInjector: any OtaTransactionFaultInjecting
    ) {
        self.init(
            configuration: configuration,
            apiClient: apiClient,
            store: store,
            downloader: downloader,
            checksumValidator: checksumValidator,
            transactionFaultInjectorOptional: transactionFaultInjector
        )
    }
#endif

    private init(
        configuration: OtaSDKConfiguration,
        apiClient: OtaAPIClientProtocol?,
        store: FileOtaReleaseStore?,
        downloader: OtaBundleDownloading?,
        checksumValidator: OtaChecksumValidating,
        transactionFaultInjectorOptional: (any OtaTransactionFaultInjecting)?
    ) {
        self.configuration = configuration
        self.apiClient = apiClient ?? ServerOtaAPIClient(
            baseURL: configuration.apiBaseURL,
            otaClientToken: configuration.otaClientToken
        )
        let resolvedStore = store ?? FileOtaReleaseStore(baseDirectory: configuration.storageDirectory)
        if let transactionFaultInjectorOptional {
            self.releaseTransaction = ReleaseTransaction(
                store: resolvedStore,
                faultInjector: transactionFaultInjectorOptional
            )
        } else {
            self.releaseTransaction = ReleaseTransaction(store: resolvedStore)
        }
        self.bundleRuntime = BundleRuntime(transaction: releaseTransaction)
        self.downloader = downloader ?? URLSessionBundleDownloader(
            allowLocalFileURLs: configuration.environment == .test &&
                configuration.apiBaseURL.scheme?.lowercased() == "http"
        )
        self.checksumValidator = checksumValidator
    }

    public func initializeEmbeddedRelease(_ release: OtaInstalledRelease) async throws {
        try await releaseTransaction.registerEmbedded(release)
        lifecycleState = .active(release.context)
    }

    /// 直接删除指定 appId 的下载版本；embedded 描述和 App 内置资源保留。
    public func deleteDownloadedBundles(lynxAppId: String) async throws {
        try await releaseTransaction.deleteDownloadedBundles(app: configuration.app, lynxAppId: lynxAppId)
        validatedBundleCache.removeAll { $0.lynxAppId == lynxAppId }
        lifecycleState = .idle(current: nil)
    }

    /// 直接删除全部 appId 的下载版本；不会建立 `.delete-*` 备份目录。
    public func deleteAllDownloadedBundles() async throws {
        try await releaseTransaction.deleteAllDownloadedBundles()
        validatedBundleCache.removeAll()
        lifecycleState = .idle(current: nil)
    }

    /** 冷启动维护，不联网；清理 Store v2 orphan 与残留 staging。 */
    public func pruneUnreferencedBundles() async throws {
        try await releaseTransaction.pruneAllUnreferencedReleases()
        validatedBundleCache.removeAll()
    }

    public func storageSnapshot(maxFilesPerTree: Int = 2_000) async throws -> OtaStorageSnapshot {
        try await releaseTransaction.storageSnapshot(maxFilesPerTree: maxFilesPerTree)
    }

    public func state() -> OtaLifecycleState {
        lifecycleState
    }

    public func getCurrentRelease() async -> OtaInstalledRelease? {
        await getCurrentRelease(lynxAppId: configuration.lynxAppId)
    }

    public func getCurrentRelease(lynxAppId: String) async -> OtaInstalledRelease? {
        await releaseTransaction.current(app: configuration.app, lynxAppId: lynxAppId)
    }

    /// 返回持久化的 candidate；current 读取入口不会消费 candidate。
    public func candidate(lynxAppId: String? = nil) async -> OtaCandidateSnapshot? {
        await releaseTransaction.candidate(
            scope: OtaReleaseScope(
                app: configuration.app,
                lynxAppId: lynxAppId ?? configuration.lynxAppId
            )
        )
    }

    public func candidateBundleURL(lynxAppId: String, bundleName: String) async throws -> URL? {
        try await releaseTransaction.candidateBundle(
            scope: OtaReleaseScope(app: configuration.app, lynxAppId: lynxAppId),
            bundleName: bundleName
        )
    }

    /// 健康确认成功后，原子地把 candidate promote 为 current，旧 current 进入 previous。
    public func confirmCandidateHealthy(lynxAppId: String? = nil) async throws -> OtaInstalledRelease {
        let resolvedLynxAppId = lynxAppId ?? configuration.lynxAppId
        let scope = OtaReleaseScope(app: configuration.app, lynxAppId: resolvedLynxAppId)
        guard let candidate = await releaseTransaction.candidate(scope: scope) else {
            throw OtaSDKError.missingCandidateRelease
        }
        lifecycleState = .activating(releaseId: candidate.release.context.releaseId)
        let confirmed = try await releaseTransaction.confirmCandidate(scope: scope)
        lifecycleState = .active(confirmed.context)
        try? await report(
            event: .activate,
            releaseId: confirmed.context.releaseId,
            lynxAppId: resolvedLynxAppId,
            pageId: nil,
            eventStage: .activate,
            eventResult: .success,
            message: "candidate_confirmed_healthy"
        )
        return confirmed
    }

    /// 页面真正打开 candidate 时才进入 trial，避免 host 全量同步让未访问 AppId 悬挂 trial。
    public func beginCandidateTrial(lynxAppId: String? = nil) async throws -> OtaCandidateSnapshot {
        let resolvedLynxAppId = lynxAppId ?? configuration.lynxAppId
        let candidate = try await releaseTransaction.beginCandidateTrial(
            scope: OtaReleaseScope(app: configuration.app, lynxAppId: resolvedLynxAppId)
        )
        lifecycleState = .trial(releaseId: candidate.release.context.releaseId)
        return candidate
    }

    public func discardCandidate(lynxAppId: String? = nil) async throws {
        let resolvedLynxAppId = lynxAppId ?? configuration.lynxAppId
        try await releaseTransaction.discardCandidate(
            scope: OtaReleaseScope(app: configuration.app, lynxAppId: resolvedLynxAppId)
        )
    }

    /// 进程在 trial 阶段退出后的冷启动恢复：丢弃未确认 candidate，current 保持不变。
    public func recoverInterruptedCandidate(lynxAppId: String? = nil) async throws {
        let resolvedLynxAppId = lynxAppId ?? configuration.lynxAppId
        try await releaseTransaction.recoverInterruptedCandidate(
            scope: OtaReleaseScope(app: configuration.app, lynxAppId: resolvedLynxAppId)
        )
    }

    /// `current` 是 Bundle Runtime 的只读入口；调用方不需要了解 pointer 文件名。
    public func current(lynxAppId: String? = nil) async -> OtaInstalledRelease? {
        await getCurrentRelease(lynxAppId: lynxAppId ?? configuration.lynxAppId)
    }

    /// Bundle Runtime 入口：按 `lynxAppId + bundleName` 读取已提交 current。
    /// 旧的 `current(lynxAppId:)` 仍返回完整 release，供状态页和诊断使用。
    public func current(lynxAppId: String, bundleName: String) async -> URL? {
        await currentTemplateURL(lynxAppId: lynxAppId, bundleName: bundleName)
    }

#if DEBUG
    /**
     * XCUITest F12 准备入口：复用已经校验过的当前 Bundle，在真实 canonical store 中构造
     * debug-previous -> debug-current 两个 downloaded Release。只在 Debug 测试 Target
     * 使用，生产没有该 API，也不会复制 baseline 到正式 OTA 目录。
     */
    func debugSeedRollbackPair(
        lynxAppId: String,
        bundleName: String,
        sourceURL: URL? = nil
    ) async throws {
        let currentURL: URL?
        if let sourceURL {
            currentURL = sourceURL
        } else {
            currentURL = await currentTemplateURL(
                lynxAppId: lynxAppId,
                bundleName: bundleName
            )
        }
        guard let currentURL else { throw OtaSDKError.missingCurrentRelease }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynx-debug-rollback-\(UUID().uuidString).lynx.bundle")
        try FileManager.default.copyItem(at: currentURL, to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let checksum = try SHA256ChecksumValidator().sha256(for: sourceURL)
        let scope = OtaReleaseScope(app: configuration.app, lynxAppId: lynxAppId)
        func release(_ releaseId: String) -> OtaInstalledRelease {
            OtaInstalledRelease(
                context: OtaCurrentReleaseContext(
                    env: configuration.environment,
                    app: configuration.app,
                    lynxAppId: lynxAppId,
                    releaseId: releaseId,
                    platform: configuration.platform,
                    status: .active
                ),
                installedAt: Date(),
                bundles: [
                    OtaInstalledBundle(
                        pageId: 0,
                        bundlePath: bundleName,
                        bundleSha256: checksum,
                        remoteURL: sourceURL,
                        localFilePath: sourceURL.path
                    ),
                ]
            )
        }

        try await releaseTransaction.stage(release("debug-previous"))
        _ = try await releaseTransaction.activate(scope: scope)
        try await releaseTransaction.stage(release("debug-current"))
        _ = try await releaseTransaction.activate(scope: scope)
    }
#endif

    /// 按 `lynxAppId + bundleName` 精确查找 current 本地文件。
    ///
    /// 读取时重新校验 SHA，避免 pointer 仍存在但文件已被截断/篡改时把坏包交给
    /// Lynx 容器。旧记录没有 bundleName 时，Models 会从 bundlePath 推导兼容名称。
    public func currentTemplateURL(lynxAppId: String, bundleName: String) async -> URL? {
        guard (try? normalizedBundleName(bundleName)) != nil,
              let release = await getCurrentRelease(lynxAppId: lynxAppId),
              let bundle = resolveBundle(named: bundleName, in: release),
              FileManager.default.fileExists(atPath: bundle.localFilePath) else {
            return nil
        }
        let localURL = URL(fileURLWithPath: bundle.localFilePath)
        guard (try? verifyCurrentBundle(
            localURL: localURL,
            releaseId: release.context.releaseId,
            lynxAppId: lynxAppId,
            bundleName: bundle.bundleName,
            expectedSha256: bundle.bundleSha256
        )) == true else {
            return nil
        }
        return localURL
    }

    /** 原子登记 current lease 后再执行当前 Bundle 的 SHA/fingerprint 门禁。 */
    public func acquireCurrentBundleLease(
        lynxAppId: String,
        bundleName: String
    ) async throws -> OtaBundleLease? {
        let scope = OtaReleaseScope(app: configuration.app, lynxAppId: lynxAppId)
        guard let lease = try await releaseTransaction.acquireCurrentBundleLease(
            scope: scope,
            bundleName: bundleName
        ) else {
            return nil
        }
        guard try verifyCurrentBundle(
            localURL: lease.fileURL,
            releaseId: lease.release.context.releaseId,
            lynxAppId: lynxAppId,
            bundleName: lease.bundle.bundleName,
            expectedSha256: lease.bundle.bundleSha256
        ) else {
            await lease.close()
            return nil
        }
        return lease
    }

    public func acquireCandidateBundleLease(
        lynxAppId: String,
        bundleName: String
    ) async throws -> OtaBundleLease? {
        let scope = OtaReleaseScope(app: configuration.app, lynxAppId: lynxAppId)
        guard let lease = try await releaseTransaction.acquireCandidateBundleLease(
            scope: scope,
            bundleName: bundleName
        ) else {
            return nil
        }
        guard try verifyCurrentBundle(
            localURL: lease.fileURL,
            releaseId: lease.release.context.releaseId,
            lynxAppId: lynxAppId,
            bundleName: lease.bundle.bundleName,
            expectedSha256: lease.bundle.bundleSha256
        ) else {
            await lease.close()
            return nil
        }
        return lease
    }

    private func verifyCurrentBundle(
        localURL: URL,
        releaseId: String,
        lynxAppId: String,
        bundleName: String,
        expectedSha256: String
    ) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // 同尺寸替换文件可能落在相同的 mtime 精度窗口内；文件身份变化时必须
        // 让进程内校验缓存 miss，不能把旧文件的“已验证”结论带给新 inode。
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let key = BundleValidationKey(
            app: configuration.app.rawValue,
            lynxAppId: lynxAppId,
            releaseId: releaseId,
            bundleName: bundleName,
            expectedSha256: expectedSha256.lowercased(),
            fileSize: fileSize,
            modificationTime: modificationTime,
            fileIdentifier: fileIdentifier
        )
        if validatedBundleCache.contains(key) {
            return true
        }
        guard let actualChecksum = try? checksumValidator.sha256(for: localURL),
              actualChecksum.lowercased() == expectedSha256.lowercased() else {
            validatedBundleCache.remove(key)
            return false
        }
        validatedBundleCache.insert(key)
        return true
    }

    /// Bundle miss 时拉取 host 下完整 latest snapshot，再返回已激活 bundle。
    /// latest/embedded 均没有这个 bundle 时抛出结构化 not-found，路由层可据此进入
    /// 等待、repair 或 not-found 分支，而不会误读 staged 文件。
    public func ensureBundleReady(lynxAppId: String, bundleName: String) async throws -> URL {
        _ = try normalizedBundleName(bundleName)
        if let url = await currentTemplateURL(lynxAppId: lynxAppId, bundleName: bundleName) {
            return url
        }
        // 页面缺包只请求目标 appId；全量接口只留给启动/回前台同步。
        _ = try await updateToLatestBundleList(lynxAppId: lynxAppId)
        let scope = OtaReleaseScope(app: configuration.app, lynxAppId: lynxAppId)
        _ = try await bundleRuntime.ensureBundleReady(scope: scope, bundleName: bundleName)
        guard let url = await currentTemplateURL(lynxAppId: lynxAppId, bundleName: bundleName) else {
            throw OtaSDKError.bundleNotFound(lynxAppId: lynxAppId, bundleName: bundleName)
        }
        return url
    }

    public func getCurrentVersion() async -> String {
        await getCurrentRelease()?.context.releaseId ?? "embedded"
    }

    public func checkForUpdate(_ request: OtaCheckRequest) async throws -> OtaPolicyMatchResponse {
        lifecycleState = .checking(current: await getCurrentRelease()?.context)
        let result = try await apiClient.checkForUpdate(
            OtaPolicyMatchRequest(
                env: configuration.environment,
                app: configuration.app,
                lynxAppId: configuration.lynxAppId,
                platform: configuration.platform,
                appVersion: configuration.appVersion,
                buildNumber: configuration.buildNumber,
                osVersion: request.osVersion,
                channel: request.channel,
                region: request.region,
                userId: request.userId,
                deviceId: request.deviceId,
                pageId: request.pageId,
                bundleName: request.bundleName,
                nativeProtocolVersion: request.nativeProtocolVersion,
                lynxSdkVersion: request.lynxSdkVersion
            )
        )
        let currentReleaseId = await getCurrentRelease()?.context.releaseId ?? "embedded"
        try? await report(
            event: .checkResult,
            releaseId: result.releaseId ?? currentReleaseId,
            pageId: request.pageId,
            userId: request.userId,
            deviceId: request.deviceId,
            osVersion: request.osVersion,
            channel: request.channel,
            region: request.region,
            nativeProtocolVersion: request.nativeProtocolVersion,
            lynxSdkVersion: request.lynxSdkVersion,
            bundleName: request.bundleName,
            eventStage: .match,
            eventResult: result.matched ? .success : .skipped,
            message: result.matched ? "matched" : "no_update"
        )
        if let current = await getCurrentRelease()?.context {
            lifecycleState = .active(current)
        } else {
            lifecycleState = .idle(current: nil)
        }
        return result
    }

    public func downloadUpdate(_ result: OtaPolicyMatchResponse) async throws -> OtaInstalledRelease {
        guard let releaseId = result.releaseId else {
            throw OtaSDKError.missingReleaseIdentifier
        }
        lifecycleState = .downloading(releaseId: releaseId)

        let manifest: OtaReleaseManifest
        do {
            manifest = try await apiClient.fetchManifest(
                releaseId: releaseId,
                env: configuration.environment,
                app: configuration.app,
                lynxAppId: configuration.lynxAppId,
                platform: configuration.platform
            )
        } catch {
            try? await report(
                event: .checkResult,
                releaseId: releaseId,
                lynxAppId: configuration.lynxAppId,
                pageId: nil,
                deviceId: nil,
                eventStage: .manifest,
                eventResult: .failed,
                reasonCode: OtaReasonCode.manifestFetchFailed.rawValue,
                reasonMessage: String(describing: error),
                message: OtaReasonCode.manifestFetchFailed.rawValue
            )
            throw error
        }
        try validateRemoteManifest(manifest)
        let current = await getCurrentRelease(lynxAppId: manifest.lynxAppId)
        let reusableRelease = await reusableReleaseSnapshot(current: current, lynxAppId: manifest.lynxAppId)
        let outcome = try await downloadAndValidate(manifest: manifest, reusableRelease: reusableRelease)
        defer {
            if let temporaryDirectory = outcome.temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        if configuration.candidateActivationEnabled {
            try await releaseTransaction.stageCandidate(outcome.installed)
        } else {
            try await releaseTransaction.stage(outcome.installed)
        }
        lifecycleState = .ready(releaseId: releaseId)
        return outcome.installed
    }

    public func activateStagedRelease() async throws -> OtaInstalledRelease {
        let scope = OtaReleaseScope(app: configuration.app, lynxAppId: configuration.lynxAppId)
        guard let staged = await releaseTransaction.staged(scope: scope) else {
            throw OtaSDKError.missingStagedRelease
        }
        lifecycleState = .activating(releaseId: staged.context.releaseId)
        let installed: OtaInstalledRelease
        do {
            installed = try await releaseTransaction.activate(scope: scope)
        } catch {
            try? await report(
                event: .activate,
                releaseId: staged.context.releaseId,
                lynxAppId: staged.context.lynxAppId,
                pageId: nil,
                deviceId: nil,
                eventStage: .activate,
                eventResult: .failed,
                reasonCode: OtaReasonCode.releaseActivateFailed.rawValue,
                reasonMessage: String(describing: error),
                message: OtaReasonCode.releaseActivateFailed.rawValue
            )
            throw error
        }
        lifecycleState = .active(installed.context)
        try? await report(
            event: .activate,
            releaseId: installed.context.releaseId,
            lynxAppId: installed.context.lynxAppId,
            pageId: nil,
            deviceId: nil,
            eventStage: .activate,
            eventResult: .success,
            message: "release_activated"
        )
        return installed
    }

    public func updateIfNeeded(_ request: OtaCheckRequest) async throws -> OtaUpdateResult {
        let current = await getCurrentRelease()
        let match = try await checkForUpdate(request)
        guard match.matched else {
            return .noUpdate(current: current)
        }
        guard let releaseId = match.releaseId else {
            throw OtaSDKError.missingReleaseIdentifier
        }
        if let current, current.context.releaseId == releaseId {
            if hasAllLocalBundles(current) {
                lifecycleState = .active(current.context)
                return .alreadyActive(current)
            }
            try? await report(
                event: .checkResult,
                releaseId: releaseId,
                lynxAppId: current.context.lynxAppId,
                pageId: nil,
                deviceId: nil,
                eventStage: .check,
                eventResult: .failed,
                reasonCode: OtaReasonCode.localBundleMissing.rawValue,
                reasonMessage: "当前 release 的本地 bundle 缺失，准备重新下载",
                message: OtaReasonCode.localBundleMissing.rawValue
            )
        }
        _ = try await downloadUpdate(match)
        if configuration.candidateActivationEnabled {
            guard let candidate = await candidate(lynxAppId: configuration.lynxAppId) else {
                throw OtaSDKError.missingCandidateRelease
            }
            lifecycleState = .candidate(releaseId: candidate.release.context.releaseId)
            return .candidate(from: current, candidate: candidate)
        }
        let activated = try await activateStagedRelease()
        return .updated(from: current, to: activated)
    }

    public func updateToLatestBundleList() async throws -> OtaLatestBundleListUpdateResult {
        try await updateToLatestBundleList(lynxAppId: configuration.lynxAppId)
    }

    /// 页面打开的定向检查入口；避免每次页面切换都请求 host 全量 appId 快照。
    public func updateToLatestBundleList(
        lynxAppId: String
    ) async throws -> OtaLatestBundleListUpdateResult {
        let current = await getCurrentRelease(lynxAppId: lynxAppId)
        lifecycleState = .checking(current: current?.context)
        let latest: OtaLatestBundleList
        do {
            latest = try await apiClient.fetchLatestBundleList(
                env: configuration.environment,
                app: configuration.app,
                lynxAppId: lynxAppId,
                platform: configuration.platform
            )
        } catch OtaSDKError.invalidResponse(let statusCode, _) where statusCode == 404 {
            if let current {
                lifecycleState = .active(current.context)
            } else {
                lifecycleState = .idle(current: nil)
            }
            return .noRelease(current: current)
        } catch {
            try? await reportLatestBundleListFailure(
                lynxAppId: lynxAppId,
                error: error
            )
            throw error
        }
        return try await updateToLatestBundleList(latest, current: current)
    }

    public func updateToLatestBundleLists() async throws -> OtaHostBundleListSyncResult {
        let latestGroup: OtaHostLatestBundleLists
        do {
            latestGroup = try await apiClient.fetchLatestBundleLists(
                env: configuration.environment,
                app: configuration.app,
                platform: configuration.platform
            )
        } catch OtaSDKError.invalidResponse(let statusCode, _) where statusCode == 404 {
            return OtaHostBundleListSyncResult(results: [:])
        } catch {
            try? await reportLatestBundleListFailure(
                lynxAppId: configuration.lynxAppId,
                error: error
            )
            throw error
        }

        var results: [String: OtaLatestBundleListUpdateResult] = [:]
        for latest in latestGroup.bundleLists {
            let current = await getCurrentRelease(lynxAppId: latest.lynxAppId)
            results[latest.lynxAppId] = try await updateToLatestBundleList(latest, current: current)
        }
        return OtaHostBundleListSyncResult(results: results)
    }

    private func updateToLatestBundleList(
        _ latest: OtaLatestBundleList,
        current: OtaInstalledRelease?
    ) async throws -> OtaLatestBundleListUpdateResult {
        if configuration.candidateActivationEnabled {
            try? await recoverInterruptedCandidate(lynxAppId: latest.lynxAppId)
        }
        if latest.status != .active {
            let reasonCode: OtaReasonCode = latest.status == .disabled ? .releaseDisabled : .releaseRolledBack
            try? await report(
                event: .checkResult,
                releaseId: latest.releaseId,
                lynxAppId: latest.lynxAppId,
                pageId: nil,
                deviceId: nil,
                eventStage: .check,
                eventResult: .skipped,
                reasonCode: reasonCode.rawValue,
                reasonMessage: "Release 状态不可激活：\(latest.status.rawValue)",
                message: reasonCode.rawValue
            )
            if let current {
                lifecycleState = .active(current.context)
            } else {
                lifecycleState = .idle(current: nil)
            }
            return .skipped(current: current, message: "Release 状态不可激活：\(latest.status.rawValue)")
        }
        if let current, current.context.releaseId == latest.releaseId {
            if hasAllLocalBundles(current, expectedBundles: latest.changedBundles) {
                lifecycleState = .active(current.context)
                try? await report(
                    event: .checkResult,
                    releaseId: latest.releaseId,
                    lynxAppId: latest.lynxAppId,
                    pageId: nil,
                    deviceId: nil,
                    eventStage: .check,
                    eventResult: .success,
                    message: "already_active"
                )
                return .alreadyActive(current)
            }
            try? await report(
                event: .checkResult,
                releaseId: latest.releaseId,
                lynxAppId: latest.lynxAppId,
                pageId: nil,
                deviceId: nil,
                eventStage: .check,
                eventResult: .failed,
                reasonCode: OtaReasonCode.localBundleMissing.rawValue,
                reasonMessage: "当前 release 的本地 bundle 缺失，准备重新下载",
                message: OtaReasonCode.localBundleMissing.rawValue
            )
        }

        if let skipMessage = versionMismatchMessage(for: latest) {
            try? await report(
                event: .checkResult,
                releaseId: latest.releaseId,
                lynxAppId: latest.lynxAppId,
                pageId: nil,
                deviceId: nil,
                eventStage: .check,
                eventResult: .skipped,
                reasonCode: OtaReasonCode.baselineBlocked.rawValue,
                reasonMessage: skipMessage,
                message: skipMessage
            )
            if let current {
                lifecycleState = .active(current.context)
            } else {
                lifecycleState = .idle(current: nil)
            }
            return .skipped(current: current, message: skipMessage)
        }

        let manifest = latest.asManifest()
        try validateRemoteManifest(manifest)
        if manifest.bundles.isEmpty {
            if let current {
                lifecycleState = .active(current.context)
            } else {
                lifecycleState = .idle(current: nil)
            }
            return .noRelease(current: current)
        }
        lifecycleState = .downloading(releaseId: manifest.releaseId)
        let reusableRelease = await reusableReleaseSnapshot(current: current, lynxAppId: latest.lynxAppId)
        let outcome = try await downloadAndValidate(manifest: manifest, reusableRelease: reusableRelease)
        defer {
            if let temporaryDirectory = outcome.temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        if configuration.candidateActivationEnabled {
            try await releaseTransaction.stageCandidate(outcome.installed)
            lifecycleState = .candidate(releaseId: manifest.releaseId)
            guard let candidate = await candidate(lynxAppId: latest.lynxAppId) else {
                throw OtaSDKError.missingCandidateRelease
            }
            return .candidate(from: current, candidate: candidate, summary: outcome.summary)
        }
        try await releaseTransaction.stage(outcome.installed)
        lifecycleState = .ready(releaseId: manifest.releaseId)
        let activated: OtaInstalledRelease
        do {
            activated = try await activateStagedRelease(lynxAppId: latest.lynxAppId)
        } catch {
            try? await report(
                event: .activate,
                releaseId: manifest.releaseId,
                lynxAppId: manifest.lynxAppId,
                pageId: nil,
                deviceId: nil,
                eventStage: .activate,
                eventResult: .failed,
                reasonCode: OtaReasonCode.releaseActivateFailed.rawValue,
                reasonMessage: String(describing: error),
                message: OtaReasonCode.releaseActivateFailed.rawValue
            )
            throw error
        }
        try? await report(
            event: .checkResult,
            releaseId: manifest.releaseId,
            lynxAppId: manifest.lynxAppId,
            pageId: nil,
            deviceId: nil,
            eventStage: .check,
            eventResult: .success,
            fromReleaseId: current?.context.releaseId,
            toReleaseId: activated.context.releaseId,
            message: "latest_bundle_list_updated"
        )
        return .updated(from: current, to: activated, summary: outcome.summary)
    }

    private func activateStagedRelease(lynxAppId: String) async throws -> OtaInstalledRelease {
        let scope = OtaReleaseScope(app: configuration.app, lynxAppId: lynxAppId)
        guard let staged = await releaseTransaction.staged(scope: scope) else {
            throw OtaSDKError.missingStagedRelease
        }
        lifecycleState = .activating(releaseId: staged.context.releaseId)
        let installed = try await releaseTransaction.activate(scope: scope)
        lifecycleState = .active(installed.context)
        try? await report(
            event: .activate,
            releaseId: installed.context.releaseId,
            lynxAppId: installed.context.lynxAppId,
            pageId: nil,
            deviceId: nil,
            eventStage: .activate,
            eventResult: .success,
            message: "release_activated"
        )
        return installed
    }

    public func rollback(reason: String) async throws -> OtaInstalledRelease? {
        try await rollback(lynxAppId: configuration.lynxAppId, reason: reason)
    }

    public func rollback(lynxAppId: String, reason: String) async throws -> OtaInstalledRelease? {
        let current = await getCurrentRelease(lynxAppId: lynxAppId)
        lifecycleState = .rollingBack(fromReleaseId: current?.context.releaseId, toReleaseId: nil)
        let rollbackOutcome = try await releaseTransaction.rollback(
            scope: OtaReleaseScope(app: configuration.app, lynxAppId: lynxAppId)
        )
        let restored: OtaInstalledRelease?
        switch rollbackOutcome {
        case let .restored(release):
            restored = release
        case .unavailable:
            restored = nil
        }
        if let restored {
            lifecycleState = .active(restored.context)
            try? await report(
                event: .rollback,
                releaseId: current?.context.releaseId ?? restored.context.releaseId,
                lynxAppId: restored.context.lynxAppId,
                pageId: nil,
                deviceId: nil,
                eventStage: .rollback,
                eventResult: .success,
                reasonCode: OtaReasonCode.manualRollback.rawValue,
                reasonMessage: reason,
                fromReleaseId: current?.context.releaseId,
                toReleaseId: restored.context.releaseId,
                message: reason
            )
        } else {
            lifecycleState = .idle(current: nil)
        }
        return restored
    }

    public func reportPageOpen(pageId: Int, lynxAppId: String? = nil, bundlePath: String? = nil) async {
        await reportPageOpen(
            pageId: Optional(pageId),
            lynxAppId: lynxAppId,
            bundleName: nil,
            bundlePath: bundlePath
        )
    }

    /// 新路由可只提供 bundleName；pageId 保留为可选埋点字段。
    public func reportPageOpen(
        pageId: Int?,
        lynxAppId: String? = nil,
        bundleName: String? = nil,
        bundlePath: String? = nil
    ) async {
        guard let current = await getCurrentRelease(lynxAppId: lynxAppId ?? configuration.lynxAppId) else {
            return
        }
        let bundle = current.bundles.first {
            (bundleName != nil && $0.bundleName == bundleName) ||
                (bundlePath != nil && ($0.bundlePath == bundlePath || $0.bundleName == bundlePath)) ||
                (pageId != nil && $0.pageId == pageId)
        }
        try? await report(
            event: .pageOpen,
            releaseId: current.context.releaseId,
            lynxAppId: current.context.lynxAppId,
            pageId: pageId,
            bundlePath: bundlePath ?? bundleName ?? bundle?.bundlePath,
            bundleName: bundleName ?? bundle?.bundleName,
            bundleSha256: bundle?.bundleSha256,
            eventStage: .pageOpen,
            eventResult: .success,
            message: "page_open"
        )
    }

    public func clearUpdates() async throws {
        _ = try await releaseTransaction.rollback(
            scope: OtaReleaseScope(app: configuration.app, lynxAppId: configuration.lynxAppId)
        )
        if let current = await getCurrentRelease()?.context {
            lifecycleState = .active(current)
        } else {
            lifecycleState = .idle(current: nil)
        }
    }

    private func downloadAndValidate(
        manifest: OtaReleaseManifest,
        reusableRelease: OtaInstalledRelease?
    ) async throws -> DownloadOutcome {
        let downloadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lynx-ota-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: downloadDirectory)
            }
        }
        var bundles: [OtaInstalledBundle] = []
        var downloadedBundleCount = 0
        var reusedBundleCount = 0
        for bundle in manifest.bundles {
            if let reusable = reusableInstalledBundle(for: bundle, in: reusableRelease) {
                reusedBundleCount += 1
                bundles.append(
                    OtaInstalledBundle(
                        bundleName: bundle.bundleName,
                        bundleSha256: bundle.bundleSha256,
                        remoteURL: bundle.bundleURL,
                        localFilePath: reusable.localFilePath,
                        pageId: bundle.pageId,
                        bundlePath: bundle.bundlePath
                    )
                )
                continue
            }

            let safePath = try normalizedBundleName(bundle.bundlePath)
            let localURL = downloadDirectory.appendingPathComponent(safePath, isDirectory: false)
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let downloadStartedAt = Date()
            do {
                try await downloader.download(from: bundle.bundleURL, to: localURL)
            } catch {
                try? await report(
                    event: .downloadSuccess,
                    releaseId: manifest.releaseId,
                    lynxAppId: manifest.lynxAppId,
                    pageId: bundle.pageId,
                    bundlePath: bundle.bundlePath,
                    bundleName: bundle.bundleName,
                    bundleSha256: bundle.bundleSha256,
                    bundleSize: bundle.size,
                    eventStage: .download,
                    eventResult: .failed,
                    reasonCode: OtaReasonCode.bundleDownloadFailed.rawValue,
                    reasonMessage: String(describing: error),
                    latencyMs: milliseconds(since: downloadStartedAt),
                    message: OtaReasonCode.bundleDownloadFailed.rawValue
                )
                throw error
            }
            lifecycleState = .validating(releaseId: manifest.releaseId)
            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            if let expectedSize = bundle.size, actualSize != Int64(expectedSize) {
                lifecycleState = .failed(step: "validate", message: "size_mismatch")
                try? await report(
                    event: .downloadSuccess,
                    releaseId: manifest.releaseId,
                    lynxAppId: manifest.lynxAppId,
                    pageId: bundle.pageId,
                    bundlePath: bundle.bundlePath,
                    bundleName: bundle.bundleName,
                    bundleSha256: bundle.bundleSha256,
                    bundleSize: bundle.size,
                    eventStage: .download,
                    eventResult: .failed,
                    reasonCode: OtaReasonCode.bundleSizeFailed.rawValue,
                    reasonMessage: "expected=\(expectedSize), actual=\(actualSize)",
                    latencyMs: milliseconds(since: downloadStartedAt),
                    message: OtaReasonCode.bundleSizeFailed.rawValue
                )
                throw OtaSDKError.sizeMismatch(expected: expectedSize, actual: actualSize)
            }
            let actualChecksum = try checksumValidator.sha256(for: localURL)
            guard actualChecksum.lowercased() == bundle.bundleSha256.lowercased() else {
                lifecycleState = .failed(step: "validate", message: "checksum_mismatch")
                try? await report(
                    event: .downloadSuccess,
                    releaseId: manifest.releaseId,
                    lynxAppId: manifest.lynxAppId,
                    pageId: bundle.pageId,
                    bundlePath: bundle.bundlePath,
                    bundleName: bundle.bundleName,
                    bundleSha256: bundle.bundleSha256,
                    bundleSize: bundle.size,
                    eventStage: .download,
                    eventResult: .failed,
                    reasonCode: OtaReasonCode.bundleChecksumFailed.rawValue,
                    reasonMessage: "expected=\(bundle.bundleSha256), actual=\(actualChecksum)",
                    latencyMs: milliseconds(since: downloadStartedAt),
                    message: OtaReasonCode.bundleChecksumFailed.rawValue
                )
                throw OtaSDKError.checksumMismatch(expected: bundle.bundleSha256, actual: actualChecksum)
            }
            try? await report(
                event: .downloadSuccess,
                releaseId: manifest.releaseId,
                lynxAppId: manifest.lynxAppId,
                pageId: bundle.pageId,
                bundlePath: bundle.bundlePath,
                bundleName: bundle.bundleName,
                bundleSha256: bundle.bundleSha256,
                bundleSize: bundle.size,
                eventStage: .download,
                eventResult: .success,
                latencyMs: milliseconds(since: downloadStartedAt),
                message: "bundle_downloaded"
            )
            downloadedBundleCount += 1
            bundles.append(
                OtaInstalledBundle(
                    pageId: bundle.pageId,
                    bundlePath: bundle.bundlePath,
                    bundleSha256: bundle.bundleSha256,
                    remoteURL: bundle.bundleURL,
                    localFilePath: localURL.path
                )
            )
        }

        let installed = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: manifest.env,
                app: manifest.app,
                lynxAppId: manifest.lynxAppId,
                releaseId: manifest.releaseId,
                platform: manifest.platform,
                status: .active
            ),
            installedAt: Date(),
            bundles: bundles
        )
        completed = true
        return DownloadOutcome(
            installed: installed,
            summary: OtaBundleSyncSummary(
                releaseId: manifest.releaseId,
                totalBundleCount: manifest.bundles.count,
                downloadedBundleCount: downloadedBundleCount,
                reusedBundleCount: reusedBundleCount
            ),
            temporaryDirectory: downloadDirectory
        )
    }

    private func validateRemoteManifest(_ manifest: OtaReleaseManifest) throws {
        guard manifest.status == .active else {
            throw OtaSDKError.invalidReleaseStatus(manifest.status.rawValue)
        }
        let allowLocalTestFixtures = configuration.environment == .test &&
            configuration.apiBaseURL.scheme?.lowercased() == "http"
        guard !manifest.bundles.isEmpty else {
            if allowLocalTestFixtures { return }
            throw OtaSDKError.invalidBundleName("Release bundles 不能为空")
        }
        for bundle in manifest.bundles {
            let scheme = bundle.bundleURL.scheme?.lowercased()
            let isHTTPS = scheme == "https" && bundle.bundleURL.host?.isEmpty == false
            let isLocalFixture = allowLocalTestFixtures && scheme == "file"
            guard (isHTTPS || isLocalFixture),
                  bundle.bundleURL.user == nil,
                  bundle.bundleURL.fragment == nil else {
                throw OtaSDKError.invalidBundleURL(bundle.bundlePath)
            }
            guard let size = bundle.size else {
                if allowLocalTestFixtures { continue }
                throw OtaSDKError.missingBundleSize(bundle.bundlePath)
            }
            guard size > 0, size <= 20 * 1024 * 1024 else {
                throw OtaSDKError.bundleTooLarge(bundle.bundlePath)
            }
        }
    }

    private func reusableInstalledBundle(
        for bundle: OtaBundleArtifact,
        in release: OtaInstalledRelease?
    ) -> OtaInstalledBundle? {
        guard let installed = release?.bundles.first(where: {
            ($0.bundleName == bundle.bundleName || $0.bundlePath == bundle.bundlePath) &&
                $0.bundleSha256.lowercased() == bundle.bundleSha256.lowercased()
        }) else {
            return nil
        }

        guard FileManager.default.fileExists(atPath: installed.localFilePath) else {
            return nil
        }

        // 元数据中的 SHA 不能证明文件仍然完整；复用前重新校验，避免把损坏的
        // 历史绝对路径复制到新 release。
        guard let actualChecksum = try? checksumValidator.sha256(for: URL(fileURLWithPath: installed.localFilePath)),
              actualChecksum.lowercased() == bundle.bundleSha256.lowercased() else {
            return nil
        }

        return installed
    }

    private func hasAllLocalBundles(
        _ release: OtaInstalledRelease,
        expectedBundles: [OtaBundleArtifact]? = nil
    ) -> Bool {
        let bundlesToCheck: [(sha256: String, localFilePath: String)]
        if let expectedBundles {
            bundlesToCheck = expectedBundles.compactMap { expected in
                guard let installed = release.bundles.first(where: {
                    ($0.bundleName == expected.bundleName || $0.bundlePath == expected.bundlePath) &&
                        $0.bundleSha256.lowercased() == expected.bundleSha256.lowercased()
                }) else {
                    return nil
                }
                return (installed.bundleSha256, installed.localFilePath)
            }
            guard bundlesToCheck.count == expectedBundles.count else {
                return false
            }
        } else {
            bundlesToCheck = release.bundles.map { ($0.bundleSha256, $0.localFilePath) }
        }

        return bundlesToCheck.allSatisfy { expected in
            guard FileManager.default.fileExists(atPath: expected.localFilePath) else {
                return false
            }
            guard let actualChecksum = try? checksumValidator.sha256(for: URL(fileURLWithPath: expected.localFilePath)) else {
                return false
            }
            return actualChecksum.lowercased() == expected.sha256.lowercased()
        }
    }

    private func versionMismatchMessage(for latest: OtaLatestBundleList) -> String? {
        if let appVersionMessage = mismatchMessage(
            label: "App 版本",
            version: configuration.appVersion,
            minVersion: latest.minAppVersion,
            maxVersion: latest.maxAppVersion
        ) {
            return appVersionMessage
        }
        if let lynxBaselineMessage = mismatchMessage(
            label: "Lynx 基线版本",
            version: configuration.lynxSdkVersion,
            range: latest.lynxSdkRange
        ) {
            return lynxBaselineMessage
        }
        return mismatchMessage(
            label: "Native 协议版本",
            version: configuration.nativeProtocolVersion,
            range: latest.nativeProtocolVersionRange
        )
    }

    private func mismatchMessage(
        label: String,
        version: String?,
        range: OtaReleaseVersionRange?
    ) -> String? {
        mismatchMessage(label: label, version: version, minVersion: range?.min, maxVersion: range?.max)
    }

    private func mismatchMessage(
        label: String,
        version: String?,
        minVersion: String?,
        maxVersion: String?
    ) -> String? {
        let normalizedMin = minVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMax = maxVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (normalizedMin == nil || normalizedMin == "") && (normalizedMax == nil || normalizedMax == "") {
            return nil
        }
        guard let version, !version.isEmpty else {
            return "跳过热更：\(label)未上报，要求范围 \(describeRange(minVersion: normalizedMin, maxVersion: normalizedMax))"
        }
        if let normalizedMin, !normalizedMin.isEmpty {
            guard let compared = compareVersion(version, normalizedMin) else {
                return "跳过热更：\(label) \(version) 无法参与版本比较，要求范围 \(describeRange(minVersion: normalizedMin, maxVersion: normalizedMax))"
            }
            if compared < 0 {
                return "跳过热更：\(label) \(version) 低于要求范围 \(describeRange(minVersion: normalizedMin, maxVersion: normalizedMax))"
            }
        }
        if let normalizedMax, !normalizedMax.isEmpty {
            guard let compared = compareVersion(version, normalizedMax) else {
                return "跳过热更：\(label) \(version) 无法参与版本比较，要求范围 \(describeRange(minVersion: normalizedMin, maxVersion: normalizedMax))"
            }
            if compared > 0 {
                return "跳过热更：\(label) \(version) 高于要求范围 \(describeRange(minVersion: normalizedMin, maxVersion: normalizedMax))"
            }
        }
        return nil
    }

    private func compareVersion(_ left: String, _ right: String) -> Int? {
        let leftParts = left.split(separator: ".")
        let rightParts = right.split(separator: ".")
        if max(leftParts.count, rightParts.count) > 1 {
            let count = max(leftParts.count, rightParts.count)
            for index in 0..<count {
                let leftValue = index < leftParts.count ? parseVersionNumber(String(leftParts[index])) : 0
                let rightValue = index < rightParts.count ? parseVersionNumber(String(rightParts[index])) : 0
                guard let leftValue, let rightValue else {
                    return nil
                }
                if leftValue != rightValue {
                    return leftValue < rightValue ? -1 : 1
                }
            }
            return 0
        }

        guard let leftValue = parseVersionNumber(left), let rightValue = parseVersionNumber(right) else {
            return nil
        }
        if leftValue == rightValue {
            return 0
        }
        return leftValue < rightValue ? -1 : 1
    }

    private func parseVersionNumber(_ raw: String) -> Int? {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return Int(raw)
    }

    private func describeRange(minVersion: String?, maxVersion: String?) -> String {
        switch (minVersion?.isEmpty == false ? minVersion : nil, maxVersion?.isEmpty == false ? maxVersion : nil) {
        case let (min?, max?):
            return "\(min) ~ \(max)"
        case let (min?, nil):
            return ">= \(min)"
        case let (nil, max?):
            return "<= \(max)"
        default:
            return "无限制"
        }
    }

    private func milliseconds(since start: Date) -> Int {
        max(Int(Date().timeIntervalSince(start) * 1000), 0)
    }

    private func normalizedBundleName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsPath = trimmed as NSString
        guard !trimmed.isEmpty,
              !nsPath.isAbsolutePath,
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              !trimmed.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: {
                    let segment = String($0)
                    return segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || segment == "." || segment == ".."
                }) else {
            throw OtaSDKError.invalidBundleName(raw)
        }
        return trimmed
    }

    /// 完整 bundlePath 精确优先；basename 仅在 current 中唯一时作为旧 pageId
    /// 兼容入口，禁止 contains/模糊匹配。
    private func resolveBundle(named bundleName: String, in release: OtaInstalledRelease) -> OtaInstalledBundle? {
        let pathMatches = release.bundles.filter { $0.bundlePath == bundleName }
        if pathMatches.count == 1 {
            return pathMatches[0]
        }
        if pathMatches.count > 1 {
            return nil
        }
        let nameMatches = release.bundles.filter { $0.bundleName == bundleName }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func reusableReleaseSnapshot(current: OtaInstalledRelease?, lynxAppId: String) async -> OtaInstalledRelease? {
        let candidates = [current].compactMap { $0 }
        guard let context = current?.context else {
            return nil
        }

        var seenKeys = Set<String>()
        var reusableBundles: [OtaInstalledBundle] = []
        for release in candidates {
            for bundle in release.bundles {
                guard FileManager.default.fileExists(atPath: bundle.localFilePath) else {
                    continue
                }
                let key = "\(bundle.bundlePath)#\(bundle.bundleSha256.lowercased())"
                guard !seenKeys.contains(key) else {
                    continue
                }
                seenKeys.insert(key)
                reusableBundles.append(bundle)
            }
        }

        guard !reusableBundles.isEmpty else {
            return nil
        }
        return OtaInstalledRelease(
            context: context,
            installedAt: Date(),
            bundles: reusableBundles
        )
    }

    private func report(
        event: OtaReportEvent,
        releaseId: String?,
        lynxAppId: String? = nil,
        pageId: Int?,
        userId: String? = nil,
        deviceId: String? = nil,
        deviceModel: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        osVersion: String? = nil,
        channel: String? = nil,
        region: String? = nil,
        nativeProtocolVersion: String? = nil,
        lynxSdkVersion: String? = nil,
        bundlePath: String? = nil,
        bundleName: String? = nil,
        bundleSha256: String? = nil,
        bundleSize: Int? = nil,
        eventStage: OtaReportEventStage? = nil,
        eventResult: OtaReportEventResult? = nil,
        reasonCode: String? = nil,
        reasonMessage: String? = nil,
        fromReleaseId: String? = nil,
        toReleaseId: String? = nil,
        latencyMs: Int? = nil,
        message: String?
    ) async throws {
        _ = try await apiClient.reportEvent(
            OtaReportPayload(
                env: configuration.environment,
                app: configuration.app,
                lynxAppId: lynxAppId ?? configuration.lynxAppId,
                releaseId: releaseId,
                platform: configuration.platform,
                event: event,
                pageId: pageId,
                userId: userId ?? configuration.userId,
                deviceId: deviceId ?? configuration.deviceId,
                deviceModel: deviceModel ?? configuration.deviceModel,
                appVersion: appVersion ?? configuration.appVersion,
                buildNumber: buildNumber ?? configuration.buildNumber,
                osVersion: osVersion ?? configuration.osVersion,
                channel: channel ?? configuration.channel,
                region: region ?? configuration.region,
                nativeProtocolVersion: nativeProtocolVersion ?? configuration.nativeProtocolVersion,
                lynxSdkVersion: lynxSdkVersion ?? configuration.lynxSdkVersion,
                bundlePath: bundlePath,
                bundleName: bundleName,
                bundleSha256: bundleSha256,
                bundleSize: bundleSize,
                eventStage: eventStage,
                eventResult: eventResult,
                reasonCode: reasonCode,
                reasonMessage: reasonMessage,
                fromReleaseId: fromReleaseId,
                toReleaseId: toReleaseId,
                latencyMs: latencyMs,
                message: message
            )
        )
    }

    private func reportLatestBundleListFailure(lynxAppId: String, error: Error) async throws {
        let reasonCode: OtaReasonCode
        if error is DecodingError {
            reasonCode = .latestBundleListDecodeFailed
        } else {
            reasonCode = .latestBundleListFetchFailed
        }

        try await report(
            event: .checkResult,
            releaseId: nil,
            lynxAppId: lynxAppId,
            pageId: nil,
            deviceId: nil,
            eventStage: .check,
            eventResult: .failed,
            reasonCode: reasonCode.rawValue,
            reasonMessage: String(describing: error),
            message: reasonCode.rawValue
        )
    }
}
