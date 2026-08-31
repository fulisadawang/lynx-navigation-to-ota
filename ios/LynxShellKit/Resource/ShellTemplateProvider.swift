import Foundation
import CryptoKit
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
