import Foundation
import Lynx

/**
 * Lynx Bundle 加载器。
 *
 * 本地路径拒绝 `..`，远程默认仅 HTTPS，不限制 Host。
 * 直接 HTTPS 使用临时 URLSession，只承担本次页面加载和进程内 HTTP 缓存协商；不会写入
 * OTA 磁盘 Store，也不执行 Manifest、SHA、current/previous 或回滚。OTA 页面应先由 OTA SDK
 * 解析并校验本地 current，再把已确认的 Bundle 交给容器，两条链路不可隐式混用。
 * 任何失败都会同时通知 Lynx 与原生错误页。容器重建或销毁时调用 [cancel]，
 * 旧任务不会再回调已经失效的 LynxView。
 */
@objc(ShellTemplateProvider)
public final class ShellTemplateProvider: NSObject, LynxTemplateProvider {
    private static let maximumBundleBytes = 20 * 1024 * 1024
    private let allowHTTPInDebug: Bool
    private let onLoadError: ((String, Error) -> Void)?
    /** prepareRoute 命中后只把一次性 Bundle 字节交给目标 Provider。 */
    private let prefetchedURL: String?
    private var prefetchedData: Data?
    private let stateLock = NSLock()
    private var cancelled = false
    private var activeTasks: [Int: URLSessionTask] = [:]
    private let session: URLSession

    @objc public override convenience init() {
        self.init(allowHTTPInDebug: false, onLoadError: nil)
    }

