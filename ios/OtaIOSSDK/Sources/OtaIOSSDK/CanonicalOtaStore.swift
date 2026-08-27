import Foundation

/// 仅供 iOS 事务测试注入的持久化故障点。
///
/// 生产初始化使用 no-op 注入器，不改变正常运行路径；测试可以在 state 写入前后
/// 模拟进程退出或磁盘写入异常，验证重启后的 current/previous 恢复边界。
enum OtaTransactionFaultPoint: Sendable, Equatable {
    case beforeStateCommit
    case afterStateCommit
    case beforeRollbackCommit
    case afterRollbackCommit
}

protocol OtaTransactionFaultInjecting: Sendable {
    func check(_ point: OtaTransactionFaultPoint) throws
}

protocol OtaStorageCapacityProbing: Sendable {
    func availableCapacity(at storageRoot: URL) -> Int64
}

struct SystemOtaStorageCapacityProbe: OtaStorageCapacityProbing {
    func availableCapacity(at storageRoot: URL) -> Int64 {
        if let values = try? storageRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: storageRoot.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
    }
}

struct NoopOtaTransactionFaultInjector: OtaTransactionFaultInjecting {
    func check(_ point: OtaTransactionFaultPoint) throws {}
}

/// iOS OTA 的 canonical durable store。
///
/// Store v2 以 `apps/<lynxAppId>` 为唯一物理隔离边界；downloaded Release 的引用
/// 只写入 state/candidate，Bundle 本体位于该 App ID 的自包含 release 目录。
actor CanonicalOtaStore {
    private let baseDirectory: URL
    private let faultInjector: any OtaTransactionFaultInjecting
    private let capacityProbe: any OtaStorageCapacityProbing
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var leaseCounts: [LeaseKey: Int] = [:]

    private struct LeaseKey: Hashable {
        let lynxAppId: String
        let releaseId: String
    }

    private struct Scope: Codable, Equatable {
        let env: String
        let hostApp: String
        let lynxAppId: String
        let platform: String
    }

    private enum RefKind: String, Codable {
        case embedded
        case downloaded
    }

    private struct ReleaseRef: Codable, Equatable {
        let kind: RefKind
        let releaseId: String
    }

    private struct State: Codable {
        let schemaVersion: Int
        let generation: Int
        let scope: Scope
        let current: ReleaseRef
        let previous: ReleaseRef?
    }

    private struct StagedState: Codable {
        let schemaVersion: Int
        let scope: Scope
        let release: ReleaseRef
    }

    private struct CandidateState: Codable {
        let schemaVersion: Int
        let scope: Scope
        let release: ReleaseRef
        let status: OtaCandidateStatus
        let failureCount: Int
        let createdAt: Date
        let trialStartedAt: Date?
    }

    private struct LocalBundle: Codable {
        let pageId: Int
        let bundleName: String
        let bundlePath: String
        let bundleSha256: String
        let remoteURL: String
        let size: Int
    }

    private struct LocalManifest: Codable {
        let schemaVersion: Int
        let env: String
        let hostApp: String
        let lynxAppId: String
        let releaseId: String
        let platform: String
        let status: String
        let installedAt: Date
        let bundles: [LocalBundle]
    }

    private struct EmbeddedDescriptor: Codable {
        let release: OtaInstalledRelease
    }

    private struct TreeScan {
        let totalBytes: Int64
        let fileCount: Int
        let files: [OtaStorageFileSnapshot]
        let truncated: Bool
    }

    init(
        baseDirectory: URL,
        faultInjector: any OtaTransactionFaultInjecting = NoopOtaTransactionFaultInjector(),
        capacityProbe: any OtaStorageCapacityProbing = SystemOtaStorageCapacityProbe()
    ) {
        self.baseDirectory = baseDirectory
        self.faultInjector = faultInjector
        self.capacityProbe = capacityProbe
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func registerEmbedded(_ release: OtaInstalledRelease) throws {
        try ensureAppDirectories(lynxAppId: release.context.lynxAppId)
        let descriptor = EmbeddedDescriptor(release: release)
        try writeAtomic(try encoder.encode(descriptor), to: embeddedURL(app: release.context.app, lynxAppId: release.context.lynxAppId))
        if readState(app: release.context.app, lynxAppId: release.context.lynxAppId) == nil {
            let state = State(
                schemaVersion: storeSchemaVersion,
                generation: 0,
                scope: scope(for: release.context),
                current: ReleaseRef(kind: .embedded, releaseId: release.context.releaseId),
                previous: nil
            )
            try writeState(state, app: release.context.app, lynxAppId: release.context.lynxAppId)
        }
        try pruneUnreferencedReleases(app: release.context.app, lynxAppId: release.context.lynxAppId)
    }

    func current(app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease? {
        guard let state = readState(app: app, lynxAppId: lynxAppId) else {
            return nil
        }
        guard state.scope.hostApp == app.rawValue,
              state.scope.lynxAppId == lynxAppId,
              state.scope.platform == OtaPlatform.ios.rawValue else {
            throw storageError("canonical state scope 不匹配")
        }
        return try resolve(state.current, app: app, lynxAppId: lynxAppId)
    }

    func staged(app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease? {
        guard let staged = readStaged(app: app, lynxAppId: lynxAppId) else {
            return nil
        }
        return try resolve(staged.release, app: app, lynxAppId: lynxAppId)
    }

    func stage(_ release: OtaInstalledRelease) throws {
        try ensureAppDirectories(lynxAppId: release.context.lynxAppId)
        try recoverStaging(lynxAppId: release.context.lynxAppId)
        try validateRelease(release)
        try pruneUnreferencedReleases(app: release.context.app, lynxAppId: release.context.lynxAppId)
        let targetBytes = try release.bundles.reduce(into: Int64(0)) { total, bundle in
            let values = try fileManager.attributesOfItem(atPath: bundle.localFilePath)
            total += (values[.size] as? NSNumber)?.int64Value ?? 0
        }
        let requiredBytes = targetBytes + metadataAllowanceBytes + max(
            safetyReserveBytes,
            (targetBytes + 9) / 10
        )
        let availableBytes = capacityProbe.availableCapacity(at: baseDirectory)
        if availableBytes >= 0, availableBytes < requiredBytes {
            throw OtaSDKError.insufficientStorage(
                required: requiredBytes,
                available: availableBytes
            )
        }
        let transactionId = UUID().uuidString
        let staging = stagingDirectory(
            lynxAppId: release.context.lynxAppId,
            releaseId: release.context.releaseId,
            transactionId: transactionId
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var localBundles: [LocalBundle] = []
            for bundle in release.bundles {
                let relativePath = try safeBundlePath(bundle.bundlePath)
                let source = URL(fileURLWithPath: bundle.localFilePath)
                let attributes = try fileManager.attributesOfItem(atPath: source.path)
                let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
                guard size > 0, size <= 20 * 1024 * 1024 else {
                    throw storageError("Bundle 大小超出 iOS OTA 限制")
                }
                let part = staging.appendingPathComponent(relativePath + ".part", isDirectory: false)
                try fileManager.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: part)
                let actual = try SHA256ChecksumValidator().sha256(for: part)
                guard actual.caseInsensitiveCompare(bundle.bundleSha256) == .orderedSame else {
                    throw OtaSDKError.checksumMismatch(expected: bundle.bundleSha256, actual: actual)
                }
                let destination = staging.appendingPathComponent(relativePath, isDirectory: false)
                try fileManager.moveItem(at: part, to: destination)
                localBundles.append(
                    LocalBundle(
                        pageId: bundle.pageId,
                        bundleName: bundle.bundleName,
                        bundlePath: relativePath,
                        bundleSha256: bundle.bundleSha256,
                        remoteURL: bundle.remoteURL.absoluteString,
                        size: size
                    )
                )
            }
            let manifest = LocalManifest(
                schemaVersion: 1,
                env: release.context.env.rawValue,
                hostApp: release.context.app.rawValue,
                lynxAppId: release.context.lynxAppId,
                releaseId: release.context.releaseId,
                platform: release.context.platform.rawValue,
                status: OtaReleaseStatus.active.rawValue,
                installedAt: release.installedAt,
                bundles: localBundles
            )
            try writeAtomic(
                try encoder.encode(manifest),
                to: staging.appendingPathComponent("release-manifest.json", isDirectory: false)
            )
            try verifyReleaseDirectory(staging, expected: manifest)
            try publishStaging(
                staging,
                lynxAppId: release.context.lynxAppId,
                releaseId: release.context.releaseId
            )
            try writeAtomic(
                try encoder.encode(
                    StagedState(
                        schemaVersion: storeSchemaVersion,
                        scope: scope(for: release.context),
                        release: ReleaseRef(kind: .downloaded, releaseId: release.context.releaseId)
                    )
                ),
                to: stagedURL(app: release.context.app, lynxAppId: release.context.lynxAppId)
            )
            try pruneUnreferencedReleases(app: release.context.app, lynxAppId: release.context.lynxAppId)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// 写入一个已经完成文件校验的候选版本，但不修改 current/previous。
    func stageCandidate(_ release: OtaInstalledRelease) throws {
        try stage(release)
        guard let staged = readStaged(app: release.context.app, lynxAppId: release.context.lynxAppId) else {
            throw storageError("candidate stage 指针不存在")
        }
        let candidate = CandidateState(
            schemaVersion: storeSchemaVersion,
            scope: staged.scope,
            release: staged.release,
            status: .pending,
            failureCount: 0,
            createdAt: Date(),
            trialStartedAt: nil
        )
        try writeAtomic(
            try encoder.encode(candidate),
            to: candidateURL(app: release.context.app, lynxAppId: release.context.lynxAppId)
        )
        try removeItemIfPresent(stagedURL(app: release.context.app, lynxAppId: release.context.lynxAppId))
        try pruneUnreferencedReleases(app: release.context.app, lynxAppId: release.context.lynxAppId)
    }

    func candidate(app: OtaAppID, lynxAppId: String) throws -> OtaCandidateSnapshot? {
        guard let state = readCandidate(app: app, lynxAppId: lynxAppId) else { return nil }
        guard let release = try resolve(state.release, app: app, lynxAppId: lynxAppId) else {
            return nil
        }
        return OtaCandidateSnapshot(
            release: release,
            status: state.status,
            failureCount: state.failureCount,
            createdAt: state.createdAt,
            trialStartedAt: state.trialStartedAt
        )
    }

    func beginCandidateTrial(app: OtaAppID, lynxAppId: String) throws -> OtaCandidateSnapshot {
        guard let state = readCandidate(app: app, lynxAppId: lynxAppId) else {
            throw OtaSDKError.missingCandidateRelease
        }
        if state.status == .trial {
            guard let snapshot = try candidate(app: app, lynxAppId: lynxAppId) else {
                throw OtaSDKError.missingCandidateRelease
            }
            return snapshot
        }
        let trial = CandidateState(
            schemaVersion: state.schemaVersion,
            scope: state.scope,
            release: state.release,
            status: .trial,
            failureCount: state.failureCount,
            createdAt: state.createdAt,
            trialStartedAt: Date()
        )
        try writeAtomic(
            try encoder.encode(trial),
            to: candidateURL(app: app, lynxAppId: lynxAppId)
        )
        guard let snapshot = try candidate(app: app, lynxAppId: lynxAppId) else {
            throw OtaSDKError.missingCandidateRelease
        }
        return snapshot
    }

    func confirmCandidate(app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease {
        guard let candidate = readCandidate(app: app, lynxAppId: lynxAppId) else {
            throw OtaSDKError.missingCandidateRelease
        }
        guard candidate.status == .trial else {
            throw OtaSDKError.candidateNotInTrial
        }
        guard let installed = try resolve(candidate.release, app: app, lynxAppId: lynxAppId) else {
            throw OtaSDKError.missingCandidateRelease
        }
        let oldState = readState(app: app, lynxAppId: lynxAppId)
        let previous = oldState?.current ?? embeddedReference(app: app, lynxAppId: lynxAppId)
        let next = State(
            schemaVersion: storeSchemaVersion,
            generation: (oldState?.generation ?? 0) + 1,
            scope: candidate.scope,
            current: candidate.release,
            previous: previous
        )
        try faultInjector.check(.beforeStateCommit)
        try writeState(next, app: app, lynxAppId: lynxAppId)
        try faultInjector.check(.afterStateCommit)
        try removeItemIfPresent(candidateURL(app: app, lynxAppId: lynxAppId))
        try pruneUnreferencedReleases(app: app, lynxAppId: lynxAppId)
        return installed
    }

    func candidateBundle(app: OtaAppID, lynxAppId: String, bundleName: String) throws -> URL? {
        guard let candidate = try candidate(app: app, lynxAppId: lynxAppId),
              let bundle = candidate.release.bundles.first(where: {
                  $0.bundleName == bundleName || $0.bundlePath == bundleName
              }),
              fileManager.fileExists(atPath: bundle.localFilePath) else {
            return nil
        }
        return URL(fileURLWithPath: bundle.localFilePath)
    }

    func acquireCurrentBundleLease(
        app: OtaAppID,
        lynxAppId: String,
        bundleName: String
    ) throws -> OtaBundleLease? {
        guard let state = readState(app: app, lynxAppId: lynxAppId) else { return nil }
        return try acquireBundleLease(
            reference: state.current,
            app: app,
            lynxAppId: lynxAppId,
            bundleName: bundleName
        )
    }

    func acquireCandidateBundleLease(
        app: OtaAppID,
        lynxAppId: String,
        bundleName: String
    ) throws -> OtaBundleLease? {
        guard let candidate = readCandidate(app: app, lynxAppId: lynxAppId) else { return nil }
        return try acquireBundleLease(
            reference: candidate.release,
            app: app,
            lynxAppId: lynxAppId,
            bundleName: bundleName
        )
    }

    func discardCandidate(app: OtaAppID, lynxAppId: String) throws {
        guard readCandidate(app: app, lynxAppId: lynxAppId) != nil else { return }
        try removeItemIfPresent(candidateURL(app: app, lynxAppId: lynxAppId))
        try pruneUnreferencedReleases(app: app, lynxAppId: lynxAppId)
    }

    func recoverInterruptedCandidate(app: OtaAppID, lynxAppId: String) throws {
        guard let candidate = readCandidate(app: app, lynxAppId: lynxAppId),
              candidate.status == .trial else { return }
        try discardCandidate(app: app, lynxAppId: lynxAppId)
    }

    func activate(app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease {
        guard let staged = readStaged(app: app, lynxAppId: lynxAppId) else {
            throw OtaSDKError.missingStagedRelease
        }
        guard let installed = try resolve(staged.release, app: app, lynxAppId: lynxAppId) else {
            throw storageError("canonical staged Release 不存在")
        }
        let oldState = readState(app: app, lynxAppId: lynxAppId)
        let previous = oldState?.current ?? embeddedReference(app: app, lynxAppId: lynxAppId)
        let next = State(
            schemaVersion: storeSchemaVersion,
            generation: (oldState?.generation ?? 0) + 1,
            scope: staged.scope,
            current: staged.release,
            previous: previous
        )
        // 如果上一次进程已经提交 current，只是还没来得及清理 staged，重启时必须
        // 把它视为同一笔事务的幂等重放，不能把 current 自己再次写成 previous。
        if oldState?.current == staged.release {
            try removeItemIfPresent(stagedURL(app: app, lynxAppId: lynxAppId))
            try pruneUnreferencedReleases(app: app, lynxAppId: lynxAppId)
            return installed
        }
        try faultInjector.check(.beforeStateCommit)
        try writeState(next, app: app, lynxAppId: lynxAppId)
        try faultInjector.check(.afterStateCommit)
        try removeItemIfPresent(stagedURL(app: app, lynxAppId: lynxAppId))
        try pruneUnreferencedReleases(app: app, lynxAppId: lynxAppId)
        return installed
    }

    func install(_ release: OtaInstalledRelease) throws -> OtaInstalledRelease {
        try stage(release)
        return try activate(app: release.context.app, lynxAppId: release.context.lynxAppId)
    }

    func rollback(app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease? {
        guard let state = readState(app: app, lynxAppId: lynxAppId), let previous = state.previous else {
            return try resolveEmbedded(app: app, lynxAppId: lynxAppId)
        }
        guard let restored = try resolve(previous, app: app, lynxAppId: lynxAppId) else {
            return nil
        }
        let next = State(
            schemaVersion: storeSchemaVersion,
            generation: state.generation + 1,
            scope: state.scope,
            current: previous,
            previous: nil
        )
        try faultInjector.check(.beforeRollbackCommit)
        try writeState(next, app: app, lynxAppId: lynxAppId)
        try faultInjector.check(.afterRollbackCommit)
        try pruneUnreferencedReleases(app: app, lynxAppId: lynxAppId)
        return restored
    }

    func deleteDownloadedBundles(app: OtaAppID, lynxAppId: String) throws {
        try removeItemIfPresent(stateURL(app: app, lynxAppId: lynxAppId))
        try removeItemIfPresent(stagedURL(app: app, lynxAppId: lynxAppId))
        try removeItemIfPresent(candidateURL(app: app, lynxAppId: lynxAppId))
        try removeItemIfPresent(stagingRoot(lynxAppId: lynxAppId))
        try pruneUnreferencedReleases(app: app, lynxAppId: lynxAppId)
    }

    func deleteAllDownloadedBundles() throws {
        guard fileManager.fileExists(atPath: appsDirectory.path) else { return }
        for appDirectory in try fileManager.contentsOfDirectory(
            at: appsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let appId = appDirectory.lastPathComponent
            guard isValidAppId(appId) else { continue }
            try removeItemIfPresent(stateURL(app: .capp, lynxAppId: appId))
            try removeItemIfPresent(stagedURL(app: .capp, lynxAppId: appId))
            try removeItemIfPresent(candidateURL(app: .capp, lynxAppId: appId))
            try removeItemIfPresent(stagingRoot(lynxAppId: appId))
            try pruneDownloadedDirectories(lynxAppId: appId, retained: [])
        }
    }

    /** 冷启动维护；状态损坏时跳过该 App，宁可保留文件也不猜测删除。 */
    func pruneAllUnreferencedReleases() throws {
        guard fileManager.fileExists(atPath: appsDirectory.path) else { return }
        for appDirectory in try fileManager.contentsOfDirectory(
            at: appsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let appId = appDirectory.lastPathComponent
            guard isValidAppId(appId) else { continue }
            if fileManager.fileExists(atPath: stateURL(app: .capp, lynxAppId: appId).path),
               readState(app: .capp, lynxAppId: appId) == nil {
                continue
            }
            if fileManager.fileExists(atPath: stagedURL(app: .capp, lynxAppId: appId).path),
               readStaged(app: .capp, lynxAppId: appId) == nil {
                continue
            }
            if fileManager.fileExists(atPath: candidateURL(app: .capp, lynxAppId: appId).path),
               readCandidate(app: .capp, lynxAppId: appId) == nil {
                continue
            }
            try recoverStaging(lynxAppId: appId)
            try pruneUnreferencedReleases(app: .capp, lynxAppId: appId)
        }
    }

    /** 与写事务共用 actor 的只读快照；不创建目录、不 prune、不重新计算 Bundle SHA。 */
    func storageSnapshot(maxFilesPerTree: Int = 2_000) throws -> OtaStorageSnapshot {
        precondition(maxFilesPerTree > 0)
        let rootScan = try scanTree(baseDirectory, maxFiles: maxFilesPerTree)
        let appURLs = fileManager.fileExists(atPath: appsDirectory.path)
            ? try fileManager.contentsOfDirectory(
                at: appsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { isValidAppId($0.lastPathComponent) }
            : []
        let apps = try appURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            try snapshotApp(lynxAppId: $0.lastPathComponent, maxFilesPerTree: maxFilesPerTree)
        }
        return OtaStorageSnapshot(
            rootPath: baseDirectory.standardizedFileURL.path,
            totalBytes: rootScan.totalBytes,
            fileCount: rootScan.fileCount,
            generatedAt: Date(),
            apps: apps
        )
    }

    private func snapshotApp(lynxAppId: String, maxFilesPerTree: Int) throws -> OtaStorageAppSnapshot {
        let state = readState(app: .capp, lynxAppId: lynxAppId)
        let candidate = readCandidate(app: .capp, lynxAppId: lynxAppId)
        let leasedReleaseIds = Set(
            leaseCounts.compactMap { key, count in
                key.lynxAppId == lynxAppId && count > 0 ? key.releaseId : nil
            }
        )
        let releaseURLs = fileManager.fileExists(atPath: releasesDirectory(lynxAppId: lynxAppId).path)
            ? try fileManager.contentsOfDirectory(
                at: releasesDirectory(lynxAppId: lynxAppId),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            : []
        let releases = try releaseURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let releaseId = url.lastPathComponent
            var roles = Set<OtaStorageReleaseRole>()
            if state?.current.kind == .downloaded, state?.current.releaseId == releaseId { roles.insert(.current) }
            if state?.previous?.kind == .downloaded, state?.previous?.releaseId == releaseId { roles.insert(.previous) }
            if candidate?.release.kind == .downloaded, candidate?.release.releaseId == releaseId { roles.insert(.candidate) }
            if leasedReleaseIds.contains(releaseId) { roles.insert(.leased) }
            if roles.isEmpty { roles.insert(.orphan) }
            let scan = try scanTree(url, maxFiles: maxFilesPerTree)
            let manifestValid: Bool
            if let manifest = try? readManifest(at: url) {
                manifestValid = manifest.lynxAppId == lynxAppId && manifest.releaseId == releaseId
            } else {
                manifestValid = false
            }
            return OtaStorageReleaseSnapshot(
                releaseId: releaseId,
                roles: roles,
                totalBytes: scan.totalBytes,
                fileCount: scan.fileCount,
                manifestValid: manifestValid,
                files: scan.files,
                truncated: scan.truncated
            )
        }
        let stagingURLs = fileManager.fileExists(atPath: stagingRoot(lynxAppId: lynxAppId).path)
            ? try fileManager.contentsOfDirectory(
                at: stagingRoot(lynxAppId: lynxAppId),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            : []
        let staging = try stagingURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let scan = try scanTree(url, maxFiles: maxFilesPerTree)
            return OtaStorageStagingSnapshot(
                transactionName: url.lastPathComponent,
                totalBytes: scan.totalBytes,
                fileCount: scan.fileCount,
                files: scan.files,
                truncated: scan.truncated
            )
        }
        let appScan = try scanTree(appDirectory(lynxAppId: lynxAppId), maxFiles: maxFilesPerTree)
        return OtaStorageAppSnapshot(
            appId: lynxAppId,
            state: state.map {
                OtaStorageStateSnapshot(
                    generation: $0.generation,
                    currentReleaseId: $0.current.releaseId,
                    currentKind: $0.current.kind.rawValue,
                    previousReleaseId: $0.previous?.releaseId,
                    previousKind: $0.previous?.kind.rawValue
                )
            },
            candidate: candidate.map {
                OtaStorageCandidateStateSnapshot(
                    releaseId: $0.release.releaseId,
                    status: $0.status.rawValue,
                    failureCount: $0.failureCount
                )
            },
            releases: releases,
            staging: staging,
            totalBytes: appScan.totalBytes,
            fileCount: appScan.fileCount
        )
    }

    private func scanTree(_ root: URL, maxFiles: Int) throws -> TreeScan {
        guard fileManager.fileExists(atPath: root.path) else {
            return TreeScan(totalBytes: 0, fileCount: 0, files: [], truncated: false)
        }
        var totalBytes: Int64 = 0
        var fileCount = 0
        var files: [OtaStorageFileSnapshot] = []
        var truncated = false

        func visit(_ directory: URL, depth: Int) throws {
            guard depth <= 32 else {
                truncated = true
                return
            }
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let values = try child.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                ])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try visit(child, depth: depth + 1)
                } else if values.isRegularFile == true {
                    let bytes = Int64(values.fileSize ?? 0)
                    totalBytes += bytes
                    fileCount += 1
                    if files.count < maxFiles {
                        files.append(
                            OtaStorageFileSnapshot(
                                relativePath: String(child.path.dropFirst(root.path.count + 1)),
                                byteCount: bytes,
                                modifiedAt: values.contentModificationDate ?? .distantPast
                            )
                        )
                    } else {
                        truncated = true
                    }
                }
            }
        }
        try visit(root, depth: 0)
        return TreeScan(totalBytes: totalBytes, fileCount: fileCount, files: files, truncated: truncated)
    }

    private var appsDirectory: URL { baseDirectory.appendingPathComponent("apps", isDirectory: true) }

    private func appDirectory(lynxAppId: String) -> URL {
        appsDirectory.appendingPathComponent(lynxAppId, isDirectory: true)
    }

    private func releasesDirectory(lynxAppId: String) -> URL {
        appDirectory(lynxAppId: lynxAppId).appendingPathComponent("releases", isDirectory: true)
    }

    private func stagingRoot(lynxAppId: String) -> URL {
        appDirectory(lynxAppId: lynxAppId).appendingPathComponent(".staging", isDirectory: true)
    }

    private func stateURL(app: OtaAppID, lynxAppId: String) -> URL {
        appDirectory(lynxAppId: lynxAppId).appendingPathComponent("state.json", isDirectory: false)
    }

    private func stagedURL(app: OtaAppID, lynxAppId: String) -> URL {
        appDirectory(lynxAppId: lynxAppId).appendingPathComponent("staged.json", isDirectory: false)
    }

    private func candidateURL(app: OtaAppID, lynxAppId: String) -> URL {
        appDirectory(lynxAppId: lynxAppId).appendingPathComponent("candidate.json", isDirectory: false)
    }

    private func embeddedURL(app: OtaAppID, lynxAppId: String) -> URL {
        appDirectory(lynxAppId: lynxAppId).appendingPathComponent("embedded.json", isDirectory: false)
    }

    private func releaseDirectory(lynxAppId: String, releaseId: String) throws -> URL {
        try safeReleaseId(releaseId)
        return releasesDirectory(lynxAppId: lynxAppId).appendingPathComponent(releaseId, isDirectory: true)
    }

    private func stagingDirectory(lynxAppId: String, releaseId: String, transactionId: String) -> URL {
        stagingRoot(lynxAppId: lynxAppId)
            .appendingPathComponent("\(releaseId).\(transactionId)", isDirectory: true)
    }

    private func scope(for context: OtaCurrentReleaseContext) -> Scope {
        Scope(
            env: context.env.rawValue,
            hostApp: context.app.rawValue,
            lynxAppId: context.lynxAppId,
            platform: context.platform.rawValue
        )
    }

    private func readState(app: OtaAppID, lynxAppId: String) -> State? {
        guard let data = try? Data(contentsOf: stateURL(app: app, lynxAppId: lynxAppId)) else { return nil }
        guard let value = try? decoder.decode(State.self, from: data),
              value.schemaVersion == storeSchemaVersion else { return nil }
        return value
    }

    private func readStaged(app: OtaAppID, lynxAppId: String) -> StagedState? {
        guard let data = try? Data(contentsOf: stagedURL(app: app, lynxAppId: lynxAppId)) else { return nil }
        guard let value = try? decoder.decode(StagedState.self, from: data),
              value.schemaVersion == storeSchemaVersion else { return nil }
        return value
    }

    private func readCandidate(app: OtaAppID, lynxAppId: String) -> CandidateState? {
        guard let data = try? Data(contentsOf: candidateURL(app: app, lynxAppId: lynxAppId)) else { return nil }
        guard let value = try? decoder.decode(CandidateState.self, from: data),
              value.schemaVersion == storeSchemaVersion else { return nil }
        return value
    }

    private func embeddedReference(app: OtaAppID, lynxAppId: String) -> ReleaseRef? {
        guard let data = try? Data(contentsOf: embeddedURL(app: app, lynxAppId: lynxAppId)),
              let descriptor = try? decoder.decode(EmbeddedDescriptor.self, from: data) else { return nil }
        return ReleaseRef(kind: .embedded, releaseId: descriptor.release.context.releaseId)
    }

    private func resolve(_ reference: ReleaseRef, app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease? {
        switch reference.kind {
        case .embedded:
            return try resolveEmbedded(app: app, lynxAppId: lynxAppId)
        case .downloaded:
            let directory = try releaseDirectory(lynxAppId: lynxAppId, releaseId: reference.releaseId)
            guard let manifest = try? readManifest(at: directory) else { return nil }
            guard manifest.hostApp == app.rawValue, manifest.lynxAppId == lynxAppId else {
                throw storageError("canonical Release scope 不匹配")
            }
            return try installedRelease(from: manifest, directory: directory)
        }
    }

    private func resolveEmbedded(app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease? {
        guard let data = try? Data(contentsOf: embeddedURL(app: app, lynxAppId: lynxAppId)) else { return nil }
        return try decoder.decode(EmbeddedDescriptor.self, from: data).release
    }

    private func readManifest(at directory: URL) throws -> LocalManifest {
        let url = directory.appendingPathComponent("release-manifest.json", isDirectory: false)
        return try decoder.decode(LocalManifest.self, from: Data(contentsOf: url))
    }

    private func installedRelease(from manifest: LocalManifest, directory: URL) throws -> OtaInstalledRelease {
        guard let env = OtaEnvironment(rawValue: manifest.env),
              let app = OtaAppID(rawValue: manifest.hostApp),
              let platform = OtaPlatform(rawValue: manifest.platform),
              let status = OtaReleaseStatus(rawValue: manifest.status) else {
            throw storageError("canonical Release 元数据非法")
        }
        let bundles = try manifest.bundles.map { bundle -> OtaInstalledBundle in
            let path = try safeBundlePath(bundle.bundlePath)
            let url = directory.appendingPathComponent(path, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else {
                throw OtaSDKError.fileNotFound(url.path)
            }
            return OtaInstalledBundle(
                pageId: bundle.pageId,
                bundlePath: path,
                bundleSha256: bundle.bundleSha256,
                remoteURL: URL(string: bundle.remoteURL) ?? URL(fileURLWithPath: url.path),
                localFilePath: url.path
            )
        }
        return OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: env,
                app: app,
                lynxAppId: manifest.lynxAppId,
                releaseId: manifest.releaseId,
                platform: platform,
                status: status
            ),
            installedAt: manifest.installedAt,
            bundles: bundles
        )
    }

    private func publishStaging(_ staging: URL, lynxAppId: String, releaseId: String) throws {
        let target = try releaseDirectory(lynxAppId: lynxAppId, releaseId: releaseId)
        try fileManager.createDirectory(
            at: releasesDirectory(lynxAppId: lynxAppId),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(
                target,
                withItemAt: staging,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
            return
        }
        try fileManager.moveItem(at: staging, to: target)
    }

    private func verifyReleaseDirectory(_ directory: URL, expected: LocalManifest) throws {
        for bundle in expected.bundles {
            let path = try safeBundlePath(bundle.bundlePath)
            let url = directory.appendingPathComponent(path, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { throw OtaSDKError.fileNotFound(url.path) }
            let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard size?.intValue == bundle.size else { throw storageError("canonical Bundle size 不一致") }
            let actual = try SHA256ChecksumValidator().sha256(for: url)
            guard actual.caseInsensitiveCompare(bundle.bundleSha256) == .orderedSame else {
                throw OtaSDKError.checksumMismatch(expected: bundle.bundleSha256, actual: actual)
            }
        }
    }

    private func validateRelease(_ release: OtaInstalledRelease) throws {
        guard release.context.status == .active else { throw storageError("只能激活 ACTIVE Release") }
        guard !release.bundles.isEmpty else { throw storageError("Release 不包含 Bundle") }
        for bundle in release.bundles {
            _ = try safeBundlePath(bundle.bundlePath)
        }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appsDirectory, withIntermediateDirectories: true)
    }

    private func ensureAppDirectories(lynxAppId: String) throws {
        guard isValidAppId(lynxAppId) else { throw storageError("lynxAppId 必须是 8 位数字") }
        try ensureDirectories()
        try fileManager.createDirectory(at: appDirectory(lynxAppId: lynxAppId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: releasesDirectory(lynxAppId: lynxAppId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingRoot(lynxAppId: lynxAppId), withIntermediateDirectories: true)
    }

    private func writeState(_ state: State, app: OtaAppID, lynxAppId: String) throws {
        try writeAtomic(try encoder.encode(state), to: stateURL(app: app, lynxAppId: lynxAppId))
    }

    private func writeAtomic(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func removeItemIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func recoverStaging(lynxAppId: String) throws {
        let root = stagingRoot(lynxAppId: lynxAppId)
        guard fileManager.fileExists(atPath: root.path) else { return }
        for item in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try removeItemIfPresent(item)
        }
    }

    private func pruneUnreferencedReleases(app: OtaAppID, lynxAppId: String) throws {
        var retained = Set<String>()
        if let state = readState(app: app, lynxAppId: lynxAppId) {
            if state.current.kind == .downloaded { retained.insert(state.current.releaseId) }
            if let previous = state.previous, previous.kind == .downloaded {
                retained.insert(previous.releaseId)
            }
        }
        if let staged = readStaged(app: app, lynxAppId: lynxAppId), staged.release.kind == .downloaded {
            retained.insert(staged.release.releaseId)
        }
        if let candidate = readCandidate(app: app, lynxAppId: lynxAppId), candidate.release.kind == .downloaded {
            retained.insert(candidate.release.releaseId)
        }
        try pruneDownloadedDirectories(lynxAppId: lynxAppId, retained: retained)
    }

    private func pruneDownloadedDirectories(lynxAppId: String, retained: Set<String>) throws {
        let leased = Set(
            leaseCounts.compactMap { key, count in
                key.lynxAppId == lynxAppId && count > 0 ? key.releaseId : nil
            }
        )
        let retained = retained.union(leased)
        let releases = releasesDirectory(lynxAppId: lynxAppId)
        guard fileManager.fileExists(atPath: releases.path) else { return }
        for item in try fileManager.contentsOfDirectory(at: releases, includingPropertiesForKeys: nil)
        where !retained.contains(item.lastPathComponent) {
            try removeItemIfPresent(item)
        }
    }

    private func acquireBundleLease(
        reference: ReleaseRef,
        app: OtaAppID,
        lynxAppId: String,
        bundleName: String
    ) throws -> OtaBundleLease? {
        guard let release = try resolve(reference, app: app, lynxAppId: lynxAppId),
              let bundle = resolveBundle(named: bundleName, in: release),
              fileManager.fileExists(atPath: bundle.localFilePath) else {
            return nil
        }
        if reference.kind == .downloaded {
            let key = LeaseKey(lynxAppId: lynxAppId, releaseId: reference.releaseId)
            leaseCounts[key, default: 0] += 1
        }
        return OtaBundleLease(
            release: release,
            bundle: bundle,
            fileURL: URL(fileURLWithPath: bundle.localFilePath)
        ) { [self] in
            guard reference.kind == .downloaded else { return }
            await releaseLease(app: app, lynxAppId: lynxAppId, releaseId: reference.releaseId)
        }
    }

    private func releaseLease(app: OtaAppID, lynxAppId: String, releaseId: String) {
        let key = LeaseKey(lynxAppId: lynxAppId, releaseId: releaseId)
        let remaining = (leaseCounts[key] ?? 0) - 1
        if remaining > 0 {
            leaseCounts[key] = remaining
        } else {
            leaseCounts.removeValue(forKey: key)
        }
        try? pruneUnreferencedReleases(app: app, lynxAppId: lynxAppId)
    }

    private func resolveBundle(named bundleName: String, in release: OtaInstalledRelease) -> OtaInstalledBundle? {
        let pathMatches = release.bundles.filter { $0.bundlePath == bundleName }
        if pathMatches.count == 1 { return pathMatches[0] }
        if pathMatches.count > 1 { return nil }
        let nameMatches = release.bundles.filter { $0.bundleName == bundleName }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func isValidAppId(_ value: String) -> Bool {
        value.range(of: "^[0-9]{8}$", options: .regularExpression) != nil
    }

    private func safeReleaseId(_ raw: String) throws {
        guard !raw.isEmpty, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines), raw != ".", raw != "..", !raw.contains("/"), !raw.contains("\\"), !raw.contains("\0") else {
            throw storageError("Release ID 非法")
        }
    }

    private func safeBundlePath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            throw storageError("Bundle path 非法")
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw storageError("Bundle path 非法")
        }
        return segments.joined(separator: "/")
    }

    private func storageError(_ message: String) -> NSError {
        NSError(domain: "OtaIOSSDK.CanonicalStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private let storeSchemaVersion = 2
    private let metadataAllowanceBytes: Int64 = 1024 * 1024
    private let safetyReserveBytes: Int64 = 32 * 1024 * 1024
}
