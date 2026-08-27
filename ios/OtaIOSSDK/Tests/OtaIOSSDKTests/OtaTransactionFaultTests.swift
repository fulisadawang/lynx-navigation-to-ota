import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("OtaTransactionFaults")
struct OtaTransactionFaultTests {
    @Test("a failure before state commit keeps old current and can retry after restart")
    func failureBeforeStateCommitIsRecoverable() async throws {
        let directory = try makeTemporaryDirectory()
        let store = FileOtaReleaseStore(baseDirectory: directory)
        let embedded = makeRelease(id: "embedded", directory: directory, contents: "embedded")
        let downloaded = makeRelease(id: "r_ios_before_commit", directory: directory, contents: "downloaded")
        let scope = OtaReleaseScope(app: .capp, lynxAppId: "10000001")
        try await ReleaseTransaction(store: store).registerEmbedded(embedded)

        let injector = ThrowingOtaTransactionFaultInjector(point: .beforeStateCommit)
        let interrupted = ReleaseTransaction(store: store, faultInjector: injector)
        try await interrupted.stage(downloaded)

        do {
            _ = try await interrupted.activate(scope: scope)
            Issue.record("Expected a fault before state commit")
        } catch let error as OtaInjectedFault {
            #expect(error.point == .beforeStateCommit)
        }

        let restarted = ReleaseTransaction(store: store)
        #expect(await restarted.current(scope: scope)?.context.releaseId == embedded.context.releaseId)
        #expect(await restarted.staged(scope: scope)?.context.releaseId == downloaded.context.releaseId)
        _ = try await restarted.activate(scope: scope)
        #expect(await restarted.current(scope: scope)?.context.releaseId == downloaded.context.releaseId)

        let rollback = try await restarted.rollback(scope: scope)
        guard case let .restored(restored) = rollback else {
            Issue.record("Expected retry flow to restore embedded")
            return
        }
        #expect(restored.context.releaseId == embedded.context.releaseId)
    }

    @Test("a failure after state commit is repaired by idempotent activation")
    func failureAfterStateCommitIsRecoverable() async throws {
        let directory = try makeTemporaryDirectory()
        let store = FileOtaReleaseStore(baseDirectory: directory)
        let embedded = makeRelease(id: "embedded", directory: directory, contents: "embedded")
        let downloaded = makeRelease(id: "r_ios_after_commit", directory: directory, contents: "downloaded")
        let scope = OtaReleaseScope(app: .capp, lynxAppId: "10000001")
        try await ReleaseTransaction(store: store).registerEmbedded(embedded)

        let injector = ThrowingOtaTransactionFaultInjector(point: .afterStateCommit)
        let interrupted = ReleaseTransaction(store: store, faultInjector: injector)
        try await interrupted.stage(downloaded)
        do {
            _ = try await interrupted.activate(scope: scope)
            Issue.record("Expected a fault after state commit")
        } catch let error as OtaInjectedFault {
            #expect(error.point == .afterStateCommit)
        }

        let restarted = ReleaseTransaction(store: store)
        #expect(await restarted.current(scope: scope)?.context.releaseId == downloaded.context.releaseId)
        _ = try await restarted.activate(scope: scope)
        let rollback = try await restarted.rollback(scope: scope)
        guard case let .restored(restored) = rollback else {
            Issue.record("Expected replay recovery to keep embedded previous")
            return
        }
        #expect(restored.context.releaseId == embedded.context.releaseId)
    }

    @Test("a failure before rollback commit leaves current untouched")
    func failureBeforeRollbackCommitIsRecoverable() async throws {
        let (store, embedded, downloaded, scope) = try await installedDownloadedRelease(id: "r_ios_before_rollback")
        let interrupted = ReleaseTransaction(
            store: store,
            faultInjector: ThrowingOtaTransactionFaultInjector(point: .beforeRollbackCommit)
        )

        do {
            _ = try await interrupted.rollback(scope: scope)
            Issue.record("Expected a fault before rollback commit")
        } catch let error as OtaInjectedFault {
            #expect(error.point == .beforeRollbackCommit)
        }

        let restarted = ReleaseTransaction(store: store)
        #expect(await restarted.current(scope: scope)?.context.releaseId == downloaded.context.releaseId)
        let rollback = try await restarted.rollback(scope: scope)
        guard case let .restored(restored) = rollback else {
            Issue.record("Expected retry rollback to restore embedded")
            return
        }
        #expect(restored.context.releaseId == embedded.context.releaseId)
    }

