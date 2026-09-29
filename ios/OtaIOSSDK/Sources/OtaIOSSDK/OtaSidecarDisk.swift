import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum OtaSidecarDisk {
    static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hashName(_ value: String) throws -> String {
        guard value.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw OtaSidecarError.invalidManifest("SHA-256 格式不合法")
        }
        return String(value.dropFirst(7))
    }

    static func relativePath(_ value: String) throws -> String {
        guard !value.isEmpty, !value.hasPrefix("/"),
              !value.contains("\\"), !value.contains("\0"), !value.contains("?"),
              !value.contains("#"), !value.contains("%"), !value.contains(":"),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw OtaSidecarError.invalidManifest("资源路径不合法")
        }
        return value
    }

    static func requestKey(_ value: String) throws -> String {
        try relativePath(value.hasPrefix("/") ? String(value.dropFirst()) : value)
    }

    static func root(_ base: URL, appId: String, channel: String) throws -> URL {
        guard appId.range(of: "^[0-9]{8}$", options: .regularExpression) != nil else {
            throw OtaSidecarError.invalidManifest("App ID 不合法")
        }
        return base.appendingPathComponent("apps/\(appId)/\(channel)", isDirectory: true)
    }

    static func object(_ root: URL, sha256: String) throws -> URL {
        let hash = try hashName(sha256)
        return root.appendingPathComponent("objects/\(hash.prefix(2))/\(hash)")
    }

    static func verifiedData(_ file: URL, sha256: String, size: Int) throws -> Data {
        _ = try hashName(sha256)
        guard size > 0, size <= 20 * 1024 * 1024,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == size else {
            throw OtaSidecarError.missingLocalResource
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard digest(data) == sha256 else { throw OtaSidecarError.missingLocalResource }
        return data
    }

    /// 文件与父目录同步后才返回，避免 current 提交完成但资源尚未持久化。
    static func write(_ data: Data, to destination: URL, commit: (@Sendable (() throws -> Void) throws -> Void)? = nil) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        let renameFile = {
            guard rename(temporary.path, destination.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        // 身份检查和最终 rename 共用短锁；编码与文件同步不占用身份注册锁。
        if let commit { try commit(renameFile) } else { try renameFile() }
        let directory = open(parent.path, O_RDONLY)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = close(directory) }
        guard fsync(directory) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func fetch(url: URL, sha256: String, size: Int, root: URL, downloader: any OtaBundleDownloading) async throws -> URL {
        let destination = try object(root, sha256: sha256)
        if (try? verifiedData(destination, sha256: sha256, size: size)) != nil { return destination }
        let data = try await downloadData(url: url, sha256: sha256, size: size, root: root, downloader: downloader)
        try write(data, to: destination)
        return destination
    }

    static func downloadData(url: URL, sha256: String, size: Int, root: URL, downloader: any OtaBundleDownloading) async throws -> Data {
        guard size > 0, size <= 20 * 1024 * 1024 else {
            throw OtaSidecarError.invalidManifest("资源大小不合法")
        }
        let temporary = root.appendingPathComponent("downloads/\(UUID().uuidString).part")
        try FileManager.default.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await downloader.download(from: url, to: temporary)
        return try verifiedData(temporary, sha256: sha256, size: size)
    }
}
