import Foundation

public enum OtaEnvironment: String, Codable, CaseIterable, Sendable {
    case test = "TEST"
    case staging = "STAGING"
    case prod = "PROD"
}

public enum OtaAppID: String, Codable, CaseIterable, Sendable {
    case capp
    case gapp
}

public enum OtaDefaults {
    public static let lynxAppId = "10000000"
    public static let otaClientToken = "ota-client-token-v1-fixed"
}

public enum OtaPlatform: String, Codable, CaseIterable, Sendable {
    case android
    case ios
}

public enum OtaReleaseStatus: String, Codable, CaseIterable, Sendable {
    case draft = "DRAFT"
    case active = "ACTIVE"
    case disabled = "DISABLED"
    case rolledBack = "ROLLED_BACK"
}

public enum OtaReportEvent: String, Codable, CaseIterable, Sendable {
    case checkResult = "lynx_ota_check_result"
    case downloadSuccess = "lynx_bundle_download_success"
    case activate = "lynx_release_activate"
    case pageOpen = "lynx_page_open"
    case rollback = "lynx_release_rollback"
}

public enum OtaReasonCode: String, Codable, CaseIterable, Sendable {
    case baselineBlocked = "baseline_blocked"
    case manifestFetchFailed = "manifest_fetch_failed"
    case latestBundleListFetchFailed = "latest_bundle_list_fetch_failed"
    case latestBundleListDecodeFailed = "latest_bundle_list_decode_failed"
    case localBundleMissing = "local_bundle_missing"
    case bundleDownloadFailed = "bundle_download_failed"
    case bundleSizeFailed = "bundle_size_failed"
    case bundleChecksumFailed = "bundle_checksum_failed"
    case releaseActivateFailed = "release_activate_failed"
    case manualRollback = "manual_rollback"
    case serverRollbackRecovered = "server_rollback_recovered"
    case releaseDisabled = "release_disabled"
    case releaseRolledBack = "release_rolled_back"
    case invalidBundleURL = "invalid_bundle_url"
    case missingBundleSize = "missing_bundle_size"
    case bundleTooLarge = "bundle_too_large"
}

public enum OtaReportEventStage: String, Codable, CaseIterable, Sendable {
    case check = "CHECK"
    case match = "MATCH"
    case manifest = "MANIFEST"
    case download = "DOWNLOAD"
    case activate = "ACTIVATE"
    case pageOpen = "PAGE_OPEN"
    case rollback = "ROLLBACK"
}

public enum OtaReportEventResult: String, Codable, CaseIterable, Sendable {
    case success = "SUCCESS"
    case skipped = "SKIPPED"
    case failed = "FAILED"
}

public struct OtaReleaseVersionRange: Codable, Equatable, Sendable {
    public let min: String?
    public let max: String?

    public init(min: String? = nil, max: String? = nil) {
        self.min = min
        self.max = max
    }
}

public struct OtaBundleArtifact: Codable, Equatable, Sendable {
    public let pageId: Int
    /// 新契约使用 bundleName 定位资源；pageId 仅作为旧服务端/埋点兼容字段。
    public let bundleName: String
    public let bundlePath: String
    public let bundleSha256: String
    public let bundleURL: URL
    public let size: Int?

    enum CodingKeys: String, CodingKey {
        case pageId
        case bundleName
        case bundlePath
        case bundleSha256
        case bundleURL = "bundleUrl"
        case size
    }

    public init(pageId: Int, bundlePath: String, bundleSha256: String, bundleURL: URL, size: Int? = nil) {
        self.pageId = pageId
        self.bundleName = (bundlePath as NSString).lastPathComponent
        self.bundlePath = bundlePath
        self.bundleSha256 = bundleSha256
        self.bundleURL = bundleURL
        self.size = size
    }

