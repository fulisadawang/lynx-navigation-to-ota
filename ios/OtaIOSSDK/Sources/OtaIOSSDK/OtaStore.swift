import Foundation

public enum OtaStoreVersion: String, Codable, Sendable {
    case v2
    case v3
}

/**
 * iOS OTA Store v2 的 storage root 描述。
 *
 * 历史版本的 `FileOtaReleaseStore` 同时维护多套 pointer 与全局 release 目录；Store v2 的
 * 读写已经全部收敛到 `CanonicalOtaStore`。这里保留旧类型名作为源码兼容入口，但不创建目录、
 * 不保存 current/staged/previous，也不复制 embedded Bundle bytes。
 */
public struct OtaStorageRoot: Sendable {
    public let baseDirectoryURL: URL
    public let version: OtaStoreVersion

    public init(baseDirectory: URL, version: OtaStoreVersion = .v2) {
        self.baseDirectoryURL = baseDirectory
        self.version = version
    }
}

public typealias FileOtaReleaseStore = OtaStorageRoot
