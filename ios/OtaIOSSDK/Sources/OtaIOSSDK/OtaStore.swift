import Foundation

public actor FileOtaReleaseStore {
    private let baseDirectory: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func currentRelease(lynxAppId: String? = nil) -> OtaInstalledRelease? {
        if let lynxAppId,
           let scoped = try? readReleasePointer(at: currentReleasePointerURL(lynxAppId: lynxAppId)) {
            return scoped
        }
        guard let legacy = try? readReleasePointer(at: legacyCurrentReleasePointerURL) else {
            return nil
        }
        if let lynxAppId, legacy.context.lynxAppId != lynxAppId {
            return nil
        }
        return legacy
    }

    /// 新布局按 hostApp + lynxAppId 隔离；读取失败时回退到旧 pointer，避免升级 SDK 后丢失已安装版本。
    public func currentRelease(app: OtaAppID, lynxAppId: String) -> OtaInstalledRelease? {
        if let scoped = try? readReleasePointer(at: currentReleasePointerURL(app: app, lynxAppId: lynxAppId)),
           scoped.context.app == app,
           scoped.context.lynxAppId == lynxAppId {
            return scoped
        }
        // 旧 pointer 没有 host 目录，回退时仍校验其中的 hostApp，避免同一
        // lynxAppId 在多个宿主之间串读。
        guard let legacy = currentRelease(lynxAppId: lynxAppId), legacy.context.app == app else {
            return nil
        }
        return legacy
    }

    public func stagedRelease(lynxAppId: String? = nil) -> OtaInstalledRelease? {
        if let lynxAppId {
            return try? readReleasePointer(at: stagedReleasePointerURL(lynxAppId: lynxAppId))
        }
        return try? readReleasePointer(at: legacyStagedReleasePointerURL)
    }

    public func stagedRelease(app: OtaAppID, lynxAppId: String) -> OtaInstalledRelease? {
        if let scoped = try? readReleasePointer(at: stagedReleasePointerURL(app: app, lynxAppId: lynxAppId)),
           scoped.context.app == app,
           scoped.context.lynxAppId == lynxAppId {
            return scoped
        }
        guard let legacy = stagedRelease(lynxAppId: lynxAppId), legacy.context.app == app else {
            return nil
        }
        return legacy
    }

    public func embeddedRelease(lynxAppId: String? = nil) -> OtaInstalledRelease? {
        if let lynxAppId,
           let scoped = try? readReleasePointer(at: embeddedReleasePointerURL(lynxAppId: lynxAppId)) {
            return scoped
        }
        guard let legacy = try? readReleasePointer(at: legacyEmbeddedReleasePointerURL) else {
            return nil
        }
        if let lynxAppId, legacy.context.lynxAppId != lynxAppId {
            return nil
        }
        return legacy
    }

    public func embeddedRelease(app: OtaAppID, lynxAppId: String) -> OtaInstalledRelease? {
        if let scoped = try? readReleasePointer(at: embeddedReleasePointerURL(app: app, lynxAppId: lynxAppId)),
           scoped.context.app == app,
           scoped.context.lynxAppId == lynxAppId {
            return scoped
        }
        guard let legacy = embeddedRelease(lynxAppId: lynxAppId), legacy.context.app == app else {
            return nil
        }
        return legacy
    }

    public func saveEmbeddedRelease(_ release: OtaInstalledRelease) throws {
        try ensureBaseDirectory()
        try writeReleasePointer(
            release,
            to: embeddedReleasePointerURL(app: release.context.app, lynxAppId: release.context.lynxAppId)
        )
        try writeReleasePointer(release, to: embeddedReleasePointerURL(lynxAppId: release.context.lynxAppId))
        if release.context.lynxAppId == OtaDefaults.lynxAppId {
            try writeReleasePointer(release, to: legacyEmbeddedReleasePointerURL)
        }
        if currentRelease(app: release.context.app, lynxAppId: release.context.lynxAppId) == nil {
            try writeReleasePointer(
                release,
                to: currentReleasePointerURL(app: release.context.app, lynxAppId: release.context.lynxAppId)
            )
            try writeReleasePointer(release, to: currentReleasePointerURL(lynxAppId: release.context.lynxAppId))
            if release.context.lynxAppId == OtaDefaults.lynxAppId {
                try writeReleasePointer(release, to: legacyCurrentReleasePointerURL)
            }
        }
    }

    public func stageRelease(_ release: OtaInstalledRelease) throws {
        try ensureBaseDirectory()
        try writeReleasePointer(
            release,
            to: stagedReleasePointerURL(app: release.context.app, lynxAppId: release.context.lynxAppId)
        )
        try writeReleasePointer(release, to: stagedReleasePointerURL(lynxAppId: release.context.lynxAppId))
        if release.context.lynxAppId == OtaDefaults.lynxAppId {
            try writeReleasePointer(release, to: legacyStagedReleasePointerURL)
        }
    }

    public func activateStagedRelease(lynxAppId: String? = nil) throws -> OtaInstalledRelease {
        guard let staged = stagedRelease(lynxAppId: lynxAppId) else {
            throw OtaSDKError.missingStagedRelease
        }
        let scopedLynxAppId = staged.context.lynxAppId
        if let current = currentRelease(lynxAppId: scopedLynxAppId) {
            try writeReleasePointer(current, to: previousReleasePointerURL(lynxAppId: scopedLynxAppId))
        }
        try writeReleasePointer(staged, to: currentReleasePointerURL(lynxAppId: scopedLynxAppId))
        try removePointer(at: stagedReleasePointerURL(lynxAppId: scopedLynxAppId))
        if scopedLynxAppId == OtaDefaults.lynxAppId {
            try writeReleasePointer(staged, to: legacyCurrentReleasePointerURL)
            try removePointer(at: legacyStagedReleasePointerURL)
        }
        return staged
    }

    /// 在 scoped pointer 上完成 staged -> current；旧 pointer 仍同步写入，保证旧宿主调用可读。
    public func activateStagedRelease(app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease {
        guard let staged = stagedRelease(app: app, lynxAppId: lynxAppId) else {
            throw OtaSDKError.missingStagedRelease
        }
        guard staged.context.app == app, staged.context.lynxAppId == lynxAppId else {
            throw OtaSDKError.missingStagedRelease
        }
        let scope = staged.context.lynxAppId
        if let current = currentRelease(app: app, lynxAppId: scope) {
            try writeReleasePointer(current, to: previousReleasePointerURL(app: app, lynxAppId: scope))
            try writeReleasePointer(current, to: previousReleasePointerURL(lynxAppId: scope))
        }
        try writeReleasePointer(staged, to: currentReleasePointerURL(app: app, lynxAppId: scope))
        try writeReleasePointer(staged, to: currentReleasePointerURL(lynxAppId: scope))
        try removePointer(at: stagedReleasePointerURL(app: app, lynxAppId: scope))
        try removePointer(at: stagedReleasePointerURL(lynxAppId: scope))
        if scope == OtaDefaults.lynxAppId {
            try writeReleasePointer(staged, to: legacyCurrentReleasePointerURL)
            try removePointer(at: legacyStagedReleasePointerURL)
        }
        return staged
    }

    public func rollback(lynxAppId: String? = nil) throws -> OtaInstalledRelease? {
        let scopedLynxAppId = lynxAppId ?? OtaDefaults.lynxAppId
        if let previous = try? readReleasePointer(at: previousReleasePointerURL(lynxAppId: scopedLynxAppId)) {
            try writeReleasePointer(previous, to: currentReleasePointerURL(lynxAppId: scopedLynxAppId))
            try removePointer(at: previousReleasePointerURL(lynxAppId: scopedLynxAppId))
            if scopedLynxAppId == OtaDefaults.lynxAppId {
                try writeReleasePointer(previous, to: legacyCurrentReleasePointerURL)
                try removePointer(at: legacyPreviousReleasePointerURL)
            }
            return previous
        }
        if let embedded = embeddedRelease(lynxAppId: scopedLynxAppId) {
            try writeReleasePointer(embedded, to: currentReleasePointerURL(lynxAppId: scopedLynxAppId))
            if scopedLynxAppId == OtaDefaults.lynxAppId {
                try writeReleasePointer(embedded, to: legacyCurrentReleasePointerURL)
            }
            return embedded
        }
        return nil
    }

    public func rollback(app: OtaAppID, lynxAppId: String) throws -> OtaInstalledRelease? {
        let scopedPrevious = try? readReleasePointer(at: previousReleasePointerURL(app: app, lynxAppId: lynxAppId))
        let legacyPrevious = try? readReleasePointer(at: previousReleasePointerURL(lynxAppId: lynxAppId))
        if let previous = (scopedPrevious ?? legacyPrevious),
           previous.context.app == app,
           previous.context.lynxAppId == lynxAppId {
            try writeReleasePointer(previous, to: currentReleasePointerURL(app: app, lynxAppId: lynxAppId))
            try writeReleasePointer(previous, to: currentReleasePointerURL(lynxAppId: lynxAppId))
            try removePointer(at: previousReleasePointerURL(app: app, lynxAppId: lynxAppId))
            try removePointer(at: previousReleasePointerURL(lynxAppId: lynxAppId))
            if lynxAppId == OtaDefaults.lynxAppId {
                try writeReleasePointer(previous, to: legacyCurrentReleasePointerURL)
                try removePointer(at: legacyPreviousReleasePointerURL)
            }
            return previous
        }
        if let embedded = embeddedRelease(app: app, lynxAppId: lynxAppId) {
            try writeReleasePointer(embedded, to: currentReleasePointerURL(app: app, lynxAppId: lynxAppId))
            try writeReleasePointer(embedded, to: currentReleasePointerURL(lynxAppId: lynxAppId))
            if lynxAppId == OtaDefaults.lynxAppId {
                try writeReleasePointer(embedded, to: legacyCurrentReleasePointerURL)
            }
            return embedded
        }
        return nil
    }

    public func localBundleURL(releaseId: String, bundlePath: String) throws -> URL {
        let url = releaseDirectory(for: releaseId).appendingPathComponent(bundlePath, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// 新 bundleName 目录按 hostApp + lynxAppId 隔离；旧 localBundleURL 保留给历史 pageId/path 调用方。
    public func localBundleURL(
        app: OtaAppID,
        lynxAppId: String,
        releaseId: String,
        bundleName: String,
        bundlePath: String? = nil
    ) throws -> URL {
        let safeName = try safeBundleName(bundleName)
        let safeRelease = try safeReleaseId(releaseId)
        let relativePath = try safeBundlePath(bundlePath ?? safeName)
        let url = releaseDirectory(app: app, lynxAppId: lynxAppId, releaseId: safeRelease)
            .appendingPathComponent(relativePath, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /**
     * 直接删除指定 hostApp + appId 的下载内容。
     *
     * 删除前只在内存中保留 embedded 元数据；不会把 Bundle 移到隐藏备份目录。新布局的
     * appId 目录和旧 pointer 明确引用的 release 会被删除，其他 appId 不受影响。
     */
    public func deleteDownloadedBundles(app: OtaAppID, lynxAppId: String) throws {
        let normalizedAppId = lynxAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAppId.isEmpty else {
            throw OtaSDKError.invalidBundleName(lynxAppId)
        }
        let embedded = embeddedRelease(app: app, lynxAppId: normalizedAppId)
        let pointerURLs = [
            currentReleasePointerURL(app: app, lynxAppId: normalizedAppId),
            stagedReleasePointerURL(app: app, lynxAppId: normalizedAppId),
            previousReleasePointerURL(app: app, lynxAppId: normalizedAppId),
            currentReleasePointerURL(lynxAppId: normalizedAppId),
            stagedReleasePointerURL(lynxAppId: normalizedAppId),
            previousReleasePointerURL(lynxAppId: normalizedAppId),
        ]
        let releaseIds = Set(pointerURLs.compactMap { url -> String? in
            guard let release = try? readReleasePointer(at: url),
                  release.context.app == app,
                  release.context.lynxAppId == normalizedAppId else {
                return nil
            }
            return release.context.releaseId
        })

        try removeItemIfPresent(scopedDirectory(app: app, lynxAppId: normalizedAppId))
        for url in pointerURLs { try removeItemIfPresent(url) }
        for releaseId in releaseIds {
            try removeItemIfPresent(releaseDirectory(for: try safeReleaseId(releaseId)))
        }
        if normalizedAppId == OtaDefaults.lynxAppId {
            try removeItemIfPresent(legacyCurrentReleasePointerURL)
            try removeItemIfPresent(legacyStagedReleasePointerURL)
            try removeItemIfPresent(legacyPreviousReleasePointerURL)
        }
        if let embedded {
            // 恢复 embedded pointer，并让 current 回落到随包版本。
            try saveEmbeddedRelease(embedded)
        }
    }

    /** 直接删除全部下载 Bundle，保留所有可解析的 embedded 描述。 */
    public func deleteAllDownloadedBundles() throws {
        let embeddedReleases = try collectEmbeddedReleases()
        try removeItemIfPresent(baseDirectory)
        try ensureBaseDirectory()
        for release in embeddedReleases {
            try saveEmbeddedRelease(release)
        }
    }

    private var legacyCurrentReleasePointerURL: URL {
        baseDirectory.appendingPathComponent("current-release.json", isDirectory: false)
    }

    private var legacyStagedReleasePointerURL: URL {
        baseDirectory.appendingPathComponent("staged-release.json", isDirectory: false)
    }

    private var legacyPreviousReleasePointerURL: URL {
        baseDirectory.appendingPathComponent("previous-release.json", isDirectory: false)
    }

    private var legacyEmbeddedReleasePointerURL: URL {
        baseDirectory.appendingPathComponent("embedded-release.json", isDirectory: false)
    }

    private func currentReleasePointerURL(lynxAppId: String) -> URL {
        baseDirectory.appendingPathComponent("current-release-\(safeFileName(lynxAppId)).json", isDirectory: false)
    }

    private func stagedReleasePointerURL(lynxAppId: String) -> URL {
        baseDirectory.appendingPathComponent("staged-release-\(safeFileName(lynxAppId)).json", isDirectory: false)
    }

    private func previousReleasePointerURL(lynxAppId: String) -> URL {
        baseDirectory.appendingPathComponent("previous-release-\(safeFileName(lynxAppId)).json", isDirectory: false)
    }

    private func embeddedReleasePointerURL(lynxAppId: String) -> URL {
        baseDirectory.appendingPathComponent("embedded-release-\(safeFileName(lynxAppId)).json", isDirectory: false)
    }

    private func currentReleasePointerURL(app: OtaAppID, lynxAppId: String) -> URL {
        scopedDirectory(app: app, lynxAppId: lynxAppId)
            .appendingPathComponent("current-release.json", isDirectory: false)
    }

    private func stagedReleasePointerURL(app: OtaAppID, lynxAppId: String) -> URL {
        scopedDirectory(app: app, lynxAppId: lynxAppId)
            .appendingPathComponent("staged-release.json", isDirectory: false)
    }

    private func previousReleasePointerURL(app: OtaAppID, lynxAppId: String) -> URL {
        scopedDirectory(app: app, lynxAppId: lynxAppId)
            .appendingPathComponent("previous-release.json", isDirectory: false)
    }

    private func embeddedReleasePointerURL(app: OtaAppID, lynxAppId: String) -> URL {
        scopedDirectory(app: app, lynxAppId: lynxAppId)
            .appendingPathComponent("embedded-release.json", isDirectory: false)
    }

    private func releaseDirectory(for releaseId: String) -> URL {
        baseDirectory
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent(releaseId, isDirectory: true)
    }

    private func scopedDirectory(app: OtaAppID, lynxAppId: String) -> URL {
        baseDirectory
            .appendingPathComponent(safeFileName(app.rawValue), isDirectory: true)
            .appendingPathComponent(safeFileName(lynxAppId), isDirectory: true)
    }

    private func releaseDirectory(app: OtaAppID, lynxAppId: String, releaseId: String) -> URL {
        scopedDirectory(app: app, lynxAppId: lynxAppId)
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent(releaseId, isDirectory: true)
    }

    private func ensureBaseDirectory() throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: baseDirectory.appendingPathComponent("releases", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func readReleasePointer(at url: URL) throws -> OtaInstalledRelease {
        let data = try Data(contentsOf: url)
        return try decoder.decode(OtaInstalledRelease.self, from: data)
    }

    private func writeReleasePointer(_ release: OtaInstalledRelease, to url: URL) throws {
        let data = try encoder.encode(release)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func removePointer(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func removeItemIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /** 遍历 pointer 文件只为保留 embedded 元数据；Bundle 文件本身不会复制或备份。 */
    private func collectEmbeddedReleases() throws -> [OtaInstalledRelease] {
        guard fileManager.fileExists(atPath: baseDirectory.path),
              let enumerator = fileManager.enumerator(
                at: baseDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var values: [String: OtaInstalledRelease] = [:]
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("embedded-release") {
            guard let release = try? readReleasePointer(at: url) else { continue }
            values["\(release.context.app.rawValue)/\(release.context.lynxAppId)"] = release
        }
        return Array(values.values)
    }

    private func safeFileName(_ raw: String) -> String {
        raw.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        .map(String.init)
        .joined()
    }

    private func safeReleaseId(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              trimmed != ".",
              trimmed != ".." else {
            throw OtaSDKError.invalidBundleName(raw)
        }
        return safeFileName(trimmed)
    }

    private func safeBundleName(_ raw: String) throws -> String {
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
        return trimmed.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." || character == "/" ? character : "_"
        }
        .map(String.init)
        .joined()
    }

    private func safeBundlePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsPath = trimmed as NSString
        guard !trimmed.isEmpty,
              !nsPath.isAbsolutePath,
              !trimmed.hasPrefix("/"),
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
}