    /// 新接口优先传 bundleName；pageId 默认 0，保持旧 pageId 字段可编码但不再参与加载。
    public init(
        bundleName: String,
        bundleSha256: String,
        bundleURL: URL,
        size: Int? = nil,
        pageId: Int = 0,
        bundlePath: String? = nil
    ) {
        self.pageId = pageId
        self.bundleName = bundleName
        self.bundlePath = bundlePath?.isEmpty == false ? bundlePath! : bundleName
        self.bundleSha256 = bundleSha256
        self.bundleURL = bundleURL
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageId = try container.decodeIfPresent(Int.self, forKey: .pageId) ?? 0
        let decodedPath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .bundleName)
        guard let name = decodedName?.isEmpty == false ? decodedName : decodedPath?.isEmpty == false ? (decodedPath! as NSString).lastPathComponent : nil,
              !name.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.bundleName,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "bundleName or bundlePath is required")
            )
        }
        bundleName = name
        bundlePath = decodedPath?.isEmpty == false ? decodedPath! : name
        bundleSha256 = try container.decode(String.self, forKey: .bundleSha256)
        bundleURL = try container.decode(URL.self, forKey: .bundleURL)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageId, forKey: .pageId)
        try container.encode(bundleName, forKey: .bundleName)
        try container.encode(bundlePath, forKey: .bundlePath)
        try container.encode(bundleSha256, forKey: .bundleSha256)
        try container.encode(bundleURL, forKey: .bundleURL)
        try container.encodeIfPresent(size, forKey: .size)
    }
}

public struct OtaReleaseManifest: Codable, Equatable, Sendable {
    public let env: OtaEnvironment
    public let app: OtaAppID
    public let lynxAppId: String
    public let releaseId: String
    public let platform: OtaPlatform
    public let platforms: [OtaPlatform]?
    public let status: OtaReleaseStatus
    public let bundles: [OtaBundleArtifact]

    enum CodingKeys: String, CodingKey {
        case env
        case app
        case hostApp
        case lynxAppId
        case releaseId
        case platform
        case platforms
        case status
        case bundles
    }

    public init(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String = OtaDefaults.lynxAppId,
        releaseId: String,
        platform: OtaPlatform,
        platforms: [OtaPlatform]? = nil,
        bundles: [OtaBundleArtifact],
        status: OtaReleaseStatus = .active
    ) {
        self.env = env
        self.app = app
        self.lynxAppId = lynxAppId
        self.releaseId = releaseId
        self.platform = platform
        self.platforms = platforms
        self.status = status
        self.bundles = bundles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        env = try container.decode(OtaEnvironment.self, forKey: .env)
        if let hostApp = try container.decodeIfPresent(OtaAppID.self, forKey: .hostApp) {
            app = hostApp
        } else {
            app = try container.decode(OtaAppID.self, forKey: .app)
        }
        lynxAppId = try container.decodeIfPresent(String.self, forKey: .lynxAppId) ?? OtaDefaults.lynxAppId
        releaseId = try container.decode(String.self, forKey: .releaseId)
        platform = try container.decode(OtaPlatform.self, forKey: .platform)
        platforms = try container.decodeIfPresent([OtaPlatform].self, forKey: .platforms)
        status = try container.decode(OtaReleaseStatus.self, forKey: .status)
        bundles = try container.decode([OtaBundleArtifact].self, forKey: .bundles)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(env, forKey: .env)
        try container.encode(app, forKey: .hostApp)
        try container.encode(lynxAppId, forKey: .lynxAppId)
        try container.encode(releaseId, forKey: .releaseId)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(platforms, forKey: .platforms)
        try container.encode(status, forKey: .status)
        try container.encode(bundles, forKey: .bundles)
    }
}

public struct OtaPolicyMatchRequest: Codable, Sendable {
    public let env: OtaEnvironment
    public let app: OtaAppID
    public let lynxAppId: String
    public let platform: OtaPlatform
    public let appVersion: String
    public let buildNumber: String
    public let osVersion: String?
    public let channel: String?
    public let region: String?
    public let userId: String?
    public let deviceId: String?
    public let pageId: Int
    public let bundleName: String?
    public let nativeProtocolVersion: String?
    public let lynxSdkVersion: String?

    enum CodingKeys: String, CodingKey {
        case env
        case hostApp
        case lynxAppId
        case platform
        case appVersion
        case buildNumber
        case osVersion
        case channel
        case region
        case userId
        case deviceId
        case pageId
        case bundleName
        case nativeProtocolVersion
        case lynxSdkVersion
    }

