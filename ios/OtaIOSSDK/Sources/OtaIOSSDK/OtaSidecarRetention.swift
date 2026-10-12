import Foundation

final class OtaSidecarSynchronization: @unchecked Sendable {
    static let shared = OtaSidecarSynchronization()
    private let lock = NSRecursiveLock()

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
}

struct OtaSidecarTransactionRecord: Codable {
    let schemaVersion: Int
    let session: String
    let manifestId: String
    let objectIds: [String]
}

/// 每次安装使用唯一事务文件，跨 await 的并发安装不会互删保护根。
final class OtaSidecarTransaction: @unchecked Sendable {
    static let session = UUID().uuidString
    private let fileURL: URL
    private let lock = NSLock()
    private var finished = false

    init(root: URL, manifestId: String, objectIds: [String]) throws {
        fileURL = root.appendingPathComponent("transactions/\(UUID().uuidString).json")
        let record = OtaSidecarTransactionRecord(schemaVersion: 1, session: Self.session, manifestId: manifestId, objectIds: objectIds)
        try OtaSidecarSynchronization.shared.withLock {
            try OtaSidecarDisk.write(OtaSidecarDisk.encode(record), to: fileURL)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        // 删除失败只会多保留对象；下一进程 GC 按 session 清理遗留事务。
        OtaSidecarSynchronization.shared.withLock {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    deinit { finish() }
}

enum OtaSidecarGarbageCollector {
    /// 与主 Store 在同一个 actor 周期里执行，避免使用已经过时的代码 roots。
    static func prune(baseDirectory: URL, appId: String, asyncIds: Set<String>) throws {
        try OtaSidecarSynchronization.shared.withLock {
            try pruneChannel(baseDirectory: baseDirectory, appId: appId, channel: "async-bundles", referenced: asyncIds)
        }
    }

    private static func pruneChannel(baseDirectory: URL, appId: String, channel: String, referenced: Set<String>) throws {
        let root = try OtaSidecarDisk.root(baseDirectory, appId: appId, channel: channel)
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            guard referenced.isEmpty else { throw OtaSidecarError.missingLocalResource }
            return
        }
        let required = referenced
        var staging = Set<String>()
        var objects = Set<String>()
        var staleTransactions: [URL] = []
        for file in try jsonFiles(root.appendingPathComponent("transactions")) {
            let transaction = try JSONDecoder().decode(OtaSidecarTransactionRecord.self, from: Data(contentsOf: file))
            guard transaction.schemaVersion == 1 else { throw OtaSidecarError.invalidManifest("事务版本不支持") }
            if transaction.session == OtaSidecarTransaction.session {
                staging.insert(transaction.manifestId)
                objects.formUnion(transaction.objectIds)
            } else {
                staleTransactions.append(file)
            }
        }
        // 先验证每一个根；缺少一个 manifest 就终止整轮，不能把它的对象误判为无引用。
        for id in required.union(staging) {
            let file = root.appendingPathComponent("manifests/\(try OtaSidecarDisk.hashName(id)).json")
            if !manager.fileExists(atPath: file.path), !required.contains(id) { continue }
            let data = try Data(contentsOf: file)
            guard OtaSidecarDisk.digest(data) == id else { throw OtaSidecarError.missingLocalResource }
            let manifest = try JSONDecoder().decode(OtaAsyncManifest.self, from: data)
            guard manifest.schemaVersion == 1 else { throw OtaSidecarError.invalidManifest("清单版本不支持") }
            objects.formUnion(manifest.entries.map(\.sha256))
        }
        let retained = required.union(staging)
        for file in try jsonFiles(root.appendingPathComponent("manifests")) {
            let id = "sha256:" + file.deletingPathExtension().lastPathComponent
            if !retained.contains(id) { try manager.removeItem(at: file) }
        }
        let objectRoot = root.appendingPathComponent("objects")
        if let enumerator = manager.enumerator(at: objectRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                   !objects.contains("sha256:" + file.lastPathComponent) {
                    try manager.removeItem(at: file)
                }
            }
        }
        for file in staleTransactions { try manager.removeItem(at: file) }
    }

    private static func jsonFiles(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }
}

/// 页面固定 Async 快照；关闭后等待在途 resolve 结束再释放资源。
public final class OtaPreparedResources: @unchecked Sendable {
    public let hasAsyncResources: Bool
    private let localPaths: [String: URL]
    private let resolver: @Sendable (String) async throws -> Data
    private let closeAction: @Sendable () async -> Void
    private let pathResolver: (@Sendable (String) -> URL?)?
    private let lock = NSLock()
    private var closed = false
    private var activeResolves = 0
    private var cleanupScheduled = false
    private var leasesToClose: [OtaBundleLease] = []
    private var drainedActions: [@Sendable () async -> Void] = []

    init(hasAsyncResources: Bool, localPaths: [String: URL],
         resolver: @escaping @Sendable (String) async throws -> Data,
         closeAction: @escaping @Sendable () async -> Void,
         pathResolver: (@Sendable (String) -> URL?)? = nil) {
        self.hasAsyncResources = hasAsyncResources
        self.localPaths = localPaths
        self.resolver = resolver
        self.closeAction = closeAction
        self.pathResolver = pathResolver
    }

    public func resolve(_ url: String) async throws -> Data {
        try beginResolve()
        defer { finishResolve() }
        return try await resolver(url)
    }

    public func localURL(_ rawURL: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        if let pathResolver { return pathResolver(rawURL) }
        if let direct = localPaths[rawURL] { return direct }
        let candidate: String
        if let url = URL(string: rawURL), url.scheme != nil {
            guard url.query == nil, url.fragment == nil else { return nil }
            candidate = url.path
        } else { candidate = rawURL }
        guard let key = try? OtaSidecarDisk.requestKey(candidate) else { return nil }
        return localPaths[key]
    }

    public func close(releasing lease: OtaBundleLease? = nil) {
        lock.lock()
        if cleanupScheduled {
            lock.unlock()
            if let lease { Task { await lease.close() } }
            return
        }
        if let lease { leasesToClose.append(lease) }
        closed = true
        let cleanup = takeCleanupLocked()
        lock.unlock()
        if cleanup { runCleanup() }
    }

    public func onDrained(_ action: @escaping @Sendable () async -> Void) {
        lock.lock()
        let runNow = cleanupScheduled
        if !runNow { drainedActions.append(action) }
        lock.unlock()
        if runNow { Task { await action() } }
    }

    deinit { close() }

    private func beginResolve() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw OtaSidecarError.resourcesClosed }
        activeResolves += 1
    }

    private func finishResolve() {
        lock.lock()
        activeResolves -= 1
        let cleanup = takeCleanupLocked()
        lock.unlock()
        if cleanup { runCleanup() }
    }

    private func takeCleanupLocked() -> Bool {
        guard closed, activeResolves == 0, !cleanupScheduled else { return false }
        cleanupScheduled = true
        return true
    }

    private func runCleanup() {
        lock.lock()
        let leases = leasesToClose
        leasesToClose.removeAll()
        let actions = drainedActions
        drainedActions.removeAll()
        lock.unlock()
        let action = closeAction
        Task {
            // Async 解析完成前必须保留主 Release lease，否则 Store GC 可能删除对象。
            for lease in leases { await lease.close() }
            await action()
            for drained in actions { await drained() }
        }
    }
}
