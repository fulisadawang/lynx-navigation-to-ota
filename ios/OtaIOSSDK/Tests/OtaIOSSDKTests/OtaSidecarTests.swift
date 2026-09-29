import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("独立 Async 本地资源")
struct OtaSidecarTests {
    @Test("旧清单不因可选资源字段改变 JSON")
    func legacyManifest() throws {
        let value = OtaReleaseManifest(env: .test, app: .capp, releaseId: "old", platform: .ios, bundles: [])
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["asyncBundleManifest"] == nil)
        #expect(object["i18nRequirement"] == nil)
        #expect(try JSONDecoder().decode(OtaReleaseManifest.self, from: data) == value)
    }

    @Test("低层 stage 不允许只有主包的 Async Release")
    func missingAsyncBlocksStage() async throws {
        let fixture = try SidecarFixture()
        defer { fixture.cleanup() }
        let reference = try await fixture.asyncManifest("missing")
        var rejected = false
        do { try await fixture.transaction.stage(fixture.release("A", reference: reference)) }
        catch { rejected = true }
        #expect(rejected)
        #expect(await fixture.transaction.current(scope: fixture.scope) == nil)
    }

    @Test("candidate 只有完整 Async 就绪后可确认，回滚会清理 sidecar")
    func candidateStagesAndRollsBackCompleteSidecars() async throws {
        let fixture = try SidecarFixture()
        defer { fixture.cleanup() }
        let embeddedBytes = Data("embedded".utf8)
        let embeddedFile = fixture.root.appendingPathComponent("embedded.lynx.bundle")
        try embeddedBytes.write(to: embeddedFile)
        let embedded = OtaInstalledRelease(context: .init(env: .test, app: .capp, lynxAppId: fixture.appId, releaseId: "embedded", platform: .ios, status: .active), installedAt: Date(), bundles: [.init(bundleName: "HomePage.lynx.bundle", bundleSha256: OtaSidecarDisk.digest(embeddedBytes), remoteURL: URL(string: "https://example.invalid/embedded")!, localFilePath: embeddedFile.path)])
        try await fixture.transaction.registerEmbedded(embedded)

        let reference = try await fixture.asyncManifest("candidate")
        let asyncTransaction = try await fixture.asyncStore.prepare(reference, appId: fixture.appId, owners: ["HomePage.lynx.bundle"])
        defer { asyncTransaction.finish() }
        let candidateFile = fixture.root.appendingPathComponent("candidate.lynx.bundle")
        let main = Data("candidate-main".utf8)
        try main.write(to: candidateFile)
        let candidateRelease = OtaInstalledRelease(context: .init(env: .test, app: .capp, lynxAppId: fixture.appId, releaseId: "candidate-complete", platform: .ios, status: .active), installedAt: Date(), bundles: [.init(bundleName: "HomePage.lynx.bundle", bundleSha256: OtaSidecarDisk.digest(main), remoteURL: URL(string: "https://example.invalid/candidate-main")!, localFilePath: candidateFile.path)], asyncBundleManifest: reference)
        try await fixture.transaction.stageCandidate(candidateRelease)
        asyncTransaction.finish()

        #expect(await fixture.transaction.current(scope: fixture.scope)?.context.releaseId == embedded.context.releaseId)
        let candidate = try #require(await fixture.transaction.candidate(scope: fixture.scope))
        #expect(candidate.release.asyncBundleManifest == reference)
        _ = try await fixture.transaction.beginCandidateTrial(scope: fixture.scope)
        #expect(try await fixture.asyncStore.resolve("/lazy-bundle/panel.bundle", owner: "HomePage.lynx.bundle", appId: fixture.appId, reference: reference) == Data("lazy-candidate".utf8))
        let confirmed = try await fixture.transaction.confirmCandidate(scope: fixture.scope)
        #expect(confirmed.context.releaseId == candidateRelease.context.releaseId)
        #expect(await fixture.transaction.current(scope: fixture.scope)?.asyncBundleManifest == reference)
        let rolledBack = try await fixture.transaction.rollback(scope: fixture.scope)
        guard case .restored(let restored) = rolledBack else { Issue.record("candidate 没有回滚到 embedded"); return }
        #expect(restored.context.releaseId == embedded.context.releaseId)
        #expect(await fixture.transaction.current(scope: fixture.scope)?.context.releaseId == embedded.context.releaseId)
    }

    @Test("旧页 lease 保留 A 的异步对象，关闭后回收")
    func asyncLeaseAndRollback() async throws {
        let fixture = try SidecarFixture()
        defer { fixture.cleanup() }
        let a = try await fixture.install("A")
        let lease = try #require(try await fixture.transaction.acquireCurrentBundleLease(scope: fixture.scope, bundleName: "HomePage.lynx.bundle"))
        _ = try await fixture.install("B")
        let c = try await fixture.install("C")
        #expect(try await fixture.asyncStore.resolve("/lazy-bundle/panel.bundle", owner: "HomePage.lynx.bundle", appId: fixture.appId, reference: a) == Data("lazy-A".utf8))
        let rollback = try await fixture.transaction.rollback(scope: fixture.scope)
        guard case .restored(let restored) = rollback else { Issue.record("没有回滚到 previous"); return }
        #expect(restored.context.releaseId == "B")
        #expect(restored.asyncBundleManifest != nil)
        await lease.close()
        try await fixture.transaction.pruneAllUnreferencedReleases()
        let root = try OtaSidecarDisk.root(fixture.root, appId: fixture.appId, channel: "async-bundles")
        let oldObject = try OtaSidecarDisk.object(root, sha256: OtaSidecarDisk.digest(Data("lazy-A".utf8)))
        #expect(!FileManager.default.fileExists(atPath: oldObject.path))
        #expect(try await fixture.asyncStore.resolve("/lazy-bundle/panel.bundle", owner: "HomePage.lynx.bundle", appId: fixture.appId, reference: c) == Data("lazy-C".utf8))
    }

    @Test("同一清单并发准备使用不同事务保护根")
    func uniqueTransactions() async throws {
        let fixture = try SidecarFixture()
        defer { fixture.cleanup() }
        let reference = try await fixture.asyncManifest("parallel")
        let first = try await fixture.asyncStore.prepare(reference, appId: fixture.appId, owners: ["HomePage.lynx.bundle"])
        let second = try await fixture.asyncStore.prepare(reference, appId: fixture.appId, owners: ["HomePage.lynx.bundle"])
        first.finish()
        try OtaSidecarGarbageCollector.prune(baseDirectory: fixture.root, appId: fixture.appId, asyncIds: [])
        #expect(try await fixture.asyncStore.resolve("/lazy-bundle/panel.bundle", owner: "HomePage.lynx.bundle", appId: fixture.appId, reference: reference) == Data("lazy-parallel".utf8))
        second.finish()
        try OtaSidecarGarbageCollector.prune(baseDirectory: fixture.root, appId: fixture.appId, asyncIds: [])
        let root = try OtaSidecarDisk.root(fixture.root, appId: fixture.appId, channel: "async-bundles")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("manifests/\(try OtaSidecarDisk.hashName(reference.sha256)).json").path))
    }

    @Test("保留清单缺失时 GC 整轮拒绝删除")
    func missingRootStopsSweep() throws {
        let fixture = try SidecarFixture()
        defer { fixture.cleanup() }
        let root = try OtaSidecarDisk.root(fixture.root, appId: fixture.appId, channel: "async-bundles")
        let bytes = Data("orphan".utf8)
        let file = try OtaSidecarDisk.object(root, sha256: OtaSidecarDisk.digest(bytes))
        try OtaSidecarDisk.write(bytes, to: file)
        var rejected = false
        do { try OtaSidecarGarbageCollector.prune(baseDirectory: fixture.root, appId: fixture.appId, asyncIds: ["sha256:" + String(repeating: "a", count: 64)]) }
        catch { rejected = true }
        #expect(rejected)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("主 Store Manifest 缺失时延后主包与 Async 回收")
    func missingRetainedMainManifestDefersSidecarSweep() async throws {
        let fixture = try SidecarFixture()
        defer { fixture.cleanup() }
        let reference = try await fixture.asyncManifest("gc")
        let asyncTransaction = try await fixture.asyncStore.prepare(reference, appId: fixture.appId, owners: ["HomePage.lynx.bundle"])
        defer { asyncTransaction.finish() }

        let mainBytes = Data("main-with-sidecars".utf8)
        let source = fixture.root.appendingPathComponent("main-with-sidecars.lynx.bundle")
        try mainBytes.write(to: source)
        let release = OtaInstalledRelease(
            context: .init(env: .test, app: .capp, lynxAppId: fixture.appId, releaseId: "retained-manifest-missing", platform: .ios, status: .active),
            installedAt: Date(),
            bundles: [.init(bundleName: "HomePage.lynx.bundle", bundleSha256: OtaSidecarDisk.digest(mainBytes), remoteURL: URL(string: "https://example.invalid/main")!, localFilePath: source.path)],
            asyncBundleManifest: reference
        )
        try await fixture.transaction.stage(release)
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        asyncTransaction.finish()

        let active = try #require(await fixture.transaction.current(scope: fixture.scope))
        let mainObject = URL(fileURLWithPath: try #require(active.bundles.first?.localFilePath))
        let asyncRoot = try OtaSidecarDisk.root(fixture.root, appId: fixture.appId, channel: "async-bundles")
        let asyncObject = try OtaSidecarDisk.object(asyncRoot, sha256: OtaSidecarDisk.digest(Data("lazy-gc".utf8)))
        let asyncManifest = asyncRoot.appendingPathComponent("manifests/\(try OtaSidecarDisk.hashName(reference.sha256)).json")
        let mainManifests = fixture.root.appendingPathComponent("apps/\(fixture.appId)/manifests", isDirectory: true)
        let manifestFiles = try FileManager.default.contentsOfDirectory(at: mainManifests, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(!manifestFiles.isEmpty)
        for file in manifestFiles { try FileManager.default.removeItem(at: file) }

        try await fixture.transaction.pruneAllUnreferencedReleases()

        #expect(FileManager.default.fileExists(atPath: mainObject.path))
        #expect(FileManager.default.fileExists(atPath: asyncManifest.path))
        #expect(FileManager.default.fileExists(atPath: asyncObject.path))
    }

    @Test("candidate 确认与回滚使用各自的 Async 快照")
    func candidateTrialConfirmAndRollbackUseBoundSidecars() async throws {
        let fixture = try SidecarFixture()
        defer { fixture.cleanup() }
        let asyncA = try await fixture.asyncManifest("stable-A")
        let asyncStageA = try await fixture.asyncStore.prepare(asyncA, appId: fixture.appId, owners: ["HomePage.lynx.bundle"])
        let mainA = Data("main-A".utf8)
        let mainFileA = fixture.root.appendingPathComponent("candidate-main-A.lynx.bundle")
        try mainA.write(to: mainFileA)
        let releaseA = OtaInstalledRelease(
            context: .init(env: .test, app: .capp, lynxAppId: fixture.appId, releaseId: "A", platform: .ios, status: .active),
            installedAt: Date(),
            bundles: [.init(bundleName: "HomePage.lynx.bundle", bundleSha256: OtaSidecarDisk.digest(mainA), remoteURL: URL(string: "https://example.invalid/main-A")!, localFilePath: mainFileA.path)],
            asyncBundleManifest: asyncA
        )
        try await fixture.transaction.stage(releaseA)
        _ = try await fixture.transaction.activate(scope: fixture.scope)
        asyncStageA.finish()

        let asyncB = try await fixture.asyncManifest("candidate-B")
        let asyncStageB = try await fixture.asyncStore.prepare(asyncB, appId: fixture.appId, owners: ["HomePage.lynx.bundle"])
        let mainB = Data("main-B".utf8)
        let mainFileB = fixture.root.appendingPathComponent("candidate-main-B.lynx.bundle")
        try mainB.write(to: mainFileB)
        let releaseB = OtaInstalledRelease(
            context: .init(env: .test, app: .capp, lynxAppId: fixture.appId, releaseId: "B", platform: .ios, status: .active),
            installedAt: Date(),
            bundles: [.init(bundleName: "HomePage.lynx.bundle", bundleSha256: OtaSidecarDisk.digest(mainB), remoteURL: URL(string: "https://example.invalid/main-B")!, localFilePath: mainFileB.path)],
            asyncBundleManifest: asyncB
        )
        try await fixture.transaction.stageCandidate(releaseB)
        asyncStageB.finish()
        _ = try await fixture.transaction.beginCandidateTrial(scope: fixture.scope)
        let candidate = try #require(await fixture.transaction.candidate(scope: fixture.scope))

        let manifest = OtaReleaseManifest(env: .test, app: .capp, lynxAppId: fixture.appId, releaseId: "B", platform: .ios, bundles: [])
        let api = FakeOtaAPIClient(response: .init(matched: false, releaseId: nil, manifestURL: nil, ruleId: nil), manifest: manifest)
        let sdk = OtaSDK(configuration: .init(apiBaseURL: URL(string: "http://127.0.0.1:8080")!, app: .capp, lynxAppId: fixture.appId, environment: .test, platform: .ios, appVersion: "1.0", buildNumber: "1", storageDirectory: fixture.root), apiClient: api, store: FileOtaReleaseStore(baseDirectory: fixture.root, version: .v3))

        let stablePage = try #require(try await sdk.prepareResources(release: releaseA, ownerBundlePath: "HomePage.lynx.bundle"))
        let candidatePage = try #require(try await sdk.prepareResources(release: candidate.release, ownerBundlePath: "HomePage.lynx.bundle"))
        #expect(try await stablePage.resolve("/lazy-bundle/panel.bundle") == Data("lazy-stable-A".utf8))
        #expect(try await candidatePage.resolve("/lazy-bundle/panel.bundle") == Data("lazy-candidate-B".utf8))

        let confirmed = try await fixture.transaction.confirmCandidate(scope: fixture.scope)
        let confirmedPage = try #require(try await sdk.prepareResources(release: confirmed, ownerBundlePath: "HomePage.lynx.bundle"))
        #expect(try await confirmedPage.resolve("/lazy-bundle/panel.bundle") == Data("lazy-candidate-B".utf8))

        let rollback = try await fixture.transaction.rollback(scope: fixture.scope)
        guard case .restored(let restored) = rollback else { Issue.record("candidate 回滚没有恢复 A"); return }
        let restoredPage = try #require(try await sdk.prepareResources(release: restored, ownerBundlePath: "HomePage.lynx.bundle"))
        #expect(restored.asyncBundleManifest == asyncA)
        #expect(try await restoredPage.resolve("/lazy-bundle/panel.bundle") == Data("lazy-stable-A".utf8))

        stablePage.close()
        candidatePage.close()
        confirmedPage.close()
        restoredPage.close()
    }

    @Test("页面关闭后拒绝新资源解析与媒体 URL 查询")
    func closedResourcesRejectReads() async throws {
        let resources = OtaPreparedResources(hasAsyncResources: true, localPaths: ["lazy/part.bundle": URL(fileURLWithPath: "/tmp/part.bundle")], resolver: { _ in Data() }, closeAction: {})
        resources.close()
        #expect(resources.localURL("/lazy/part.bundle") == nil)
        do {
            _ = try await resources.resolve("/lazy/part.bundle")
            Issue.record("已关闭的资源仍允许解析")
        } catch let error as OtaSidecarError {
            if case .resourcesClosed = error { } else { Issue.record("关闭资源返回了错误类型") }
        } catch {
            Issue.record("关闭资源返回了意外错误")
        }
    }

    @Test("真实请求键单前导斜杠允许，路径穿越拒绝")
    func requestKeyValidation() throws {
        #expect(try OtaSidecarDisk.requestKey("/lazy-bundle/part.bundle") == "lazy-bundle/part.bundle")
        for key in ["//lazy-bundle/part.bundle", "../part", "/a/../part", "a%2fpart", "a?query", "a\\b"] {
            #expect(throws: OtaSidecarError.self) { try OtaSidecarDisk.requestKey(key) }
        }
    }
}

private actor SidecarDownloader: OtaBundleDownloading {
    var resources: [URL: Data] = [:]
    func add(_ url: URL, _ data: Data) { resources[url] = data }
    func download(from remoteURL: URL, to localURL: URL) async throws {
        guard let data = resources[remoteURL] else { throw OtaSidecarError.missingLocalResource }
        try data.write(to: localURL)
    }
}

private struct SidecarFixture {
    let root: URL
    let appId = "10020000"
    let scope = OtaReleaseScope(app: .capp, lynxAppId: "10020000")
    let downloader = SidecarDownloader()
    let asyncStore: OtaAsyncBundleStore
    let transaction: ReleaseTransaction

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ota-sidecar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        asyncStore = OtaAsyncBundleStore(baseDirectory: root, downloader: downloader)
        transaction = ReleaseTransaction(store: FileOtaReleaseStore(baseDirectory: root, version: .v3))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func asyncManifest(_ version: String) async throws -> OtaAsyncManifestReference {
        let bytes = Data("lazy-\(version)".utf8)
        let url = URL(string: "https://example.invalid/\(version)/part.bundle")!
        await downloader.add(url, bytes)
        let entry = OtaAsyncResource(ownerBundlePath: "HomePage.lynx.bundle", requestKey: "/lazy-bundle/panel.bundle", path: "lazy-bundle/panel.bundle", url: url, sha256: OtaSidecarDisk.digest(bytes), size: bytes.count, kind: "bundle")
        let manifest = OtaAsyncManifest(schemaVersion: 1, entries: [entry])
        let data = try JSONEncoder().encode(manifest)
        let manifestURL = URL(string: "https://example.invalid/\(version)/async.json")!
        await downloader.add(manifestURL, data)
        return OtaAsyncManifestReference(url: manifestURL, sha256: OtaSidecarDisk.digest(data), size: data.count)
    }

    func release(_ version: String, reference: OtaAsyncManifestReference) throws -> OtaInstalledRelease {
        let bytes = Data("main-\(version)".utf8)
        let file = root.appendingPathComponent("source-\(version).lynx.bundle")
        try bytes.write(to: file)
        return OtaInstalledRelease(context: .init(env: .test, app: .capp, lynxAppId: appId, releaseId: version, platform: .ios, status: .active), installedAt: Date(), bundles: [OtaInstalledBundle(bundleName: "HomePage.lynx.bundle", bundleSha256: OtaSidecarDisk.digest(bytes), remoteURL: URL(string: "https://example.invalid/main")!, localFilePath: file.path)], asyncBundleManifest: reference)
    }

    func install(_ version: String) async throws -> OtaAsyncManifestReference {
        let reference = try await asyncManifest(version)
        let staging = try await asyncStore.prepare(reference, appId: appId, owners: ["HomePage.lynx.bundle"])
        defer { staging.finish() }
        try await transaction.stage(release(version, reference: reference))
        _ = try await transaction.activate(scope: scope)
        return reference
    }

}
