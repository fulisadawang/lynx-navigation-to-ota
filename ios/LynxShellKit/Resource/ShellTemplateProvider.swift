import Foundation
import CryptoKit
import Lynx

/**
 * Lynx Bundle 加载器。
 *
 * 本地路径拒绝 `..`，远程默认仅 HTTPS，不限制 Host。
 * 直接 HTTPS 优先读取应用私有的 URL 级 Bundle 缓存，并在命中后后台重新下载；不会写入
 * OTA 磁盘 Store，也不执行内容 SHA、Manifest、current/previous 或回滚。OTA 页面应先由
 * OTA SDK 解析并校验本地 current，再把已确认的 Bundle 交给容器，两条链路不可隐式混用。
 * 任何失败都会同时通知 Lynx 与原生错误页。容器重建或销毁时调用 [cancel]，
 * 旧任务不会再回调已经失效的 LynxView。
 */
@objc(ShellTemplateProvider)
public final class ShellTemplateProvider: NSObject, LynxTemplateProvider {
    private static let maximumBundleBytes = 20 * 1024 * 1024
    private let allowHTTPInDebug: Bool
    private let onLoadError: ((String, Error) -> Void)?
    private let onTemplateData: ((String, Data) -> Void)?
    /** prepareRoute 命中后只把一次性 Bundle 字节交给目标 Provider。 */
    private let prefetchedURL: String?
    private var prefetchedData: Data?
    /** OTA 的逻辑 URL 不一定对应 App Bundle 根路径；重载继续读取当前页面已固定的文件。 */
    private let prefetchedFileURL: URL?
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
        prefetchedData: Data? = nil,
        prefetchedFileURL: URL? = nil,
        onTemplateData: ((String, Data) -> Void)? = nil
    ) {
        self.allowHTTPInDebug = allowHTTPInDebug
        self.onLoadError = onLoadError
        self.onTemplateData = onTemplateData
        self.prefetchedURL = prefetchedURL
        self.prefetchedData = prefetchedData
        self.prefetchedFileURL = prefetchedFileURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
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
        prefetchedData = nil
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
            // 首次字节仍只消费一次；OTA 重载使用固定文件，普通预取仍回到原加载链路。
            prefetchedData = nil
        }
        stateLock.unlock()
        if let prepared {
            completeSuccess(prepared, url: url, callback: callback)
            return
        }
        if prefetchedURL == url, let prefetchedFileURL {
            loadLocal(url, preparedFileURL: prefetchedFileURL, callback: callback)
            return
        }
        if RemoteBundlePolicy.isRemote(url) {
            loadRemote(url, callback: callback)
        } else {
            loadLocal(url, callback: callback)
        }
    }

    private func loadLocal(
        _ rawURL: String,
        preparedFileURL: URL? = nil,
        callback: @escaping LynxTemplateLoadBlock
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.isCancelled else { return }
            do {
                let fileURL: URL
                if let preparedFileURL {
                    fileURL = preparedFileURL
                } else {
                    let path = try self.normalizedAssetPath(rawURL)
                    fileURL = try self.resolveLocalBundle(path)
                }
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                guard !data.isEmpty else { throw TemplateError.emptyBundle }
                guard data.count <= Self.maximumBundleBytes else { throw TemplateError.bundleTooLarge }
                self.completeSuccess(data, url: rawURL, callback: callback)
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

        let isHTTPS = url.scheme?.lowercased() == "https"
        if isHTTPS, let cached = Self.readRemoteCache(rawURL) {
            completeSuccess(cached, url: rawURL, callback: callback)
            Self.scheduleRemoteRefresh(rawURL, allowHTTPInDebug: allowHTTPInDebug)
            return
        }

        loadRemoteFromNetwork(
            rawURL: rawURL,
            url: url,
            persistToCache: isHTTPS,
            callback: callback
        )
    }

    private func loadRemoteFromNetwork(
        rawURL: String,
        url: URL,
        persistToCache: Bool,
        callback: @escaping LynxTemplateLoadBlock
    ) {
        var task: URLSessionDataTask?
        task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            if let identifier = task?.taskIdentifier { self.untrackTask(identifier) }
            guard !self.isCancelled else { return }

            do {
                if let error { throw error }
                let bundleData = try Self.validateRemoteData(
                    data,
                    response: response,
                    allowHTTPInDebug: self.allowHTTPInDebug
                )
                if persistToCache {
                    _ = Self.writeRemoteCache(rawURL, data: bundleData)
                }
                self.completeSuccess(bundleData, url: rawURL, callback: callback)
            } catch {
                self.completeFailure(url: rawURL, error: error, callback: callback)
            }
        }
        guard let task else { return }
        trackTask(task)
        task.resume()
    }

    private static func validateRemoteData(
        _ data: Data?,
        response: URLResponse?,
        allowHTTPInDebug: Bool
    ) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw TemplateError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            throw TemplateError.httpStatus(http.statusCode)
        }
        guard let finalURL = http.url else { throw TemplateError.invalidResponse }
        let finalScheme = finalURL.scheme?.lowercased()
        let secureFinalURL = finalScheme == "https"
        #if DEBUG
        let permittedDebugHTTP = allowHTTPInDebug && finalScheme == "http"
        #else
        let permittedDebugHTTP = false
        #endif
        guard secureFinalURL || permittedDebugHTTP else { throw TemplateError.insecureRedirect }
        guard let data, !data.isEmpty else { throw TemplateError.emptyBundle }
        guard data.count <= maximumBundleBytes else { throw TemplateError.bundleTooLarge }
        return data
    }

    private static let remoteRefreshQueue = DispatchQueue(
        label: "com.example.lynxshell.direct-https-refresh",
        qos: .utility
    )
    private static let remoteRefreshLock = NSLock()
    private static var refreshingRemoteURLs = Set<String>()
    private static let remoteRefreshSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static func scheduleRemoteRefresh(_ rawURL: String, allowHTTPInDebug: Bool) {
        remoteRefreshLock.lock()
        guard refreshingRemoteURLs.insert(rawURL).inserted else {
            remoteRefreshLock.unlock()
            return
        }
        remoteRefreshLock.unlock()

        remoteRefreshQueue.async {
            guard let url = URL(string: rawURL) else {
                Self.finishRemoteRefresh(rawURL)
                return
            }
            let task = Self.remoteRefreshSession.dataTask(with: url) { data, response, error in
                defer { Self.finishRemoteRefresh(rawURL) }
                guard error == nil else { return }
                guard let bundleData = try? Self.validateRemoteData(
                    data,
                    response: response,
                    allowHTTPInDebug: allowHTTPInDebug
                ) else { return }
                _ = Self.writeRemoteCache(rawURL, data: bundleData)
            }
            task.resume()
        }
    }

    private static func finishRemoteRefresh(_ rawURL: String) {
        remoteRefreshLock.lock()
        refreshingRemoteURLs.remove(rawURL)
        remoteRefreshLock.unlock()
    }

    private static func readRemoteCache(_ rawURL: String) -> Data? {
        let fileURL = remoteCacheFileURL(rawURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              !data.isEmpty,
              data.count <= maximumBundleBytes else {
            return nil
        }
        return data
    }

    /** 只用 URL 生成文件名；这里不计算、不校验 Bundle 内容 SHA-256。 */
    private static func remoteCacheFileURL(_ rawURL: String) -> URL {
        let key = SHA256.hash(data: Data(rawURL.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("LynxShell/https-bundles", isDirectory: true)
        return directory.appendingPathComponent("\(key).lynx.bundle", isDirectory: false)
    }

    /** 临时文件写完后再替换正式缓存；缓存失败不能阻断在线页面加载。 */
    private static func writeRemoteCache(_ rawURL: String, data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBundleBytes else { return false }
        let fileManager = FileManager.default
        let target = remoteCacheFileURL(rawURL)
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(target.lastPathComponent).\(UUID().uuidString).part",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.replaceItemAt(
                    target,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporary, to: target)
            }
            return true
        } catch {
            try? fileManager.removeItem(at: temporary)
            return false
        }
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

    private func completeSuccess(_ data: Data, url: String, callback: @escaping LynxTemplateLoadBlock) {
        guard !isCancelled else { return }
        if onTemplateData != nil, Thread.isMainThread {
            // 预取字节原本可同步回调；开启监控后把一次性内容哈希放到资源线程，避免阻塞 UIKit。
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.completeSuccess(data, url: url, callback: callback)
            }
            return
        }
        onTemplateData?(url, data)
        guard !isCancelled else { return }
        // SDK 会在这个回调中重置并重建 UIKit 渲染树；读文件和哈希可在后台，交付必须回主线程。
        if Thread.isMainThread {
            callback(data, nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isCancelled else { return }
                callback(data, nil)
            }
        }
    }

    private func completeFailure(
        url: String,
        error: Error,
        callback: @escaping LynxTemplateLoadBlock
    ) {
        guard !isCancelled else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.completeFailure(url: url, error: error, callback: callback)
            }
            return
        }
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

