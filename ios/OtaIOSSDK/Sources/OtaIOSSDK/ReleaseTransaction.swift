import Foundation

/// 一个宿主下某个 LynxApp 的持久化作用域。
///
/// `ReleaseTransaction` 不负责 HTTP；它只把 staged/current/previous/embedded 的
/// 文件指针操作收拢到一个 actor 中，避免调用方在多个 actor 之间拼接错误顺序。
public struct OtaReleaseScope: Equatable, Sendable {
    public let app: OtaAppID
    public let lynxAppId: String

    public init(app: OtaAppID, lynxAppId: String) {
        self.app = app
        self.lynxAppId = lynxAppId
    }
}

/// 已经完成下载和校验、可交给事务提交的完整 release 快照。
public struct OtaReleaseInstallRequest: Sendable {
    public let scope: OtaReleaseScope
    public let release: OtaInstalledRelease

    public init(scope: OtaReleaseScope, release: OtaInstalledRelease) {
        self.scope = scope
        self.release = release
    }
}

public enum OtaReleaseInstallOutcome: Equatable, Sendable {
    case alreadyActive(OtaInstalledRelease)
    case updated(from: OtaInstalledRelease?, to: OtaInstalledRelease)
}

public enum OtaReleaseRollbackOutcome: Equatable, Sendable {
    case restored(OtaInstalledRelease)
    case unavailable
}