    public init(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        platform: OtaPlatform,
        appVersion: String,
        buildNumber: String,
        osVersion: String?,
        channel: String?,
        region: String?,
        userId: String?,
        deviceId: String?,
        pageId: Int,
        bundleName: String? = nil,
        nativeProtocolVersion: String?,
        lynxSdkVersion: String?
    ) {
        self.env = env
        self.app = app
        self.lynxAppId = lynxAppId
        self.platform = platform
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.channel = channel
        self.region = region
        self.userId = userId
        self.deviceId = deviceId
        self.pageId = pageId
        self.bundleName = bundleName
        self.nativeProtocolVersion = nativeProtocolVersion
        self.lynxSdkVersion = lynxSdkVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        env = try container.decode(OtaEnvironment.self, forKey: .env)
        app = try container.decode(OtaAppID.self, forKey: .hostApp)
        lynxAppId = try container.decode(String.self, forKey: .lynxAppId)
        platform = try container.decode(OtaPlatform.self, forKey: .platform)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        // 新 bundleName 入口可以不带旧 pageId；内部用 0 表示兼容缺省。
        pageId = try container.decodeIfPresent(Int.self, forKey: .pageId) ?? 0
        bundleName = try container.decodeIfPresent(String.self, forKey: .bundleName)
        nativeProtocolVersion = try container.decodeIfPresent(String.self, forKey: .nativeProtocolVersion)
        lynxSdkVersion = try container.decodeIfPresent(String.self, forKey: .lynxSdkVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(env, forKey: .env)
        try container.encode(app, forKey: .hostApp)
        try container.encode(lynxAppId, forKey: .lynxAppId)
        try container.encode(platform, forKey: .platform)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(buildNumber, forKey: .buildNumber)
        try container.encodeIfPresent(osVersion, forKey: .osVersion)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encode(pageId, forKey: .pageId)
        try container.encodeIfPresent(bundleName, forKey: .bundleName)
        try container.encodeIfPresent(nativeProtocolVersion, forKey: .nativeProtocolVersion)
        try container.encodeIfPresent(lynxSdkVersion, forKey: .lynxSdkVersion)
    }
}

public struct OtaPolicyMatchResponse: Codable, Equatable, Sendable {
    public let matched: Bool
    public let releaseId: String?
    public let manifestURL: URL?
    public let ruleId: String?

    enum CodingKeys: String, CodingKey {
        case matched
        case releaseId
        case manifestURL = "manifestUrl"
        case ruleId
    }

    public init(
        matched: Bool,
        releaseId: String? = nil,
        manifestURL: URL? = nil,
        ruleId: String? = nil
    ) {
        self.matched = matched
        self.releaseId = releaseId
        self.manifestURL = manifestURL
        self.ruleId = ruleId
    }
}

public struct OtaCurrentReleaseContext: Codable, Equatable, Sendable {
    public let env: OtaEnvironment
    public let app: OtaAppID
    public let lynxAppId: String
    public let releaseId: String
    public let platform: OtaPlatform
    public let status: OtaReleaseStatus

    enum CodingKeys: String, CodingKey {
        case env
        case app
        case hostApp
        case lynxAppId
        case releaseId
        case platform
        case status
    }

    public init(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String = OtaDefaults.lynxAppId,
        releaseId: String,
        platform: OtaPlatform,
        status: OtaReleaseStatus
    ) {
        self.env = env
        self.app = app
        self.lynxAppId = lynxAppId
        self.releaseId = releaseId
        self.platform = platform
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        env = try container.decode(OtaEnvironment.self, forKey: .env)
        if let hostApp = try container.decodeIfPresent(OtaAppID.self, forKey: .hostApp) {
            app = hostApp
        } else {
            app = try container.decode(OtaAppID.self, forKey: .app)
        }
        lynxAppId = try container.decodeIfPresent(String.self, forKey: .lynxAppId) ?? OtaDefaults.lynxAppId
        releaseId = try container.decode(String.self, forKey: .releaseId)
        platform = try container.decode(OtaPlatform.self, forKey: .platform)
        status = try container.decode(OtaReleaseStatus.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(env, forKey: .env)
        try container.encode(app, forKey: .hostApp)
        try container.encode(lynxAppId, forKey: .lynxAppId)
        try container.encode(releaseId, forKey: .releaseId)
        try container.encode(platform, forKey: .platform)
        try container.encode(status, forKey: .status)
    }
}

public struct OtaInstalledBundle: Codable, Equatable, Sendable {
    public let pageId: Int
    /// bundleName 是运行时主索引；bundlePath/localFilePath 保留旧存储和宿主兼容。
    public let bundleName: String
    public let bundlePath: String
    public let bundleSha256: String
    public let remoteURL: URL
    public let localFilePath: String

