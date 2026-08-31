import Foundation

/**
 * Router/SDK 使用的持久化 Store 最小异步边界。
 *
 * v2 与 v3 都实现这一组能力，调用方不需要知道 Release 目录或 CAS Object 的物理布局。
 */
protocol OtaReleaseStoreBackend: Sendable {
    func current(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease?
    func existingObject(
        app: OtaAppID,
        lynxAppId: String,
        objectId: String,
        expectedSize: Int64?
    ) async throws -> URL?
    func staged(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease?
    func install(_ release: OtaInstalledRelease) async throws -> OtaInstalledRelease
    func stage(_ release: OtaInstalledRelease) async throws
    func stageCandidate(_ release: OtaInstalledRelease) async throws
    func candidate(app: OtaAppID, lynxAppId: String) async throws -> OtaCandidateSnapshot?
    func beginCandidateTrial(app: OtaAppID, lynxAppId: String) async throws -> OtaCandidateSnapshot
    func confirmCandidate(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease
    func candidateBundle(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> URL?
    func acquireCurrentBundleLease(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> OtaBundleLease?
    func acquireCandidateBundleLease(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> OtaBundleLease?
    func discardCandidate(app: OtaAppID, lynxAppId: String) async throws
    func recoverInterruptedCandidate(app: OtaAppID, lynxAppId: String) async throws
    func activate(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease
    func registerEmbedded(_ release: OtaInstalledRelease) async throws
    func deleteDownloadedBundles(app: OtaAppID, lynxAppId: String) async throws
    func deleteAllDownloadedBundles() async throws
    func pruneAllUnreferencedReleases() async throws
    func rollback(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease?
    func storageSnapshot(maxFilesPerTree: Int) async throws -> OtaStorageSnapshot
}

/** 将历史同步 actor 包装到 v3 统一边界；默认直接调用仍可保持旧测试和迁移兼容。 */
actor LegacyOtaStoreBackend: OtaReleaseStoreBackend {
    private let store: CanonicalOtaStore

    init(
        baseDirectory: URL,
        faultInjector: any OtaTransactionFaultInjecting = NoopOtaTransactionFaultInjector(),
        capacityProbe: any OtaStorageCapacityProbing = SystemOtaStorageCapacityProbe()
    ) {
        self.store = CanonicalOtaStore(
            baseDirectory: baseDirectory,
            faultInjector: faultInjector,
            capacityProbe: capacityProbe
        )
    }

    func current(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease? {
        try await store.current(app: app, lynxAppId: lynxAppId)
    }

    func existingObject(
        app: OtaAppID,
        lynxAppId: String,
        objectId: String,
        expectedSize: Int64?
    ) async throws -> URL? {
        nil
    }

    func staged(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease? {
        try await store.staged(app: app, lynxAppId: lynxAppId)
    }

    func install(_ release: OtaInstalledRelease) async throws -> OtaInstalledRelease {
        try await store.install(release)
    }

    func stage(_ release: OtaInstalledRelease) async throws {
        try await store.stage(release)
    }

    func stageCandidate(_ release: OtaInstalledRelease) async throws {
        try await store.stageCandidate(release)
    }

    func candidate(app: OtaAppID, lynxAppId: String) async throws -> OtaCandidateSnapshot? {
        try await store.candidate(app: app, lynxAppId: lynxAppId)
    }

    func beginCandidateTrial(app: OtaAppID, lynxAppId: String) async throws -> OtaCandidateSnapshot {
        try await store.beginCandidateTrial(app: app, lynxAppId: lynxAppId)
    }

    func confirmCandidate(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease {
        try await store.confirmCandidate(app: app, lynxAppId: lynxAppId)
    }

    func candidateBundle(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> URL? {
        try await store.candidateBundle(app: app, lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func acquireCurrentBundleLease(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> OtaBundleLease? {
        try await store.acquireCurrentBundleLease(app: app, lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func acquireCandidateBundleLease(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> OtaBundleLease? {
        try await store.acquireCandidateBundleLease(app: app, lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func discardCandidate(app: OtaAppID, lynxAppId: String) async throws {
        try await store.discardCandidate(app: app, lynxAppId: lynxAppId)
    }

    func recoverInterruptedCandidate(app: OtaAppID, lynxAppId: String) async throws {
        try await store.recoverInterruptedCandidate(app: app, lynxAppId: lynxAppId)
    }

    func activate(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease {
        try await store.activate(app: app, lynxAppId: lynxAppId)
    }

    func registerEmbedded(_ release: OtaInstalledRelease) async throws {
        try await store.registerEmbedded(release)
    }

    func deleteDownloadedBundles(app: OtaAppID, lynxAppId: String) async throws {
        try await store.deleteDownloadedBundles(app: app, lynxAppId: lynxAppId)
    }

    func deleteAllDownloadedBundles() async throws {
        try await store.deleteAllDownloadedBundles()
    }

    func pruneAllUnreferencedReleases() async throws {
        try await store.pruneAllUnreferencedReleases()
    }

    func rollback(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease? {
        try await store.rollback(app: app, lynxAppId: lynxAppId)
    }

    func storageSnapshot(maxFilesPerTree: Int) async throws -> OtaStorageSnapshot {
        try await store.storageSnapshot(maxFilesPerTree: maxFilesPerTree)
    }
}
