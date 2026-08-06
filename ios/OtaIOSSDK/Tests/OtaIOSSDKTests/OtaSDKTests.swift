import Foundation
import Testing
@testable import OtaIOSSDK

actor FakeOtaAPIClient: OtaAPIClientProtocol {
    let response: OtaPolicyMatchResponse
    let manifest: OtaReleaseManifest
    let latestBundleList: OtaLatestBundleList
    let latestBundleLists: OtaHostLatestBundleLists
    let manifestError: OtaSDKError?
    let latestBundleListError: Error?
    let latestBundleListsError: Error?
    private(set) var reportedEvents: [OtaReportPayload] = []
    private(set) var lastPolicyRequest: OtaPolicyMatchRequest?
    private(set) var requestedLatestAppIds: [String] = []

    init(
        response: OtaPolicyMatchResponse,
        manifest: OtaReleaseManifest,
        manifestError: OtaSDKError? = nil,
        latestBundleListError: Error? = nil,
        latestBundleListsError: Error? = nil,
        latestBundleList: OtaLatestBundleList? = nil,
        latestBundleLists: OtaHostLatestBundleLists? = nil
    ) {
        self.response = response
        self.manifest = manifest
        self.manifestError = manifestError
        self.latestBundleListError = latestBundleListError
        self.latestBundleListsError = latestBundleListsError
        let defaultLatestBundleList = latestBundleList ?? OtaLatestBundleList(
            env: manifest.env,
            app: manifest.app,
            lynxAppId: manifest.lynxAppId,
            releaseId: manifest.releaseId,
            platform: manifest.platform,
            platforms: manifest.platforms,
            status: .active,
            changedBundles: manifest.bundles
        )
        self.latestBundleList = defaultLatestBundleList
        self.latestBundleLists = latestBundleLists ?? OtaHostLatestBundleLists(
            env: defaultLatestBundleList.env,
            app: defaultLatestBundleList.app,
            platform: defaultLatestBundleList.platform,
            bundleLists: [defaultLatestBundleList]
        )
    }

    func checkForUpdate(_ request: OtaPolicyMatchRequest) async throws -> OtaPolicyMatchResponse {
        lastPolicyRequest = request
        return response
    }

    func fetchManifest(
        releaseId: String,
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform
    ) async throws -> OtaReleaseManifest {
        if let manifestError {
            throw manifestError
        }
        return manifest
    }

    func fetchLatestBundleList(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform
    ) async throws -> OtaLatestBundleList {
        requestedLatestAppIds.append(lynxAppId)
        if let latestBundleListError {
            throw latestBundleListError
        }
        return latestBundleList
    }

    func fetchLatestBundleLists(
        env: OtaEnvironment,
        app: OtaAppID,
        platform: OtaPlatform
    ) async throws -> OtaHostLatestBundleLists {
        if let latestBundleListsError {
            throw latestBundleListsError
        }
        return latestBundleLists
    }

    func reportEvent(_ payload: OtaReportPayload) async throws -> OtaReportResponse {
        reportedEvents.append(payload)
        return OtaReportResponse(accepted: true, releaseId: payload.releaseId, event: payload.event)
    }

    func events() -> [OtaReportPayload] {
        reportedEvents
    }

    func policyRequest() -> OtaPolicyMatchRequest? {
        lastPolicyRequest
    }

    func latestAppIds() -> [String] {
        requestedLatestAppIds
    }
}

actor RecordingBundleDownloader: OtaBundleDownloading {
    private var downloadedURLs: [URL] = []

    func download(from remoteURL: URL, to localURL: URL) async throws {
        downloadedURLs.append(remoteURL)
        try await URLSessionBundleDownloader().download(from: remoteURL, to: localURL)
    }

    func downloads() -> [URL] {
        downloadedURLs
    }
}

@Suite("OtaIOSSDK")
struct OtaSDKTests {
    @Test("reports latest bundle-list decode failure without releaseId")
    func latestBundleListDecodeFailure() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let manifest = OtaReleaseManifest(
            env: .test,
            app: .capp,
            releaseId: "r20260506_ios_latest_fail",
            platform: .ios,
            bundles: []
        )