    public init(
        pageId: Int,
        bundlePath: String,
        bundleSha256: String,
        remoteURL: URL,
        localFilePath: String
    ) {
        self.pageId = pageId
        self.bundleName = (bundlePath as NSString).lastPathComponent
        self.bundlePath = bundlePath
        self.bundleSha256 = bundleSha256
        self.remoteURL = remoteURL
        self.localFilePath = localFilePath
    }

    public init(
        bundleName: String,
        bundleSha256: String,
        remoteURL: URL,
        localFilePath: String,
        pageId: Int = 0,
        bundlePath: String? = nil
    ) {
        self.pageId = pageId
        self.bundleName = bundleName
        self.bundlePath = bundlePath?.isEmpty == false ? bundlePath! : bundleName
        self.bundleSha256 = bundleSha256
        self.remoteURL = remoteURL
        self.localFilePath = localFilePath
    }

    enum CodingKeys: String, CodingKey {
        case pageId
        case bundleName
        case bundlePath
        case bundleSha256
        case remoteURL
        case localFilePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageId = try container.decodeIfPresent(Int.self, forKey: .pageId) ?? 0
        let decodedPath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .bundleName)
        guard let name = decodedName?.isEmpty == false ? decodedName : decodedPath?.isEmpty == false ? (decodedPath! as NSString).lastPathComponent : nil,
              !name.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.bundleName,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "bundleName or bundlePath is required")
            )
        }
        bundleName = name
        bundlePath = decodedPath?.isEmpty == false ? decodedPath! : name
        bundleSha256 = try container.decode(String.self, forKey: .bundleSha256)
        remoteURL = try container.decode(URL.self, forKey: .remoteURL)
        localFilePath = try container.decode(String.self, forKey: .localFilePath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageId, forKey: .pageId)
        try container.encode(bundleName, forKey: .bundleName)
        try container.encode(bundlePath, forKey: .bundlePath)
        try container.encode(bundleSha256, forKey: .bundleSha256)
        try container.encode(remoteURL, forKey: .remoteURL)
        try container.encode(localFilePath, forKey: .localFilePath)
    }
}

public struct OtaInstalledRelease: Codable, Equatable, Sendable {
    public let context: OtaCurrentReleaseContext
    public let installedAt: Date
    public let bundles: [OtaInstalledBundle]

    public init(context: OtaCurrentReleaseContext, installedAt: Date, bundles: [OtaInstalledBundle]) {
        self.context = context
        self.installedAt = installedAt
        self.bundles = bundles
    }
}

public struct OtaCheckRequest: Sendable {
    public let pageId: Int
    public let bundleName: String?
    public let userId: String?
    public let deviceId: String?
    public let osVersion: String?
    public let channel: String?
    public let region: String?
    public let nativeProtocolVersion: String?
    public let lynxSdkVersion: String?

    public init(
        pageId: Int,
        bundleName: String? = nil,
        userId: String? = nil,
        deviceId: String? = nil,
        osVersion: String? = nil,
        channel: String? = nil,
        region: String? = nil,
        nativeProtocolVersion: String? = nil,
        lynxSdkVersion: String? = nil
    ) {
        self.pageId = pageId
        self.bundleName = bundleName
        self.userId = userId
        self.deviceId = deviceId
        self.osVersion = osVersion
        self.channel = channel
        self.region = region
        self.nativeProtocolVersion = nativeProtocolVersion
        self.lynxSdkVersion = lynxSdkVersion
    }
}

