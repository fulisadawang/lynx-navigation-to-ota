import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("OTA user selection and Store v3 context")
struct OtaUserSelectionTests {
    @Test("native context normalization is exact and HTTP uses the three specified query names")
    func queryAndNormalization() throws {
        #expect(try OtaUserContext.normalizeUserId("  001Aa  ") == "001Aa")
        #expect(try OtaUserContext.normalizeUserId("  ") == nil)
        for code in Array(0...31) + Array(127...159) {
            let control = String(UnicodeScalar(code)!)
            for raw in [control + "A", "A" + control, control] {
                #expect(throws: OtaSelectionError.invalidUserId) { try OtaUserContext.normalizeUserId(raw) }
            }
        }
        #expect(try OtaUserContext.normalizeUserId("\u{FEFF}A\u{3000}") == "A")
        #expect(throws: OtaSelectionError.invalidUserId) { try OtaUserContext.normalizeUserId("a\nb") }
        #expect(throws: OtaSelectionError.invalidUserId) { try OtaUserContext.normalizeUserId(String(repeating: "中", count: 86)) }
        #expect(try OtaUserContext.normalizeVersionCode("0009223372036854775807") == "9223372036854775807")
        #expect(try OtaUserContext.normalizeVersionCode(" \n00025\t ") == "25")
        for code in ["0", "-1", "1.2", "1e2", "9223372036854775808", "１２"] {
            #expect(throws: OtaSelectionError.invalidVersionCode) { try OtaUserContext.normalizeVersionCode(code) }
        }
        #expect(try OtaUserContext.normalizeLynxSdkVersion("04.10") == "4.10.0")
        #expect(try OtaUserContext.normalizeLynxSdkVersion(" \n04.10\t ") == "4.10.0")
        #expect(try OtaUserContext.normalizeLynxSdkVersion("9223372036854775808.0") == "9223372036854775808.0.0")
        #expect(throws: OtaSelectionError.invalidSDKVersion) { try OtaUserContext.normalizeLynxSdkVersion("4. 0") }
        #expect(throws: OtaSelectionError.invalidSDKVersion) { try OtaUserContext.normalizeLynxSdkVersion("4.0.0-beta") }
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let context = try OtaUserContextBox(configuration: fixture.config(user: "001Aa")).capture()
        let unicodeIdentity = OtaUserContextBox(configuration: fixture.config(user: "e\u{0301}"))
        #expect(try unicodeIdentity.register("é"))
        let client = ServerOtaAPIClient(baseURL: URL(string: "https://ota.example.com")!)
        let request = try client.latestRequest(env: .test, app: .capp, lynxAppId: fixture.appId, platform: .ios, context: context)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "versioncode" }?.value == "25")
        #expect(query.first { $0.name == "lynxSdkVersion" }?.value == "4.1.0")
        #expect(query.first { $0.name == "userId" }?.value == "001Aa")
        #expect(!query.contains { $0.name == "selectionProtocol" || $0.name == "versionCode" })
    }

    @Test("wire response decodes selected and directive shapes and rejects missing metadata")
    func wireDecoding() throws {
        let fixture = try SelectionFixture(); defer { fixture.cleanup() }
        let selected = try fixture.latest("6", kind: .gray, revision: "2")
        let decoded = try JSONDecoder().decode(OtaSingleSelectionResponse.self, from: JSONEncoder().encode(selected))
        #expect(decoded.selection == .release(selected))
        var wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as! [String: Any]
        wire["platforms"] = ["android", "ios", "harmony"]
        let multiPlatform = try JSONDecoder().decode(OtaLatestBundleList.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(multiPlatform.platforms == [.android, .ios, .harmony])
        for invalidRange in [["minimum": "20"], ["min": NSNull()]] as [[String: Any]] {
            wire["versionCodeRange"] = invalidRange
            #expect(throws: OtaSelectionError.invalidSelectionMetadata) {
                try JSONDecoder().decode(OtaLatestBundleList.self, from: JSONSerialization.data(withJSONObject: wire))
            }
        }
        let directive = Data("{\"selectionSchemaVersion\":1,\"env\":\"TEST\",\"hostApp\":\"capp\",\"platform\":\"ios\",\"decision\":{\"lynxAppId\":\"10000001\",\"action\":\"use_embedded\",\"policyRevision\":\"9007199254740993\",\"reason\":\"forced\"}}".utf8)
        if case let .directive(value) = try JSONDecoder().decode(OtaSingleSelectionResponse.self, from: directive).selection {
            #expect(value.policyRevision == "9007199254740993")
        } else { Issue.record("expected directive") }
        let legacy = try fixture.latest("5", metadata: false)
        #expect(throws: OtaSelectionError.missingSelectionMetadata) {
            try JSONDecoder().decode(OtaSingleSelectionResponse.self, from: JSONEncoder().encode(legacy))
        }
    }

    @Test("gray A to B invalidates reads synchronously and falls back to full previous before reconcile")
    func identityAndPersistence() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        try await f.install("5", revision: "1", sdk: sdk)
        try await f.install("6", kind: .gray, revision: "2", sdk: sdk)
        #expect(await sdk.current()?.context.releaseId == "6")
        let saved = try String(contentsOf: f.stateURL, encoding: .utf8)
        #expect(saved.contains("selectionSchemaVersion"))
        #expect(saved.contains("lastDecision"))
        #expect(!saved.contains("\"userId\""))
        let coldA = try await f.sdk(user: "A")
        #expect(await coldA.current()?.context.releaseId == "6")
        #expect(try sdk.registerUserId(" B "))
        #expect(try !sdk.registerUserId("B"))
        #expect(sdk.userIdentityEpoch == 1)
        #expect(await sdk.state() == .idle(current: nil))
        #expect(await sdk.current()?.context.releaseId == "5")
        #expect(await sdk.currentTemplateURL(lynxAppId: f.appId, bundleName: "main.lynx.bundle") != nil)
        #expect(await sdk.candidate() == nil)
        try await sdk.reconcileUserContext()
        #expect(await sdk.current()?.context.releaseId == "5")
        let anonymous = try await f.sdk(user: nil)
        #expect(await anonymous.current()?.selection?.kind == .full)
        #expect(!FileManager.default.fileExists(atPath: f.storage.appendingPathComponent("users").path))
    }

    @Test("delayed A response after B registration cannot write state or return success")
    func delayedResponse() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        await f.api.set(.release(try f.latest("6", kind: .gray, revision: "2")))
        await f.api.pauseNext()
        let pending = Task { try await sdk.updateToLatestBundleList(lynxAppId: f.appId) }
        await f.api.waitUntilBlocked()
        #expect(try sdk.registerUserId("B"))
        try await sdk.reconcileUserContext()
        let stateAfterB = try Data(contentsOf: f.stateURL)
        await f.api.resume()
        do { _ = try await pending.value; Issue.record("stale request succeeded") }
        catch { #expect(error as? OtaSelectionError == .staleIdentity) }
        #expect(try Data(contentsOf: f.stateURL) == stateAfterB)
        #expect(await f.downloader.count == 0)
    }

    @Test("registration immediately before final State replacement aborts activation atomically")
    func finalCommitRace() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let injector = SelectionRegistrationFault()
        let sdk = try await f.sdk(user: "A", injector: injector)
        injector.arm(skip: 1) { _ = try? sdk.registerUserId("B") }
        await f.api.set(.release(try f.latest("6", kind: .gray, revision: "2")))
        do { _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId); Issue.record("stale commit succeeded") }
        catch { #expect(error as? OtaSelectionError == .staleIdentity) }
        #expect(sdk.userIdentityEpoch == 1)
        #expect(await sdk.current()?.context.releaseId == "embedded")
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String: Any]
        #expect((state["current"] as? [String: Any])?["releaseId"] as? String == "embedded")
    }

    @Test("same release gray to full refreshes State metadata with no byte download")
    func grayToFull() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        try await f.install("6", kind: .gray, revision: "2", sdk: sdk)
        let count = await f.downloader.count
        try await f.install("6", kind: .full, revision: "3", sdk: sdk)
        #expect(await f.downloader.count == count)
        #expect(await sdk.current()?.selection?.kind == .full)
        #expect(try sdk.registerUserId(nil))
        #expect(await sdk.current()?.context.releaseId == "6")
        let cold = try await f.sdk(user: nil)
        #expect(await cold.current()?.selection?.kind == .full)
    }

    @Test("directives survive cold read and higher revision allows rollback to lower sequence")
    func directivesAndRevision() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        try await f.install("5", revision: "10", sdk: sdk)
        try await f.install("10", revision: "11", sdk: sdk)
        await f.api.set(.release(try f.latest("5", revision: "12", reason: "server_rollback")))
        _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId)
        #expect(await sdk.current()?.context.releaseId == "5")
        #expect(await sdk.current()?.selection?.releaseSequence == "5")
        await f.api.set(.directive(.init(lynxAppId: f.appId, action: .useEmbedded, policyRevision: "13", reason: "forced")))
        _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId)
        #expect(await sdk.current()?.context.releaseId == "embedded")
        #expect(try await sdk.rollback(reason: "must not restore revoked previous")?.context.releaseId == "embedded")
        let cold = try await f.sdk(user: "A")
        #expect(await cold.current()?.context.releaseId == "embedded")
        await f.api.set(.release(try f.latest("10", revision: "12")))
        do { _ = try await cold.updateToLatestBundleList(lynxAppId: f.appId); Issue.record("old revision accepted") }
        catch { #expect(error as? OtaSelectionError == .staleDecision) }
    }

    @Test("new mode refuses missing selection and native/SDK incompatibility, legacy wire remains optional")
    func compatibility() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        await f.api.set(.release(try f.latest("5", metadata: false)))
        do { _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId); Issue.record("missing selection accepted") }
        catch { #expect(error as? OtaSelectionError == .missingSelectionMetadata) }
        await f.api.set(.release(try f.latest("5", minCode: "26")))
        do { _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId); Issue.record("incompatible code accepted") }
        catch { #expect(error as? OtaSelectionError == .incompatibleRelease) }
        await f.api.set(.release(try f.latest("5", sdkMin: "4.1.1", sdkMax: "4.2")))
        do { _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId); Issue.record("incompatible SDK accepted") }
        catch { #expect(error as? OtaSelectionError == .incompatibleRelease) }
        let missingSDK = OtaSDK(configuration: f.config(user: "A", sdk: nil), apiClient: f.api, downloader: f.downloader)
        do { _ = try await missingSDK.updateToLatestBundleList(lynxAppId: f.appId); Issue.record("missing runtime version accepted") }
        catch { #expect(error as? OtaSelectionError == .invalidSDKVersion) }
        #expect(await f.downloader.count == 0)
    }

    @Test("late candidate health or discard cannot alter a candidate prepared for the next identity")
    func candidateEpoch() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A", candidate: true)
        try await f.install("6", kind: .gray, revision: "1", sdk: sdk)
        let old = try await sdk.beginCandidateTrial()
        #expect(try sdk.registerUserId("B"))
        try await sdk.reconcileUserContext()
        try await f.install("7", revision: "2", sdk: sdk)
        _ = try await sdk.beginCandidateTrial()
        do { _ = try await sdk.confirmCandidateHealthy(expectedReleaseId: "6", expectedIdentityEpoch: old.identityEpoch); Issue.record("old candidate promoted") }
        catch { #expect(error as? OtaSelectionError == .staleIdentity) }
        do { try await sdk.discardCandidate(expectedReleaseId: "6", expectedIdentityEpoch: old.identityEpoch); Issue.record("old callback discarded new candidate") }
        catch { #expect(error as? OtaSelectionError == .staleIdentity) }
        #expect(await sdk.candidate()?.release.context.releaseId == "7")
        _ = try await sdk.confirmCandidateHealthy(expectedReleaseId: "7", expectedIdentityEpoch: sdk.userIdentityEpoch)
        #expect(await sdk.current()?.context.releaseId == "7")
    }

    @Test("unknown old v3 metadata is hidden until confirmation and all 100 CAS objects are reused")
    func unknownAndHundredReuse() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let legacy = try await f.sdk(user: nil, versionCode: nil)
        await f.api.set(.release(try f.latest("5", count: 100, metadata: false)))
        _ = try await legacy.updateToLatestBundleList(lynxAppId: f.appId)
        #expect(await f.downloader.count == 100)
        let current = try await f.sdk(user: "A")
        #expect(await current.current()?.context.releaseId == "embedded")
        await f.api.set(.release(try f.latest("5", count: 100, revision: "1")))
        _ = try await current.updateToLatestBundleList(lynxAppId: f.appId)
        #expect(await f.downloader.count == 100)
        #expect(await current.current()?.bundles.count == 100)
        #expect(try await current.storageSnapshot().apps.first?.objectCount == 100)
    }

    @Test("identity reconciliation retains active lease files until close")
    func leaseSurvivesIdentity() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        try await f.install("5", revision: "1", sdk: sdk)
        try await f.install("6", kind: .gray, revision: "2", sdk: sdk)
        let lease = try #require(await sdk.acquireCurrentBundleLease(lynxAppId: f.appId, bundleName: "main.lynx.bundle"))
        let bytes = try Data(contentsOf: lease.fileURL)
        _ = try sdk.registerUserId("B")
        try await sdk.reconcileUserContext()
        try await f.install("7", revision: "3", sdk: sdk)
        try await f.install("8", revision: "4", sdk: sdk)
        #expect(try Data(contentsOf: lease.fileURL) == bytes)
        await lease.close()
        try await sdk.pruneUnreferencedBundles()
        #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
    }

    @Test("download completion after switching user reports the captured identity and never commits stale state")
    func downloadIdentityReport() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        await f.api.set(.release(try f.latest("6", kind: .gray, revision: "1")))
        await f.downloader.pauseNext()
        let pending = Task { try await sdk.updateToLatestBundleList(lynxAppId: f.appId) }
        await f.downloader.waitUntilBlocked()
        _ = try sdk.registerUserId("B")
        try await sdk.reconcileUserContext()
        let stateAfterB = try Data(contentsOf: f.stateURL)
        await f.downloader.resume()
        do { _ = try await pending.value; Issue.record("stale download was activated") }
        catch { #expect(error as? OtaSelectionError == .staleIdentity) }
        #expect(try Data(contentsOf: f.stateURL) == stateAfterB)
        let reports = await f.api.reports
        #expect(!reports.isEmpty)
        #expect(reports.allSatisfy { $0.userId == "A" && $0.versioncode == "25" })
    }

    @Test("host query applies selected lists and explicit no-compatible directives together")
    func hostDirectives() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: nil)
        let latest = try f.latest("5", revision: "2")
        let group = OtaHostLatestBundleLists(env: .test, app: .capp, platform: .ios, bundleLists: [latest], selectionSchemaVersion: 1,
            directives: [.init(lynxAppId: "10000002", action: .noCompatibleRelease, policyRevision: "2", reason: "no_candidate")])
        let decoded = try JSONDecoder().decode(OtaHostLatestBundleLists.self, from: JSONEncoder().encode(group))
        #expect(decoded == group)
        await f.api.setGroup(group)
        let result = try await sdk.updateToLatestBundleLists()
        #expect(result.results.count == 2)
        #expect(await sdk.current()?.context.releaseId == "5")
        #expect(await sdk.current(lynxAppId: "10000002") == nil)
        let state = try String(contentsOf: f.storage.appendingPathComponent("apps/10000002/state.json"), encoding: .utf8)
        #expect(state.contains("no_compatible_release"))
    }

    @Test("same-user slow download cannot replace a newer policy decision or consume its staged transaction")
    func slowOlderRevision() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        await f.api.set(.release(try f.latest("6", kind: .gray, revision: "1")))
        await f.downloader.pauseNext()
        let pending = Task { try await sdk.updateToLatestBundleList(lynxAppId: f.appId) }
        await f.downloader.waitUntilBlocked()
        try await f.install("7", revision: "2", sdk: sdk)
        let afterNewer = try Data(contentsOf: f.stateURL)
        await f.downloader.resume()
        do { _ = try await pending.value; Issue.record("old download superseded newer decision") }
        catch { #expect(error as? OtaSelectionError == .staleDecision) }
        #expect(try Data(contentsOf: f.stateURL) == afterNewer)
        #expect(await sdk.current()?.context.releaseId == "7")
    }

    @Test("native and SDK ranges include both boundaries and compare numeric components exactly")
    func rangeBoundaries() {
        let range = OtaVersionCodeRange(min: "20", max: "29")
        #expect(!OtaSelectionValidation.matchesCode("19", range: range))
        #expect(OtaSelectionValidation.matchesCode("20", range: range))
        #expect(OtaSelectionValidation.matchesCode("29", range: range))
        #expect(!OtaSelectionValidation.matchesCode("30", range: range))
        #expect(!OtaSelectionValidation.matchesCode(nil, range: range))
        let largeRange = OtaVersionCodeRange(min: "9007199254740993")
        #expect(OtaSelectionValidation.matchesCode("9223372036854775807", range: largeRange))
        #expect(!OtaSelectionValidation.matchesCode("9007199254740992", range: largeRange))
        let sdkRange = OtaReleaseVersionRange(min: "4.9", max: "4.10")
        #expect(OtaSelectionValidation.matchesVersion("4.9", range: sdkRange, strict: true))
        #expect(OtaSelectionValidation.matchesVersion("4.10", range: sdkRange, strict: true))
        #expect(!OtaSelectionValidation.matchesVersion("4.8", range: sdkRange, strict: true))
        #expect(!OtaSelectionValidation.matchesVersion(nil, range: sdkRange, strict: true))
        let malformed = OtaReleaseVersionRange(min: "4.0-beta")
        #expect(!OtaSelectionValidation.matchesVersion("4.10", range: malformed, strict: true))
    }

    @Test("new selection mode still downloads only one changed object out of one hundred")
    func oneOfHundred() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        await f.api.set(.release(try f.latest("5", count: 100, revision: "1")))
        _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId)
        await f.api.set(.release(try f.latest("6", count: 100, kind: .gray, revision: "2", reuseVersion: "5")))
        let result = try await sdk.updateToLatestBundleList(lynxAppId: f.appId)
        if case let .updated(_, _, summary) = result {
            #expect(summary.downloadedBundleCount == 1)
            #expect(summary.reusedBundleCount == 99)
        } else { Issue.record("expected updated snapshot") }
        #expect(await f.downloader.count == 101)
        let snapshot = try await sdk.storageSnapshot()
        #expect(snapshot.apps.first?.objectCount == 101)
        #expect(snapshot.apps.first?.lastOperation?.byteCopyCount == 0)
    }

    @Test("cold native upgrades recheck stored compatibility and do not revive an embedded directive")
    func coldVersionChanges() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        try await f.install("5", revision: "1", sdk: sdk)
        let upgraded = try await f.sdk(user: "A", versionCode: "30")
        #expect(await upgraded.current()?.context.releaseId == "embedded")
        await f.api.set(.directive(.init(lynxAppId: f.appId, action: .useEmbedded, policyRevision: "2", reason: "forced")))
        _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId)
        let changedCompatibleVersion = try await f.sdk(user: "A", versionCode: "26")
        #expect(await changedCompatibleVersion.current()?.context.releaseId == "embedded")
    }

    @Test("host identity wrapper refuses old A probe continuations even when B keeps the same full release")
    func callbackIdentityWrapper() async throws {
        for mutation in SelectionCallbackMutation.allCases {
            let f = try SelectionFixture(); defer { f.cleanup() }
            let sdk = try await f.sdk(user: "A")
            try await f.install("5", revision: "1", sdk: sdk)
            try await f.install("6", revision: "2", sdk: sdk)
            let full = try #require(await sdk.current())
            let epochA = sdk.userIdentityEpoch
            let gate = SelectionProbeGate()
            let pending = Task {
                try await sdk.withUserIdentity(expectedIdentityEpoch: epochA) {
                    _ = await sdk.candidate() // The original host callback's asynchronous candidate probe.
                    await gate.stop()
                    try await mutation.perform(sdk, appId: f.appId, release: full)
                    return full.context.releaseId
                }
            }
            await gate.waitUntilStopped()
            _ = try sdk.registerUserId("B")
            try await sdk.reconcileUserContext()
            #expect(await sdk.current()?.context.releaseId == "6")
            let stateB = try Data(contentsOf: f.stateURL)
            await gate.resume()
            do { _ = try await pending.value; Issue.record("old callback succeeded: \(mutation)") }
            catch { #expect(error as? OtaSelectionError == .staleIdentity) }
            #expect(try Data(contentsOf: f.stateURL) == stateB)
            #expect(await sdk.current()?.context.releaseId == "6")
        }
    }

    @Test("host identity wrapper validates entry epoch and preserves generic return values")
    func wrapperEntryAndResult() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        let epochA = sdk.userIdentityEpoch
        let value: Int = try await sdk.withUserIdentity(expectedIdentityEpoch: epochA) { 42 }
        #expect(value == 42)
        _ = try sdk.registerUserId("B")
        do {
            _ = try await sdk.withUserIdentity(expectedIdentityEpoch: epochA) {
                throw OtaSelectionError.invalidSelectionMetadata // Must never enter this closure.
            } as Int
            Issue.record("stale expected epoch accepted")
        } catch { #expect(error as? OtaSelectionError == .staleIdentity) }
    }

    @Test("wrapper reaches the final Store guard for rollback and deletion even with no embedded registration")
    func wrapperFinalStoreGuard() async throws {
        for delete in [false, true] {
            let f = try SelectionFixture(); defer { f.cleanup() }
            let injector = SelectionRegistrationFault()
            // No embedded registration: deletion must not bypass State commit by removing the whole directory.
            let sdk = OtaSDK(configuration: f.config(user: "A"), apiClient: f.api, downloader: f.downloader, transactionFaultInjector: injector)
            try await f.install("5", revision: "1", sdk: sdk)
            try await f.install("6", revision: "2", sdk: sdk)
            let before = try Data(contentsOf: f.stateURL)
            let epochA = sdk.userIdentityEpoch
            injector.arm(skip: 0) { _ = try? sdk.registerUserId("B") }
            do {
                try await sdk.withUserIdentity(expectedIdentityEpoch: epochA) {
                    if delete { try await sdk.deleteDownloadedBundles(lynxAppId: f.appId) }
                    else { _ = try await sdk.rollback(lynxAppId: f.appId, reason: "old-callback") }
                }
                Issue.record("final State guard accepted stale callback")
            } catch { #expect(error as? OtaSelectionError == .staleIdentity) }
            #expect(try Data(contentsOf: f.stateURL) == before)
            #expect(await sdk.current()?.context.releaseId == "6")
        }
    }

    @Test("wrapper closes rejected lease results synchronously, including Optional results retained elsewhere")
    func wrapperReleasesStaleLease() async throws {
        for optional in [false, true] {
            let f = try SelectionFixture(); defer { f.cleanup() }
            let sdk = try await f.sdk(user: "A")
            try await f.install("5", revision: "1", sdk: sdk)
            let capture = SelectionLeaseCapture()
            let epochA = sdk.userIdentityEpoch
            let acquire: @Sendable () async throws -> OtaBundleLease = {
                guard let lease = try await sdk.acquireCurrentBundleLease(lynxAppId: f.appId, bundleName: "main.lynx.bundle") else {
                    throw OtaSDKError.missingCurrentRelease
                }
                // Retain outside the returned result, so deinit cleanup cannot mask a wrapper leak.
                await capture.store(lease)
                _ = try sdk.registerUserId("B")
                return lease
            }
            do {
                if optional {
                    let _: OtaBundleLease? = try await sdk.withUserIdentity(expectedIdentityEpoch: epochA) { Optional(try await acquire()) }
                } else {
                    let _: OtaBundleLease = try await sdk.withUserIdentity(expectedIdentityEpoch: epochA, operation: acquire)
                }
                Issue.record("wrapper returned a stale lease")
            } catch { #expect(error as? OtaSelectionError == .staleIdentity) }
            let lease = try #require(await capture.lease)
            let snapshot = try await sdk.storageSnapshot()
            #expect(snapshot.apps.first?.releases.contains { $0.releaseId == "5" && $0.roles.contains(.leased) } == false)
            try await f.install("6", revision: "2", sdk: sdk)
            try await f.install("7", revision: "3", sdk: sdk)
            #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
            await lease.close() // Remains safe and idempotent after wrapper cleanup.
        }
    }

    @Test("current lease reads finish while a background latest download remains suspended")
    func leaseReadDuringDownload() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        try await f.install("5", revision: "1", sdk: sdk)
        await f.api.set(.release(try f.latest("6", revision: "2")))
        await f.downloader.pauseNext()
        let pending = Task { try await sdk.updateToLatestBundleList(lynxAppId: f.appId) }
        await f.downloader.waitUntilBlocked()
        // A failing implementation must report a failure rather than hang the whole test suite.
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 2_000_000_000); await f.downloader.resume() }
            catch { /* The read completed before the deadline. */ }
        }
        let lease = try #require(try await sdk.withUserIdentity(expectedIdentityEpoch: sdk.userIdentityEpoch) {
            try await sdk.acquireCurrentBundleLease(lynxAppId: f.appId, bundleName: "main.lynx.bundle")
        })
        #expect(await f.downloader.isBlocked)
        #expect(lease.release.context.releaseId == "5")
        timeout.cancel()
        await f.downloader.resume()
        _ = try await pending.value
        await lease.close()
    }

    @Test("batch commits every valid decision before downloads and continues other Apps after a download failure")
    func batchDecisionIsolation() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        await f.api.set(.release(try f.latest("5", revision: "1", appId: "10000002")))
        _ = try await sdk.updateToLatestBundleList(lynxAppId: "10000002")
        #expect(await sdk.current(lynxAppId: "10000002")?.context.releaseId == "5")
        let baselineDownloads = await f.downloader.count
        let broken = try f.latest("6", revision: "2")
        let otherBroken = try f.latest("8", revision: "2", appId: "10000003")
        let success = try f.latest("7", revision: "2", appId: "10000004")
        let directive = OtaSelectionDirective(lynxAppId: "10000002", action: .useEmbedded, policyRevision: "2", reason: "forced")
        await f.api.setGroup(.init(env: .test, app: .capp, platform: .ios, bundleLists: [broken, otherBroken, success], selectionSchemaVersion: 1, directives: [directive]))
        // The first download remains paused while we inspect the decisions for all four Apps.
        await f.downloader.pauseNext()
        await f.downloader.fail([broken.changedBundles[0].bundleURL, otherBroken.changedBundles[0].bundleURL])
        let pending = Task { try await sdk.updateToLatestBundleLists() }
        await f.downloader.waitUntilBlocked()
        let allDecisions = [f.appId, "10000002", "10000003", "10000004"].allSatisfy {
            guard let data = try? Data(contentsOf: f.storage.appendingPathComponent("apps/\($0)/state.json")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (state["lastDecision"] as? [String: Any])?["policyRevision"] as? String == "2"
        }
        await f.downloader.resume()
        var failed = false
        do { _ = try await pending.value }
        catch {
            failed = true
            let batch = try #require(error as? OtaHostBundleListSyncError)
            #expect(Set(batch.failures.keys) == Set([f.appId, "10000003"]))
            #expect(batch.failures.values.allSatisfy { $0.stage == .update })
            #expect(batch.failures.values.allSatisfy { $0.cause as? OtaSDKError == .invalidResponse(statusCode: 503, body: "fixture download failure") })
            #expect(Set(batch.partialResult.results.keys) == Set(["10000002", "10000004"]))
        }
        #expect(allDecisions)
        #expect(failed) // Partial completion must not be returned as an all-success result.
        #expect(await f.downloader.count == baselineDownloads + 3)
        #expect(await sdk.current(lynxAppId: "10000004")?.context.releaseId == "7")
        let directiveState = try? Data(contentsOf: f.storage.appendingPathComponent("apps/10000002/state.json"))
        #expect(directiveState != nil)
        if let directiveState { #expect(String(decoding: directiveState, as: UTF8.self).contains("use_embedded")) }
        #expect(await sdk.current(lynxAppId: "10000002") == nil)
        let cold = try await f.sdk(user: "A")
        #expect(await cold.current(lynxAppId: "10000002") == nil)
    }

    @Test("C05 installed A gray switches to offline B with embedded fallback or nil when no embedded exists")
    func installedGrayOfflineFallback() async throws {
        for hasEmbedded in [false, true] {
            let f = try SelectionFixture(); defer { f.cleanup() }
            let sdk: OtaSDK
            if hasEmbedded { sdk = try await f.sdk(user: "A") }
            else { sdk = OtaSDK(configuration: f.config(user: "A"), apiClient: f.api, downloader: f.downloader) }
            try await f.install("6", kind: .gray, revision: "1", sdk: sdk)
            #expect(await sdk.current()?.context.releaseId == "6")
            await f.api.failQuery(.invalidResponse(statusCode: -1, body: "offline fixture"))
            _ = try sdk.registerUserId("B")
            try await sdk.reconcileUserContext()
            let fallback = await sdk.current()
            #expect(fallback?.context.releaseId == (hasEmbedded ? "embedded" : nil))
            #expect(try await sdk.acquireCurrentBundleLease(lynxAppId: f.appId, bundleName: "main.lynx.bundle") == nil)
            #expect(await f.downloader.count == 1)
        }
    }

    @Test("C10 B rollback refuses previous that is precisely A's gray release")
    func rollbackPreviousOtherAudience() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        try await f.install("5", kind: .gray, revision: "1", sdk: sdk)
        _ = try sdk.registerUserId("B")
        // Install B's full before reconciliation so disk previous is exactly A gray.
        try await f.install("6", revision: "2", sdk: sdk)
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String: Any]
        #expect((disk["previous"] as? [String: Any])?["releaseId"] as? String == "5")
        let restored = try await sdk.rollback(reason: "B-local-recovery")
        #expect(restored?.context.releaseId == "embedded")
        #expect(await sdk.current()?.context.releaseId == "embedded")
        #expect(try await sdk.acquireCurrentBundleLease(lynxAppId: f.appId, bundleName: "main.lynx.bundle") == nil)
    }

    @Test("C11 anonymous cold start cannot read disk current that is directly A gray")
    func anonymousColdGrayCurrent() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdkA = try await f.sdk(user: "A")
        try await f.install("6", kind: .gray, revision: "1", sdk: sdkA)
        let gray = try #require(await sdkA.current())
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String: Any]
        #expect((disk["current"] as? [String: Any])?["releaseId"] as? String == "6")
        let anonymous = try await f.sdk(user: nil)
        #expect(await anonymous.current()?.context.releaseId == "embedded")
        let url = await anonymous.currentTemplateURL(lynxAppId: f.appId, bundleName: "main.lynx.bundle")
        #expect(url?.path != gray.bundles.first?.localFilePath)
        #expect(try await anonymous.acquireCurrentBundleLease(lynxAppId: f.appId, bundleName: "main.lynx.bundle") == nil)
        #expect(await f.downloader.count == 1)
    }

    @Test("batch validates every selection protocol before committing any directive or starting bytes")
    func batchProtocolPreflight() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "A")
        let valid = try f.latest("5", revision: "2")
        let malformed = try f.latest("6", metadata: false, appId: "10000003")
        await f.api.setGroup(.init(env: .test, app: .capp, platform: .ios, bundleLists: [valid, malformed], selectionSchemaVersion: 1,
            directives: [.init(lynxAppId: "10000002", action: .useEmbedded, policyRevision: "2", reason: "forced")]))
        let before = try Data(contentsOf: f.stateURL)
        do { _ = try await sdk.updateToLatestBundleLists(); Issue.record("malformed batch accepted") }
        catch { #expect(error as? OtaSelectionError == .missingSelectionMetadata) }
        #expect(try Data(contentsOf: f.stateURL) == before)
        #expect(await f.downloader.count == 0)
        #expect(!FileManager.default.fileExists(atPath: f.storage.appendingPathComponent("apps/10000002/state.json").path))
    }

    @Test("new-mode failed queries report captured identity without raw identity in diagnostics")
    func selectionFailureReportPrivacy() async throws {
        for batch in [false, true] {
            let f = try SelectionFixture(); defer { f.cleanup() }
            let privateIdentity = "test-private-user-A"
            let sdk = try await f.sdk(user: privateIdentity)
            await f.api.set(.release(try f.latest("5")))
            await f.api.failQuery(.invalidResponse(statusCode: 503, body: "upstream userId=\(privateIdentity)"))
            await f.api.pauseNext()
            let pending = Task {
                if batch { _ = try await sdk.updateToLatestBundleLists() }
                else { _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId) }
            }
            await f.api.waitUntilBlocked()
            _ = try sdk.registerUserId("test-user-B")
            await f.api.resume()
            do { try await pending.value; Issue.record("failed request returned success") } catch {}
            let reports = await f.api.reports.filter { $0.event == .checkResult && $0.eventResult == .failed }
            #expect(reports.count == 1)
            if let report = reports.first {
                #expect(report.userId == privateIdentity) // The dedicated protocol field retains the operation identity.
                #expect(report.versioncode == "25")
                #expect(report.reasonCode == OtaReasonCode.latestBundleListFetchFailed.rawValue)
                let reasonMessage = report.reasonMessage ?? ""
                let message = report.message ?? ""
                #expect(!reasonMessage.contains(privateIdentity))
                #expect(!message.contains(privateIdentity))
                #expect(report.releaseId == nil)
            }
        }
    }

    @Test("candidate staging reports a successful check and protocol failures report decode failure")
    func candidateAndProtocolCheckReports() async throws {
        let f = try SelectionFixture(); defer { f.cleanup() }
        let sdk = try await f.sdk(user: "test-private-user-A", candidate: true)
        try await f.install("6", kind: .gray, revision: "1", sdk: sdk)
        let success = await f.api.reports.filter { $0.event == .checkResult && $0.eventResult == .success }
        #expect(success.count == 1)
        #expect(success.first?.releaseId == "6")
        #expect(success.first?.userId == "test-private-user-A")
        let candidateMessage = success.first?.message ?? ""
        #expect(!candidateMessage.contains("test-private-user-A"))
        await f.api.set(.release(try f.latest("7", metadata: false)))
        do { _ = try await sdk.updateToLatestBundleList(lynxAppId: f.appId); Issue.record("missing metadata accepted") } catch {}
        let failures = await f.api.reports.filter { $0.event == .checkResult && $0.eventResult == .failed }
        #expect(failures.count == 1)
        #expect(failures.first?.reasonCode == OtaReasonCode.latestBundleListDecodeFailed.rawValue)
        #expect(await sdk.candidate()?.release.context.releaseId == "6")
    }
}

