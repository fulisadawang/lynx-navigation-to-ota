import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("OtaSDKFaultPaths")
struct OtaSDKFaultPathTests {
    @Test("latest bundle-list timeout keeps the embedded current release")
    func latestBundleListFailureDoesNotPublish() async throws {
        let directory = try makeSDKFaultTempDirectory()
        let manifest = OtaReleaseManifest(
            env: .test,
            app: .capp,
            lynxAppId: "10000001",
            releaseId: "r_ios_latest_timeout",
            platform: .ios,
            bundles: []
        )
        let api = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: false),
            manifest: manifest,
            latestBundleListError: OtaSDKError.invalidResponse(statusCode: 500, body: "timeout")
        )
        let sdk = makeSDK(
            directory: directory,
            api: api,
            downloader: RecordingBundleDownloader()
        )
        let embedded = makeEmbeddedRelease()
        try await sdk.initializeEmbeddedRelease(embedded)

        do {
            _ = try await sdk.updateToLatestBundleList()
            Issue.record("Expected latest bundle-list failure")
        } catch let error as OtaSDKError {
            #expect(error == .invalidResponse(statusCode: 500, body: "timeout"))
        }

        #expect(await sdk.getCurrentRelease()?.context.releaseId == embedded.context.releaseId)
        #expect(await api.events().last?.reasonCode == OtaReasonCode.latestBundleListFetchFailed.rawValue)
    }

    @Test("a tampered current file misses validation cache and is not returned")
    func tamperedCurrentFileIsRejected() async throws {
        let directory = try makeSDKFaultTempDirectory()
        let bundleURL = directory.appendingPathComponent("current/main.lynx.bundle")
        try FileManager.default.createDirectory(at: bundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("good-data".utf8).write(to: bundleURL)
        let checksum = try SHA256ChecksumValidator().sha256(for: bundleURL)
        let current = OtaInstalledRelease(
            context: OtaCurrentReleaseContext(
                env: .test,
                app: .capp,
                lynxAppId: "10000001",
                releaseId: "r_ios_tamper_current",
                platform: .ios,
                status: .active
            ),
            installedAt: .now,
            bundles: [
                OtaInstalledBundle(
                    pageId: 10000001,
                    bundlePath: "main.lynx.bundle",
                    bundleSha256: checksum,
                    remoteURL: bundleURL,
                    localFilePath: bundleURL.path
                )
            ]
        )
        let manifest = OtaReleaseManifest(
            env: .test,
            app: .capp,
            lynxAppId: "10000001",
            releaseId: "r_ios_tamper_latest",
            platform: .ios,
            bundles: []
        )
        let sdk = makeSDK(
            directory: directory,
            api: FakeOtaAPIClient(response: OtaPolicyMatchResponse(matched: false), manifest: manifest),
            downloader: RecordingBundleDownloader()
        )
        try await sdk.initializeEmbeddedRelease(current)
        #expect(await sdk.currentTemplateURL(lynxAppId: "10000001", bundleName: "main.lynx.bundle") != nil)
        guard let activeBundle = await sdk.getCurrentRelease()?.bundles.first else {
            Issue.record("Expected an active bundle")
            return
        }
        let activeURL = URL(fileURLWithPath: activeBundle.localFilePath)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: activeURL.path)

        let replacementURL = activeURL.deletingLastPathComponent().appendingPathComponent("tampered.lynx.bundle")
        try Data("bad-data!".utf8).write(to: replacementURL)
        _ = try FileManager.default.replaceItemAt(activeURL, withItemAt: replacementURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: activeURL.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: activeURL.path)
        #expect(originalAttributes[.systemFileNumber] as? NSNumber != attributes[.systemFileNumber] as? NSNumber)
        #expect(try SHA256ChecksumValidator().sha256(for: activeURL) != checksum)
        #expect(await sdk.currentTemplateURL(lynxAppId: "10000001", bundleName: "main.lynx.bundle") == nil)
        #expect(await sdk.getCurrentRelease()?.context.releaseId == current.context.releaseId)
    }

    @Test("download failure keeps the embedded current release")
    func downloadFailureDoesNotPublish() async throws {
        let directory = try makeSDKFaultTempDirectory()
        let source = directory.appendingPathComponent("expected.lynx.bundle")
        try Data("good-bundle".utf8).write(to: source)
        let checksum = try SHA256ChecksumValidator().sha256(for: source)
        let manifest = makeManifest(
            releaseId: "r_ios_download_failure",
            checksum: checksum,
            size: Data("good-bundle".utf8).count,
            bundleURL: URL(string: "https://cdn.example.com/failure.lynx.bundle")!
        )
        let api = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId),
            manifest: manifest
        )
        let sdk = makeSDK(
            directory: directory,
            api: api,
            downloader: ThrowingSDKBundleDownloader(error: .network)
        )
        let embedded = makeEmbeddedRelease()
        try await sdk.initializeEmbeddedRelease(embedded)

        do {
            _ = try await sdk.updateToLatestBundleList()
            Issue.record("Expected downloader failure")
        } catch let error as SDKInjectedDownloadError {
            #expect(error == .network)
        }

        #expect(await sdk.getCurrentRelease()?.context.releaseId == embedded.context.releaseId)
        let event = await api.events().last { $0.reasonCode == OtaReasonCode.bundleDownloadFailed.rawValue }
        #expect(event?.eventResult == .failed)
    }

    @Test("same-size checksum failure keeps the embedded current release")
    func checksumFailureDoesNotPublish() async throws {
        let directory = try makeSDKFaultTempDirectory()
        let expected = directory.appendingPathComponent("expected.lynx.bundle")
        try Data("good-data".utf8).write(to: expected)
        let checksum = try SHA256ChecksumValidator().sha256(for: expected)
        let manifest = makeManifest(
            releaseId: "r_ios_checksum_failure",
            checksum: checksum,
            size: Data("good-data".utf8).count,
            bundleURL: URL(string: "https://cdn.example.com/checksum.lynx.bundle")!
        )
        let api = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId),
            manifest: manifest
        )
        let sdk = makeSDK(
            directory: directory,
            api: api,
            downloader: FixedSDKBundleDownloader(contents: "bad-data!")
        )
        let embedded = makeEmbeddedRelease()
        try await sdk.initializeEmbeddedRelease(embedded)

        do {
            _ = try await sdk.updateToLatestBundleList()
            Issue.record("Expected checksum failure")
        } catch let error as OtaSDKError {
            guard case .checksumMismatch = error else {
                Issue.record("Expected checksumMismatch, got \(error)")
                return
            }
        }

        #expect(await sdk.getCurrentRelease()?.context.releaseId == embedded.context.releaseId)
        let event = await api.events().last { $0.reasonCode == OtaReasonCode.bundleChecksumFailed.rawValue }
        #expect(event?.eventResult == .failed)
    }

    @Test("app version gate skips an incompatible latest bundle list")
    func appVersionGateSkipsBeforeDownload() async throws {
        let directory = try makeSDKFaultTempDirectory()
        let source = directory.appendingPathComponent("app-gate.lynx.bundle")
        try Data("app-gate".utf8).write(to: source)
        let manifest = makeManifest(
            releaseId: "r_ios_app_gate",
            checksum: try SHA256ChecksumValidator().sha256(for: source),
            size: Data("app-gate".utf8).count,
            bundleURL: source
        )
        let latest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: "10000001",
            releaseId: manifest.releaseId,
            platform: .ios,
            status: .active,
            minAppVersion: "2.0.0",
            changedBundles: manifest.bundles
        )
        let api = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId),
            manifest: manifest,
            latestBundleList: latest
        )
        let downloader = RecordingBundleDownloader()
        let sdk = makeSDK(directory: directory, api: api, downloader: downloader, appVersion: "1.9.9")
        try await sdk.initializeEmbeddedRelease(makeEmbeddedRelease())

        let result = try await sdk.updateToLatestBundleList()
        guard case let .skipped(_, message) = result else {
            Issue.record("Expected app version gate to skip")
            return
        }
        #expect(message.contains("App 版本"))
        #expect(await downloader.downloads().isEmpty)
        #expect(await api.events().last?.reasonCode == OtaReasonCode.baselineBlocked.rawValue)
    }

    @Test("native protocol version gate skips an incompatible latest bundle list")
    func nativeProtocolVersionGateSkipsBeforeDownload() async throws {
        let directory = try makeSDKFaultTempDirectory()
        let source = directory.appendingPathComponent("protocol-gate.lynx.bundle")
        try Data("protocol".utf8).write(to: source)
        let manifest = makeManifest(
            releaseId: "r_ios_native_protocol_gate",
            checksum: try SHA256ChecksumValidator().sha256(for: source),
            size: Data("protocol".utf8).count,
            bundleURL: source
        )
        let latest = OtaLatestBundleList(
            env: .test,
            app: .capp,
            lynxAppId: "10000001",
            releaseId: manifest.releaseId,
            platform: .ios,
            status: .active,
            nativeProtocolVersionRange: OtaReleaseVersionRange(min: "2.0.0", max: "3.0.0"),
            changedBundles: manifest.bundles
        )
        let api = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId),
            manifest: manifest,
            latestBundleList: latest
        )
        let downloader = RecordingBundleDownloader()
        let sdk = makeSDK(
            directory: directory,
            api: api,
            downloader: downloader,
            nativeProtocolVersion: "1.9.9"
        )
        try await sdk.initializeEmbeddedRelease(makeEmbeddedRelease())

        let result = try await sdk.updateToLatestBundleList()
        guard case let .skipped(_, message) = result else {
            Issue.record("Expected native protocol gate to skip")
            return
        }
        #expect(message.contains("Native 协议版本"))
        #expect(await downloader.downloads().isEmpty)
        #expect(await api.events().last?.reasonCode == OtaReasonCode.baselineBlocked.rawValue)
    }
}