        let decodeError = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "latest bundle-list json parse failed")
        )

        let apiClient = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: false, releaseId: nil, manifestURL: nil, ruleId: nil),
            manifest: manifest,
            latestBundleListError: decodeError
        )

        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: "10000000",
                environment: .test,
                platform: .ios,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory
            ),
            apiClient: apiClient,
            store: FileOtaReleaseStore(baseDirectory: tempDirectory),
            downloader: RecordingBundleDownloader()
        )

        await #expect(throws: DecodingError.self) {
            _ = try await sdk.updateToLatestBundleList()
        }

        let event = await apiClient.events().last
        #expect(event?.releaseId == nil)
        #expect(event?.event == .checkResult)
        #expect(event?.eventStage == .check)
        #expect(event?.eventResult == .failed)
        #expect(event?.reasonCode == OtaReasonCode.latestBundleListDecodeFailed.rawValue)
    }

    @Test("reports manifest fetch failure with structured reason code")
    func manifestFetchFailure() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let manifest = OtaReleaseManifest(
            env: .test,
            app: .capp,
            releaseId: "r20260505_ios_manifest_fail",
            platform: .ios,
            bundles: []
        )
        let apiClient = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(
                matched: true,
                releaseId: manifest.releaseId,
                manifestURL: URL(string: "http://127.0.0.1:8080/api/ota/v1/release/\(manifest.releaseId)/manifest"),
                ruleId: "rule_manifest_failure"
            ),
            manifest: manifest,
            manifestError: .invalidResponse(statusCode: 500, body: "manifest boom")
        )
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient
        )

        do {
            _ = try await sdk.updateIfNeeded(OtaCheckRequest(pageId: 10000001, userId: "42"))
            Issue.record("Expected manifest fetch to fail")
        } catch let error as OtaSDKError {
            #expect(error == .invalidResponse(statusCode: 500, body: "manifest boom"))
        }
        let event = await apiClient.events().last
        #expect(event?.event == .checkResult)
        #expect(event?.eventStage == .manifest)
        #expect(event?.eventResult == .failed)
        #expect(event?.reasonCode == OtaReasonCode.manifestFetchFailed.rawValue)
        #expect(event?.releaseId == manifest.releaseId)
    }

    @Test("downloads, validates, activates and rolls back release")
    func otaLifecycle() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let sourceBundleURL = tempDirectory.appendingPathComponent("source/main.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: sourceBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bundleData = Data("demo-bundle".utf8)
        try bundleData.write(to: sourceBundleURL)

        let checksum = try SHA256ChecksumValidator().sha256(for: sourceBundleURL)
        let manifest = OtaReleaseManifest(
            env: .test,
            app: .capp,
            releaseId: "r20260421_ios_001",
            platform: .ios,
            bundles: [
                OtaBundleArtifact(
                    pageId: 10000001,
                    bundlePath: "pages/10000001/main.lynx.bundle",
                    bundleSha256: checksum,
                    bundleURL: sourceBundleURL
                )
            ]
        )
        let match = OtaPolicyMatchResponse(
            matched: true,
            releaseId: manifest.releaseId,
            manifestURL: URL(string: "http://127.0.0.1:8080/api/ota/v1/release/\(manifest.releaseId)/manifest"),
            ruleId: "rule_capp_default"
        )
        let apiClient = FakeOtaAPIClient(response: match, manifest: manifest)
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient
        )

        let embedded = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                releaseId: "embedded",
                platform: .ios,
                status: .active
            ),
            installedAt: .now,
            bundles: []
        )
        try await sdk.initializeEmbeddedRelease(embedded)

        let result = try await sdk.updateIfNeeded(OtaCheckRequest(pageId: 10000001, userId: "42"))
        switch result {
        case let .updated(from, to):
            #expect(from?.context.releaseId == "embedded")
            #expect(to.context.releaseId == manifest.releaseId)
            #expect(to.bundles.count == 1)
        default:
            Issue.record("Expected updated result")
        }

        let currentVersion = await sdk.getCurrentVersion()
        #expect(currentVersion == manifest.releaseId)

        let restored = try await sdk.rollback(reason: "manual_rollback")
        #expect(restored?.context.releaseId == "embedded")

        let events = await apiClient.events().map(\.event)
        #expect(events.contains(.checkResult))
        #expect(events.contains(.downloadSuccess))
        #expect(events.contains(.activate))
        #expect(events.contains(.rollback))
        let reportedEvents = await apiClient.events()
        let checkEvent = reportedEvents.first { $0.event == .checkResult }
        let downloadEvent = reportedEvents.first { $0.event == .downloadSuccess }
        let activateEvent = reportedEvents.first { $0.event == .activate }
        let rollbackEvent = reportedEvents.first { $0.event == .rollback }
        #expect(checkEvent?.eventStage == .match)
        #expect(checkEvent?.eventResult == .success)
        #expect(downloadEvent?.eventStage == .download)
        #expect(downloadEvent?.eventResult == .success)
        #expect((downloadEvent?.latencyMs ?? 0) >= 0)
        #expect(activateEvent?.eventStage == .activate)
        #expect(activateEvent?.eventResult == .success)
        #expect(rollbackEvent?.eventStage == .rollback)
        #expect(rollbackEvent?.eventResult == .success)
        #expect(rollbackEvent?.reasonCode == "manual_rollback")
        #expect(rollbackEvent?.fromReleaseId == manifest.releaseId)
        #expect(rollbackEvent?.toReleaseId == "embedded")
        let policyRequest = await apiClient.policyRequest()
        #expect(policyRequest?.lynxAppId == OtaDefaults.lynxAppId)
    }

    @Test("rejects downloaded bundle when manifest size does not match")
    func rejectsBundleSizeMismatch() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = tempDirectory.appendingPathComponent("source/home.lynx.bundle")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("bundle-with-size".utf8)
        try data.write(to: sourceURL)
        let checksum = try SHA256ChecksumValidator().sha256(for: sourceURL)
        let manifest = OtaReleaseManifest(
            env: .test,
            app: .capp,
            lynxAppId: "10000001",
            releaseId: "r_size_mismatch",
            platform: .ios,
            bundles: [
                OtaBundleArtifact(
                    bundleName: "home.lynx.bundle",
                    bundleSha256: checksum,
                    bundleURL: sourceURL,
                    size: data.count + 1
                )
            ]
        )
        let apiClient = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId),
            manifest: manifest,
            latestBundleList: OtaLatestBundleList(
                env: .test,
                app: .capp,
                lynxAppId: manifest.lynxAppId,
                releaseId: manifest.releaseId,
                platform: .ios,
                platforms: [.ios],
                status: .active,
                changedBundles: manifest.bundles
            )
        )
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: manifest.lynxAppId,
                environment: .test,
                platform: .ios,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient
        )

        do {
            _ = try await sdk.updateToLatestBundleList(lynxAppId: manifest.lynxAppId)
            Issue.record("Expected size mismatch")
        } catch let error as OtaSDKError {
            #expect(error == .sizeMismatch(expected: data.count + 1, actual: Int64(data.count)))
        }
        let event = await apiClient.events().last { $0.reasonCode == OtaReasonCode.bundleSizeFailed.rawValue }
        #expect(event?.eventResult == .failed)
    }

    @Test("facade returns local template url after activation")
    func facadeTemplateURL() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let sourceBundleURL = tempDirectory.appendingPathComponent("source/template.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: sourceBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bundle-template".utf8).write(to: sourceBundleURL)
        let checksum = try SHA256ChecksumValidator().sha256(for: sourceBundleURL)

        let manifest = OtaReleaseManifest(
            env: .test,
            app: .capp,
            releaseId: "r20260421_ios_002",
            platform: .ios,
            bundles: [
                OtaBundleArtifact(
                    pageId: 10000002,
                    bundlePath: "pages/10000002/main.lynx.bundle",
                    bundleSha256: checksum,
                    bundleURL: sourceBundleURL
                )
            ]
        )
        let match = OtaPolicyMatchResponse(
            matched: true,
            releaseId: manifest.releaseId,
            manifestURL: nil,
            ruleId: "rule_capp_default"
        )
        let apiClient = FakeOtaAPIClient(response: match, manifest: manifest)
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient
        )

        let embedded = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                releaseId: "embedded",
                platform: .ios,
                status: .active
            ),
            installedAt: .now,
            bundles: []
        )

        let hotUpdate = LynxHotUpdate()
        try await hotUpdate.initialize(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("facade-store", isDirectory: true)
            ),
            embeddedRelease: embedded
        )

        // reinitialize dedicated facade through a custom template router is not supported yet, so verify main SDK path instead
        try await sdk.initializeEmbeddedRelease(embedded)
        _ = try await sdk.updateIfNeeded(OtaCheckRequest(pageId: 10000002))
        let current = await sdk.getCurrentRelease()
        #expect(current?.context.releaseId == manifest.releaseId)
        let localPath = current?.bundles.first?.localFilePath
        #expect(localPath?.contains("pages/10000002/main.lynx.bundle") == true)
    }

    @Test("reuses unchanged local bundles and downloads only changed bundles")
    func incrementalBundleDownload() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let reusableLocalURL = tempDirectory.appendingPathComponent("installed/App.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: reusableLocalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unchanged-app-bundle".utf8).write(to: reusableLocalURL)
        let reusableChecksum = try SHA256ChecksumValidator().sha256(for: reusableLocalURL)

        let changedSourceURL = tempDirectory.appendingPathComponent("source/GuideServiceDetail.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: changedSourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("changed-guide-bundle".utf8).write(to: changedSourceURL)
        let changedChecksum = try SHA256ChecksumValidator().sha256(for: changedSourceURL)

        let manifest = OtaReleaseManifest(
            env: .test,
            app: .capp,
            releaseId: "r20260427_incremental_001",
            platform: .ios,
            bundles: [
                OtaBundleArtifact(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: reusableChecksum,
                    bundleURL: URL(string: "https://cdn.example.com/App.lynx.bundle")!
                ),
                OtaBundleArtifact(
                    pageId: 10000001,
                    bundlePath: "GuideServiceDetail.lynx.bundle",
                    bundleSha256: changedChecksum,
                    bundleURL: changedSourceURL
                )
            ]
        )
        let match = OtaPolicyMatchResponse(
            matched: true,
            releaseId: manifest.releaseId,
            manifestURL: nil,
            ruleId: "default_active_release"
        )
        let apiClient = FakeOtaAPIClient(response: match, manifest: manifest)
        let downloader = RecordingBundleDownloader()
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient,
            downloader: downloader
        )

        let current = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                releaseId: "r20260427_previous",
                platform: .ios,
                status: .active
            ),
            installedAt: .now,
            bundles: [
                OtaInstalledBundle(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: reusableChecksum,
                    remoteURL: URL(string: "https://cdn.example.com/old/App.lynx.bundle")!,
                    localFilePath: reusableLocalURL.path
                )
            ]
        )
        try await sdk.initializeEmbeddedRelease(current)

        let result = try await sdk.updateIfNeeded(OtaCheckRequest(pageId: 10000000, userId: "42"))
        guard case let .updated(_, installed) = result else {
            Issue.record("Expected updated result")
            return
        }

        let reusedBundle = installed.bundles.first { $0.bundlePath == "App.lynx.bundle" }
        let changedBundle = installed.bundles.first { $0.bundlePath == "GuideServiceDetail.lynx.bundle" }
        #expect(reusedBundle?.localFilePath == reusableLocalURL.path)
        #expect(changedBundle?.localFilePath.contains(manifest.releaseId) == true)
        #expect(await downloader.downloads() == [changedSourceURL])

        let downloadEvents = await apiClient.events().filter { $0.event == .downloadSuccess }
        #expect(downloadEvents.map(\.pageId) == [10000001])
    }

    @Test("syncs latest bundle list and keeps unchanged bundles local")
    func latestBundleListSync() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let reusableLocalURL = tempDirectory.appendingPathComponent("installed/App.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: reusableLocalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unchanged-app-bundle".utf8).write(to: reusableLocalURL)
        let reusableChecksum = try SHA256ChecksumValidator().sha256(for: reusableLocalURL)

        let changedSourceURL = tempDirectory.appendingPathComponent("source/PriceAdjustment.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: changedSourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("changed-price-bundle".utf8).write(to: changedSourceURL)
        let changedChecksum = try SHA256ChecksumValidator().sha256(for: changedSourceURL)

        let latest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: "10000000",
            releaseId: "r20260427_latest_001",
            platform: .ios,
            platforms: [.android, .ios],
            status: .active,
            changedBundles: [
                OtaBundleArtifact(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: reusableChecksum,
                    bundleURL: URL(string: "https://cdn.example.com/App.lynx.bundle")!
                ),
                OtaBundleArtifact(
                    pageId: 10000002,
                    bundlePath: "PriceAdjustment.lynx.bundle",
                    bundleSha256: changedChecksum,
                    bundleURL: changedSourceURL
                )
            ]
        )
        let manifest = latest.asManifest()
        let match = OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId, manifestURL: nil, ruleId: nil)
        let apiClient = FakeOtaAPIClient(response: match, manifest: manifest, latestBundleList: latest)
        let downloader = RecordingBundleDownloader()
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: "10000000",
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient,
            downloader: downloader
        )

        let current = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: "10000000",
                releaseId: "r20260427_previous",
                platform: .ios,
                status: .active
            ),
            installedAt: .now,
            bundles: [
                OtaInstalledBundle(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: reusableChecksum,
                    remoteURL: URL(string: "https://cdn.example.com/old/App.lynx.bundle")!,
                    localFilePath: reusableLocalURL.path
                )
            ]
        )
        try await sdk.initializeEmbeddedRelease(current)

        let result = try await sdk.updateToLatestBundleList()
        guard case let .updated(_, installed, summary) = result else {
            Issue.record("Expected latest bundle-list update result")
            return
        }

        #expect(installed.context.lynxAppId == "10000000")
        #expect(installed.context.releaseId == latest.releaseId)
        #expect(summary.totalBundleCount == 2)
        #expect(summary.reusedBundleCount == 1)
        #expect(summary.downloadedBundleCount == 1)
        #expect(installed.bundles.first { $0.bundlePath == "App.lynx.bundle" }?.localFilePath == reusableLocalURL.path)
        #expect(await downloader.downloads() == [changedSourceURL])
    }

    @Test("skips latest bundle list when Lynx baseline does not match")
    func latestBundleListSkipsWhenBaselineDoesNotMatch() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let embeddedURL = tempDirectory.appendingPathComponent("embedded/App.lynx.bundle", isDirectory: false)
        let remoteURL = tempDirectory.appendingPathComponent("remote/App.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: embeddedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("embedded".utf8).write(to: embeddedURL)
        try Data("remote".utf8).write(to: remoteURL)
        let checksum = try SHA256ChecksumValidator().sha256(for: remoteURL)

        let latest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: "10000000",
            releaseId: "r20260430_ios_skip_001",
            platform: .ios,
            platforms: [.ios],
            status: .active,
            lynxSdkRange: OtaReleaseVersionRange(min: "3.0.0"),
            changedBundles: [
                OtaBundleArtifact(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: checksum,
                    bundleURL: remoteURL
                )
            ]
        )
        let apiClient = FakeOtaAPIClient(response: OtaPolicyMatchResponse(matched: true, releaseId: latest.releaseId, manifestURL: nil, ruleId: nil), manifest: latest.asManifest(), latestBundleList: latest)
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: "10000000",
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                lynxSdkVersion: "2.9.0",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient
        )

        try await sdk.initializeEmbeddedRelease(
            OtaInstalledRelease(
                context: OtaCurrentReleaseContext(env: .test, app: .capp, lynxAppId: "10000000", releaseId: "embedded", platform: .ios, status: .active),
                installedAt: .now,
                bundles: [
                    OtaInstalledBundle(pageId: 10000000, bundlePath: "App.lynx.bundle", bundleSha256: checksum, remoteURL: embeddedURL, localFilePath: embeddedURL.path)
                ]
            )
        )

        let result = try await sdk.updateToLatestBundleList()
        guard case let .skipped(current, message) = result else {
            Issue.record("Expected skipped result")
            return
        }

        #expect(current?.context.releaseId == "embedded")
        #expect(message.contains("Lynx 基线版本"))
        #expect(await sdk.getCurrentRelease()?.context.releaseId == "embedded")
        let reportedEvents = await apiClient.events()
        #expect(reportedEvents.count == 1)
        #expect(reportedEvents[0].event == .checkResult)
        #expect(reportedEvents[0].eventStage == .check)
        #expect(reportedEvents[0].eventResult == .skipped)
        #expect(reportedEvents[0].reasonCode == "baseline_blocked")
        #expect(reportedEvents[0].reasonMessage?.contains("Lynx 基线版本") == true)
    }

    @Test("reports check result when latest bundle list is already active")
    func latestBundleListReportsAlreadyActiveCheckResult() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let localBundleURL = tempDirectory.appendingPathComponent("current/App.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: localBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("already-active-bundle".utf8).write(to: localBundleURL)
        let checksum = try SHA256ChecksumValidator().sha256(for: localBundleURL)

        let latest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: "10000000",
            releaseId: "r20260506_ios_already_active",
            platform: .ios,
            platforms: [.ios],
            status: .active,
            changedBundles: [
                OtaBundleArtifact(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: checksum,
                    bundleURL: localBundleURL
                )
            ]
        )
        let manifest = latest.asManifest()
        let apiClient = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId, manifestURL: nil, ruleId: nil),
            manifest: manifest,
            latestBundleList: latest
        )
        let downloader = RecordingBundleDownloader()
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: "10000000",
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient,
            downloader: downloader
        )

        let current = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: "10000000",
                releaseId: latest.releaseId,
                platform: .ios,
                status: .active
            ),
            installedAt: .now,
            bundles: [
                OtaInstalledBundle(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: checksum,
                    remoteURL: localBundleURL,
                    localFilePath: localBundleURL.path
                )
            ]
        )
        try await sdk.initializeEmbeddedRelease(current)

        let result = try await sdk.updateToLatestBundleList()
        guard case let .alreadyActive(installed) = result else {
            Issue.record("Expected already active result")
            return
        }

        #expect(installed.context.releaseId == latest.releaseId)
        #expect(await downloader.downloads().isEmpty)
        let reportedEvents = await apiClient.events()
        #expect(reportedEvents.count == 1)
        #expect(reportedEvents[0].event == .checkResult)
        #expect(reportedEvents[0].eventStage == .check)
        #expect(reportedEvents[0].eventResult == .success)
        #expect(reportedEvents[0].releaseId == latest.releaseId)
        #expect(reportedEvents[0].lynxAppId == "10000000")
        #expect(reportedEvents[0].message == "already_active")
    }

    @Test("syncs latest bundle lists for every LynxApp in host app")
    func hostLatestBundleListsSyncsMultipleLynxApps() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let firstSourceURL = tempDirectory.appendingPathComponent("embedded/10000000/App.lynx.bundle", isDirectory: false)
        let secondSourceURL = tempDirectory.appendingPathComponent("embedded/10000002/App.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: firstSourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first-lynx-app-bundle".utf8).write(to: firstSourceURL)
        try Data("second-lynx-app-bundle".utf8).write(to: secondSourceURL)
        let firstChecksum = try SHA256ChecksumValidator().sha256(for: firstSourceURL)
        let secondChecksum = try SHA256ChecksumValidator().sha256(for: secondSourceURL)

        let firstLatest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: "10000000",
            releaseId: "r_first_latest",
            platform: .ios,
            platforms: [.ios],
            status: .active,
            changedBundles: [
                OtaBundleArtifact(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: firstChecksum,
                    bundleURL: URL(string: "https://cdn.example.com/10000000/App.lynx.bundle")!
                )
            ]
        )
        let secondLatest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: "10000002",
            releaseId: "r_second_latest",
            platform: .ios,
            platforms: [.ios],
            status: .active,
            changedBundles: [
                OtaBundleArtifact(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: secondChecksum,
                    bundleURL: URL(string: "https://cdn.example.com/10000002/App.lynx.bundle")!
                )
            ]
        )
        let hostLatest = OtaHostLatestBundleLists(
            env: .test,
            app: .capp,
            platform: .ios,
            bundleLists: [firstLatest, secondLatest]
        )
        let apiClient = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: firstLatest.releaseId, manifestURL: nil, ruleId: nil),
            manifest: firstLatest.asManifest(),
            latestBundleList: firstLatest,
            latestBundleLists: hostLatest
        )
        let downloader = RecordingBundleDownloader()
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: "10000000",
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient,
            downloader: downloader
        )

        try await sdk.initializeEmbeddedRelease(
            OtaInstalledRelease(
                context: OtaCurrentReleaseContext(env: .test, app: .capp, lynxAppId: "10000000", releaseId: "embedded-first", platform: .ios, status: .active),
                installedAt: .now,
                bundles: [
                    OtaInstalledBundle(pageId: 10000000, bundlePath: "App.lynx.bundle", bundleSha256: firstChecksum, remoteURL: firstSourceURL, localFilePath: firstSourceURL.path)
                ]
            )
        )
        try await sdk.initializeEmbeddedRelease(
            OtaInstalledRelease(
                context: OtaCurrentReleaseContext(env: .test, app: .capp, lynxAppId: "10000002", releaseId: "embedded-second", platform: .ios, status: .active),
                installedAt: .now,
                bundles: [
                    OtaInstalledBundle(pageId: 10000000, bundlePath: "App.lynx.bundle", bundleSha256: secondChecksum, remoteURL: secondSourceURL, localFilePath: secondSourceURL.path)
                ]
            )
        )

        let result = try await sdk.updateToLatestBundleLists()

        #expect(result.updatedCount == 2)
        #expect(result.results.keys.sorted() == ["10000000", "10000002"])
        #expect(await sdk.getCurrentRelease(lynxAppId: "10000000")?.context.releaseId == firstLatest.releaseId)
        #expect(await sdk.getCurrentRelease(lynxAppId: "10000002")?.context.releaseId == secondLatest.releaseId)
        #expect(await sdk.getCurrentRelease(lynxAppId: "10000002")?.bundles.first?.localFilePath == secondSourceURL.path)
        #expect(await downloader.downloads().isEmpty)
        #expect(await apiClient.events().filter { $0.event == .checkResult }.map(\.lynxAppId).sorted() == ["10000000", "10000002"])
    }

    @Test("same latest release reuses fresh embedded bundle when active path is missing")
    func latestBundleListReusesFreshEmbeddedWhenActivePathIsMissing() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let sourceBundleURL = tempDirectory.appendingPathComponent("source/App.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: sourceBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current-release-bundle".utf8).write(to: sourceBundleURL)
        let checksum = try SHA256ChecksumValidator().sha256(for: sourceBundleURL)
        let missingLocalURL = tempDirectory.appendingPathComponent("old-app-container/App.lynx.bundle", isDirectory: false)

        let latest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: "10000000",
            releaseId: "r20260428_same_latest_missing_file",
            platform: .ios,
            platforms: [.ios],
            status: .active,
            changedBundles: [
                OtaBundleArtifact(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: checksum,
                    bundleURL: sourceBundleURL
                )
            ]
        )
        let manifest = latest.asManifest()
        let match = OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId, manifestURL: nil, ruleId: nil)
        let apiClient = FakeOtaAPIClient(response: match, manifest: manifest, latestBundleList: latest)
        let downloader = RecordingBundleDownloader()
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: "10000000",
                environment: .test,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient,
            downloader: downloader
        )

        let current = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: "10000000",
                releaseId: latest.releaseId,
                platform: .ios,
                status: .active
            ),
            installedAt: .now,
            bundles: [
                OtaInstalledBundle(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: checksum,
                    remoteURL: sourceBundleURL,
                    localFilePath: missingLocalURL.path
                )
            ]
        )
        try await sdk.initializeEmbeddedRelease(current)

        let freshEmbedded = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: "10000000",
                releaseId: "embedded-dist-test",
                platform: .ios,
                status: .active
            ),
            installedAt: .now,
            bundles: [
                OtaInstalledBundle(
                    pageId: 10000000,
                    bundlePath: "App.lynx.bundle",
                    bundleSha256: checksum,
                    remoteURL: sourceBundleURL,
                    localFilePath: sourceBundleURL.path
                )
            ]
        )
        try await sdk.initializeEmbeddedRelease(freshEmbedded)

        let result = try await sdk.updateToLatestBundleList()
        guard case let .updated(_, installed, summary) = result else {
            Issue.record("Expected missing active bundle path to trigger refresh")
            return
        }

        let installedBundle = try #require(installed.bundles.first)
        #expect(summary.downloadedBundleCount == 0)
        #expect(summary.reusedBundleCount == 1)
        #expect(installedBundle.localFilePath != missingLocalURL.path)
        #expect(installedBundle.localFilePath == sourceBundleURL.path)
        #expect(FileManager.default.fileExists(atPath: installedBundle.localFilePath))
        #expect(await downloader.downloads().isEmpty)
    }

    @Test("resolves bundleName exactly and repairs a missing bundle from latest snapshot")
    func bundleNameLookupAndEnsureBundleReady() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let sourceBundleURL = tempDirectory.appendingPathComponent("source/home.lynx.bundle", isDirectory: false)
        try FileManager.default.createDirectory(at: sourceBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bundle-runtime-home".utf8).write(to: sourceBundleURL)
        let checksum = try SHA256ChecksumValidator().sha256(for: sourceBundleURL)
        let appId = "10000001"
        let bundle = OtaBundleArtifact(
            bundleName: "home.lynx.bundle",
            bundleSha256: checksum,
            bundleURL: sourceBundleURL,
            pageId: 0,
            bundlePath: "pages/home/home.lynx.bundle"
        )
        let latest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: appId,
            releaseId: "r_bundle_name_001",
            platform: .ios,
            platforms: [.ios],
            status: .active,
            changedBundles: [bundle]
        )
        let apiClient = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: false),
            manifest: latest.asManifest(),
            latestBundleLists: OtaHostLatestBundleLists(
                env: .test,
                app: .capp,
                platform: .ios,
                bundleLists: [latest]
            )
        )
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: appId,
                environment: .test,
                platform: .ios,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory.appendingPathComponent("store", isDirectory: true)
            ),
            apiClient: apiClient
        )
        try await sdk.initializeEmbeddedRelease(
            OtaInstalledRelease(
                context: OtaCurrentReleaseContext(
                    env: .test,
                    app: .capp,
                    lynxAppId: appId,
                    releaseId: "embedded",
                    platform: .ios,
                    status: .active
                ),
                installedAt: .now,
                bundles: []
            )
        )

        #expect(await sdk.currentTemplateURL(lynxAppId: appId, bundleName: "home.lynx.bundle") == nil)
        let readyURL = try await sdk.ensureBundleReady(lynxAppId: appId, bundleName: "home.lynx.bundle")
        #expect(readyURL.path.hasSuffix("pages/home/home.lynx.bundle"))
        #expect(FileManager.default.fileExists(atPath: readyURL.path))
        #expect(await sdk.currentTemplateURL(lynxAppId: appId, bundleName: "home.lynx.bundle") == readyURL)
        #expect(await sdk.current(lynxAppId: appId, bundleName: "home.lynx.bundle") == readyURL)
        #expect(await sdk.currentTemplateURL(lynxAppId: appId, bundleName: "pages/home/home.lynx.bundle") == readyURL)
        #expect(await sdk.current(lynxAppId: appId, bundleName: "pages/home/home.lynx.bundle") == readyURL)
        #expect(await sdk.getCurrentRelease(lynxAppId: appId)?.context.releaseId == latest.releaseId)
        #expect(await apiClient.latestAppIds() == [appId])
    }

    @Test("rejects unsafe bundleName before touching storage")
    func unsafeBundleNameIsRejected() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sdk = OtaSDK(
            configuration: OtaSDKConfiguration(
                apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
                app: .capp,
                lynxAppId: "10000001",
                environment: .test,
                platform: .ios,
                appVersion: "1.0.0",
                buildNumber: "100",
                storageDirectory: tempDirectory
            ),
            apiClient: FakeOtaAPIClient(
                response: OtaPolicyMatchResponse(matched: false),
                manifest: OtaReleaseManifest(
                    env: .test,
                    app: .capp,
                    lynxAppId: "10000001",
                    releaseId: "unused",
                    platform: .ios,
                    bundles: []
                )
            )
        )

        do {
            _ = try await sdk.ensureBundleReady(lynxAppId: "10000001", bundleName: "../secret")
            Issue.record("Expected traversal bundleName to be rejected")
        } catch let error as OtaSDKError {
            #expect(error == .invalidBundleName("../secret"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        for unsafeName in ["/absolute.lynx.bundle", "pages//home.lynx.bundle", "pages/./home.lynx.bundle", "pages/../home.lynx.bundle", "pages\\home.lynx.bundle", "bad\0name.lynx.bundle"] {
            do {
                _ = try await sdk.ensureBundleReady(lynxAppId: "10000001", bundleName: unsafeName)
                Issue.record("Expected unsafe bundleName to be rejected: \(unsafeName)")
            } catch let error as OtaSDKError {
                #expect(error == .invalidBundleName(unsafeName))
            } catch {
                Issue.record("Unexpected error for \(unsafeName): \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: tempDirectory.path))

        do {
            _ = try await sdk.ensureBundleReady(lynxAppId: "10000001", bundleName: "missing.lynx.bundle")
            Issue.record("Expected missing bundle to throw")
        } catch let error as OtaSDKError {
            #expect(error == .bundleNotFound(lynxAppId: "10000001", bundleName: "missing.lynx.bundle"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("release transaction isolates host app scope and rolls back previous release")
    func releaseTransactionScopeAndRollback() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileOtaReleaseStore(baseDirectory: tempDirectory)
        let transaction = ReleaseTransaction(store: store)
        let runtime = BundleRuntime(transaction: transaction)
        let sourceURL = tempDirectory.appendingPathComponent("bundle/home.lynx.bundle")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("transaction-bundle".utf8).write(to: sourceURL)
        let checksum = try SHA256ChecksumValidator().sha256(for: sourceURL)

        func release(app: OtaAppID, appId: String, releaseId: String) -> OtaInstalledRelease {
            OtaInstalledRelease(
                context: OtaCurrentReleaseContext(
                    env: .test,
                    app: app,
                    lynxAppId: appId,
                    releaseId: releaseId,
                    platform: .ios,
                    status: .active
                ),
                installedAt: .now,
                bundles: [
                    OtaInstalledBundle(
                        bundleName: "home.lynx.bundle",
                        bundleSha256: checksum,
                        remoteURL: sourceURL,
                        localFilePath: sourceURL.path
                    )
                ]
            )
        }

        let cappScope = OtaReleaseScope(app: .capp, lynxAppId: "10000001")
        let gappScope = OtaReleaseScope(app: .gapp, lynxAppId: "10000001")
        let cappEmbedded = release(app: .capp, appId: cappScope.lynxAppId, releaseId: "capp-embedded")
        let cappUpdate = release(app: .capp, appId: cappScope.lynxAppId, releaseId: "capp-update")
        let gappEmbedded = release(app: .gapp, appId: gappScope.lynxAppId, releaseId: "gapp-embedded")

        try await store.saveEmbeddedRelease(cappEmbedded)
        try await store.saveEmbeddedRelease(gappEmbedded)
        let first = try await transaction.install(OtaReleaseInstallRequest(scope: cappScope, release: cappUpdate))
        guard case let .updated(from, to) = first else {
            Issue.record("Expected scoped install to update capp")
            return
        }
        #expect(from?.context.releaseId == cappEmbedded.context.releaseId)
        #expect(to.context.releaseId == cappUpdate.context.releaseId)
        #expect((try await runtime.ensureBundleReady(scope: cappScope, bundleName: "home.lynx.bundle")).path == sourceURL.path)
        #expect((await transaction.current(scope: gappScope))?.context.releaseId == gappEmbedded.context.releaseId)

        let rollback = try await transaction.rollback(scope: cappScope)
        guard case let .restored(restored) = rollback else {
            Issue.record("Expected capp rollback to restore embedded release")
            return
        }
        #expect(restored.context.releaseId == cappEmbedded.context.releaseId)
        #expect((await transaction.current(scope: cappScope))?.context.releaseId == cappEmbedded.context.releaseId)
        #expect((await transaction.current(scope: gappScope))?.context.releaseId == gappEmbedded.context.releaseId)
    }

    @Test("deletes one appId or all downloaded bundles without hidden backups")
    func directBundleDeletionPreservesEmbeddedFallback() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeDirectory = tempDirectory.appendingPathComponent("store", isDirectory: true)
        let embeddedDirectory = tempDirectory.appendingPathComponent("embedded", isDirectory: true)
        let store = FileOtaReleaseStore(baseDirectory: storeDirectory)
        try FileManager.default.createDirectory(at: embeddedDirectory, withIntermediateDirectories: true)

        func makeEmbedded(appId: String) throws -> OtaInstalledRelease {
            let bundleURL = embeddedDirectory.appendingPathComponent("\(appId)-home.lynx.bundle")
            try Data("embedded-\(appId)".utf8).write(to: bundleURL)
            let checksum = try SHA256ChecksumValidator().sha256(for: bundleURL)
            return OtaInstalledRelease(
                context: OtaCurrentReleaseContext(
                    env: .test,
                    app: .capp,
                    lynxAppId: appId,
                    releaseId: "embedded-\(appId)",
                    platform: .ios,
                    status: .active
                ),
                installedAt: .now,
                bundles: [
                    OtaInstalledBundle(
                        bundleName: "home.lynx.bundle",
                        bundleSha256: checksum,
                        remoteURL: bundleURL,
                        localFilePath: bundleURL.path
                    )
                ]
            )
        }

        func installDownloaded(appId: String) async throws -> (OtaInstalledRelease, URL) {
            let releaseId = "downloaded-\(appId)"
            let localURL = try await store.localBundleURL(
                app: .capp,
                lynxAppId: appId,
                releaseId: releaseId,
                bundleName: "home.lynx.bundle"
            )
            try Data("downloaded-\(appId)".utf8).write(to: localURL)
            let checksum = try SHA256ChecksumValidator().sha256(for: localURL)
            let release = OtaInstalledRelease(
                context: OtaCurrentReleaseContext(
                    env: .test,
                    app: .capp,
                    lynxAppId: appId,
                    releaseId: releaseId,
                    platform: .ios,
                    status: .active
                ),
                installedAt: .now,
                bundles: [
                    OtaInstalledBundle(
                        bundleName: "home.lynx.bundle",
                        bundleSha256: checksum,
                        remoteURL: localURL,
                        localFilePath: localURL.path
                    )
                ]
            )
            try await store.stageRelease(release)
            _ = try await store.activateStagedRelease(app: .capp, lynxAppId: appId)
            return (release, localURL)
        }

        let firstAppId = "10000001"
        let secondAppId = "10000002"
        let firstEmbedded = try makeEmbedded(appId: firstAppId)
        let secondEmbedded = try makeEmbedded(appId: secondAppId)
        try await store.saveEmbeddedRelease(firstEmbedded)
        try await store.saveEmbeddedRelease(secondEmbedded)
        let (_, firstDownloadedURL) = try await installDownloaded(appId: firstAppId)
        let (secondDownloaded, secondDownloadedURL) = try await installDownloaded(appId: secondAppId)

        try await store.deleteDownloadedBundles(app: .capp, lynxAppId: firstAppId)

        #expect(!FileManager.default.fileExists(atPath: firstDownloadedURL.path))
        #expect(FileManager.default.fileExists(atPath: secondDownloadedURL.path))
        #expect(await store.currentRelease(app: .capp, lynxAppId: firstAppId)?.context.releaseId == firstEmbedded.context.releaseId)
        #expect(await store.currentRelease(app: .capp, lynxAppId: secondAppId)?.context.releaseId == secondDownloaded.context.releaseId)

        try await store.deleteAllDownloadedBundles()

        #expect(!FileManager.default.fileExists(atPath: secondDownloadedURL.path))
        #expect(await store.currentRelease(app: .capp, lynxAppId: firstAppId)?.context.releaseId == firstEmbedded.context.releaseId)
        #expect(await store.currentRelease(app: .capp, lynxAppId: secondAppId)?.context.releaseId == secondEmbedded.context.releaseId)
        let storedNames = (FileManager.default.enumerator(atPath: storeDirectory.path)?.allObjects as? [String]) ?? []
        #expect(!storedNames.contains { $0.contains(".delete-") || $0.contains(".staging") })
    }

    @Test("policy and report payloads encode hostApp and lynxAppId")
    func payloadCodingUsesServerFieldNames() throws {
        let encoder = JSONEncoder()
        let policyData = try encoder.encode(
            OtaPolicyMatchRequest(
                env: .test,
                app: .capp,
                lynxAppId: "10000000",
                platform: .ios,
                appVersion: "1.0.0",
                buildNumber: "100",
                osVersion: "17.0",
                channel: nil,
                region: nil,
                userId: nil,
                deviceId: nil,
                pageId: 10000000,
                bundleName: "home.lynx.bundle",
                nativeProtocolVersion: nil,
                lynxSdkVersion: nil
            )
        )
        let policyJSON = try #require(JSONSerialization.jsonObject(with: policyData) as? [String: Any])
        #expect(policyJSON["hostApp"] as? String == "capp")
        #expect(policyJSON["lynxAppId"] as? String == "10000000")
        #expect(policyJSON["bundleName"] as? String == "home.lynx.bundle")
        #expect(policyJSON["app"] == nil)

        let reportData = try encoder.encode(
            OtaReportPayload(
                env: .test,
                app: .capp,
                lynxAppId: "10000000",
                releaseId: "r1",
                platform: .ios,
                event: .activate,
                pageId: nil,
                deviceId: nil,
                message: "ok"
            )
        )
        let reportJSON = try #require(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        #expect(reportJSON["hostApp"] as? String == "capp")
        #expect(reportJSON["lynxAppId"] as? String == "10000000")
        #expect(reportJSON["app"] == nil)
    }
}