private actor SelectionLeaseCapture {
    var lease: OtaBundleLease?
    func store(_ value: OtaBundleLease) { lease = value }
}

private enum SelectionCallbackMutation: CaseIterable, Sendable {
    case rollback, deleteOne, deleteAll, reconcile, latestSingle, latestHost, clear, prune, initialize
    case activate, beginTrial, discard, recover, download, check, updateIfNeeded, ensure, nestedRebind, resultOnly

    func perform(_ sdk: OtaSDK, appId: String, release: OtaInstalledRelease) async throws {
        switch self {
        case .rollback: _ = try await sdk.rollback(lynxAppId: appId, reason: "old-callback")
        case .deleteOne: try await sdk.deleteDownloadedBundles(lynxAppId: appId)
        case .deleteAll: try await sdk.deleteAllDownloadedBundles()
        case .reconcile: try await sdk.reconcileUserContext()
        case .latestSingle: _ = try await sdk.updateToLatestBundleList(lynxAppId: appId)
        case .latestHost: _ = try await sdk.updateToLatestBundleLists()
        case .clear: try await sdk.clearUpdates()
        case .prune: try await sdk.pruneUnreferencedBundles()
        case .initialize: try await sdk.initializeEmbeddedRelease(release)
        case .activate: _ = try await sdk.activateStagedRelease()
        case .beginTrial: _ = try await sdk.beginCandidateTrial(lynxAppId: appId)
        case .discard: try await sdk.discardCandidate(lynxAppId: appId)
        case .recover: try await sdk.recoverInterruptedCandidate(lynxAppId: appId)
        case .download: _ = try await sdk.downloadUpdate(.init(matched: true, releaseId: release.context.releaseId))
        case .check: _ = try await sdk.checkForUpdate(.init(pageId: 1))
        case .updateIfNeeded: _ = try await sdk.updateIfNeeded(.init(pageId: 1))
        case .ensure: _ = try await sdk.ensureBundleReady(lynxAppId: appId, bundleName: "main.lynx.bundle")
        case .nestedRebind:
            try await sdk.withUserIdentity(expectedIdentityEpoch: sdk.userIdentityEpoch) { try await sdk.deleteDownloadedBundles(lynxAppId: appId) }
        case .resultOnly: break // The outer wrapper must reject a stale value even with no final SDK call.
        }
    }
}