private enum SDKInjectedDownloadError: Error, Equatable, Sendable {
    case network
}

private actor ThrowingSDKBundleDownloader: OtaBundleDownloading {
    let error: SDKInjectedDownloadError

    init(error: SDKInjectedDownloadError) {
        self.error = error
    }

    func download(from remoteURL: URL, to localURL: URL) async throws {
        throw error
    }
}

private actor FixedSDKBundleDownloader: OtaBundleDownloading {
    let contents: String

    init(contents: String) {
        self.contents = contents
    }

    func download(from remoteURL: URL, to localURL: URL) async throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: localURL)
    }
}

private func makeSDKFaultTempDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ota-sdk-fault-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeManifest(releaseId: String, checksum: String, size: Int, bundleURL: URL) -> OtaReleaseManifest {
    OtaReleaseManifest(
        env: .test,
        app: .capp,
        lynxAppId: "10000001",
        releaseId: releaseId,
        platform: .ios,
        bundles: [
            OtaBundleArtifact(
                pageId: 10000001,
                bundlePath: "main.lynx.bundle",
                bundleSha256: checksum,
                bundleURL: bundleURL,
                size: size
            )
        ]
    )
}

private func makeEmbeddedRelease() -> OtaInstalledRelease {
    OtaInstalledRelease(
        context: OtaCurrentReleaseContext(
            env: .test,
            app: .capp,
            lynxAppId: "10000001",
            releaseId: "embedded",
            platform: .ios,
            status: .active
        ),
        installedAt: .now,
        bundles: []
    )
}

private func makeSDK(
    directory: URL,
    api: FakeOtaAPIClient,
    downloader: any OtaBundleDownloading,
    appVersion: String = "1.0.0",
    nativeProtocolVersion: String? = nil
) -> OtaSDK {
    OtaSDK(
        configuration: OtaSDKConfiguration(
            apiBaseURL: URL(string: "https://ota.example.com")!,
            app: .capp,
            lynxAppId: "10000001",
            environment: .test,
            platform: .ios,
            appVersion: appVersion,
            buildNumber: "100",
            nativeProtocolVersion: nativeProtocolVersion,
            storageDirectory: directory.appendingPathComponent("store", isDirectory: true)
        ),
        apiClient: api,
        downloader: downloader
    )
}
