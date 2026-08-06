import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CryptoKit

public protocol OtaAPIClientProtocol: Sendable {
    func checkForUpdate(_ request: OtaPolicyMatchRequest) async throws -> OtaPolicyMatchResponse
    func fetchManifest(
        releaseId: String,
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform
    ) async throws -> OtaReleaseManifest
    func fetchLatestBundleList(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform
    ) async throws -> OtaLatestBundleList
    func fetchLatestBundleLists(
        env: OtaEnvironment,
        app: OtaAppID,
        platform: OtaPlatform
    ) async throws -> OtaHostLatestBundleLists
    func reportEvent(_ payload: OtaReportPayload) async throws -> OtaReportResponse
}

public protocol OtaBundleDownloading: Sendable {
    func download(from remoteURL: URL, to localURL: URL) async throws
}

public protocol OtaChecksumValidating: Sendable {
    func sha256(for fileURL: URL) throws -> String
}

public struct URLSessionBundleDownloader: OtaBundleDownloading {
    /** 在 iOS 13 continuation 路径中保存底层任务，使上层取消 Loading 时网络也真正取消。 */
    private final class DownloadTaskState: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var cancelled = false

        func install(_ task: URLSessionDownloadTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    public init() {}

    public func download(from remoteURL: URL, to localURL: URL) async throws {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch remoteURL.scheme?.lowercased() {
        case "file":
            let sourcePath = remoteURL.path
            guard fileManager.fileExists(atPath: sourcePath) else {
                throw OtaSDKError.fileNotFound(sourcePath)
            }
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.copyItem(at: remoteURL, to: localURL)
            do {
                try Task.checkCancellation()
            } catch {
                try? fileManager.removeItem(at: localURL)
                throw error
            }
        case "http", "https":
            let (temporaryURL, response) = try await downloadTemporaryFile(from: remoteURL)
            // URLSession 回调内部已经把 CFNetwork 的临时文件移动到了 SDK 自己的
            // 临时目录。这里无论 HTTP 状态是否成功都负责清理，避免失败响应留下孤儿文件。
            defer { try? fileManager.removeItem(at: temporaryURL) }
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw OtaSDKError.invalidResponse(statusCode: statusCode, body: "")
            }

            // 下载期间另一个生命周期任务可能清理过 release 目录；移动前再次创建
            // 父目录，避免临时文件存在但目标目录已被删除时直接失败。
            let parentDirectory = localURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            guard fileManager.fileExists(atPath: temporaryURL.path) else {
                throw OtaSDKError.fileNotFound(temporaryURL.path)
            }
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            do {
                try fileManager.moveItem(at: temporaryURL, to: localURL)
            } catch {
                // 仅在临时文件仍然存在时重试；如果第一次移动已经完成或临时文件
                // 被系统清理，保留原始错误，避免覆盖真正的下载失败原因。
                guard fileManager.fileExists(atPath: temporaryURL.path) else {
                    throw error
                }
                try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
                try fileManager.moveItem(at: temporaryURL, to: localURL)
            }
            do {
                try Task.checkCancellation()
            } catch {
                try? fileManager.removeItem(at: localURL)
                throw error
            }
        default:
            throw OtaSDKError.unsupportedDownloadScheme(remoteURL.scheme ?? "unknown")
        }
    }

    private func downloadTemporaryFile(from remoteURL: URL) async throws -> (URL, URLResponse) {
        let state = DownloadTaskState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: remoteURL) { temporaryURL, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let temporaryURL, let response else {
                        continuation.resume(throwing: OtaSDKError.invalidResponse(statusCode: -1, body: "Missing download response"))
                        return
                    }
                    // CFNetwork 提供的 URL 只保证在这个回调期间有效，不能直接跨
                    // continuation 传给上层。必须在回调里马上移动到我们自己的临时目录。
                    let ownedURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("lynx-ota-download-\(UUID().uuidString).tmp")
                    do {
                        try FileManager.default.moveItem(at: temporaryURL, to: ownedURL)
                        continuation.resume(returning: (ownedURL, response))
                    } catch {
                        try? FileManager.default.removeItem(at: ownedURL)
                        continuation.resume(throwing: error)
                    }
                }
                state.install(task)
                task.resume()
            }
        } onCancel: {
            state.cancel()
        }
    }

}

