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
/// 当前 SDK 已有 `FileOtaReleaseStore` actor。这里不复制它的 JSON 格式，而是
/// 作为稳定的 deep façade：未来可以把锁、恢复和容量预检放进本模块，外部仍只
/// 需要理解 install/current/rollback 三个动作。旧 pageId pointer 读取仍由 store
/// 完成，因此升级后可以无损读取历史安装状态。
public actor ReleaseTransaction {
    private let store: FileOtaReleaseStore
    private let canonicalStore: CanonicalOtaStore

    public init(store: FileOtaReleaseStore) {
        self.store = store
        self.canonicalStore = CanonicalOtaStore(baseDirectory: store.baseDirectoryURL)
    }

    /// 返回作用域内 current；没有 OTA current 时由 embedded 作为首次运行回退。
    public func current(scope: OtaReleaseScope) async -> OtaInstalledRelease? {
        do {
            if let current = try await canonicalStore.current(app: scope.app, lynxAppId: scope.lynxAppId) {
                return current
            }
        } catch {
            // 损坏的 canonical state 不应吞掉 legacy fallback；下一次事务会重新物化。
        }
        return await store.currentRelease(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func current(app: OtaAppID, lynxAppId: String) async -> OtaInstalledRelease? {
        await current(scope: OtaReleaseScope(app: app, lynxAppId: lynxAppId))
    }

    /// 只解析 current 中精确的 bundleName；不会读取 staged 或历史目录。
    public func currentBundle(scope: OtaReleaseScope, bundleName: String) async throws -> URL? {
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
        try await prepareLegacyStateIfNeeded(scope: request.scope)
        let activated = try await canonicalStore.install(request.release)
        return .updated(from: currentRelease, to: activated)
    }

    public func stage(_ release: OtaInstalledRelease) async throws {
        let scope = OtaReleaseScope(app: release.context.app, lynxAppId: release.context.lynxAppId)
        try await prepareLegacyStateIfNeeded(scope: scope)
        try await canonicalStore.stage(release)
    }

    public func activate(scope: OtaReleaseScope) async throws -> OtaInstalledRelease {
        if (try await canonicalStore.staged(app: scope.app, lynxAppId: scope.lynxAppId)) != nil {
            return try await canonicalStore.activate(app: scope.app, lynxAppId: scope.lynxAppId)
        }
        return try await store.activateStagedRelease(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func staged(scope: OtaReleaseScope) async -> OtaInstalledRelease? {
        do {
            if let staged = try await canonicalStore.staged(app: scope.app, lynxAppId: scope.lynxAppId) {
                return staged
            }
        } catch {
            // fall through to the legacy staged pointer during migration
            print("[OtaIOSSDK] canonical staged read failed: \(error)")
        }
        return await store.stagedRelease(app: scope.app, lynxAppId: scope.lynxAppId)
    }

    public func registerEmbedded(_ release: OtaInstalledRelease) async throws {
        if let legacy = await store.currentRelease(app: release.context.app, lynxAppId: release.context.lynxAppId),
           legacy.context.releaseId != "embedded" {
            try? await canonicalStore.adoptLegacy(legacy)
        }
        try await canonicalStore.registerEmbedded(release)
    }

    public func deleteDownloadedBundles(app: OtaAppID, lynxAppId: String) async throws {
        try await canonicalStore.deleteDownloadedBundles(app: app, lynxAppId: lynxAppId)
        try await store.deleteDownloadedBundles(app: app, lynxAppId: lynxAppId)
    }

    public func deleteAllDownloadedBundles() async throws {
        try await canonicalStore.deleteAllDownloadedBundles()
        try await store.deleteAllDownloadedBundles()
    }

    /// 恢复 previous；没有 previous 时回退 embedded。不会扫描或猜测其它历史目录。
    public func rollback(scope: OtaReleaseScope) async throws -> OtaReleaseRollbackOutcome {
        if let restored = try await canonicalStore.rollback(app: scope.app, lynxAppId: scope.lynxAppId) {
            return .restored(restored)
        }
        guard let restored = try await store.rollback(app: scope.app, lynxAppId: scope.lynxAppId) else {
            return .unavailable
        }
        return .restored(restored)
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

    private func prepareLegacyStateIfNeeded(scope: OtaReleaseScope) async throws {
        if try await canonicalStore.current(app: scope.app, lynxAppId: scope.lynxAppId) != nil {
            return
        }
        let legacy = await store.currentRelease(app: scope.app, lynxAppId: scope.lynxAppId)
        if let legacy, legacy.context.releaseId != "embedded" {
            do {
                try await canonicalStore.adoptLegacy(legacy)
                return
            } catch {
                // 旧 current 可能指向已失效的绝对路径；保留 legacy 供诊断，继续回退 embedded。
            }
        }
        if let embedded = await store.embeddedRelease(app: scope.app, lynxAppId: scope.lynxAppId) {
            try await canonicalStore.registerEmbedded(embedded)
        }
    }
}

/// 便于旧宿主按 Ota 前缀引用；正式实现名保持与 Android 对齐的 ReleaseTransaction。
public typealias OtaReleaseTransaction = ReleaseTransaction