    @Test("a failure after rollback commit leaves the restored pointer durable")
    func failureAfterRollbackCommitIsDurable() async throws {
        let (store, embedded, _, scope) = try await installedDownloadedRelease(id: "r_ios_after_rollback")
        let interrupted = ReleaseTransaction(
            store: store,
            faultInjector: ThrowingOtaTransactionFaultInjector(point: .afterRollbackCommit)
        )

        do {
            _ = try await interrupted.rollback(scope: scope)
            Issue.record("Expected a fault after rollback commit")
        } catch let error as OtaInjectedFault {
            #expect(error.point == .afterRollbackCommit)
        }

        let restarted = ReleaseTransaction(store: store)
        #expect(await restarted.current(scope: scope)?.context.releaseId == embedded.context.releaseId)
        let rollback = try await restarted.rollback(scope: scope)
        guard case let .restored(restored) = rollback else {
            Issue.record("Expected idempotent rollback result")
            return
        }
        #expect(restored.context.releaseId == embedded.context.releaseId)
    }

    @Test("replaying an activation after the state commit keeps previous stable")
    func replayedActivationIsIdempotent() async throws {
        let directory = try makeTemporaryDirectory()
        let store = FileOtaReleaseStore(baseDirectory: directory)
        let transaction = ReleaseTransaction(store: store)
        let embedded = makeRelease(id: "embedded", directory: directory, contents: "embedded")
        let downloaded = makeRelease(id: "r_ios_replay", directory: directory, contents: "downloaded")
        let scope = OtaReleaseScope(app: .capp, lynxAppId: "10000001")

        try await transaction.registerEmbedded(embedded)
        try await transaction.stage(downloaded)
        _ = try await transaction.activate(scope: scope)

        // 模拟“写入 current 后进程在删除 staged 指针前退出”：下一次启动仍看见同一 staged。
        try await transaction.stage(downloaded)
        _ = try await transaction.activate(scope: scope)

        let rollback = try await transaction.rollback(scope: scope)
        guard case let .restored(restored) = rollback else {
            Issue.record("Expected replayed activation to preserve embedded previous")
            return
        }
        #expect(restored.context.releaseId == embedded.context.releaseId)
    }
}

private struct OtaInjectedFault: Error, Equatable {
    let point: OtaTransactionFaultPoint
}

private final class ThrowingOtaTransactionFaultInjector: OtaTransactionFaultInjecting, @unchecked Sendable {
    let point: OtaTransactionFaultPoint

    init(point: OtaTransactionFaultPoint) {
        self.point = point
    }

    func check(_ point: OtaTransactionFaultPoint) throws {
        if self.point == point {
            throw OtaInjectedFault(point: point)
        }
    }
}

private func installedDownloadedRelease(
    id: String
) async throws -> (FileOtaReleaseStore, OtaInstalledRelease, OtaInstalledRelease, OtaReleaseScope) {
    let directory = try makeTemporaryDirectory()
    let store = FileOtaReleaseStore(baseDirectory: directory)
    let transaction = ReleaseTransaction(store: store)
    let embedded = makeRelease(id: "embedded", directory: directory, contents: "embedded")
    let downloaded = makeRelease(id: id, directory: directory, contents: "downloaded")
    let scope = OtaReleaseScope(app: .capp, lynxAppId: "10000001")
    try await transaction.registerEmbedded(embedded)
    try await transaction.stage(downloaded)
    _ = try await transaction.activate(scope: scope)
    return (store, embedded, downloaded, scope)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ota-transaction-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeRelease(id: String, directory: URL, contents: String) -> OtaInstalledRelease {
    let bundleURL = directory
        .appendingPathComponent("source", isDirectory: true)
        .appendingPathComponent(id + ".lynx.bundle", isDirectory: false)
    try! FileManager.default.createDirectory(at: bundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(contents.utf8).write(to: bundleURL)
    let checksum = try! SHA256ChecksumValidator().sha256(for: bundleURL)
    return OtaInstalledRelease(
        context: OtaCurrentReleaseContext(
            env: .test,
            app: .capp,
            lynxAppId: "10000001",
            releaseId: id,
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
}