public struct OtaReportPayload: Codable, Sendable {
    public let env: OtaEnvironment
    public let app: OtaAppID
    public let lynxAppId: String
    public let releaseId: String?
    public let platform: OtaPlatform
    public let event: OtaReportEvent
    public let pageId: Int?
    public let userId: String?
    public let deviceId: String?
    public let deviceModel: String?
    public let appVersion: String?
    public let buildNumber: String?
    public let osVersion: String?
    public let channel: String?
    public let region: String?
    public let nativeProtocolVersion: String?
    public let lynxSdkVersion: String?
    public let bundlePath: String?
    public let bundleName: String?
    public let bundleSha256: String?
    public let bundleSize: Int?
    public let eventStage: OtaReportEventStage?
    public let eventResult: OtaReportEventResult?
    public let reasonCode: String?
    public let reasonMessage: String?
    public let fromReleaseId: String?
    public let toReleaseId: String?
    public let latencyMs: Int?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case env
        case hostApp
        case lynxAppId
        case releaseId
        case platform
        case event
        case pageId
        case userId
        case deviceId
        case deviceModel
        case appVersion
        case buildNumber
        case osVersion
        case channel
        case region
        case nativeProtocolVersion
        case lynxSdkVersion
        case bundlePath
        case bundleName
        case bundleSha256
        case bundleSize
        case eventStage
        case eventResult
        case reasonCode
        case reasonMessage
        case fromReleaseId
        case toReleaseId
        case latencyMs
        case message
    }

    public init(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String,
        releaseId: String?,
        platform: OtaPlatform,
        event: OtaReportEvent,
        pageId: Int?,
        userId: String? = nil,
        deviceId: String? = nil,
        deviceModel: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        osVersion: String? = nil,
        channel: String? = nil,
        region: String? = nil,
        nativeProtocolVersion: String? = nil,
        lynxSdkVersion: String? = nil,
        bundlePath: String? = nil,
        bundleName: String? = nil,
        bundleSha256: String? = nil,
        bundleSize: Int? = nil,
        eventStage: OtaReportEventStage? = nil,
        eventResult: OtaReportEventResult? = nil,
        reasonCode: String? = nil,
        reasonMessage: String? = nil,
        fromReleaseId: String? = nil,
        toReleaseId: String? = nil,
        latencyMs: Int? = nil,
        message: String?
    ) {
        self.env = env
        self.app = app
        self.lynxAppId = lynxAppId
        self.releaseId = releaseId
        self.platform = platform
        self.event = event
        self.pageId = pageId
        self.userId = userId
        self.deviceId = deviceId
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.channel = channel
        self.region = region
        self.nativeProtocolVersion = nativeProtocolVersion
        self.lynxSdkVersion = lynxSdkVersion
        self.bundlePath = bundlePath
        self.bundleName = bundleName
        self.bundleSha256 = bundleSha256
        self.bundleSize = bundleSize
        self.eventStage = eventStage
        self.eventResult = eventResult
        self.reasonCode = reasonCode
        self.reasonMessage = reasonMessage
        self.fromReleaseId = fromReleaseId
        self.toReleaseId = toReleaseId
        self.latencyMs = latencyMs
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        env = try container.decode(OtaEnvironment.self, forKey: .env)
        app = try container.decode(OtaAppID.self, forKey: .hostApp)
        lynxAppId = try container.decode(String.self, forKey: .lynxAppId)
        releaseId = try container.decodeIfPresent(String.self, forKey: .releaseId)
        platform = try container.decode(OtaPlatform.self, forKey: .platform)
        event = try container.decode(OtaReportEvent.self, forKey: .event)
        pageId = try container.decodeIfPresent(Int.self, forKey: .pageId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        buildNumber = try container.decodeIfPresent(String.self, forKey: .buildNumber)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        nativeProtocolVersion = try container.decodeIfPresent(String.self, forKey: .nativeProtocolVersion)
        lynxSdkVersion = try container.decodeIfPresent(String.self, forKey: .lynxSdkVersion)
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
        bundleName = try container.decodeIfPresent(String.self, forKey: .bundleName)
        bundleSha256 = try container.decodeIfPresent(String.self, forKey: .bundleSha256)
        bundleSize = try container.decodeIfPresent(Int.self, forKey: .bundleSize)
        eventStage = try container.decodeIfPresent(OtaReportEventStage.self, forKey: .eventStage)
        eventResult = try container.decodeIfPresent(OtaReportEventResult.self, forKey: .eventResult)
        reasonCode = try container.decodeIfPresent(String.self, forKey: .reasonCode)
        reasonMessage = try container.decodeIfPresent(String.self, forKey: .reasonMessage)
        fromReleaseId = try container.decodeIfPresent(String.self, forKey: .fromReleaseId)
        toReleaseId = try container.decodeIfPresent(String.self, forKey: .toReleaseId)
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(env, forKey: .env)
        try container.encode(app, forKey: .hostApp)
        try container.encode(lynxAppId, forKey: .lynxAppId)
        try container.encodeIfPresent(releaseId, forKey: .releaseId)
        try container.encode(platform, forKey: .platform)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(pageId, forKey: .pageId)
        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encodeIfPresent(deviceModel, forKey: .deviceModel)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(buildNumber, forKey: .buildNumber)
        try container.encodeIfPresent(osVersion, forKey: .osVersion)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encodeIfPresent(nativeProtocolVersion, forKey: .nativeProtocolVersion)
        try container.encodeIfPresent(lynxSdkVersion, forKey: .lynxSdkVersion)
        try container.encodeIfPresent(bundlePath, forKey: .bundlePath)
        try container.encodeIfPresent(bundleName, forKey: .bundleName)
        try container.encodeIfPresent(bundleSha256, forKey: .bundleSha256)
        try container.encodeIfPresent(bundleSize, forKey: .bundleSize)
        try container.encodeIfPresent(eventStage, forKey: .eventStage)
        try container.encodeIfPresent(eventResult, forKey: .eventResult)
        try container.encodeIfPresent(reasonCode, forKey: .reasonCode)
        try container.encodeIfPresent(reasonMessage, forKey: .reasonMessage)
        try container.encodeIfPresent(fromReleaseId, forKey: .fromReleaseId)
        try container.encodeIfPresent(toReleaseId, forKey: .toReleaseId)
        try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

public struct OtaReportResponse: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let releaseId: String?
    public let event: OtaReportEvent

    public init(accepted: Bool, releaseId: String? = nil, event: OtaReportEvent) {
        self.accepted = accepted
        self.releaseId = releaseId
        self.event = event
    }
}

public enum OtaCandidateStatus: String, Codable, Equatable, Sendable {
    case pending
    case trial
}

/// 已完成下载和文件校验、但还没有替换 current 的候选 Release。
public struct OtaCandidateSnapshot: Equatable, Sendable {
    public let release: OtaInstalledRelease
    public let status: OtaCandidateStatus
    public let failureCount: Int
    public let createdAt: Date
    public let trialStartedAt: Date?

    public init(
        release: OtaInstalledRelease,
        status: OtaCandidateStatus,
        failureCount: Int = 0,
        createdAt: Date,
        trialStartedAt: Date? = nil
    ) {
        self.release = release
        self.status = status
        self.failureCount = failureCount
        self.createdAt = createdAt
        self.trialStartedAt = trialStartedAt
    }
}

public enum OtaUpdateResult: Equatable, Sendable {
    case noUpdate(current: OtaInstalledRelease?)
    case alreadyActive(OtaInstalledRelease)
    case updated(from: OtaInstalledRelease?, to: OtaInstalledRelease)
    case candidate(from: OtaInstalledRelease?, candidate: OtaCandidateSnapshot)
}

public struct OtaBundleSyncSummary: Equatable, Sendable {
    public let releaseId: String
    public let totalBundleCount: Int
    public let downloadedBundleCount: Int
    public let reusedBundleCount: Int

    public init(releaseId: String, totalBundleCount: Int, downloadedBundleCount: Int, reusedBundleCount: Int) {
        self.releaseId = releaseId
        self.totalBundleCount = totalBundleCount
        self.downloadedBundleCount = downloadedBundleCount
        self.reusedBundleCount = reusedBundleCount
    }
}

public enum OtaLatestBundleListUpdateResult: Equatable, Sendable {
    case noRelease(current: OtaInstalledRelease?)
    case alreadyActive(OtaInstalledRelease)
    case skipped(current: OtaInstalledRelease?, message: String)
    case updated(from: OtaInstalledRelease?, to: OtaInstalledRelease, summary: OtaBundleSyncSummary)
    case candidate(from: OtaInstalledRelease?, candidate: OtaCandidateSnapshot, summary: OtaBundleSyncSummary)
}

public struct OtaHostLatestBundleLists: Codable, Equatable, Sendable {
    public let env: OtaEnvironment
    public let app: OtaAppID
    public let platform: OtaPlatform?
    public let bundleLists: [OtaLatestBundleList]

    enum CodingKeys: String, CodingKey {
        case env
        case app
        case hostApp
        case platform
        case bundleLists
    }

    public init(
        env: OtaEnvironment,
        app: OtaAppID,
        platform: OtaPlatform? = nil,
        bundleLists: [OtaLatestBundleList]
    ) {
        self.env = env
        self.app = app
        self.platform = platform
        self.bundleLists = bundleLists
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        env = try container.decode(OtaEnvironment.self, forKey: .env)
        if let hostApp = try container.decodeIfPresent(OtaAppID.self, forKey: .hostApp) {
            app = hostApp
        } else {
            app = try container.decode(OtaAppID.self, forKey: .app)
        }
        platform = try container.decodeIfPresent(OtaPlatform.self, forKey: .platform)
        bundleLists = try container.decode([OtaLatestBundleList].self, forKey: .bundleLists)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(env, forKey: .env)
        try container.encode(app, forKey: .hostApp)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encode(bundleLists, forKey: .bundleLists)
    }
}

public struct OtaHostBundleListSyncResult: Equatable, Sendable {
    public let results: [String: OtaLatestBundleListUpdateResult]

    public init(results: [String: OtaLatestBundleListUpdateResult]) {
        self.results = results
    }

    public var updatedCount: Int {
        results.values.filter {
            if case .updated = $0 {
                return true
            }
            return false
        }.count
    }

    public var alreadyActiveCount: Int {
        results.values.filter {
            if case .alreadyActive = $0 {
                return true
            }
            return false
        }.count
    }

    public var skippedCount: Int {
        results.values.filter {
            if case .skipped = $0 {
                return true
            }
            return false
        }.count
    }
}

public struct OtaLatestBundleList: Codable, Equatable, Sendable {
    public let env: OtaEnvironment
    public let app: OtaAppID
    public let lynxAppId: String
    public let releaseId: String
    public let platform: OtaPlatform
    public let platforms: [OtaPlatform]?
    public let status: OtaReleaseStatus
    public let updatedAt: String?
    public let minAppVersion: String?
    public let maxAppVersion: String?
    public let lynxSdkRange: OtaReleaseVersionRange?
    public let nativeProtocolVersionRange: OtaReleaseVersionRange?
    public let changedBundles: [OtaBundleArtifact]

    enum CodingKeys: String, CodingKey {
        case env
        case app
        case hostApp
        case lynxAppId
        case releaseId
        case platform
        case platforms
        case status
        case updatedAt
        case minAppVersion
        case maxAppVersion
        case lynxSdkRange
        case nativeProtocolVersionRange
        case changedBundles
    }

    public init(
        env: OtaEnvironment,
        app: OtaAppID,
        lynxAppId: String = OtaDefaults.lynxAppId,
        releaseId: String,
        platform: OtaPlatform,
        platforms: [OtaPlatform]? = nil,
        status: OtaReleaseStatus,
        updatedAt: String? = nil,
        minAppVersion: String? = nil,
        maxAppVersion: String? = nil,
        lynxSdkRange: OtaReleaseVersionRange? = nil,
        nativeProtocolVersionRange: OtaReleaseVersionRange? = nil,
        changedBundles: [OtaBundleArtifact]
    ) {
        self.env = env
        self.app = app
        self.lynxAppId = lynxAppId
        self.releaseId = releaseId
        self.platform = platform
        self.platforms = platforms
        self.status = status
        self.updatedAt = updatedAt
        self.minAppVersion = minAppVersion
        self.maxAppVersion = maxAppVersion
        self.lynxSdkRange = lynxSdkRange
        self.nativeProtocolVersionRange = nativeProtocolVersionRange
        self.changedBundles = changedBundles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        env = try container.decode(OtaEnvironment.self, forKey: .env)
        if let hostApp = try container.decodeIfPresent(OtaAppID.self, forKey: .hostApp) {
            app = hostApp
        } else {
            app = try container.decode(OtaAppID.self, forKey: .app)
        }
        lynxAppId = try container.decodeIfPresent(String.self, forKey: .lynxAppId) ?? OtaDefaults.lynxAppId
        releaseId = try container.decode(String.self, forKey: .releaseId)
        platform = try container.decode(OtaPlatform.self, forKey: .platform)
        platforms = try container.decodeIfPresent([OtaPlatform].self, forKey: .platforms)
        status = try container.decode(OtaReleaseStatus.self, forKey: .status)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion)
        maxAppVersion = try container.decodeIfPresent(String.self, forKey: .maxAppVersion)
        lynxSdkRange = try container.decodeIfPresent(OtaReleaseVersionRange.self, forKey: .lynxSdkRange)
        nativeProtocolVersionRange = try container.decodeIfPresent(OtaReleaseVersionRange.self, forKey: .nativeProtocolVersionRange)
        changedBundles = try container.decode([OtaBundleArtifact].self, forKey: .changedBundles)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(env, forKey: .env)
        try container.encode(app, forKey: .hostApp)
        try container.encode(lynxAppId, forKey: .lynxAppId)
        try container.encode(releaseId, forKey: .releaseId)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(platforms, forKey: .platforms)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(minAppVersion, forKey: .minAppVersion)
        try container.encodeIfPresent(maxAppVersion, forKey: .maxAppVersion)
        try container.encodeIfPresent(lynxSdkRange, forKey: .lynxSdkRange)
        try container.encodeIfPresent(nativeProtocolVersionRange, forKey: .nativeProtocolVersionRange)
        try container.encode(changedBundles, forKey: .changedBundles)
    }

    public func asManifest() -> OtaReleaseManifest {
        OtaReleaseManifest(
            env: env,
            app: app,
            lynxAppId: lynxAppId,
            releaseId: releaseId,
            platform: platform,
            platforms: platforms,
            bundles: changedBundles,
            status: status
        )
    }
}