    init(
        allowHTTPInDebug: Bool,
        onLoadError: ((String, Error) -> Void)?,
        prefetchedURL: String? = nil,
        prefetchedData: Data? = nil
    ) {
        self.allowHTTPInDebug = allowHTTPInDebug
        self.onLoadError = onLoadError
        self.prefetchedURL = prefetchedURL
        self.prefetchedData = prefetchedData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    deinit {
        cancel()
    }

    /** 取消网络任务并永久屏蔽本 Provider 的后续回调。 */
    func cancel() {
        stateLock.lock()
        guard !cancelled else {
            stateLock.unlock()
            return
        }
        cancelled = true
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        stateLock.unlock()

        tasks.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }

    public func loadTemplate(
        withUrl url: String!,
        onComplete callback: LynxTemplateLoadBlock!
    ) {
        guard !isCancelled else { return }
        guard let url, !url.isEmpty else {
            completeFailure(url: "", error: TemplateError.emptyURL, callback: callback)
            return
        }
        stateLock.lock()
        let prepared = prefetchedURL == url ? prefetchedData : nil
        if prepared != nil {
            // 单个 Provider 也只消费一次，重试时回到正常安全加载链路。
            prefetchedData = nil
        }
        stateLock.unlock()
        if let prepared {
            completeSuccess(prepared, callback: callback)
            return
        }
        if RemoteBundlePolicy.isRemote(url) {
            loadRemote(url, callback: callback)
        } else {
            loadLocal(url, callback: callback)
        }
    }

    private func loadLocal(_ rawURL: String, callback: @escaping LynxTemplateLoadBlock) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.isCancelled else { return }
            do {
                let path = try self.normalizedAssetPath(rawURL)
                let fileURL = try self.resolveLocalBundle(path)
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                guard !data.isEmpty else { throw TemplateError.emptyBundle }
                guard data.count <= Self.maximumBundleBytes else { throw TemplateError.bundleTooLarge }
                self.completeSuccess(data, callback: callback)
            } catch {
                self.completeFailure(url: rawURL, error: error, callback: callback)
            }
        }
    }

    private func loadRemote(_ rawURL: String, callback: @escaping LynxTemplateLoadBlock) {
        guard let url = URL(string: rawURL) else {
            completeFailure(url: rawURL, error: TemplateError.invalidURL, callback: callback)
            return
        }
        if url.scheme?.lowercased() == "http" {
            #if DEBUG
            guard allowHTTPInDebug else {
                completeFailure(url: rawURL, error: TemplateError.insecureHTTP, callback: callback)
                return
            }
            #else
            completeFailure(url: rawURL, error: TemplateError.insecureHTTP, callback: callback)
            return
            #endif
        }

        var task: URLSessionDataTask?
        task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            if let identifier = task?.taskIdentifier { self.untrackTask(identifier) }
            guard !self.isCancelled else { return }

            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse else { throw TemplateError.invalidResponse }
                guard (200 ... 299).contains(http.statusCode) else {
                    throw TemplateError.httpStatus(http.statusCode)
                }
                guard let finalURL = http.url else { throw TemplateError.invalidResponse }
                let finalScheme = finalURL.scheme?.lowercased()
                let secureFinalURL = finalScheme == "https"
                #if DEBUG
                let permittedDebugHTTP = self.allowHTTPInDebug && finalScheme == "http"
                #else
                let permittedDebugHTTP = false
                #endif
                guard secureFinalURL || permittedDebugHTTP else { throw TemplateError.insecureRedirect }
                guard let data, !data.isEmpty else { throw TemplateError.emptyBundle }
                guard data.count <= Self.maximumBundleBytes else { throw TemplateError.bundleTooLarge }
                self.completeSuccess(data, callback: callback)
            } catch {
                self.completeFailure(url: rawURL, error: error, callback: callback)
            }
        }
        guard let task else { return }
        trackTask(task)
        task.resume()
    }

    private func normalizedAssetPath(_ rawURL: String) throws -> String {
        let prefixes = ["assets://", "file://lynx?local://"]
        var path = rawURL
        for prefix in prefixes where path.lowercased().hasPrefix(prefix) {
            path.removeFirst(prefix.count)
            break
        }
        path = path.components(separatedBy: "?").first ?? path
        path = path.components(separatedBy: "#").first ?? path
        path = path.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path.removeFirst(2) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { throw TemplateError.emptyURL }
        guard !path.split(separator: "/").contains("..") else { throw TemplateError.unsafePath }

        // 跨端路由统一推荐 assets://bundles；iOS 文件夹实际名为 Bundles。
        if path.lowercased().hasPrefix("bundles/") {
            let suffix = path.split(separator: "/").dropFirst().joined(separator: "/")
            path = "Bundles/\(suffix)"
        }
        return path
    }

    private func resolveLocalBundle(_ path: String) throws -> URL {
        if let exact = bundleURL(for: path) { return exact }
        // 兼容 Explorer 常见的 local://main.lynx.bundle 根路径写法。
        if !path.contains("/"), let bundled = bundleURL(for: "Bundles/\(path)") {
            return bundled
        }
        throw TemplateError.localBundleNotFound(path)
    }

    private func bundleURL(for path: String) -> URL? {
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent == "."
            ? nil
            : nsPath.deletingLastPathComponent
        let filename = nsPath.lastPathComponent as NSString
        let name = filename.deletingPathExtension
        let ext = filename.pathExtension.isEmpty ? nil : filename.pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory)
    }

    private func completeSuccess(_ data: Data, callback: @escaping LynxTemplateLoadBlock) {
        guard !isCancelled else { return }
        callback(data, nil)
    }

    private func completeFailure(
        url: String,
        error: Error,
        callback: @escaping LynxTemplateLoadBlock
    ) {
        guard !isCancelled else { return }
        callback(nil, error)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onLoadError?(url, error)
        }
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func trackTask(_ task: URLSessionTask) {
        stateLock.lock()
        if cancelled {
            stateLock.unlock()
            task.cancel()
            return
        }
        activeTasks[task.taskIdentifier] = task
        stateLock.unlock()
    }

    private func untrackTask(_ identifier: Int) {
        stateLock.lock()
        activeTasks.removeValue(forKey: identifier)
        stateLock.unlock()
    }
}

private enum TemplateError: LocalizedError {
    case emptyURL
    case invalidURL
    case unsafePath
    case localBundleNotFound(String)
    case insecureHTTP
    case insecureRedirect
    case invalidResponse
    case httpStatus(Int)
    case emptyBundle
    case bundleTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyURL: return "Bundle URL 为空"
        case .invalidURL: return "Bundle URL 不合法"
        case .unsafePath: return "本地 Bundle 路径包含不安全的 .."
        case let .localBundleNotFound(path): return "App Bundle 中未找到: \(path)"
        case .insecureHTTP: return "宿主拒绝明文 HTTP Bundle"
        case .insecureRedirect: return "Bundle 重定向到了不安全协议"
        case .invalidResponse: return "Bundle 网络响应无效"
        case let .httpStatus(code): return "Bundle HTTP 状态码异常: \(code)"
        case .emptyBundle: return "Bundle 内容为空"
        case .bundleTooLarge: return "Bundle 超过 20MB 限制"
        }
    }
}
