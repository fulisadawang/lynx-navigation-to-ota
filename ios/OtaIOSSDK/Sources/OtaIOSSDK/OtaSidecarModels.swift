import Foundation

public struct OtaAsyncManifestReference: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let url: URL
    public let sha256: String
    public let size: Int

    public init(schemaVersion: Int = 1, url: URL, sha256: String, size: Int) {
        self.schemaVersion = schemaVersion
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

public struct OtaAsyncResource: Codable, Equatable, Sendable {
    public let ownerBundlePath: String
    public let requestKey: String
    public let path: String
    public let url: URL
    public let sha256: String
    public let size: Int
    public let kind: String
}

public struct OtaAsyncManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let entries: [OtaAsyncResource]
}

public enum OtaSidecarError: Error, LocalizedError, Sendable {
    case invalidManifest(String)
    case missingLocalResource
    case unknownRequest
    case resourcesClosed

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "异步资源清单不合法：\(reason)"
        case .missingLocalResource: return "已激活版本的本地资源缺失或损坏"
        case .unknownRequest: return "当前页面版本没有声明该异步资源请求"
        case .resourcesClosed: return "当前页面已关闭，不能再读取附属资源"
        }
    }
}
