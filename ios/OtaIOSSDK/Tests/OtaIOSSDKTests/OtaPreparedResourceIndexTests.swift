import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("页面固定 Async 索引回归")
struct OtaPreparedResourceIndexTests {
    @Test("已准备页面的十次读取不再依赖清单文件", arguments: ["missing", "corrupt"])
    func preparedPageRetainsVerifiedManifestIndex(change: String) async throws {
        let fixture = try await PreparedIndexFixture()
        defer { fixture.cleanup() }
        let page = try #require(try await fixture.sdk.prepareResources(release: fixture.release, ownerBundlePath: fixture.owner))
        defer { page.close() }
        if change == "missing" {
            try FileManager.default.removeItem(at: fixture.manifestFile)
        } else {
            try Data("invalidated-manifest".utf8).write(to: fixture.manifestFile)
        }
        for entry in fixture.entries where entry.ownerBundlePath == fixture.owner {
            do {
                let result = try await page.resolve(entry.requestKey)
                #expect(result == fixture.bytes[entry.requestKey])
            } catch {
                Issue.record("已准备页面重新依赖了清单磁盘文件：\(entry.requestKey)，\(error)")
            }
        }
    }

    @Test("新开页面仍拒绝已损坏清单")
    func newPageRejectsInvalidManifest() async throws {
        let fixture = try await PreparedIndexFixture()
        defer { fixture.cleanup() }
        let page = try #require(try await fixture.sdk.prepareResources(release: fixture.release, ownerBundlePath: fixture.owner))
        defer { page.close() }
        try Data("invalidated-manifest".utf8).write(to: fixture.manifestFile)
        await #expect(throws: OtaSidecarError.self) {
            _ = try await fixture.sdk.prepareResources(release: fixture.release, ownerBundlePath: fixture.owner)
        }
    }

    @Test("已准备索引每次读取仍校验目标大小和 SHA", arguments: ["same-size", "short"])
    func targetTamperingIsRejected(change: String) async throws {
        let fixture = try await PreparedIndexFixture()
        defer { fixture.cleanup() }
        let page = try #require(try await fixture.sdk.prepareResources(release: fixture.release, ownerBundlePath: fixture.owner))
        defer { page.close() }
        let entry = try #require(fixture.entries.first)
        let bytes = try #require(fixture.bytes[entry.requestKey])
        let root = try OtaSidecarDisk.root(fixture.root, appId: fixture.appId, channel: "async-bundles")
        let object = try OtaSidecarDisk.object(root, sha256: entry.sha256)
        let tampered = change == "same-size" ? Data(repeating: 88, count: bytes.count) : Data("short".utf8)
        try tampered.write(to: object)
        await #expect(throws: OtaSidecarError.self) { _ = try await page.resolve(entry.requestKey) }
    }

    @Test("索引保持 owner 隔离及请求地址规范化")
    func ownerAndURLContractsArePreserved() async throws {
        let fixture = try await PreparedIndexFixture()
        defer { fixture.cleanup() }
        let page = try #require(try await fixture.sdk.prepareResources(release: fixture.release, ownerBundlePath: fixture.owner))
        defer { page.close() }
        let entry = try #require(fixture.entries.first)
        let expected = try #require(fixture.bytes[entry.requestKey])
        #expect(try await page.resolve(entry.requestKey) == expected)
        #expect(try await page.resolve(String(entry.requestKey.dropFirst())) == expected)
        #expect(try await page.resolve(entry.url.absoluteString) == expected)
        #expect(page.localURL(entry.requestKey) != nil)
        #expect(page.localURL(entry.url.absoluteString) != nil)
        for request in ["/static/foreign-only.bin", "../escape.js", "//static/script/p0.js", "/static/script/p0.js?x=1", "https://example.invalid/static/script/p0.js#x", "https://example.invalid/static/script/p0.js?x=1", "static%2fscript/p0.js"] {
            await #expect(throws: OtaSidecarError.self) { _ = try await page.resolve(request) }
        }
        #expect(page.localURL("/static/foreign-only.bin") == nil)
    }

    @Test("同 owner 的 URL 别名冲突仍拒绝歧义请求")
    func ambiguousAbsoluteURLIsRejected() async throws {
        let fixture = try await PreparedIndexFixture(ambiguousAlias: true)
        defer { fixture.cleanup() }
        let page = try #require(try await fixture.sdk.prepareResources(release: fixture.release, ownerBundlePath: fixture.owner))
        defer { page.close() }
        let first = try #require(fixture.entries.first)
        await #expect(throws: OtaSidecarError.self) { _ = try await page.resolve(first.url.absoluteString) }
        #expect(page.localURL(first.url.absoluteString) == nil)
        #expect(try await page.resolve("/static/script/alias.js") == fixture.bytes["/static/script/alias.js"])
    }

    @Test("完整 URL 与另一项请求路径冲突时 byte/path 都拒绝")
    func absoluteURLAndDeclaredPathCollisionIsRejected() async throws {
        let fixture = try await PreparedIndexFixture(urlPathCollision: true)
        defer { fixture.cleanup() }
        let page = try #require(try await fixture.sdk.prepareResources(release: fixture.release, ownerBundlePath: fixture.owner))
        defer { page.close() }
        let first = try #require(fixture.entries.first)
        await #expect(throws: OtaSidecarError.self) { _ = try await page.resolve(first.url.absoluteString) }
        #expect(page.localURL(first.url.absoluteString) == nil)
    }

    @Test("真实 SDK 页面关闭后拒绝读取和媒体 URL")
    func realSDKClosedPageRejectsReads() async throws {
        let fixture = try await PreparedIndexFixture()
        defer { fixture.cleanup() }
        let page = try #require(try await fixture.sdk.prepareResources(release: fixture.release, ownerBundlePath: fixture.owner))
        page.close()
        #expect(page.localURL("/static/script/p0.js") == nil)
        await #expect(throws: OtaSidecarError.self) { _ = try await page.resolve("/static/script/p0.js") }
    }

    @Test("close 等待在途解析结束后才执行 drain", arguments: [false, true])
    func activeResolveDrainsBeforeCleanup(cancel: Bool) async throws {
        let entered = ResourceTestSignal()
        let unblock = ResourceTestSignal()
        let cleaned = ResourceTestSignal()
        let drained = ResourceTestSignal()
        let page = OtaPreparedResources(hasAsyncResources: true, localPaths: [:], resolver: { _ in
            await entered.signal()
            await unblock.wait()
            try Task.checkCancellation()
            return Data("resolved".utf8)
        }, closeAction: { await cleaned.signal() })
        let reading = Task { try await page.resolve("/static/script/p0.js") }
        await entered.wait()
        page.onDrained { await drained.signal() }
        page.close()
        #expect(await cleaned.isSignaled == false)
        #expect(await drained.isSignaled == false)
        await #expect(throws: OtaSidecarError.self) { _ = try await page.resolve("/static/script/p1.js") }
        if cancel { reading.cancel() }
        await unblock.signal()
        if cancel {
            await #expect(throws: CancellationError.self) { _ = try await reading.value }
        } else {
            #expect(try await reading.value == Data("resolved".utf8))
        }
        await cleaned.wait()
        await drained.wait()
        #expect(await cleaned.isSignaled)
        #expect(await drained.isSignaled)
    }
}

