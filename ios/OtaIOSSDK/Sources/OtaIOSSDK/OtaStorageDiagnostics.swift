import Foundation

public enum OtaStorageReleaseRole: String, Sendable, Hashable {
    case current
    case previous
    case candidate
    case leased
    case orphan
}

public struct OtaStorageFileSnapshot: Sendable {
    public let relativePath: String
    public let byteCount: Int64
    public let modifiedAt: Date
}

public struct OtaStorageStateSnapshot: Sendable {
    public let generation: Int
    public let currentReleaseId: String
    public let currentKind: String
    public let previousReleaseId: String?
    public let previousKind: String?
}

public struct OtaStorageCandidateStateSnapshot: Sendable {
    public let releaseId: String
    public let status: String
    public let failureCount: Int
}

public struct OtaStorageReleaseSnapshot: Sendable {
    public let releaseId: String
    public let roles: Set<OtaStorageReleaseRole>
    public let totalBytes: Int64
    public let fileCount: Int
    public let manifestValid: Bool
    public let files: [OtaStorageFileSnapshot]
    public let truncated: Bool
}

public struct OtaStorageStagingSnapshot: Sendable {
    public let transactionName: String
    public let totalBytes: Int64
    public let fileCount: Int
    public let files: [OtaStorageFileSnapshot]
    public let truncated: Bool
}

public struct OtaStorageAppSnapshot: Sendable {
    public let appId: String
    public let state: OtaStorageStateSnapshot?
    public let candidate: OtaStorageCandidateStateSnapshot?
    public let releases: [OtaStorageReleaseSnapshot]
    public let staging: [OtaStorageStagingSnapshot]
    public let totalBytes: Int64
    public let fileCount: Int
}

public struct OtaStorageSnapshot: Sendable {
    public let rootPath: String
    public let totalBytes: Int64
    public let fileCount: Int
    public let generatedAt: Date
    public let apps: [OtaStorageAppSnapshot]
}
