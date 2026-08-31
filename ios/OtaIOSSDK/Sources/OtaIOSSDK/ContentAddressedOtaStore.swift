import Foundation
import CryptoKit

/**
 * OTA Store v3 的 iOS 实现。
 *
 * Release 只保存完整逻辑 Manifest，Bundle bytes 按 SHA-256 放进 App ID 作用域内的对象库。
 * current/previous/candidate 只引用 Manifest；页面 lease 引用 Manifest 及其对象，GC 从这些
 * roots 重建引用集合，不依赖容易在崩溃时失真的持久化 refcount。
 */
actor ContentAddressedOtaStore: OtaReleaseStoreBackend {
    private static let storeSchemaVersion = 3
    private static let manifestSchemaVersion = 3
    private static let metadataAllowanceBytes: Int64 = 1024 * 1024
    private static let safetyReserveBytes: Int64 = 32 * 1024 * 1024
    private static let maxBundleBytes: Int64 = 20 * 1024 * 1024

    private let baseDirectory: URL
    private let faultInjector: any OtaTransactionFaultInjecting
    private let capacityProbe: any OtaStorageCapacityProbing
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var embeddedReleases: [String: OtaInstalledRelease] = [:]
    private var leaseCounts: [LeaseKey: Int] = [:]
    private var lastOperation: OtaStoreOperationMetrics?

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
        let manifestId: String?
    }

    private struct CandidateState: Codable, Equatable {
        let release: ReleaseRef
        var status: OtaCandidateStatus
        var failureCount: Int
        let createdAt: Date
        var trialStartedAt: Date?
    }

    private struct State: Codable, Equatable {
        let schemaVersion: Int
        var generation: Int
        let scope: Scope
        var current: ReleaseRef
        var previous: ReleaseRef?
        var candidate: CandidateState?
    }

    private struct EmbeddedBundle: Codable {
        let pageId: Int
        let bundleName: String
        let bundlePath: String
        let bundleSha256: String
        let size: Int
    }

    private struct EmbeddedDescriptor: Codable {
        let schemaVersion: Int
        let releaseId: String
        let env: String
        let hostApp: String
        let lynxAppId: String
        let platform: String
        let bundles: [EmbeddedBundle]
    }

    private struct LocalBundle: Codable, Equatable {
        let pageId: Int
        let bundleName: String
        let bundlePath: String
        let bundleSha256: String
        let objectId: String
        let remoteURL: String
        let size: Int
    }

    private struct LocalManifest: Codable, Equatable {
        let schemaVersion: Int
        let manifestId: String
        let env: String
        let hostApp: String
        let lynxAppId: String
        let releaseId: String
        let platform: String
        let status: String
        let installedAt: Date
        let bundles: [LocalBundle]
    }

    private struct ManifestHashInput: Codable {
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

    private struct TransactionJournal: Codable {
        let schemaVersion: Int
        let scope: Scope
        let releaseId: String
        let manifestId: String
        let objectIds: [String]
        var status: String
    }

    private struct LeaseKey: Hashable {
        let lynxAppId: String
        let releaseId: String
        let manifestId: String?
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
        self.baseDirectory = baseDirectory.standardizedFileURL
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

    func registerEmbedded(_ release: OtaInstalledRelease) async throws {
        try validateAppId(release.context.lynxAppId)
        // embedded bytes 属于 App Bundle；注册只保存逻辑元数据，不能要求把它们复制到
        // OTA Store，也不能因为旧 embedded 路径在测试/升级后变化而阻断启动。
        for bundle in release.bundles {
            _ = try safeBundlePath(bundle.bundlePath)
            _ = try normalizeSha256(bundle.bundleSha256)
        }
        try ensureAppDirectories(lynxAppId: release.context.lynxAppId)
        embeddedReleases[release.context.lynxAppId] = release

        let descriptor = EmbeddedDescriptor(
            schemaVersion: 1,
            releaseId: release.context.releaseId,
            env: release.context.env.rawValue,
            hostApp: release.context.app.rawValue,
            lynxAppId: release.context.lynxAppId,
            platform: release.context.platform.rawValue,
            bundles: release.bundles.map {
                EmbeddedBundle(
                    pageId: $0.pageId,
                    bundleName: $0.bundleName,
                    bundlePath: $0.bundlePath,
                    bundleSha256: $0.bundleSha256,
                    size: Int(fileSize(URL(fileURLWithPath: $0.localFilePath)))
                )
            }
        )
        try writeDurableAtomic(try encoder.encode(descriptor), to: embeddedURL(lynxAppId: release.context.lynxAppId))

        let existing = readState(app: release.context.app, lynxAppId: release.context.lynxAppId)
        if existing == nil {
            let state = State(
                schemaVersion: Self.storeSchemaVersion,
                generation: 0,
                scope: scope(for: release.context),
                current: ReleaseRef(kind: .embedded, releaseId: release.context.releaseId, manifestId: nil),
                previous: nil,
                candidate: nil
            )
            try commitState(state, app: release.context.app, lynxAppId: release.context.lynxAppId, operation: "register_embedded")
        }
    }

    func current(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease? {
        guard let state = readState(app: app, lynxAppId: lynxAppId) else { return nil }
        try ensureScope(state.scope, app: app, lynxAppId: lynxAppId)
        return try resolve(state.current, app: app, lynxAppId: lynxAppId)
    }

    /** 按 appId + SHA 复用任意已存在 CAS 对象，不要求它来自 current release。 */
    func existingObject(
        app: OtaAppID,
        lynxAppId: String,
        objectId: String,
        expectedSize: Int64?
    ) async throws -> URL? {
        try validateAppId(lynxAppId)
        let expectedSha256 = try normalizeSha256(objectId)
        let object = objectURL(lynxAppId: lynxAppId, objectId: expectedSha256)
        guard fileManager.fileExists(atPath: object.path) else { return nil }
        if let expectedSize {
            guard try validObject(
                object,
                expectedSha256: expectedSha256,
                expectedSize: expectedSize
            ) else { return nil }
        } else {
            guard try SHA256ChecksumValidator().sha256(for: object)
                .caseInsensitiveCompare(expectedSha256) == .orderedSame else {
                return nil
            }
        }
        return object
    }

    func staged(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease? {
        guard let journal = readyTransaction(app: app, lynxAppId: lynxAppId) else { return nil }
        return try resolve(
            ReleaseRef(kind: .downloaded, releaseId: journal.releaseId, manifestId: journal.manifestId),
            app: app,
            lynxAppId: lynxAppId
        )
    }

    func install(_ release: OtaInstalledRelease) async throws -> OtaInstalledRelease {
        if let current = try await current(app: release.context.app, lynxAppId: release.context.lynxAppId),
           current.context.releaseId == release.context.releaseId {
            return current
        }
        try await stage(release)
        return try await activate(app: release.context.app, lynxAppId: release.context.lynxAppId)
    }

    func stage(_ release: OtaInstalledRelease) async throws {
        try validateAppId(release.context.lynxAppId)
        try validateRelease(release)
        try ensureAppDirectories(lynxAppId: release.context.lynxAppId)
        try removeUnfinishedTransactions(lynxAppId: release.context.lynxAppId)
        try pruneApp(app: release.context.app, lynxAppId: release.context.lynxAppId)

        let transactionId = UUID().uuidString
        let transactionDirectory = transactionDirectory(
            lynxAppId: release.context.lynxAppId,
            transactionId: transactionId
        )
        let transactionObjects = transactionDirectory.appendingPathComponent("objects", isDirectory: true)
        try fileManager.createDirectory(at: transactionObjects, withIntermediateDirectories: true)

        var missingBytes: Int64 = 0
        for bundle in release.bundles {
            let object = objectURL(lynxAppId: release.context.lynxAppId, objectId: bundle.bundleSha256)
            if try !validObject(object, expectedSha256: bundle.bundleSha256, expectedSize: fileSize(URL(fileURLWithPath: bundle.localFilePath))) {
                missingBytes += fileSize(URL(fileURLWithPath: bundle.localFilePath))
            }
        }
        let requiredBytes = missingBytes + Self.metadataAllowanceBytes + max(Self.safetyReserveBytes, (missingBytes + 9) / 10)
        let availableBytes = capacityProbe.availableCapacity(at: baseDirectory)
        if availableBytes >= 0, availableBytes < requiredBytes {
            throw OtaSDKError.insufficientStorage(required: requiredBytes, available: availableBytes)
        }

        var casWriteCount = 0
        var casWriteBytes: Int64 = 0
        var manifestWriteCount = 0
        var localBundles: [LocalBundle] = []
        let placeholder = TransactionJournal(
            schemaVersion: Self.storeSchemaVersion,
            scope: scope(for: release.context),
            releaseId: release.context.releaseId,
            manifestId: "pending",
            objectIds: [],
            status: "staging"
        )
        try writeDurableAtomic(try encoder.encode(placeholder), to: journalURL(transactionDirectory))

        do {
            for bundle in release.bundles {
                let normalizedPath = try safeBundlePath(bundle.bundlePath)
                let expectedSha256 = try normalizeSha256(bundle.bundleSha256)
                let source = URL(fileURLWithPath: bundle.localFilePath)
                let size = fileSize(source)
                let object = objectURL(lynxAppId: release.context.lynxAppId, objectId: expectedSha256)
                if try !validObject(object, expectedSha256: expectedSha256, expectedSize: size) {
                    let part = transactionObjects.appendingPathComponent("\(expectedSha256).part", isDirectory: false)
                    try copyAndValidate(source: source, destination: part, expectedSha256: expectedSha256, expectedSize: size)
                    try faultInjector.check(.beforeObjectCommit)
                    try fileManager.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if try validObject(object, expectedSha256: expectedSha256, expectedSize: size) {
                        try removeItemIfPresent(part)
                    } else {
                        try removeItemIfPresent(object)
                        try fileManager.moveItem(at: part, to: object)
                        casWriteCount += 1
                        casWriteBytes += size
                    }
                    try faultInjector.check(.afterObjectCommit)
                }
                localBundles.append(
                    LocalBundle(
                        pageId: bundle.pageId,
                        bundleName: bundle.bundleName,
                        bundlePath: normalizedPath,
                        bundleSha256: expectedSha256,
                        objectId: expectedSha256,
                        remoteURL: bundle.remoteURL.absoluteString,
                        size: Int(size)
                    )
                )
            }

            let localManifest = makeManifest(release: release, bundles: localBundles)
            let transactionManifest = transactionDirectory.appendingPathComponent("manifest.json", isDirectory: false)
            try writeDurableAtomic(try encoder.encode(localManifest), to: transactionManifest)
            try faultInjector.check(.beforeManifestCommit)
            let finalManifest = manifestURL(
                lynxAppId: release.context.lynxAppId,
                manifestId: localManifest.manifestId
            )
            try fileManager.createDirectory(at: finalManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: finalManifest.path) {
                let existing = try readManifest(at: finalManifest)
                guard existing == localManifest else {
                    throw storageError("同一 Manifest ID 对应了不同内容")
                }
                try removeItemIfPresent(transactionManifest)
            } else {
                try fileManager.moveItem(at: transactionManifest, to: finalManifest)
                manifestWriteCount = 1
            }
            try faultInjector.check(.afterManifestCommit)

            let ready = TransactionJournal(
                schemaVersion: Self.storeSchemaVersion,
                scope: scope(for: release.context),
                releaseId: release.context.releaseId,
                manifestId: localManifest.manifestId,
                objectIds: localBundles.map(\.objectId),
                status: "ready"
            )
            try writeDurableAtomic(try encoder.encode(ready), to: journalURL(transactionDirectory))
            let objectStats = objectStatistics(lynxAppId: release.context.lynxAppId)
            lastOperation = OtaStoreOperationMetrics(
                operation: "stage",
                lynxAppId: release.context.lynxAppId,
                releaseId: release.context.releaseId,
                manifestId: localManifest.manifestId,
                casWriteCount: casWriteCount,
                casWriteBytes: casWriteBytes,
                manifestWriteCount: manifestWriteCount,
                objectCount: objectStats.count,
                objectBytes: objectStats.bytes
            )
        } catch {
            try? removeItemIfPresent(transactionDirectory)
            throw error
        }
    }

    func stageCandidate(_ release: OtaInstalledRelease) async throws {
        try await stage(release)
        guard let journal = readyTransaction(app: release.context.app, lynxAppId: release.context.lynxAppId) else {
            throw storageError("v3 candidate stage transaction 不存在")
        }
        var state = try stateOrEmbedded(app: release.context.app, lynxAppId: release.context.lynxAppId, context: release.context)
        state.candidate = CandidateState(
            release: ReleaseRef(kind: .downloaded, releaseId: journal.releaseId, manifestId: journal.manifestId),
            status: .pending,
            failureCount: 0,
            createdAt: Date(),
            trialStartedAt: nil
        )
        try commitState(state, app: release.context.app, lynxAppId: release.context.lynxAppId, operation: "stage_candidate")
        lastOperation = updatedMetrics(stateCommitCount: 1, operation: "stage_candidate", appId: release.context.lynxAppId)
        try removeItemIfPresent(journal.directory)
        try pruneApp(app: release.context.app, lynxAppId: release.context.lynxAppId)
    }

    func candidate(app: OtaAppID, lynxAppId: String) async throws -> OtaCandidateSnapshot? {
        guard let state = readState(app: app, lynxAppId: lynxAppId),
              let candidate = state.candidate,
              let release = try resolve(candidate.release, app: app, lynxAppId: lynxAppId) else {
            return nil
        }
        return OtaCandidateSnapshot(
            release: release,
            status: candidate.status,
            failureCount: candidate.failureCount,
            createdAt: candidate.createdAt,
            trialStartedAt: candidate.trialStartedAt
        )
    }

    func beginCandidateTrial(app: OtaAppID, lynxAppId: String) async throws -> OtaCandidateSnapshot {
        var state = try stateOrThrow(app: app, lynxAppId: lynxAppId)
        guard var candidateState = state.candidate else { throw OtaSDKError.missingCandidateRelease }
        if candidateState.status != .trial {
            candidateState.status = .trial
            candidateState.trialStartedAt = Date()
            state.candidate = candidateState
            try commitState(state, app: app, lynxAppId: lynxAppId, operation: "candidate_trial")
        }
        guard let snapshot = try await candidate(app: app, lynxAppId: lynxAppId) else {
            throw OtaSDKError.missingCandidateRelease
        }
        return snapshot
    }

    func confirmCandidate(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease {
        var state = try stateOrThrow(app: app, lynxAppId: lynxAppId)
        guard let candidate = state.candidate, candidate.status == .trial,
              let installed = try resolve(candidate.release, app: app, lynxAppId: lynxAppId) else {
            throw OtaSDKError.candidateNotInTrial
        }
        let oldCurrent = state.current
        state.current = candidate.release
        state.previous = oldCurrent
        state.candidate = nil
        try commitState(state, app: app, lynxAppId: lynxAppId, operation: "candidate_confirm")
        lastOperation = updatedMetrics(stateCommitCount: 1, operation: "candidate_confirm", appId: lynxAppId)
        try pruneApp(app: app, lynxAppId: lynxAppId)
        return installed
    }

    func candidateBundle(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> URL? {
        guard let state = readState(app: app, lynxAppId: lynxAppId),
              let candidate = state.candidate,
              let release = try resolve(candidate.release, app: app, lynxAppId: lynxAppId),
              let bundle = resolveBundle(named: bundleName, in: release) else { return nil }
        return URL(fileURLWithPath: bundle.localFilePath)
    }

    func acquireCurrentBundleLease(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> OtaBundleLease? {
        guard let state = readState(app: app, lynxAppId: lynxAppId) else { return nil }
        guard state.current.kind == .downloaded else { return nil }
        return try acquireBundleLease(
            reference: state.current,
            app: app,
            lynxAppId: lynxAppId,
            bundleName: bundleName
        )
    }

    func acquireCandidateBundleLease(app: OtaAppID, lynxAppId: String, bundleName: String) async throws -> OtaBundleLease? {
        guard let state = readState(app: app, lynxAppId: lynxAppId), let candidate = state.candidate else { return nil }
        return try acquireBundleLease(
            reference: candidate.release,
            app: app,
            lynxAppId: lynxAppId,
            bundleName: bundleName
        )
    }

    func discardCandidate(app: OtaAppID, lynxAppId: String) async throws {
        guard var state = readState(app: app, lynxAppId: lynxAppId), state.candidate != nil else { return }
        state.candidate = nil
        try commitState(state, app: app, lynxAppId: lynxAppId, operation: "candidate_discard")
        lastOperation = updatedMetrics(stateCommitCount: 1, operation: "candidate_discard", appId: lynxAppId)
        try pruneApp(app: app, lynxAppId: lynxAppId)
    }

    func recoverInterruptedCandidate(app: OtaAppID, lynxAppId: String) async throws {
        guard let state = readState(app: app, lynxAppId: lynxAppId), state.candidate?.status == .trial else { return }
        try await discardCandidate(app: app, lynxAppId: lynxAppId)
    }

    func activate(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease {
        guard let journal = readyTransaction(app: app, lynxAppId: lynxAppId),
              let installed = try resolve(
                  ReleaseRef(kind: .downloaded, releaseId: journal.releaseId, manifestId: journal.manifestId),
                  app: app,
                  lynxAppId: lynxAppId
              ) else {
            throw OtaSDKError.missingStagedRelease
        }
        var state = try stateOrEmbedded(
            app: app,
            lynxAppId: lynxAppId,
            context: installed.context
        )
        let oldCurrent = state.current
        state.current = ReleaseRef(kind: .downloaded, releaseId: journal.releaseId, manifestId: journal.manifestId)
        state.previous = oldCurrent.releaseId == journal.releaseId ? state.previous : oldCurrent
        state.candidate = nil
        try commitState(state, app: app, lynxAppId: lynxAppId, operation: "activate")
        lastOperation = updatedMetrics(stateCommitCount: 1, operation: "activate", appId: lynxAppId)
        try removeItemIfPresent(journal.directory)
        try pruneApp(app: app, lynxAppId: lynxAppId)
        return installed
    }

    func deleteDownloadedBundles(app: OtaAppID, lynxAppId: String) async throws {
        guard var state = readState(app: app, lynxAppId: lynxAppId) else { return }
        guard let embedded = embeddedReleases[lynxAppId] else {
            try removeItemIfPresent(appDirectory(lynxAppId: lynxAppId))
            return
        }
        state.generation += 1
        state.current = ReleaseRef(kind: .embedded, releaseId: embedded.context.releaseId, manifestId: nil)
        state.previous = nil
        state.candidate = nil
        try commitState(state, app: app, lynxAppId: lynxAppId, operation: "delete_downloaded")
        lastOperation = updatedMetrics(stateCommitCount: 1, operation: "delete_downloaded", appId: lynxAppId)
        try pruneApp(app: app, lynxAppId: lynxAppId)
    }

    func deleteAllDownloadedBundles() async throws {
        guard fileManager.fileExists(atPath: appsDirectory.path) else { return }
        let appDirectories = try fileManager.contentsOfDirectory(
            at: appsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for directory in appDirectories {
            let appId = directory.lastPathComponent
            guard let state = readAnyState(lynxAppId: appId),
                  let app = OtaAppID(rawValue: state.scope.hostApp) else { continue }
            try await deleteDownloadedBundles(app: app, lynxAppId: appId)
        }
    }

    func pruneAllUnreferencedReleases() async throws {
        guard fileManager.fileExists(atPath: appsDirectory.path) else { return }
        let directories = try fileManager.contentsOfDirectory(
            at: appsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for directory in directories {
            let appId = directory.lastPathComponent
            guard let state = readAnyState(lynxAppId: appId),
                  let app = OtaAppID(rawValue: state.scope.hostApp) else { continue }
            try pruneApp(app: app, lynxAppId: appId)
        }
    }

    func rollback(app: OtaAppID, lynxAppId: String) async throws -> OtaInstalledRelease? {
        guard var state = readState(app: app, lynxAppId: lynxAppId), let previous = state.previous,
              let restored = try resolve(previous, app: app, lynxAppId: lynxAppId) else { return nil }
        let oldCurrent = state.current
        state.current = previous
        state.previous = oldCurrent
        state.candidate = nil
        try faultInjector.check(.beforeRollbackCommit)
        try commitState(state, app: app, lynxAppId: lynxAppId, operation: "rollback")
        try faultInjector.check(.afterRollbackCommit)
        lastOperation = updatedMetrics(stateCommitCount: 1, operation: "rollback", appId: lynxAppId)
        try pruneApp(app: app, lynxAppId: lynxAppId)
        return restored
    }

    func storageSnapshot(maxFilesPerTree: Int) async throws -> OtaStorageSnapshot {
        let rootScan = try scanTree(baseDirectory, maxFiles: maxFilesPerTree)
        guard fileManager.fileExists(atPath: appsDirectory.path) else {
            return OtaStorageSnapshot(
                rootPath: baseDirectory.path,
                totalBytes: rootScan.totalBytes,
                fileCount: rootScan.fileCount,
                generatedAt: Date(),
                apps: []
            )
        }
        let directories = try fileManager.contentsOfDirectory(
            at: appsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let apps = try directories.map { try snapshotApp(lynxAppId: $0.lastPathComponent, maxFilesPerTree: maxFilesPerTree) }
        return OtaStorageSnapshot(
            rootPath: baseDirectory.path,
            totalBytes: rootScan.totalBytes,
            fileCount: rootScan.fileCount,
            generatedAt: Date(),
            apps: apps
        )
    }

    private func snapshotApp(lynxAppId: String, maxFilesPerTree: Int) throws -> OtaStorageAppSnapshot {
        let appDirectory = appDirectory(lynxAppId: lynxAppId)
        let state = readAnyState(lynxAppId: lynxAppId)
        let stateSnapshot = state.map {
            OtaStorageStateSnapshot(
                generation: $0.generation,
                currentReleaseId: $0.current.releaseId,
                currentKind: $0.current.kind.rawValue,
                previousReleaseId: $0.previous?.releaseId,
                previousKind: $0.previous?.kind.rawValue,
                currentManifestId: $0.current.manifestId,
                previousManifestId: $0.previous?.manifestId,
                candidateReleaseId: $0.candidate?.release.releaseId,
                candidateManifestId: $0.candidate?.release.manifestId,
                candidateStatus: $0.candidate?.status.rawValue
            )
        }
        let candidateSnapshot = state?.candidate.map {
            OtaStorageCandidateStateSnapshot(
                releaseId: $0.release.releaseId,
                status: $0.status.rawValue,
                failureCount: $0.failureCount
            )
        }

        let manifestFiles = try fileManager.fileExists(atPath: manifestsDirectory(lynxAppId: lynxAppId).path)
            ? fileManager.contentsOfDirectory(at: manifestsDirectory(lynxAppId: lynxAppId), includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            : []
        let leased = Set(leaseCounts.filter { $0.key.lynxAppId == lynxAppId && $0.value > 0 }.map { $0.key })
        let releases = manifestFiles.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url -> OtaStorageReleaseSnapshot in
            let manifestId = "sha256:" + url.deletingPathExtension().lastPathComponent
            let manifest = try? readManifest(at: url)
            var roles = Set<OtaStorageReleaseRole>()
            if let state, state.current.manifestId == manifestId { roles.insert(.current) }
            if let state, state.previous?.manifestId == manifestId { roles.insert(.previous) }
            if let state, state.candidate?.release.manifestId == manifestId { roles.insert(.candidate) }
            if leased.contains(where: { $0.manifestId == manifestId }) { roles.insert(.leased) }
            if roles.isEmpty { roles.insert(.orphan) }
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return OtaStorageReleaseSnapshot(
                releaseId: manifest?.releaseId ?? manifestId,
                roles: roles,
                totalBytes: bytes,
                fileCount: 1,
                manifestValid: manifest != nil && manifest?.lynxAppId == lynxAppId,
                files: [OtaStorageFileSnapshot(relativePath: url.lastPathComponent, byteCount: bytes, modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)],
                truncated: false,
                manifestId: manifestId,
                bundleCount: manifest?.bundles.count ?? 0,
                objectIds: manifest?.bundles.map(\.objectId) ?? []
            )
        }

        var objectRoles: [String: Set<OtaStorageReleaseRole>] = [:]
        var objectReleases: [String: Set<String>] = [:]
        for release in releases {
            for objectId in release.objectIds {
                objectRoles[objectId, default: []].formUnion(release.roles)
                objectReleases[objectId, default: []].insert(release.releaseId)
            }
        }
        let objectURLs = try objectURLs(lynxAppId: lynxAppId)
        let objects = objectURLs.map { url -> OtaStorageObjectSnapshot in
            let objectId = "sha256:" + String(url.lastPathComponent.dropLast(".lynx.bundle".count))
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return OtaStorageObjectSnapshot(
                objectId: objectId,
                byteCount: bytes,
                roles: objectRoles[objectId, default: [.orphan]],
                referencedReleaseIds: objectReleases[objectId, default: []].sorted()
            )
        }
        let transactionURLs = fileManager.fileExists(atPath: transactionsDirectory(lynxAppId: lynxAppId).path)
            ? try fileManager.contentsOfDirectory(at: transactionsDirectory(lynxAppId: lynxAppId), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            : []
        let staging = try transactionURLs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let scan = try scanTree(url, maxFiles: maxFilesPerTree)
            return OtaStorageStagingSnapshot(transactionName: url.lastPathComponent, totalBytes: scan.totalBytes, fileCount: scan.fileCount, files: scan.files, truncated: scan.truncated)
        }
        let appScan = try scanTree(appDirectory, maxFiles: maxFilesPerTree)
        let objectBytes = objects.reduce(Int64(0)) { $0 + $1.byteCount }
        let manifestBytes = releases.reduce(Int64(0)) { $0 + $1.totalBytes }
        return OtaStorageAppSnapshot(
            appId: lynxAppId,
            state: stateSnapshot,
            candidate: candidateSnapshot,
            releases: releases,
            staging: staging,
            totalBytes: appScan.totalBytes,
            fileCount: appScan.fileCount,
            objects: objects,
            objectCount: objects.count,
            objectBytes: objectBytes,
            manifestBytes: manifestBytes,
            lastOperation: lastOperation?.lynxAppId == lynxAppId ? lastOperation : nil
        )
    }

    private func acquireBundleLease(
        reference: ReleaseRef,
        app: OtaAppID,
        lynxAppId: String,
        bundleName: String
    ) throws -> OtaBundleLease? {
        guard let release = try resolve(reference, app: app, lynxAppId: lynxAppId),
              let bundle = resolveBundle(named: bundleName, in: release) else { return nil }
        let fileURL = URL(fileURLWithPath: bundle.localFilePath)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let key = LeaseKey(lynxAppId: lynxAppId, releaseId: release.context.releaseId, manifestId: reference.manifestId)
        leaseCounts[key, default: 0] += 1
        return OtaBundleLease(
            release: release,
            bundle: bundle,
            fileURL: fileURL,
            closeAction: { [weak self] in
                await self?.releaseLease(key)
            }
        )
    }

    private func releaseLease(_ key: LeaseKey) {
        guard let count = leaseCounts[key] else { return }
        if count <= 1 { leaseCounts.removeValue(forKey: key) } else { leaseCounts[key] = count - 1 }
        let app = readAnyState(lynxAppId: key.lynxAppId).flatMap { OtaAppID(rawValue: $0.scope.hostApp) } ?? .capp
        try? pruneApp(app: app, lynxAppId: key.lynxAppId)
    }

    private func resolve(_ reference: ReleaseRef, app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease? {
        switch reference.kind {
        case .embedded:
            return embeddedReleases[lynxAppId]
        case .downloaded:
            guard let manifestId = reference.manifestId else { return nil }
            let manifest = try readManifest(at: manifestURL(lynxAppId: lynxAppId, manifestId: manifestId))
            guard manifest.releaseId == reference.releaseId,
                  manifest.lynxAppId == lynxAppId,
                  manifest.hostApp == app.rawValue,
                  manifest.platform == OtaPlatform.ios.rawValue else {
                throw storageError("v3 Manifest scope 不匹配")
            }
            return try installedRelease(from: manifest, app: app, lynxAppId: lynxAppId)
        }
    }

    private func installedRelease(from manifest: LocalManifest, app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease {
        guard manifest.manifestId == makeManifestId(manifest) else { throw storageError("v3 Manifest digest 不匹配") }
        guard let env = OtaEnvironment(rawValue: manifest.env),
              let status = OtaReleaseStatus(rawValue: manifest.status) else { throw storageError("v3 Manifest 枚举非法") }
        let bundles = try manifest.bundles.map { bundle -> OtaInstalledBundle in
            let path = try safeBundlePath(bundle.bundlePath)
            let object = objectURL(lynxAppId: lynxAppId, objectId: bundle.objectId)
            guard try validObject(object, expectedSha256: bundle.objectId, expectedSize: Int64(bundle.size)) else {
                throw OtaSDKError.fileNotFound(object.path)
            }
            return OtaInstalledBundle(
                pageId: bundle.pageId,
                bundlePath: path,
                bundleSha256: bundle.bundleSha256,
                remoteURL: URL(string: bundle.remoteURL) ?? object,
                localFilePath: object.path
            )
        }
        return OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: env,
                app: app,
                lynxAppId: lynxAppId,
                releaseId: manifest.releaseId,
                platform: .ios,
                status: status
            ),
            installedAt: manifest.installedAt,
            bundles: bundles
        )
    }

    private func makeManifest(release: OtaInstalledRelease, bundles: [LocalBundle]) -> LocalManifest {
        // JSONEncoder 的 ISO8601 策略按秒持久化；先把内存 Date 规范化，保证同一
        // release 在同一秒内重放 stage 时，Manifest ID 与内容比较都保持幂等。
        let installedAt = canonicalManifestDate(release.installedAt)
        let input = ManifestHashInput(
            schemaVersion: Self.manifestSchemaVersion,
            env: release.context.env.rawValue,
            hostApp: release.context.app.rawValue,
            lynxAppId: release.context.lynxAppId,
            releaseId: release.context.releaseId,
            platform: release.context.platform.rawValue,
            status: OtaReleaseStatus.active.rawValue,
            installedAt: installedAt,
            bundles: bundles
        )
        let manifestId = digest(try! encoder.encode(input))
        return LocalManifest(
            schemaVersion: Self.manifestSchemaVersion,
            manifestId: manifestId,
            env: release.context.env.rawValue,
            hostApp: release.context.app.rawValue,
            lynxAppId: release.context.lynxAppId,
            releaseId: release.context.releaseId,
            platform: release.context.platform.rawValue,
            status: OtaReleaseStatus.active.rawValue,
            installedAt: installedAt,
            bundles: bundles
        )
    }

    private func makeManifestId(_ manifest: LocalManifest) -> String {
        let input = ManifestHashInput(
            schemaVersion: manifest.schemaVersion,
            env: manifest.env,
            hostApp: manifest.hostApp,
            lynxAppId: manifest.lynxAppId,
            releaseId: manifest.releaseId,
            platform: manifest.platform,
            status: manifest.status,
            installedAt: manifest.installedAt,
            bundles: manifest.bundles
        )
        return digest(try! encoder.encode(input))
    }

    private func canonicalManifestDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private func commitState(_ state: State, app: OtaAppID, lynxAppId: String, operation: String) throws {
        try faultInjector.check(.beforeStateCommit)
        try writeDurableAtomic(try encoder.encode(state), to: stateURL(lynxAppId: lynxAppId))
        try faultInjector.check(.afterStateCommit)
        if lastOperation == nil || lastOperation?.lynxAppId != lynxAppId {
            lastOperation = OtaStoreOperationMetrics(operation: operation, lynxAppId: lynxAppId, stateCommitCount: 1)
        }
    }

    private func updatedMetrics(stateCommitCount: Int, operation: String, appId: String) -> OtaStoreOperationMetrics {
        let base = lastOperation
        let objects = objectStatistics(lynxAppId: appId)
        return OtaStoreOperationMetrics(
            operation: operation,
            lynxAppId: appId,
            releaseId: base?.releaseId,
            manifestId: base?.manifestId,
            downloadedBundleCount: base?.downloadedBundleCount ?? 0,
            downloadedBytes: base?.downloadedBytes ?? 0,
            casWriteCount: base?.casWriteCount ?? 0,
            casWriteBytes: base?.casWriteBytes ?? 0,
            byteCopyCount: 0,
            copiedBytes: 0,
            manifestWriteCount: base?.manifestWriteCount ?? 0,
            stateCommitCount: (base?.stateCommitCount ?? 0) + stateCommitCount,
            objectCount: objects.count,
            objectBytes: objects.bytes
        )
    }

    private func stateOrThrow(app: OtaAppID, lynxAppId: String) throws -> State {
        guard let state = readState(app: app, lynxAppId: lynxAppId) else { throw OtaSDKError.missingCurrentRelease }
        try ensureScope(state.scope, app: app, lynxAppId: lynxAppId)
        return state
    }

    private func stateOrEmbedded(app: OtaAppID, lynxAppId: String, context: OtaCurrentReleaseContext) throws -> State {
        if let state = readState(app: app, lynxAppId: lynxAppId) { return state }
        return State(
            schemaVersion: Self.storeSchemaVersion,
            generation: 0,
            scope: scope(for: context),
            current: ReleaseRef(kind: .embedded, releaseId: context.releaseId, manifestId: nil),
            previous: nil,
            candidate: nil
        )
    }

    private func readState(app: OtaAppID, lynxAppId: String) -> State? {
        guard let data = try? Data(contentsOf: stateURL(lynxAppId: lynxAppId)),
              let state = try? decoder.decode(State.self, from: data),
              state.schemaVersion == Self.storeSchemaVersion,
              state.scope.hostApp == app.rawValue,
              state.scope.lynxAppId == lynxAppId else { return nil }
        return state
    }

    private func readAnyState(lynxAppId: String) -> State? {
        guard let data = try? Data(contentsOf: stateURL(lynxAppId: lynxAppId)),
              let state = try? decoder.decode(State.self, from: data),
              state.schemaVersion == Self.storeSchemaVersion,
              state.scope.lynxAppId == lynxAppId else { return nil }
        return state
    }

    private func readManifest(at url: URL) throws -> LocalManifest {
        let manifest = try decoder.decode(LocalManifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == Self.manifestSchemaVersion,
              manifest.manifestId == makeManifestId(manifest) else {
            throw storageError("v3 Manifest schema 或 digest 不匹配")
        }
        return manifest
    }

    private func readyTransaction(app: OtaAppID, lynxAppId: String) -> (releaseId: String, manifestId: String, directory: URL)? {
        let root = transactionsDirectory(lynxAppId: lynxAppId)
        guard let directories = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        return directories.compactMap { directory -> (String, String, URL)? in
            guard let journal = try? decoder.decode(TransactionJournal.self, from: Data(contentsOf: journalURL(directory))), journal.status == "ready",
                  journal.scope.hostApp == app.rawValue, journal.scope.lynxAppId == lynxAppId else { return nil }
            return (journal.releaseId, journal.manifestId, directory)
        }.sorted { $0.2.lastPathComponent < $1.2.lastPathComponent }.last
    }

    private func removeUnfinishedTransactions(lynxAppId: String) throws {
        let root = transactionsDirectory(lynxAppId: lynxAppId)
        guard fileManager.fileExists(atPath: root.path) else { return }
        for directory in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let journal = try? decoder.decode(TransactionJournal.self, from: Data(contentsOf: journalURL(directory))), journal.status == "ready" else {
                try removeItemIfPresent(directory)
                continue
            }
        }
    }

    private func pruneApp(app: OtaAppID, lynxAppId: String) throws {
        let stateFile = stateURL(lynxAppId: lynxAppId)
        if fileManager.fileExists(atPath: stateFile.path), readState(app: app, lynxAppId: lynxAppId) == nil {
            return
        }
        let state = readState(app: app, lynxAppId: lynxAppId)
        var retainedManifestIds = Set<String>()
        for reference in [state?.current, state?.previous, state?.candidate?.release].compactMap({ $0 }) {
            if let manifestId = reference.manifestId { retainedManifestIds.insert(manifestId) }
        }
        let leased = leaseCounts.filter { $0.key.lynxAppId == lynxAppId && $0.value > 0 }
        retainedManifestIds.formUnion(leased.compactMap { $0.key.manifestId })

        let manifestRoot = manifestsDirectory(lynxAppId: lynxAppId)
        let manifestURLs = fileManager.fileExists(atPath: manifestRoot.path)
            ? try fileManager.contentsOfDirectory(at: manifestRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension == "json" }
            : []
        var manifests: [(id: String, manifest: LocalManifest)] = []
        for url in manifestURLs {
            guard let manifest = try? readManifest(at: url) else { return }
            manifests.append(("sha256:" + url.deletingPathExtension().lastPathComponent, manifest))
        }
        var retainedObjectIds = Set<String>()
        for item in manifests where retainedManifestIds.contains(item.id) {
            retainedObjectIds.formUnion(item.manifest.bundles.map(\.objectId))
        }

        let transactionRoot = transactionsDirectory(lynxAppId: lynxAppId)
        if fileManager.fileExists(atPath: transactionRoot.path) {
            for directory in try fileManager.contentsOfDirectory(at: transactionRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let journal = try? decoder.decode(TransactionJournal.self, from: Data(contentsOf: journalURL(directory))) else {
                    try removeItemIfPresent(directory)
                    continue
                }
                if journal.status == "ready" {
                    retainedManifestIds.insert(journal.manifestId)
                    retainedObjectIds.formUnion(journal.objectIds)
                } else {
                    try removeItemIfPresent(directory)
                }
            }
        }

        for item in manifests where !retainedManifestIds.contains(item.id) {
            try removeItemIfPresent(manifestURL(lynxAppId: lynxAppId, manifestId: item.id))
        }
        for object in try objectURLs(lynxAppId: lynxAppId) {
            let id = "sha256:" + String(object.lastPathComponent.dropLast(".lynx.bundle".count))
            if !retainedObjectIds.contains(id) { try removeItemIfPresent(object) }
        }
    }

    private func objectStatistics(lynxAppId: String) -> (count: Int, bytes: Int64) {
        let urls = (try? objectURLs(lynxAppId: lynxAppId)) ?? []
        return (urls.count, urls.reduce(Int64(0)) { $0 + fileSize($1) })
    }

    private func objectURLs(lynxAppId: String) throws -> [URL] {
        let root = objectsDirectory(lynxAppId: lynxAppId)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "bundle",
                  url.lastPathComponent.replacingOccurrences(of: ".lynx.bundle", with: "").range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func validObject(_ url: URL, expectedSha256: String, expectedSize: Int64) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path), fileSize(url) == expectedSize else { return false }
        return try SHA256ChecksumValidator().sha256(for: url).caseInsensitiveCompare(expectedSha256) == .orderedSame
    }

    private func copyAndValidate(source: URL, destination: URL, expectedSha256: String, expectedSize: Int64) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try removeItemIfPresent(destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else { throw storageError("无法创建 CAS part 文件") }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        while true {
            let chunk = input.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            output.write(chunk)
        }
        try output.synchronize()
        guard try validObject(destination, expectedSha256: expectedSha256, expectedSize: expectedSize) else {
            throw OtaSDKError.checksumMismatch(expected: expectedSha256, actual: (try? SHA256ChecksumValidator().sha256(for: destination)) ?? "unknown")
        }
    }

    private func ensureAppDirectories(lynxAppId: String) throws {
        try validateAppId(lynxAppId)
        try fileManager.createDirectory(at: appsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appDirectory(lynxAppId: lynxAppId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: objectsDirectory(lynxAppId: lynxAppId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: manifestsDirectory(lynxAppId: lynxAppId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transactionsDirectory(lynxAppId: lynxAppId), withIntermediateDirectories: true)
    }

    private func writeDurableAtomic(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private func removeItemIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func scanTree(_ root: URL, maxFiles: Int) throws -> TreeScan {
        guard fileManager.fileExists(atPath: root.path) else { return TreeScan(totalBytes: 0, fileCount: 0, files: [], truncated: false) }
        var totalBytes: Int64 = 0
        var fileCount = 0
        var files: [OtaStorageFileSnapshot] = []
        var truncated = false
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else {
            return TreeScan(totalBytes: 0, fileCount: 0, files: [], truncated: false)
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            totalBytes += bytes
            fileCount += 1
            if files.count < maxFiles {
                files.append(OtaStorageFileSnapshot(relativePath: String(url.path.dropFirst(root.path.count + 1)), byteCount: bytes, modifiedAt: values.contentModificationDate ?? .distantPast))
            } else {
                truncated = true
            }
        }
        return TreeScan(totalBytes: totalBytes, fileCount: fileCount, files: files.sorted { $0.relativePath < $1.relativePath }, truncated: truncated)
    }

    private func scope(for context: OtaCurrentReleaseContext) -> Scope {
        Scope(env: context.env.rawValue, hostApp: context.app.rawValue, lynxAppId: context.lynxAppId, platform: context.platform.rawValue)
    }

    private func ensureScope(_ scope: Scope, app: OtaAppID, lynxAppId: String) throws {
        guard scope.hostApp == app.rawValue, scope.lynxAppId == lynxAppId, scope.platform == OtaPlatform.ios.rawValue else {
            throw storageError("v3 State scope 不匹配")
        }
    }

    private func validateRelease(_ release: OtaInstalledRelease) throws {
        guard release.context.status == .active else { throw OtaSDKError.invalidReleaseStatus(release.context.status.rawValue) }
        guard !release.bundles.isEmpty else { throw storageError("Release 不包含 Bundle") }
        for bundle in release.bundles {
            _ = try safeBundlePath(bundle.bundlePath)
            _ = try normalizeSha256(bundle.bundleSha256)
            let source = URL(fileURLWithPath: bundle.localFilePath)
            guard fileManager.fileExists(atPath: source.path) else { throw OtaSDKError.fileNotFound(source.path) }
            let size = fileSize(source)
            guard size > 0, size <= Self.maxBundleBytes else { throw OtaSDKError.bundleTooLarge(bundle.bundlePath) }
        }
    }

    private func resolveBundle(named bundleName: String, in release: OtaInstalledRelease) -> OtaInstalledBundle? {
        let pathMatches = release.bundles.filter { $0.bundlePath == bundleName }
        if pathMatches.count == 1 { return pathMatches[0] }
        if pathMatches.count > 1 { return nil }
        let nameMatches = release.bundles.filter { $0.bundleName == bundleName }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func safeBundlePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsPath = trimmed as NSString
        guard !trimmed.isEmpty,
              !nsPath.isAbsolutePath,
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              !trimmed.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                  let segment = String($0)
                  return segment.isEmpty || segment == "." || segment == ".."
              }) else { throw OtaSDKError.invalidBundleName(raw) }
        return trimmed
    }

    private func validateAppId(_ value: String) throws {
        guard value.range(of: "^[0-9]{8}$", options: .regularExpression) != nil else { throw OtaSDKError.invalidBundleName(value) }
    }

    private func normalizeSha256(_ raw: String) throws -> String {
        let value = raw.lowercased()
        guard value.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil else { throw storageError("Bundle SHA-256 格式错误") }
        return value
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func storageError(_ message: String) -> NSError {
        NSError(domain: "com.lynx.ota.store.v3", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private var appsDirectory: URL { baseDirectory.appendingPathComponent("apps", isDirectory: true) }

    private func appDirectory(lynxAppId: String) -> URL { appsDirectory.appendingPathComponent(lynxAppId, isDirectory: true) }

    private func objectsDirectory(lynxAppId: String) -> URL { appDirectory(lynxAppId: lynxAppId).appendingPathComponent("objects", isDirectory: true) }

    private func manifestsDirectory(lynxAppId: String) -> URL { appDirectory(lynxAppId: lynxAppId).appendingPathComponent("manifests", isDirectory: true) }

    private func transactionsDirectory(lynxAppId: String) -> URL { appDirectory(lynxAppId: lynxAppId).appendingPathComponent("transactions", isDirectory: true) }

    private func stateURL(lynxAppId: String) -> URL { appDirectory(lynxAppId: lynxAppId).appendingPathComponent("state.json", isDirectory: false) }

    private func embeddedURL(lynxAppId: String) -> URL { appDirectory(lynxAppId: lynxAppId).appendingPathComponent("embedded.json", isDirectory: false) }

    private func manifestURL(lynxAppId: String, manifestId: String) -> URL {
        let fileName = manifestId.replacingOccurrences(of: "sha256:", with: "")
        return manifestsDirectory(lynxAppId: lynxAppId).appendingPathComponent("\(fileName).json", isDirectory: false)
    }

    private func objectURL(lynxAppId: String, objectId: String) -> URL {
        let value = objectId.replacingOccurrences(of: "sha256:", with: "").lowercased()
        return objectsDirectory(lynxAppId: lynxAppId)
            .appendingPathComponent(String(value.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(value).lynx.bundle", isDirectory: false)
    }

    private func transactionDirectory(lynxAppId: String, transactionId: String) -> URL {
        transactionsDirectory(lynxAppId: lynxAppId).appendingPathComponent(transactionId, isDirectory: true)
    }

    private func journalURL(_ transactionDirectory: URL) -> URL { transactionDirectory.appendingPathComponent("transaction.json", isDirectory: false) }
}
