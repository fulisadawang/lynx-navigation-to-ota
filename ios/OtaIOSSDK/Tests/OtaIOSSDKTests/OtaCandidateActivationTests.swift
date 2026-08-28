import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("OtaCandidateActivation")
struct OtaCandidateActivationTests {
    @Test("candidate stays out of current until healthy confirmation")
    func candidateRequiresHealthyConfirmation() async throws {
        let directory = try makeCandidateDirectory()
        let source = directory.appendingPathComponent("candidate.lynx.bundle")
        try Data("candidate-v2".utf8).write(to: source)
        let checksum = try SHA256ChecksumValidator().sha256(for: source)
        let manifest = makeCandidateManifest(
            releaseId: "r_ios_candidate_v2",
            source: source,
            checksum: checksum
        )
        let api = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId),
            manifest: manifest
        )
        let configuration = makeCandidateConfiguration(directory: directory)
        let sdk = OtaSDK(
            configuration: configuration,
            apiClient: api,
            downloader: RecordingBundleDownloader()
        )
        let embedded = makeCandidateEmbeddedRelease()
        try await sdk.initializeEmbeddedRelease(embedded)

        let result = try await sdk.updateToLatestBundleList()
        guard case let .candidate(from, candidate, summary) = result else {
            Issue.record("Expected candidate result")
            return
        }
        #expect(summary.releaseId == manifest.releaseId)
        #expect(from?.context.releaseId == embedded.context.releaseId)
        #expect(candidate.release.context.releaseId == manifest.releaseId)
        #expect(candidate.status == .pending)
        #expect(await sdk.getCurrentRelease()?.context.releaseId == embedded.context.releaseId)
        #expect(await sdk.candidate(lynxAppId: "10000001")?.status == .pending)

        let trial = try await sdk.beginCandidateTrial(lynxAppId: "10000001")
        #expect(trial.status == .trial)

        let confirmed = try await sdk.confirmCandidateHealthy(lynxAppId: "10000001")
        #expect(confirmed.context.releaseId == manifest.releaseId)
        #expect(await sdk.getCurrentRelease()?.context.releaseId == manifest.releaseId)
        #expect(await sdk.candidate(lynxAppId: "10000001") == nil)
    }

    @Test("restart recovery discards an unfinished trial and keeps current")
    func unfinishedTrialIsDiscardedAfterRestart() async throws {
        let directory = try makeCandidateDirectory()
        let source = directory.appendingPathComponent("candidate-recovery.lynx.bundle")
        try Data("candidate-recovery".utf8).write(to: source)
        let checksum = try SHA256ChecksumValidator().sha256(for: source)
        let manifest = makeCandidateManifest(
            releaseId: "r_ios_candidate_recovery",
            source: source,
            checksum: checksum
        )
        let api = FakeOtaAPIClient(
            response: OtaPolicyMatchResponse(matched: true, releaseId: manifest.releaseId),
            manifest: manifest
        )
        let configuration = makeCandidateConfiguration(directory: directory)
        let firstSDK = OtaSDK(
            configuration: configuration,
            apiClient: api,
            downloader: RecordingBundleDownloader()
        )
        let embedded = makeCandidateEmbeddedRelease()
        try await firstSDK.initializeEmbeddedRelease(embedded)
        _ = try await firstSDK.updateToLatestBundleList()
        _ = try await firstSDK.beginCandidateTrial(lynxAppId: "10000001")
        #expect(await firstSDK.candidate(lynxAppId: "10000001")?.status == .trial)

        let restartedSDK = OtaSDK(
            configuration: configuration,
            apiClient: api,
            downloader: RecordingBundleDownloader()
        )
        try await restartedSDK.recoverInterruptedCandidate(lynxAppId: "10000001")
        #expect(await restartedSDK.candidate(lynxAppId: "10000001") == nil)
        #expect(await restartedSDK.getCurrentRelease()?.context.releaseId == embedded.context.releaseId)
    }
}

private func makeCandidateDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ota-candidate-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeCandidateConfiguration(directory: URL) -> OtaSDKConfiguration {
    OtaSDKConfiguration(
        apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
        app: .capp,
        lynxAppId: "10000001",
        environment: .test,
        platform: .ios,
        appVersion: "1.0.0",
        buildNumber: "100",
        storageDirectory: directory.appendingPathComponent("store", isDirectory: true),
        candidateActivationEnabled: true
    )
}

private func makeCandidateManifest(releaseId: String, source: URL, checksum: String) -> OtaReleaseManifest {
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
                bundleURL: source,
                size: (try? Data(contentsOf: source).count) ?? 0
            )
        ]
    )
}

private func makeCandidateEmbeddedRelease() -> OtaInstalledRelease {
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
