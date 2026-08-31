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
    public let currentManifestId: String?
    public let previousManifestId: String?
    public let candidateReleaseId: String?
    public let candidateManifestId: String?
    public let candidateStatus: String?

    public init(
        generation: Int,
        currentReleaseId: String,
        currentKind: String,
        previousReleaseId: String?,
        previousKind: String?,
        currentManifestId: String? = nil,
        previousManifestId: String? = nil,
        candidateReleaseId: String? = nil,
        candidateManifestId: String? = nil,
        candidateStatus: String? = nil
    ) {
        self.generation = generation
        self.currentReleaseId = currentReleaseId
        self.currentKind = currentKind
        self.previousReleaseId = previousReleaseId
        self.previousKind = previousKind
        self.currentManifestId = currentManifestId
        self.previousManifestId = previousManifestId
        self.candidateReleaseId = candidateReleaseId
        self.candidateManifestId = candidateManifestId
        self.candidateStatus = candidateStatus
    }
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
    public let manifestId: String?
    public let bundleCount: Int
    public let objectIds: [String]

    public init(
        releaseId: String,
        roles: Set<OtaStorageReleaseRole>,
        totalBytes: Int64,
        fileCount: Int,
        manifestValid: Bool,
        files: [OtaStorageFileSnapshot],
        truncated: Bool,
        manifestId: String? = nil,
        bundleCount: Int = 0,
        objectIds: [String] = []
    ) {
        self.releaseId = releaseId
        self.roles = roles
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.manifestValid = manifestValid
        self.files = files
        self.truncated = truncated
        self.manifestId = manifestId
        self.bundleCount = bundleCount
        self.objectIds = objectIds
    }
}

public struct OtaStorageObjectSnapshot: Sendable {
    public let objectId: String
    public let byteCount: Int64
    public let roles: Set<OtaStorageReleaseRole>
    public let referencedReleaseIds: [String]

    public init(
        objectId: String,
        byteCount: Int64,
        roles: Set<OtaStorageReleaseRole> = [],
        referencedReleaseIds: [String] = []
    ) {
        self.objectId = objectId
        self.byteCount = byteCount
        self.roles = roles
        self.referencedReleaseIds = referencedReleaseIds
    }
}

public struct OtaStoreOperationMetrics: Sendable, Equatable {
    public let operation: String
    public let lynxAppId: String?
    public let releaseId: String?
    public let manifestId: String?
    public let downloadedBundleCount: Int
    public let downloadedBytes: Int64
    public let casWriteCount: Int
    public let casWriteBytes: Int64
    public let byteCopyCount: Int
    public let copiedBytes: Int64
    public let manifestWriteCount: Int
    public let stateCommitCount: Int
    public let objectCount: Int
    public let objectBytes: Int64
    public let recordedAt: Date

    public init(
        operation: String = "none",
        lynxAppId: String? = nil,
        releaseId: String? = nil,
        manifestId: String? = nil,
        downloadedBundleCount: Int = 0,
        downloadedBytes: Int64 = 0,
        casWriteCount: Int = 0,
        casWriteBytes: Int64 = 0,
        byteCopyCount: Int = 0,
        copiedBytes: Int64 = 0,
        manifestWriteCount: Int = 0,
        stateCommitCount: Int = 0,
        objectCount: Int = 0,
        objectBytes: Int64 = 0,
        recordedAt: Date = Date()
    ) {
        self.operation = operation
        self.lynxAppId = lynxAppId
        self.releaseId = releaseId
        self.manifestId = manifestId
        self.downloadedBundleCount = downloadedBundleCount
        self.downloadedBytes = downloadedBytes
        self.casWriteCount = casWriteCount
        self.casWriteBytes = casWriteBytes
        self.byteCopyCount = byteCopyCount
        self.copiedBytes = copiedBytes
        self.manifestWriteCount = manifestWriteCount
        self.stateCommitCount = stateCommitCount
        self.objectCount = objectCount
        self.objectBytes = objectBytes
        self.recordedAt = recordedAt
    }
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
    public let objects: [OtaStorageObjectSnapshot]
    public let objectCount: Int
    public let objectBytes: Int64
    public let manifestBytes: Int64
    public let lastOperation: OtaStoreOperationMetrics?

    public init(
        appId: String,
        state: OtaStorageStateSnapshot?,
        candidate: OtaStorageCandidateStateSnapshot?,
        releases: [OtaStorageReleaseSnapshot],
        staging: [OtaStorageStagingSnapshot],
        totalBytes: Int64,
        fileCount: Int,
        objects: [OtaStorageObjectSnapshot] = [],
        objectCount: Int = 0,
        objectBytes: Int64 = 0,
        manifestBytes: Int64 = 0,
        lastOperation: OtaStoreOperationMetrics? = nil
    ) {
        self.appId = appId
        self.state = state
        self.candidate = candidate
        self.releases = releases
        self.staging = staging
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.objects = objects
        self.objectCount = objectCount
        self.objectBytes = objectBytes
        self.manifestBytes = manifestBytes
        self.lastOperation = lastOperation
    }
}

public struct OtaStorageSnapshot: Sendable {
    public let rootPath: String
    public let totalBytes: Int64
    public let fileCount: Int
    public let generatedAt: Date
    public let apps: [OtaStorageAppSnapshot]
}