/// iOS 端的最小 release 事务模块。
///
/// 所有 current/previous/candidate 与下载文件都由 canonical Store v2 管理。
/// `FileOtaReleaseStore` 只保留 storage root 构造兼容，不再读写旧 pointer。
public actor ReleaseTransaction {
    private let canonicalStore: CanonicalOtaStore

    public init(store: FileOtaReleaseStore) {
        self.canonicalStore = CanonicalOtaStore(baseDirectory: store.baseDirectoryURL)
    }

    /// 测试专用初始化：把持久化提交前后的故障点注入 canonical store。
    /// 生产调用方继续使用 `init(store:)`，因此不会暴露或依赖故障控制能力。
    init(store: FileOtaReleaseStore, faultInjector: any OtaTransactionFaultInjecting) {
        self.canonicalStore = CanonicalOtaStore(
            baseDirectory: store.baseDirectoryURL,
            faultInjector: faultInjector
        )
    }

    init(store: FileOtaReleaseStore, capacityProbe: any OtaStorageCapacityProbing) {
        self.canonicalStore = CanonicalOtaStore(
            baseDirectory: store.baseDirectoryURL,
            capacityProbe: capacityProbe
        )
    }

    /// 返回作用域内 current；没有 OTA current 时由 embedded 作为首次运行回退。
    public func current(scope: OtaReleaseScope) async -> OtaInstalledRelease? {
        guard isValidAppId(scope.lynxAppId) else { return nil }
        do {
            return try await canonicalStore.current(app: scope.app, lynxAppId: scope.lynxAppId)
        } catch {
            return nil
        }
    }

    public func current(app: OtaAppID, lynxAppId: String) async -> OtaInstalledRelease? {
        await current(scope: OtaReleaseScope(app: app, lynxAppId: lynxAppId))
    }

    /// 只解析 current 中精确的 bundleName；不会读取 staged 或历史目录。
    public func currentBundle(scope: OtaReleaseScope, bundleName: String) async throws -> URL? {
        try validateAppId(scope.lynxAppId)
        try validateBundleName(bundleName)
        guard let release = await current(scope: scope),
              let bundle = resolveBundle(named: bundleName, in: release),
              FileManager.default.fileExists(atPath: bundle.localFilePath) else {
            return nil
        }
        return URL(fileURLWithPath: bundle.localFilePath)
    }

    /// 只在完整 release 已准备好后切换指针；失败时旧 current 不受影响。
    public func install(_ request: OtaReleaseInstallRequest) async throws -> OtaReleaseInstallOutcome {
        guard request.release.context.app == request.scope.app,
              request.release.context.lynxAppId == request.scope.lynxAppId else {
            throw OtaSDKError.invalidReleaseScope(
                expectedApp: request.scope.app,
                expectedLynxAppId: request.scope.lynxAppId,
                actualApp: request.release.context.app,
                actualLynxAppId: request.release.context.lynxAppId
            )
        }
        let currentRelease = await current(scope: request.scope)
        if currentRelease?.context.releaseId == request.release.context.releaseId {
            return .alreadyActive(currentRelease ?? request.release)
        }
        let activated = try await canonicalStore.install(request.release)
        return .updated(from: currentRelease, to: activated)
    }

    public func stage(_ release: OtaInstalledRelease) async throws {
        try await canonicalStore.stage(release)
    }

    public func stageCandidate(_ release: OtaInstalledRelease) async throws {
        try await canonicalStore.stageCandidate(release)
    }

    public func candidate(scope: OtaReleaseScope) async -> OtaCandidateSnapshot? {
        guard isValidAppId(scope.lynxAppId) else { return nil }
        return try? await canonicalStore.candidate(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func beginCandidateTrial(scope: OtaReleaseScope) async throws -> OtaCandidateSnapshot {
        try validateAppId(scope.lynxAppId)
        return try await canonicalStore.beginCandidateTrial(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func confirmCandidate(scope: OtaReleaseScope) async throws -> OtaInstalledRelease {
        try validateAppId(scope.lynxAppId)
        return try await canonicalStore.confirmCandidate(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func candidateBundle(scope: OtaReleaseScope, bundleName: String) async throws -> URL? {
        try validateAppId(scope.lynxAppId)
        try validateBundleName(bundleName)
        return try await canonicalStore.candidateBundle(
            app: scope.app,
            lynxAppId: scope.lynxAppId,
            bundleName: bundleName
        )
    }

    public func acquireCurrentBundleLease(
        scope: OtaReleaseScope,
        bundleName: String
    ) async throws -> OtaBundleLease? {
        try validateAppId(scope.lynxAppId)
        try validateBundleName(bundleName)
        return try await canonicalStore.acquireCurrentBundleLease(
            app: scope.app,
            lynxAppId: scope.lynxAppId,
            bundleName: bundleName
        )
    }

    public func acquireCandidateBundleLease(
        scope: OtaReleaseScope,
        bundleName: String
    ) async throws -> OtaBundleLease? {
        try validateAppId(scope.lynxAppId)
        try validateBundleName(bundleName)
        return try await canonicalStore.acquireCandidateBundleLease(
            app: scope.app,
            lynxAppId: scope.lynxAppId,
            bundleName: bundleName
        )
    }

    public func discardCandidate(scope: OtaReleaseScope) async throws {
        try await canonicalStore.discardCandidate(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func recoverInterruptedCandidate(scope: OtaReleaseScope) async throws {
        try await canonicalStore.recoverInterruptedCandidate(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func activate(scope: OtaReleaseScope) async throws -> OtaInstalledRelease {
        try await canonicalStore.activate(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func staged(scope: OtaReleaseScope) async -> OtaInstalledRelease? {
        try? await canonicalStore.staged(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func registerEmbedded(_ release: OtaInstalledRelease) async throws {
        try await canonicalStore.registerEmbedded(release)
    }

    public func deleteDownloadedBundles(app: OtaAppID, lynxAppId: String) async throws {
        try validateAppId(lynxAppId)
        try await canonicalStore.deleteDownloadedBundles(app: app, lynxAppId: lynxAppId)
    }

    public func deleteAllDownloadedBundles() async throws {
        try await canonicalStore.deleteAllDownloadedBundles()
    }

    public func storageSnapshot(maxFilesPerTree: Int = 2_000) async throws -> OtaStorageSnapshot {
        try await canonicalStore.storageSnapshot(maxFilesPerTree: maxFilesPerTree)
    }

    public func pruneAllUnreferencedReleases() async throws {
        try await canonicalStore.pruneAllUnreferencedReleases()
    }

    /// 恢复 previous；没有 previous 时回退 embedded。不会扫描或猜测其它历史目录。
    public func rollback(scope: OtaReleaseScope) async throws -> OtaReleaseRollbackOutcome {
        if let restored = try await canonicalStore.rollback(app: scope.app, lynxAppId: scope.lynxAppId) {
            return .restored(restored)
        }
        return .unavailable
    }

    public func rollback(app: OtaAppID, lynxAppId: String) async throws -> OtaReleaseRollbackOutcome {
        try await rollback(scope: OtaReleaseScope(app: app, lynxAppId: lynxAppId))
    }

    private func validateBundleName(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed as NSString
        guard !trimmed.isEmpty,
              !path.isAbsolutePath,
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              !trimmed.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: {
                    let segment = String($0)
                    return segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || segment == "." || segment == ".."
                }) else {
            throw OtaSDKError.invalidBundleName(raw)
        }
    }

    private func validateAppId(_ value: String) throws {
        guard isValidAppId(value) else {
            throw OtaSDKError.invalidBundleName(value)
        }
    }

    private func isValidAppId(_ value: String) -> Bool {
        value.range(of: "^[0-9]{8}$", options: .regularExpression) != nil
    }

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

}

/// 便于旧宿主按 Ota 前缀引用；正式实现名保持与 Android 对齐的 ReleaseTransaction。
public typealias OtaReleaseTransaction = ReleaseTransaction
