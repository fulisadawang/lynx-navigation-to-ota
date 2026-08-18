import Foundation

/// iOS OTA 的 canonical durable store。
///
/// 旧版 `FileOtaReleaseStore` 仍负责 legacy pointer 兼容读取；新事务只把
/// downloaded Release 的引用写入 state，把 Bundle 本体放入自包含的 release 目录。
actor CanonicalOtaStore {
    private let baseDirectory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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

    private struct ReleaseRef: Codable {
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

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func registerEmbedded(_ release: OtaInstalledRelease) throws {
        try ensureDirectories()
        let descriptor = EmbeddedDescriptor(release: release)
        try writeAtomic(try encoder.encode(descriptor), to: embeddedURL(app: release.context.app, lynxAppId: release.context.lynxAppId))
        guard readState(app: release.context.app, lynxAppId: release.context.lynxAppId) == nil else {
            return
        }
        let state = State(
            schemaVersion: 1,
            generation: 0,
            scope: scope(for: release.context),
            current: ReleaseRef(kind: .embedded, releaseId: release.context.releaseId),
            previous: nil
        )
        try writeState(state, app: release.context.app, lynxAppId: release.context.lynxAppId)
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

    func adoptLegacy(_ release: OtaInstalledRelease) throws {
        try ensureDirectories()
        guard release.context.releaseId != "embedded" else {
            try registerEmbedded(release)
            return
        }
        if readState(app: release.context.app, lynxAppId: release.context.lynxAppId) != nil {
            return
        }
        try publishRelease(release)
        let state = State(
            schemaVersion: 1,
            generation: 0,
            scope: scope(for: release.context),
            current: ReleaseRef(kind: .downloaded, releaseId: release.context.releaseId),
            previous: nil
        )
        try writeState(state, app: release.context.app, lynxAppId: release.context.lynxAppId)
    }

    func stage(_ release: OtaInstalledRelease) throws {
        try ensureDirectories()
        try validateRelease(release)
        let transactionId = UUID().uuidString
        let staging = stagingDirectory(releaseId: release.context.releaseId, transactionId: transactionId)
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
            try publishStaging(staging, releaseId: release.context.releaseId)
            try writeAtomic(
                try encoder.encode(
                    StagedState(
                        schemaVersion: 1,
                        scope: scope(for: release.context),
                        release: ReleaseRef(kind: .downloaded, releaseId: release.context.releaseId)
                    )
                ),
                to: stagedURL(app: release.context.app, lynxAppId: release.context.lynxAppId)
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
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
            schemaVersion: 1,
            generation: (oldState?.generation ?? 0) + 1,
            scope: staged.scope,
            current: staged.release,
            previous: previous
        )
        try writeState(next, app: app, lynxAppId: lynxAppId)
        try removeItemIfPresent(stagedURL(app: app, lynxAppId: lynxAppId))
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
            schemaVersion: 1,
            generation: state.generation + 1,
            scope: state.scope,
            current: previous,
            previous: nil
        )
        try writeState(next, app: app, lynxAppId: lynxAppId)
        return restored
    }

    func deleteDownloadedBundles(app: OtaAppID, lynxAppId: String) throws {
        try removeItemIfPresent(stateURL(app: app, lynxAppId: lynxAppId))
        try removeItemIfPresent(stagedURL(app: app, lynxAppId: lynxAppId))
        guard fileManager.fileExists(atPath: releasesDirectory.path) else { return }
        for item in try fileManager.contentsOfDirectory(at: releasesDirectory, includingPropertiesForKeys: nil) {
            guard let manifest = try? readManifest(at: item),
                  manifest.hostApp == app.rawValue,
                  manifest.lynxAppId == lynxAppId else { continue }
            try removeItemIfPresent(item)
        }
        if let embedded = try resolveEmbedded(app: app, lynxAppId: lynxAppId) {
            try registerEmbedded(embedded)
        }
    }

    func deleteAllDownloadedBundles() throws {
        try removeItemIfPresent(releasesDirectory)
        try removeItemIfPresent(stagingDirectoryRoot)
        try removeItemIfPresent(statesDirectory)
        try ensureDirectories()
        if let enumerator = fileManager.enumerator(at: embeddedDirectory, includingPropertiesForKeys: nil) {
            for case let descriptor as URL in enumerator where descriptor.lastPathComponent == "release.json" {
                if let data = try? Data(contentsOf: descriptor),
                   let value = try? decoder.decode(EmbeddedDescriptor.self, from: data) {
                    try registerEmbedded(value.release)
                }
            }
        }
    }

    private var releasesDirectory: URL { baseDirectory.appendingPathComponent("releases", isDirectory: true) }
    private var stagingDirectoryRoot: URL { baseDirectory.appendingPathComponent(".staging", isDirectory: true) }
    private var statesDirectory: URL { baseDirectory.appendingPathComponent("states", isDirectory: true) }
    private var embeddedDirectory: URL { baseDirectory.appendingPathComponent("embedded", isDirectory: true) }

    private func stateURL(app: OtaAppID, lynxAppId: String) -> URL {
        statesDirectory.appendingPathComponent("\(safeFileName(app.rawValue))_\(safeFileName(lynxAppId)).json", isDirectory: false)
    }

    private func stagedURL(app: OtaAppID, lynxAppId: String) -> URL {
        statesDirectory.appendingPathComponent(".\(safeFileName(app.rawValue))_\(safeFileName(lynxAppId)).staged.json", isDirectory: false)
    }

    private func embeddedURL(app: OtaAppID, lynxAppId: String) -> URL {
        embeddedDirectory
            .appendingPathComponent(safeFileName(app.rawValue), isDirectory: true)
            .appendingPathComponent(safeFileName(lynxAppId), isDirectory: true)
            .appendingPathComponent("release.json", isDirectory: false)
    }

    private func releaseDirectory(_ releaseId: String) throws -> URL {
        try safeReleaseId(releaseId)
        return releasesDirectory.appendingPathComponent(releaseId, isDirectory: true)
    }

    private func stagingDirectory(releaseId: String, transactionId: String) -> URL {
        stagingDirectoryRoot.appendingPathComponent("\(releaseId).\(transactionId)", isDirectory: true)
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
        return try? decoder.decode(State.self, from: data)
    }

    private func readStaged(app: OtaAppID, lynxAppId: String) -> StagedState? {
        guard let data = try? Data(contentsOf: stagedURL(app: app, lynxAppId: lynxAppId)) else { return nil }
        return try? decoder.decode(StagedState.self, from: data)
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
            let directory = try releaseDirectory(reference.releaseId)
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

    private func publishRelease(_ release: OtaInstalledRelease) throws {
        let staging = stagingDirectory(releaseId: release.context.releaseId, transactionId: "adopt-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var bundles: [LocalBundle] = []
            for bundle in release.bundles {
                let path = try safeBundlePath(bundle.bundlePath)
                let source = URL(fileURLWithPath: bundle.localFilePath)
                let destination = staging.appendingPathComponent(path, isDirectory: false)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                let size = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
                let byteCount = size?.intValue ?? -1
                guard byteCount > 0, byteCount <= 20 * 1024 * 1024 else { throw storageError("legacy Bundle 大小非法") }
                let actual = try SHA256ChecksumValidator().sha256(for: destination)
                guard actual.caseInsensitiveCompare(bundle.bundleSha256) == .orderedSame else {
                    throw OtaSDKError.checksumMismatch(expected: bundle.bundleSha256, actual: actual)
                }
                bundles.append(LocalBundle(pageId: bundle.pageId, bundleName: bundle.bundleName, bundlePath: path, bundleSha256: bundle.bundleSha256, remoteURL: bundle.remoteURL.absoluteString, size: byteCount))
            }
            let manifest = LocalManifest(schemaVersion: 1, env: release.context.env.rawValue, hostApp: release.context.app.rawValue, lynxAppId: release.context.lynxAppId, releaseId: release.context.releaseId, platform: release.context.platform.rawValue, status: OtaReleaseStatus.active.rawValue, installedAt: release.installedAt, bundles: bundles)
            try writeAtomic(try encoder.encode(manifest), to: staging.appendingPathComponent("release-manifest.json", isDirectory: false))
            try verifyReleaseDirectory(staging, expected: manifest)
            try publishStaging(staging, releaseId: release.context.releaseId)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func publishStaging(_ staging: URL, releaseId: String) throws {
        let target = try releaseDirectory(releaseId)
        try fileManager.createDirectory(at: releasesDirectory, withIntermediateDirectories: true)
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
        try fileManager.createDirectory(at: releasesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectoryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: statesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: embeddedDirectory, withIntermediateDirectories: true)
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

    private func safeFileName(_ raw: String) -> String {
        raw.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.map(String.init).joined()
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
}
