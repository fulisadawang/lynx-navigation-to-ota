import Foundation
import Testing
@testable import OtaIOSSDK

@Suite("OtaReadinessCancellation")
struct OtaReadinessCancellationTests {
    @Test("cancelling candidate confirmation before its commit keeps the trial", arguments: [OtaStoreVersion.v2, .v3])
    func cancellationBeforeCandidateCommitKeepsTrial(storeVersion: OtaStoreVersion) async throws {
        let fixture = try await makeFixture(storeVersion: storeVersion, pauseAt: .beforeStateCommit)
        defer { fixture.cleanup() }

        let confirmation = Task { try await fixture.transaction.confirmCandidate(scope: fixture.scope) }
        try await fixture.injector.waitUntilBlocked()

        // cancel() 本身是同步动作；只有随后放行才能到达确认的线性化点。
        confirmation.cancel()
        fixture.injector.release()

        do {
            _ = try await confirmation.value
            Issue.record("被取消的 candidate confirmation 不应写入 current")
        } catch is CancellationError {
            // 预期：fault 栅栏后、写 State 前的 Task.checkCancellation 拒绝本次提交。
        } catch {
            Issue.record("candidate confirmation 应因取消结束，实际错误：\(error)")
        }

        #expect(await fixture.transaction.current(scope: fixture.scope)?.context.releaseId == "embedded")
        #expect(await fixture.transaction.candidate(scope: fixture.scope)?.release.context.releaseId == "candidate")
        #expect(await fixture.transaction.candidate(scope: fixture.scope)?.status == .trial)
    }

    @Test("cancelling after candidate state commit does not roll back the committed release", arguments: [OtaStoreVersion.v2, .v3])
    func cancellationAfterCandidateCommitDoesNotRollback(storeVersion: OtaStoreVersion) async throws {
        let fixture = try await makeFixture(storeVersion: storeVersion, pauseAt: .afterStateCommit)
        defer { fixture.cleanup() }

        let confirmation = Task { try await fixture.transaction.confirmCandidate(scope: fixture.scope) }
        try await fixture.injector.waitUntilBlocked()

        // State 已经 durable 后的取消不能把成功提交逆转成 rollback。
        confirmation.cancel()
        fixture.injector.release()
        let confirmed = try await confirmation.value

        #expect(confirmed.context.releaseId == "candidate")
        #expect(await fixture.transaction.current(scope: fixture.scope)?.context.releaseId == "candidate")
        #expect(await fixture.transaction.candidate(scope: fixture.scope) == nil)
    }

    private func makeFixture(
        storeVersion: OtaStoreVersion,
        pauseAt: OtaTransactionFaultPoint
    ) async throws -> CandidateCommitFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ota-readiness-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let injector = CandidateCommitBarrier(point: pauseAt)
        let transaction = ReleaseTransaction(
            store: FileOtaReleaseStore(
                baseDirectory: root.appendingPathComponent("store", isDirectory: true),
                version: storeVersion
            ),
            faultInjector: injector
        )
        let scope = OtaReleaseScope(app: .capp, lynxAppId: "10000001")
        try await transaction.registerEmbedded(makeRelease(id: "embedded", directory: root, contents: "embedded"))
        try await transaction.stageCandidate(makeRelease(id: "candidate", directory: root, contents: "candidate"))
        let trial = try await transaction.beginCandidateTrial(scope: scope)
        #expect(trial.status == .trial)
        // setup 同样会写 State；只把真正的 confirm 路径挂到可控栅栏上。
        injector.arm()
        return CandidateCommitFixture(root: root, transaction: transaction, scope: scope, injector: injector)
    }

    private func makeRelease(id: String, directory: URL, contents: String) -> OtaInstalledRelease {
        let bundleURL = directory
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent("\(id).lynx.bundle", isDirectory: false)
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
}

private final class CandidateCommitFixture: @unchecked Sendable {
    let root: URL
    let transaction: ReleaseTransaction
    let scope: OtaReleaseScope
    let injector: CandidateCommitBarrier

    init(root: URL, transaction: ReleaseTransaction, scope: OtaReleaseScope, injector: CandidateCommitBarrier) {
        self.root = root
        self.transaction = transaction
        self.scope = scope
        self.injector = injector
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum CandidateCommitBarrierError: Error {
    case timeout
}

/// 用真实 store 的 fault hook 形成可控栅栏，避免用 sleep 猜测 Task 的执行时机。
private final class CandidateCommitBarrier: OtaTransactionFaultInjecting, @unchecked Sendable {
    private let target: OtaTransactionFaultPoint
    private let condition = NSCondition()
    private var armed = false
    private var reached = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(point: OtaTransactionFaultPoint) {
        target = point
    }

    func check(_ point: OtaTransactionFaultPoint) throws {
        condition.lock()
        let shouldBlock = armed && point == target
        condition.unlock()
        guard shouldBlock else { return }
        condition.lock()
        reached = true
        let pending = waiters
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for waiter in pending { waiter.resume() }

        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    func arm() {
        condition.lock()
        armed = true
        reached = false
        released = false
        condition.unlock()
    }

    func waitUntilBlocked() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForBarrier() }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                self.release()
                throw CandidateCommitBarrierError.timeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private func waitForBarrier() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if reached {
                condition.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            condition.unlock()
        }
    }
}
