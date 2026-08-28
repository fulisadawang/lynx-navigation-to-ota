import Foundation

/** 活体 iOS 页面对一个已解析 Bundle 的进程内租约。 */
public final class OtaBundleLease: @unchecked Sendable {
    public let release: OtaInstalledRelease
    public let bundle: OtaInstalledBundle
    public let fileURL: URL

    private let lock = NSLock()
    private var closeAction: (@Sendable () async -> Void)?

    init(
        release: OtaInstalledRelease,
        bundle: OtaInstalledBundle,
        fileURL: URL,
        closeAction: @escaping @Sendable () async -> Void
    ) {
        self.release = release
        self.bundle = bundle
        self.fileURL = fileURL
        self.closeAction = closeAction
    }

    /** 幂等释放；最后一个 lease 关闭后立即执行 app-scoped prune。 */
    public func close() async {
        guard let action = takeCloseAction() else { return }
        await action()
    }

    deinit {
        guard let action = takeCloseAction() else { return }
        Task { await action() }
    }

    private func takeCloseAction() -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let action = closeAction
        closeAction = nil
        return action
    }
}