public enum OtaLifecycleState: Equatable, Sendable {
    case idle(current: OtaCurrentReleaseContext?)
    case checking(current: OtaCurrentReleaseContext?)
    case downloading(releaseId: String)
    case validating(releaseId: String)
    case ready(releaseId: String)
    case candidate(releaseId: String)
    case trial(releaseId: String)
    case activating(releaseId: String)
    case active(OtaCurrentReleaseContext)
    case rollingBack(fromReleaseId: String?, toReleaseId: String?)
    case failed(step: String, message: String)
}

public struct OtaSDKConfiguration: Sendable {
    public let apiBaseURL: URL
    public let app: OtaAppID
    public let lynxAppId: String
    public let environment: OtaEnvironment
    public let platform: OtaPlatform
    public let appVersion: String
    public let buildNumber: String
    public let userId: String?
    public let deviceId: String?
    public let deviceModel: String?
    public let osVersion: String?
    public let channel: String?
    public let region: String?
    public let nativeProtocolVersion: String?
    public let lynxSdkVersion: String?
    public let otaClientToken: String
    public let storageDirectory: URL
    /// 开启后下载校验只写 candidate/trial，健康确认后才 promote 到 current。
    public let candidateActivationEnabled: Bool
    /// 低层 SDK 默认保留 v2 兼容；宿主的 LynxOtaConfiguration 默认切到 v3。
    public let storeVersion: OtaStoreVersion
    /// 仅供 TEST 环境连接 loopback 本地 OTA fixture；Release 必须保持 false。
    public let allowLocalHTTPForTest: Bool