private actor SelectionProbeGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func stop() async { await withCheckedContinuation { pending = $0; waiters.forEach { $0.resume() }; waiters.removeAll() } }
    func waitUntilStopped() async { if pending != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func resume() { pending?.resume(); pending = nil }
}

private actor SelectionAPI: OtaAPIClientProtocol {
    var result: OtaLatestSelection?
    var group: OtaHostLatestBundleLists?
    var reports: [OtaReportPayload] = []
    private var pause = false
    private var queryFailure: OtaSDKError?
    private var pending: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func set(_ value: OtaLatestSelection) { result = value }
    func setGroup(_ value: OtaHostLatestBundleLists) { group = value }
    func failQuery(_ value: OtaSDKError) { queryFailure = value }
    func pauseNext() { pause = true }
    func waitUntilBlocked() async { if pending != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func resume() { pending?.resume(); pending = nil }
    func checkForUpdate(_ request: OtaPolicyMatchRequest) async throws -> OtaPolicyMatchResponse { .init(matched: false) }
    func fetchManifest(releaseId: String, env: OtaEnvironment, app: OtaAppID, lynxAppId: String, platform: OtaPlatform) async throws -> OtaReleaseManifest {
        try await fetchLatestBundleList(env: env, app: app, lynxAppId: lynxAppId, platform: platform).asManifest()
    }
    func fetchLatestBundleList(env: OtaEnvironment, app: OtaAppID, lynxAppId: String, platform: OtaPlatform) async throws -> OtaLatestBundleList {
        guard case let .release(latest) = result else { throw OtaSelectionError.missingSelectionMetadata }; return latest
    }
    func fetchLatestBundleLists(env: OtaEnvironment, app: OtaAppID, platform: OtaPlatform) async throws -> OtaHostLatestBundleLists {
        let error = queryFailure
        if pause {
            pause = false
            await withCheckedContinuation { pending = $0; waiters.forEach { $0.resume() }; waiters.removeAll() }
        }
        if let error { throw error }
        if let group { return group }
        switch result {
        case let .release(latest): return .init(env: env, app: app, platform: platform, bundleLists: [latest], selectionSchemaVersion: 1)
        case let .directive(directive): return .init(env: env, app: app, platform: platform, bundleLists: [], selectionSchemaVersion: 1, directives: [directive])
        case nil: throw OtaSelectionError.missingSelectionMetadata
        }
    }
    func fetchLatestBundleList(env: OtaEnvironment, app: OtaAppID, lynxAppId: String, platform: OtaPlatform, context: OtaUserContext) async throws -> OtaLatestSelection {
        guard let result else { throw OtaSelectionError.missingSelectionMetadata }
        let error = queryFailure
        if pause {
            pause = false
            await withCheckedContinuation { pending = $0; waiters.forEach { $0.resume() }; waiters.removeAll() }
        }
        if let error { throw error }
        return result
    }
    func reportEvent(_ payload: OtaReportPayload) async throws -> OtaReportResponse {
        reports.append(payload); return .init(accepted: true, releaseId: payload.releaseId, event: payload.event)
    }
}

private actor SelectionDownloader: OtaBundleDownloading {
    var count = 0
    var isBlocked: Bool { pending != nil }
    private var pause = false
    private var failures = Set<URL>()
    func fail(_ urls: [URL]) { failures = Set(urls) }
    private var pending: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pauseNext() { pause = true }
    func waitUntilBlocked() async { if pending != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func resume() { pending?.resume(); pending = nil }
    func download(from remoteURL: URL, to localURL: URL) async throws {
        count += 1
        if pause { pause = false; await withCheckedContinuation { pending = $0; waiters.forEach { $0.resume() }; waiters.removeAll() } }
        if failures.contains(remoteURL) { throw OtaSDKError.invalidResponse(statusCode: 503, body: "fixture download failure") }
        try FileManager.default.copyItem(at: remoteURL, to: localURL)
    }
}

private final class SelectionFixture: @unchecked Sendable {
    let appId = "10000001"
    let root: URL
    let storage: URL
    let api = SelectionAPI()
    let downloader = SelectionDownloader()
    var stateURL: URL { storage.appendingPathComponent("apps/\(appId)/state.json") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ota-selection-\(UUID().uuidString)")
        storage = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func config(user: String?, versionCode: String? = "25", sdk: String? = "4.1.0", candidate: Bool = false) -> OtaSDKConfiguration {
        .init(apiBaseURL: URL(string: "http://127.0.0.1:1")!, app: .capp, lynxAppId: appId, environment: .test,
              appVersion: "1.0.0", buildNumber: "legacy-build", versionCode: versionCode, userId: user, lynxSdkVersion: sdk,
              storageDirectory: storage, candidateActivationEnabled: candidate, storeVersion: .v3, allowLocalHTTPForTest: true)
    }
    func sdk(user: String?, versionCode: String? = "25", candidate: Bool = false, injector: SelectionRegistrationFault? = nil) async throws -> OtaSDK {
        let sdk: OtaSDK
        if let injector { sdk = OtaSDK(configuration: config(user: user, versionCode: versionCode, candidate: candidate), apiClient: api, downloader: downloader, transactionFaultInjector: injector) }
        else { sdk = OtaSDK(configuration: config(user: user, versionCode: versionCode, candidate: candidate), apiClient: api, downloader: downloader) }
        let source = root.appendingPathComponent("embedded.lynx.bundle")
        try Data("embedded-fixture".utf8).write(to: source)
        let bundle = OtaInstalledBundle(pageId: 1, bundlePath: "main.lynx.bundle", bundleSha256: try SHA256ChecksumValidator().sha256(for: source), remoteURL: source, localFilePath: source.path)
        try await sdk.initializeEmbeddedRelease(.init(context: .init(env: .test, app: .capp, lynxAppId: appId, releaseId: "embedded", platform: .ios, status: .active), installedAt: Date(), bundles: [bundle]))
        return sdk
    }
    func latest(_ version: String, count: Int = 1, kind: OtaSelectionKind = .full, revision: String = "1", metadata: Bool = true, minCode: String = "20", sdkMin: String = "4.0", sdkMax: String = "4.1", reason: String? = nil, reuseVersion: String? = nil, appId: String? = nil) throws -> OtaLatestBundleList {
        let bundles = try (0..<count).map { index -> OtaBundleArtifact in
            let bytesVersion = index == 50 ? version : (reuseVersion ?? version)
            let data = Data("version=\(bytesVersion);bundle=\(index)".utf8)
            let url = root.appendingPathComponent("v\(version)-\(index).lynx.bundle")
            try data.write(to: url)
            return .init(pageId: index + 1, bundlePath: count == 1 ? "main.lynx.bundle" : "bundle-\(index).lynx.bundle", bundleSha256: try SHA256ChecksumValidator().sha256(for: url), bundleURL: url, size: data.count)
        }
        return .init(env: .test, app: .capp, lynxAppId: appId ?? self.appId, releaseId: version, platform: .ios, status: .active,
                     lynxSdkRange: .init(min: sdkMin, max: sdkMax), selectionSchemaVersion: metadata ? 1 : nil, releaseSequence: metadata ? version : nil,
                     selection: metadata ? .init(kind: kind, ruleId: kind == .gray ? "test-rule" : nil, policyRevision: revision, reason: reason ?? (kind == .gray ? "matched_gray" : "latest_full")) : nil,
                     versionCodeRange: .init(min: minCode, max: "29"), changedBundles: bundles)
    }
    func install(_ version: String, kind: OtaSelectionKind = .full, revision: String, sdk: OtaSDK) async throws {
        await api.set(.release(try latest(version, kind: kind, revision: revision)))
        _ = try await sdk.updateToLatestBundleList(lynxAppId: appId)
    }
}

private final class SelectionRegistrationFault: OtaTransactionFaultInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var skip = 0
    private var action: (@Sendable () -> Void)?
    func arm(skip: Int, action: @escaping @Sendable () -> Void) { lock.lock(); self.skip = skip; self.action = action; lock.unlock() }
    func check(_ point: OtaTransactionFaultPoint) throws {
        guard point == .beforeStateCommit else { return }
        lock.lock()
        let callback: (@Sendable () -> Void)?
        if skip > 0 { skip -= 1; callback = nil }
        else { callback = action; action = nil }
        lock.unlock()
        callback?()
    }
}