/** 多个内置 Lynx App 共用的资源索引；不通过目录扫描猜测 lynxAppId。 */
struct EmbeddedBundleDescriptor {
    let lynxAppId: String
    let releaseId: String
    let bundleName: String
    let fileURL: URL
    let size: Int
    let sha256: String
}

/**
 * 读取 App Bundle 中的 embedded registry，并按 Manifest 校验 size/SHA。
 *
 * Manifest 的逻辑 assetPath 使用 `bundles/...`；iOS 的 `Bundles` folder reference
 * 已经是资源根目录，因此实际 URL 会去掉这一层前缀。
 */
final class EmbeddedBundleRegistry {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let apps: [App]
    }

    private struct App: Decodable {
        let lynxAppId: String
        let releaseId: String
        let bundles: [ManifestBundle]
    }

    private struct ManifestBundle: Decodable {
        let pageId: Int?
        let bundleName: String
        let bundlePath: String?
        let assetPath: String
        let size: Int
        let sha256: String
    }

    private let resourceBundle: Foundation.Bundle
    private let entries: [App]

    init(resourceBundle: Foundation.Bundle = .main) {
        self.resourceBundle = resourceBundle
        guard let manifestURL = resourceBundle.url(
            forResource: "embedded-bundles",
            withExtension: "json",
            subdirectory: "Bundles/lynx"
        ) else {
            entries = []
            return
        }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion == 1 else {
                throw NSError(domain: "LynxShellEmbedded", code: 1001, userInfo: [
                    NSLocalizedDescriptionKey: "内置 Bundle Manifest schemaVersion 不支持"
                ])
            }
            entries = manifest.apps
        } catch {
            // Manifest 存在但损坏时不能静默把错误 Bundle 当普通资源使用。
            fatalError("内置 Bundle Manifest 读取失败：\(error.localizedDescription)")
        }
    }

    func resolve(lynxAppId: String, bundleName: String) throws -> EmbeddedBundleDescriptor? {
        guard let app = entries.first(where: { $0.lynxAppId == lynxAppId }),
              let bundle = app.bundles.first(where: { $0.bundleName == bundleName }) else {
            return nil
        }
        let logicalPath = try validateAssetPath(bundle.assetPath)
        let shaBody = String(bundle.sha256.dropFirst("sha256:".count))
        guard bundle.sha256.hasPrefix("sha256:"),
              shaBody.count == 64,
              shaBody.allSatisfy({ $0.isHexDigit }) else {
            throw NSError(domain: "LynxShellEmbedded", code: 1006, userInfo: [
                NSLocalizedDescriptionKey: "内置 Bundle sha256 格式错误：\(bundle.sha256)"
            ])
        }
        guard let resourceRoot = resourceBundle.resourceURL else {
            throw NSError(domain: "LynxShellEmbedded", code: 1002, userInfo: [
                NSLocalizedDescriptionKey: "App Bundle 缺少资源根目录"
            ])
        }
        let fileURL = resourceRoot
            .appendingPathComponent("Bundles", isDirectory: true)
            .appendingPathComponent(logicalPath, isDirectory: false)
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count == bundle.size else {
            throw NSError(domain: "LynxShellEmbedded", code: 1003, userInfo: [
                NSLocalizedDescriptionKey: "内置 Bundle size 校验失败：\(bundle.assetPath)"
            ])
        }
        let actual = "sha256:\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())"
        guard actual.caseInsensitiveCompare(bundle.sha256) == .orderedSame else {
            throw NSError(domain: "LynxShellEmbedded", code: 1004, userInfo: [
                NSLocalizedDescriptionKey: "内置 Bundle SHA-256 校验失败：\(bundle.assetPath)"
            ])
        }
        return EmbeddedBundleDescriptor(
            lynxAppId: app.lynxAppId,
            releaseId: app.releaseId,
            bundleName: bundle.bundleName,
            fileURL: fileURL,
            size: bundle.size,
            sha256: bundle.sha256
        )
    }

    func firstIdentity() -> (lynxAppId: String, bundleName: String)? {
        guard let app = entries.first, let bundle = app.bundles.first else { return nil }
        return (app.lynxAppId, bundle.bundleName)
    }

    /** 按内置 Manifest 查找 Bundle 身份，供 Demo/宿主避免自行猜测 App ID。 */
    func identity(bundleName: String) -> (lynxAppId: String, bundleName: String)? {
        for app in entries where app.bundles.contains(where: { $0.bundleName == bundleName }) {
            return (app.lynxAppId, bundleName)
        }
        return nil
    }

    /** 判断 App ID 是否存在随包 baseline；只查 Manifest，不读取或复制 Bundle。 */
    func containsApp(lynxAppId: String) -> Bool {
        entries.contains { $0.lynxAppId == lynxAppId }
    }

    func isEmbeddedRelease(lynxAppId: String, releaseId: String) -> Bool {
        entries.contains { $0.lynxAppId == lynxAppId && $0.releaseId == releaseId }
    }

    /** 将 Manifest 中的全部内置 App 转成 OTA Store 只读 baseline 描述。 */
    func installedReleases(
        env: OtaEnvironment,
        app: OtaAppID,
        platform: OtaPlatform
    ) throws -> [OtaInstalledRelease] {
        try entries.map { entry in
            let bundles = try entry.bundles.map { item -> OtaInstalledBundle in
                guard let descriptor = try resolve(
                    lynxAppId: entry.lynxAppId,
                    bundleName: item.bundleName
                ) else {
                    throw NSError(domain: "LynxShellEmbedded", code: 1007, userInfo: [
                        NSLocalizedDescriptionKey: "内置 Bundle 解析失败：\(entry.lynxAppId)/\(item.bundleName)"
                    ])
                }
                return OtaInstalledBundle(
                    bundleName: descriptor.bundleName,
                    bundleSha256: descriptor.sha256,
                    remoteURL: descriptor.fileURL,
                    localFilePath: descriptor.fileURL.path,
                    pageId: item.pageId ?? 0,
                    bundlePath: item.bundlePath ?? descriptor.bundleName
                )
            }
            return OtaInstalledRelease(
                context: OtaCurrentReleaseContext(
                    env: env,
                    app: app,
                    lynxAppId: entry.lynxAppId,
                    releaseId: entry.releaseId,
                    platform: platform,
                    status: .active
                ),
                installedAt: .distantPast,
                bundles: bundles
            )
        }
    }

    private func validateAssetPath(_ value: String) throws -> String {
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard value.hasPrefix("bundles/"),
              value.lowercased().hasSuffix(".lynx.bundle"),
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw NSError(domain: "LynxShellEmbedded", code: 1005, userInfo: [
                NSLocalizedDescriptionKey: "内置 Bundle assetPath 不安全：\(value)"
            ])
        }
        return String(value.dropFirst("bundles/".count))
    }
}