    public init(
        apiBaseURL: URL,
        app: OtaAppID,
        lynxAppId: String = OtaDefaults.lynxAppId,
        environment: OtaEnvironment,
        platform: OtaPlatform = .ios,
        appVersion: String,
        buildNumber: String,
        userId: String? = nil,
        deviceId: String? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil,
        channel: String? = nil,
        region: String? = nil,
        nativeProtocolVersion: String? = nil,
        lynxSdkVersion: String? = nil,
        otaClientToken: String = OtaDefaults.otaClientToken,
        storageDirectory: URL? = nil,
        candidateActivationEnabled: Bool = false,
        storeVersion: OtaStoreVersion = .v2,
        allowLocalHTTPForTest: Bool = false
    ) {
        self.apiBaseURL = apiBaseURL
        self.app = app
        self.lynxAppId = lynxAppId
        self.environment = environment
        self.platform = platform
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.userId = userId
        self.deviceId = deviceId
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.channel = channel
        self.region = region
        self.nativeProtocolVersion = nativeProtocolVersion
        self.lynxSdkVersion = lynxSdkVersion
        self.otaClientToken = otaClientToken
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ota-ios-sdk", isDirectory: true)
        self.candidateActivationEnabled = candidateActivationEnabled
        self.storeVersion = storeVersion
        self.allowLocalHTTPForTest = allowLocalHTTPForTest
    }
}