public struct SHA256ChecksumValidator: OtaChecksumValidating {
    public init() {}

    public func sha256(for fileURL: URL) throws -> String {
        // OTA bundle 可能较大，按块读取避免把整个 release 一次性载入内存。
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        // read(upToCount:) 从 iOS 13.4 才可用；这里保持 CocoaPods 声明的 iOS 13.0 下限。
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return "sha256:\(hasher.finalize().compactMap { String(format: "%02x", $0) }.joined())"
    }
}

public struct ServerOtaAPIClient: OtaAPIClientProtocol {
    private static let otaClientTokenHeader = "x-ota-client-token"
    private let baseURL: URL
    private let otaClientToken: String
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL, otaClientToken: String = OtaDefaults.otaClientToken) {
        self.baseURL = baseURL
        self.otaClientToken = otaClientToken
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    public func checkForUpdate(_ request: OtaPolicyMatchRequest) async throws -> OtaPolicyMatchResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/ota/v1/policy/match", isDirectory: false))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)
        applyClientToken(to: &urlRequest)
        return try await send(urlRequest, as: OtaPolicyMatchResponse.self)
    }

    public func fetchManifest(
        releaseId: String,
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform
    ) async throws -> OtaReleaseManifest {
        let manifestURL = baseURL.appendingPathComponent("api/ota/v1/release/\(releaseId)/manifest", isDirectory: false)
        var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "env", value: env.rawValue),
            URLQueryItem(name: "hostApp", value: app.rawValue),
            URLQueryItem(name: "lynxAppId", value: lynxAppId),
            URLQueryItem(name: "platform", value: platform.rawValue)
        ]
        let url = components?.url ?? manifestURL
        var urlRequest = URLRequest(url: url)
        applyClientToken(to: &urlRequest)
        return try await send(urlRequest, as: OtaReleaseManifest.self)
    }

    public func fetchLatestBundleList(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform
    ) async throws -> OtaLatestBundleList {
        let latestURL = baseURL.appendingPathComponent("api/ota/v1/releases/latest-bundle-list", isDirectory: false)
        var components = URLComponents(url: latestURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "env", value: env.rawValue),
            URLQueryItem(name: "hostApp", value: app.rawValue),
            URLQueryItem(name: "lynxAppId", value: lynxAppId),
            URLQueryItem(name: "platform", value: platform.rawValue)
        ]
        let url = components?.url ?? latestURL
        var urlRequest = URLRequest(url: url)
        applyClientToken(to: &urlRequest)
        return try await send(urlRequest, as: OtaLatestBundleList.self)
    }

    public func fetchLatestBundleLists(
        env: OtaEnvironment,
        app: OtaAppID,
        platform: OtaPlatform
    ) async throws -> OtaHostLatestBundleLists {
        let latestURL = baseURL.appendingPathComponent("api/ota/v1/releases/latest-bundle-list", isDirectory: false)
        var components = URLComponents(url: latestURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "env", value: env.rawValue),
            URLQueryItem(name: "hostApp", value: app.rawValue),
            URLQueryItem(name: "platform", value: platform.rawValue)
        ]
        let url = components?.url ?? latestURL
        var urlRequest = URLRequest(url: url)
        applyClientToken(to: &urlRequest)
        return try await send(urlRequest, as: OtaHostLatestBundleLists.self)
    }

    public func reportEvent(_ payload: OtaReportPayload) async throws -> OtaReportResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/ota/v1/release/report", isDirectory: false))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(payload)
        applyClientToken(to: &urlRequest)
        return try await send(urlRequest, as: OtaReportResponse.self)
    }

    private func applyClientToken(to request: inout URLRequest) {
        request.setValue(otaClientToken, forHTTPHeaderField: Self.otaClientTokenHeader)
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OtaSDKError.invalidResponse(statusCode: -1, body: "Missing HTTPURLResponse")
        }
        guard 200..<300 ~= http.statusCode else {
            throw OtaSDKError.invalidResponse(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try decoder.decode(T.self, from: data)
    }
}
