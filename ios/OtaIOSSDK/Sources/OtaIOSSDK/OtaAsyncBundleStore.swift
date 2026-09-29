import Foundation

actor OtaAsyncBundleStore {
    private let baseDirectory: URL
    private let downloader: any OtaBundleDownloading

    init(baseDirectory: URL, downloader: any OtaBundleDownloading) {
        self.baseDirectory = baseDirectory
        self.downloader = downloader
    }

    func prepare(_ reference: OtaAsyncManifestReference, appId: String, owners: Set<String>) async throws -> OtaSidecarTransaction {
        guard reference.schemaVersion == 1, reference.size <= 1024 * 1024 else {
            throw OtaSidecarError.invalidManifest("不支持的清单版本或大小")
        }
        let root = try OtaSidecarDisk.root(baseDirectory, appId: appId, channel: "async-bundles")
        let localManifest = try manifestURL(root, reference)
        let data: Data
        if let cached = try? OtaSidecarDisk.verifiedData(localManifest, sha256: reference.sha256, size: reference.size) {
            data = cached
        } else {
            data = try await OtaSidecarDisk.downloadData(url: reference.url, sha256: reference.sha256, size: reference.size, root: root, downloader: downloader)
        }
        let manifest = try JSONDecoder().decode(OtaAsyncManifest.self, from: data)
        try Self.validate(manifest, owners: owners)
        // 事务清单先落盘，后台 GC 据此保护尚未写入代码 Manifest 的对象。
        let transaction = try OtaSidecarTransaction(root: root, manifestId: reference.sha256, objectIds: manifest.entries.map(\.sha256))
        do {
            for entry in manifest.entries {
                _ = try await OtaSidecarDisk.fetch(url: entry.url, sha256: entry.sha256, size: entry.size, root: root, downloader: downloader)
            }
            try OtaSidecarDisk.write(data, to: manifestURL(root, reference))
            return transaction
        } catch {
            transaction.finish()
            throw error
        }
    }

    func resolve(_ rawURL: String, owner: String, appId: String, reference: OtaAsyncManifestReference) throws -> Data {
        let root = try OtaSidecarDisk.root(baseDirectory, appId: appId, channel: "async-bundles")
        let data = try OtaSidecarDisk.verifiedData(manifestURL(root, reference), sha256: reference.sha256, size: reference.size)
        let manifest = try JSONDecoder().decode(OtaAsyncManifest.self, from: data)
        let key: String
        if let url = URL(string: rawURL), url.scheme != nil {
            guard url.query == nil, url.fragment == nil else { throw OtaSidecarError.unknownRequest }
            key = try OtaSidecarDisk.requestKey(url.path)
        } else {
            key = try OtaSidecarDisk.requestKey(rawURL)
        }
        let matches = try manifest.entries.filter { entry in
            guard entry.ownerBundlePath == owner else { return false }
            let declared = try OtaSidecarDisk.requestKey(entry.requestKey)
            return rawURL == entry.url.absoluteString || key == declared
        }
        guard matches.count == 1, let entry = matches.first else { throw OtaSidecarError.unknownRequest }
        return try OtaSidecarDisk.verifiedData(OtaSidecarDisk.object(root, sha256: entry.sha256), sha256: entry.sha256, size: entry.size)
    }

    func localPaths(owner: String, appId: String, reference: OtaAsyncManifestReference) throws -> [String: URL] {
        let root = try OtaSidecarDisk.root(baseDirectory, appId: appId, channel: "async-bundles")
        let data = try OtaSidecarDisk.verifiedData(manifestURL(root, reference), sha256: reference.sha256, size: reference.size)
        let manifest = try JSONDecoder().decode(OtaAsyncManifest.self, from: data)
        var result: [String: URL] = [:]
        for entry in manifest.entries where entry.ownerBundlePath == owner {
            let file = try OtaSidecarDisk.object(root, sha256: entry.sha256)
            _ = try OtaSidecarDisk.verifiedData(file, sha256: entry.sha256, size: entry.size)
            result[try OtaSidecarDisk.requestKey(entry.requestKey)] = file
            result[entry.url.absoluteString] = file
        }
        return result
    }

    static func validate(_ manifest: OtaAsyncManifest, owners: Set<String>) throws {
        guard manifest.schemaVersion == 1, !manifest.entries.isEmpty else { throw OtaSidecarError.invalidManifest("清单为空或版本不支持") }
        var keys = Set<String>()
        for entry in manifest.entries {
            _ = try OtaSidecarDisk.relativePath(entry.path)
            _ = try OtaSidecarDisk.relativePath(entry.ownerBundlePath)
            let key = try OtaSidecarDisk.requestKey(entry.requestKey)
            _ = try OtaSidecarDisk.hashName(entry.sha256)
            guard owners.contains(entry.ownerBundlePath), entry.size > 0, entry.size <= 20 * 1024 * 1024,
                  ["bundle", "script", "style", "asset"].contains(entry.kind),
                  keys.insert(entry.ownerBundlePath + "|" + key).inserted else {
                throw OtaSidecarError.invalidManifest("资源归属、大小、类型或请求键不合法")
            }
        }
    }

    static func verifyInstalled(baseDirectory: URL, appId: String, reference: OtaAsyncManifestReference, owners: Set<String>) throws {
        let root = try OtaSidecarDisk.root(baseDirectory, appId: appId, channel: "async-bundles")
        let file = root.appendingPathComponent("manifests/\(try OtaSidecarDisk.hashName(reference.sha256)).json")
        let data = try OtaSidecarDisk.verifiedData(file, sha256: reference.sha256, size: reference.size)
        let manifest = try JSONDecoder().decode(OtaAsyncManifest.self, from: data)
        try validate(manifest, owners: owners)
        for entry in manifest.entries {
            _ = try OtaSidecarDisk.verifiedData(OtaSidecarDisk.object(root, sha256: entry.sha256), sha256: entry.sha256, size: entry.size)
        }
    }

    private func manifestURL(_ root: URL, _ reference: OtaAsyncManifestReference) throws -> URL {
        root.appendingPathComponent("manifests/\(try OtaSidecarDisk.hashName(reference.sha256)).json")
    }
}