private actor ResourceTestSignal {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isSignaled = false

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct PreparedIndexFixture {
    let root: URL
    let appId = "10030071"
    let owner = "HomePage.lynx.bundle"
    let manifestFile: URL
    let entries: [OtaAsyncResource]
    let bytes: [String: Data]
    let release: OtaInstalledRelease
    let sdk: OtaSDK
    private let transaction: OtaSidecarTransaction

    init(ambiguousAlias: Bool = false, urlPathCollision: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ota-prepared-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [OtaAsyncResource] = []
        var content: [String: Data] = [:]
        var downloadFiles: [URL: URL] = [:]
        for index in 0..<11 {
            let path = index == 10 ? "static/foreign-only.bin" : "static/script/p\(index).js"
            let key = "/" + path
            let data = Data("real-fixture-resource-\(index)-abcdefghijk".utf8)
            let remote = URL(string: "https://example.invalid/\(path)")!
            let source = directory.appendingPathComponent("source-\(index).bin")
            try data.write(to: source)
            downloadFiles[remote] = source
            content[key] = data
            records.append(.init(ownerBundlePath: index == 10 ? "DetailPage.lynx.bundle" : "HomePage.lynx.bundle", requestKey: key, path: path, url: remote, sha256: OtaSidecarDisk.digest(data), size: data.count, kind: index == 10 ? "asset" : "script"))
        }
        if ambiguousAlias {
            let first = records[0]
            content["/static/script/alias.js"] = content[first.requestKey]
            records.append(.init(ownerBundlePath: first.ownerBundlePath, requestKey: "/static/script/alias.js", path: "static/script/alias.js", url: first.url, sha256: first.sha256, size: first.size, kind: "script"))
        }
        if urlPathCollision {
            let first = records[0]
            let collision = URL(string: "https://cdn.example.invalid/static/script/p1.js")!
            downloadFiles[collision] = directory.appendingPathComponent("source-0.bin")
            records[0] = .init(ownerBundlePath: first.ownerBundlePath, requestKey: first.requestKey,
                               path: first.path, url: collision, sha256: first.sha256, size: first.size, kind: first.kind)
        }
        let data = try JSONEncoder().encode(OtaAsyncManifest(schemaVersion: 1, entries: records))
        let source = directory.appendingPathComponent("source-manifest.json")
        try data.write(to: source)
        let remote = URL(string: "https://example.invalid/async.json")!
        downloadFiles[remote] = source
        let reference = OtaAsyncManifestReference(url: remote, sha256: OtaSidecarDisk.digest(data), size: data.count)
        let downloader = ResourceFixtureDownloader(files: downloadFiles)
        let store = OtaAsyncBundleStore(baseDirectory: directory, downloader: downloader)
        let preparedTransaction = try await store.prepare(reference, appId: "10030071", owners: ["HomePage.lynx.bundle", "DetailPage.lynx.bundle"])
        let mainBytes = Data("main-fixture".utf8)
        let mainFile = directory.appendingPathComponent("main.lynx.bundle")
        try mainBytes.write(to: mainFile)
        self.root = directory
        self.entries = records
        self.bytes = content
        self.transaction = preparedTransaction
        let resourceRoot = try OtaSidecarDisk.root(directory, appId: "10030071", channel: "async-bundles")
        self.manifestFile = resourceRoot.appendingPathComponent("manifests/\(try OtaSidecarDisk.hashName(reference.sha256)).json")
        self.release = .init(context: .init(env: .test, app: .template, lynxAppId: "10030071", releaseId: "index-regression", platform: .ios, status: .active), installedAt: Date(), bundles: [
            .init(bundleName: "HomePage.lynx.bundle", bundleSha256: OtaSidecarDisk.digest(mainBytes), remoteURL: URL(string: "https://example.invalid/HomePage.lynx.bundle")!, localFilePath: mainFile.path),
            .init(bundleName: "DetailPage.lynx.bundle", bundleSha256: OtaSidecarDisk.digest(mainBytes), remoteURL: URL(string: "https://example.invalid/DetailPage.lynx.bundle")!, localFilePath: mainFile.path)
        ], asyncBundleManifest: reference)
        self.sdk = OtaSDK(configuration: .init(apiBaseURL: URL(string: "https://example.invalid")!, app: .template, lynxAppId: "10030071", environment: .test, platform: .ios, appVersion: "1.0", buildNumber: "1", storageDirectory: directory, storeVersion: .v3), downloader: downloader)
    }

    func cleanup() {
        transaction.finish()
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ResourceFixtureDownloader: OtaBundleDownloading {
    let files: [URL: URL]

    func download(from remoteURL: URL, to localURL: URL) async throws {
        guard let source = files[remoteURL] else { throw OtaSidecarError.missingLocalResource }
        try FileManager.default.copyItem(at: source, to: localURL)
    }
}
