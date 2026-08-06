import Foundation
import UIKit

/**
 * 只保存 Bundle 字节的预置路由缓存。
 *
 * 它不会保存 LynxView、UIViewController、JS Runtime 或转场快照，因此内存警告、
 * 过期、取消后都可以安全回到普通 TemplateProvider 加载。
 */
final class ShellPreparedRouteStore {
    struct PreparedRoute {
        let token: String
        let bundleURL: String
        let data: Data
        let expiresAt: Date
        var lastAccessAt: Date
    }

    enum StoreError: LocalizedError {
        case notFound
        case urlMismatch
        case cacheLimit

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "预置路由不存在、已消费或已过期"
            case .urlMismatch:
                return "预置路由与目标 Bundle URL 不一致"
            case .cacheLimit:
                return "预置 Bundle 超过 32MB 缓存上限"
            }
        }
    }

    static let shared = ShellPreparedRouteStore()

    private let ttl: TimeInterval = 30
    private let maximumEntries = 4
    private let maximumTotalBytes = 32 * 1024 * 1024
    private var entries: [String: PreparedRoute] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /**
     * 完成安全路由解析后预取 Bundle。
     *
     * 回调始终回到主线程；返回 token 后条目才可以被 cancel/consume。
     */
    func prepare(
        request: LynxPageRequest,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let provider = ShellTemplateProvider(
            allowHTTPInDebug: request.allowHTTPInDebug,
            onLoadError: nil
        )
        provider.loadTemplate(withUrl: request.bundleURL) { [weak self, provider] data, error in
            // 捕获 provider，确保异步加载结束前不会被 deinit/cancel。
            _ = provider
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data = data as? Data, !data.isEmpty else {
                    completion(.failure(StoreError.notFound))
                    return
                }
                guard data.count <= self.maximumTotalBytes else {
                    completion(.failure(StoreError.cacheLimit))
                    return
                }

                self.removeExpired()
                self.makeRoom(for: data.count)
                let token = UUID().uuidString
                let expiresAt = Date().addingTimeInterval(self.ttl)
                self.entries[token] = PreparedRoute(
                    token: token,
                    bundleURL: request.bundleURL,
                    data: data,
                    expiresAt: expiresAt,
                    lastAccessAt: Date()
                )
                completion(.success([
                    "token": token,
                    "bundleURL": request.bundleURL,
                    "byteCount": data.count,
                    // 与前端冻结契约保持同名，同时保留 byteCount 兼容旧调用方。
                    "sizeBytes": data.count,
                    "routeKey": request.resolvedRouteKey,
                    "expiresAt": Int64(expiresAt.timeIntervalSince1970 * 1_000),
                    "ttlMs": Int(self.ttl * 1_000),
                ]))
            }
        }
    }

    /** token 一次消费；URL 不一致时不把错误字节交给其他路由。 */
    func consume(token: String, expectedURL: String) -> Result<Data, Error> {
        dispatchPrecondition(condition: .onQueue(.main))
        removeExpired()
        guard let entry = entries.removeValue(forKey: token) else {
            return .failure(StoreError.notFound)
        }
        guard entry.bundleURL == expectedURL else {
            return .failure(StoreError.urlMismatch)
        }
        return .success(entry.data)
    }

    @discardableResult
    func cancel(token: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        removeExpired()
        return entries.removeValue(forKey: token) != nil
    }

    func removeAll() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.removeAll() }
            return
        }
        entries.removeAll()
    }

    private func removeExpired(now: Date = Date()) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private func makeRoom(for incomingBytes: Int) {
        while entries.count >= maximumEntries ||
            totalBytes + incomingBytes > maximumTotalBytes {
            guard let lru = entries.values.min(by: {
                $0.lastAccessAt < $1.lastAccessAt
            }) else {
                break
            }
            entries.removeValue(forKey: lru.token)
        }
    }

    private var totalBytes: Int {
        entries.values.reduce(0) { $0 + $1.data.count }
    }
}
