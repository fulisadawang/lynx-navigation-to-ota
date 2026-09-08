import Foundation
import CryptoKit

public enum OtaSelectionError: Error, Equatable, Sendable {
    case invalidUserId
    case invalidVersionCode
    case invalidSDKVersion
    case missingSelectionMetadata
    case invalidSelectionMetadata
    case incompatibleRelease
    case staleIdentity
    case staleDecision
    case staleCandidate
    case requiresStoreV3
}

public struct OtaVersionCodeRange: Codable, Equatable, Sendable {
    public let min: String?
    public let max: String?
    public init(min: String? = nil, max: String? = nil) { self.min = min; self.max = max }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: OtaRangeKey.self)
        try OtaRangeKey.validate(values)
        min = try values.decodeIfPresent(String.self, forKey: .init("min"))
        max = try values.decodeIfPresent(String.self, forKey: .init("max"))
    }
}

struct OtaRangeKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func validate(_ values: KeyedDecodingContainer<OtaRangeKey>) throws {
        for key in values.allKeys {
            guard ["min", "max"].contains(key.stringValue), try !values.decodeNil(forKey: key) else {
                throw OtaSelectionError.invalidSelectionMetadata
            }
        }
    }
}

public enum OtaSelectionKind: String, Codable, Sendable { case full, gray }

public struct OtaSelectionMetadata: Codable, Equatable, Sendable {
    public let kind: OtaSelectionKind
    public let ruleId: String?
    public let policyRevision: String
    public let reason: String
    public init(kind: OtaSelectionKind, ruleId: String? = nil, policyRevision: String, reason: String) {
        self.kind = kind; self.ruleId = ruleId; self.policyRevision = policyRevision; self.reason = reason
    }
}

public struct OtaStoredSelection: Codable, Equatable, Sendable {
    public let kind: OtaSelectionKind
    public let audienceKey: String?
    public let ruleId: String?
    public let releaseSequence: String
    public let policyRevision: String
    public let versionCodeRange: OtaVersionCodeRange?
    public let lynxSdkRange: OtaReleaseVersionRange?
    public let minAppVersion: String?
    public let maxAppVersion: String?
    public let nativeProtocolVersionRange: OtaReleaseVersionRange?

    public init(latest: OtaLatestBundleList, context: OtaUserContext) throws {
        try self.init(validatingProtocol: latest, context: context)
        guard isCompatible(with: context) else { throw OtaSelectionError.incompatibleRelease }
    }

    init(validatingProtocol latest: OtaLatestBundleList, context: OtaUserContext) throws {
        guard latest.selectionSchemaVersion == 1, let metadata = latest.selection,
              let sequence = latest.releaseSequence else { throw OtaSelectionError.missingSelectionMetadata }
        _ = try OtaSelectionValidation.decimal(sequence)
        _ = try OtaSelectionValidation.decimal(metadata.policyRevision, allowZero: true)
        guard ["latest_full", "matched_gray", "server_rollback"].contains(metadata.reason),
              metadata.kind != .gray || (context.userId != nil && metadata.ruleId?.isEmpty == false) else {
            throw OtaSelectionError.invalidSelectionMetadata
        }
        kind = metadata.kind; audienceKey = kind == .gray ? context.audienceKey : nil
        ruleId = metadata.ruleId; releaseSequence = sequence; policyRevision = metadata.policyRevision
        versionCodeRange = latest.versionCodeRange; lynxSdkRange = latest.lynxSdkRange
        minAppVersion = latest.minAppVersion; maxAppVersion = latest.maxAppVersion
        nativeProtocolVersionRange = latest.nativeProtocolVersionRange
        try OtaSelectionValidation.validateCodeRange(versionCodeRange)
        try OtaSelectionValidation.validateSDKRange(lynxSdkRange)
    }

    func isCompatible(with context: OtaUserContext) -> Bool {
        guard (try? OtaSelectionValidation.decimal(releaseSequence)) != nil,
              (try? OtaSelectionValidation.decimal(policyRevision, allowZero: true)) != nil else { return false }
        guard kind != .gray || (context.userId != nil && audienceKey == context.audienceKey) else { return false }
        return OtaSelectionValidation.matchesCode(context.versionCode, range: versionCodeRange)
            && OtaSelectionValidation.matchesVersion(context.lynxSdkVersion, range: lynxSdkRange, strict: true)
            && OtaSelectionValidation.matchesVersion(context.appVersion, range: .init(min: minAppVersion, max: maxAppVersion))
            && OtaSelectionValidation.matchesVersion(context.nativeProtocolVersion, range: nativeProtocolVersionRange)
    }
}

public enum OtaSelectionAction: String, Codable, Sendable {
    case useRelease = "use_release"
    case useEmbedded = "use_embedded"
    case noCompatibleRelease = "no_compatible_release"
}

public struct OtaSelectionDirective: Codable, Equatable, Sendable {
    public let lynxAppId: String
    public let action: OtaSelectionAction
    public let policyRevision: String
    public let reason: String
    public init(lynxAppId: String, action: OtaSelectionAction, policyRevision: String, reason: String) {
        self.lynxAppId = lynxAppId; self.action = action; self.policyRevision = policyRevision; self.reason = reason
    }
}

public struct OtaLastDecision: Codable, Equatable, Sendable {
    public let audienceKey: String
    public let clientContextKey: String
    public let policyRevision: String
    public let action: OtaSelectionAction
    public let targetReleaseId: String?
    public let reason: String
    init(context: OtaUserContext, policyRevision: String, action: OtaSelectionAction, targetReleaseId: String?, reason: String) {
        audienceKey = context.audienceKey; clientContextKey = context.clientContextKey
        self.policyRevision = policyRevision; self.action = action; self.targetReleaseId = targetReleaseId; self.reason = reason
    }
}

public enum OtaLatestSelection: Equatable, Sendable {
    case release(OtaLatestBundleList)
    case directive(OtaSelectionDirective)
}

/// Plain userId is only held in memory and used on the authenticated-context request/report.
public struct OtaUserContext: Equatable, Sendable {
    public static func normalizeUserId(_ value: String?) throws -> String? { try OtaSelectionValidation.userId(value) }
    public static func normalizeVersionCode(_ value: String) throws -> String { String(try OtaSelectionValidation.decimal(value)) }
    public static func normalizeLynxSdkVersion(_ value: String) throws -> String { try OtaSelectionValidation.sdk(value) }
    public let userId: String?
    public let identityEpoch: UInt64
    public let audienceKey: String
    public let clientContextKey: String
    public let env: OtaEnvironment
    public let app: OtaAppID
    public let platform: OtaPlatform
    public let versionCode: String?
    public let lynxSdkVersion: String?
    public let appVersion: String
    public let nativeProtocolVersion: String?
    public var selectionEnabled: Bool { versionCode != nil }
}

enum OtaSelectionValidation {
    // ECMAScript String.trim whitespace, shared with the Server normalizers.
    private static let trimCharacters = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: trimCharacters) }

    private static func digits(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw OtaSelectionError.invalidVersionCode }
        let value = String(raw.drop(while: { $0 == "0" }))
        return value.isEmpty ? "0" : value
    }

    static func userId(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard !raw.unicodeScalars.contains(where: { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) }) else {
            throw OtaSelectionError.invalidUserId
        }
        let value = trim(raw)
        if value.isEmpty { return nil }
        guard value.utf8.count <= 256 else {
            throw OtaSelectionError.invalidUserId
        }
        return value
    }

    static func decimal(_ raw: String, allowZero: Bool = false) throws -> Int64 {
        let normalized = try digits(trim(raw))
        guard let value = Int64(normalized), value >= (allowZero ? 0 : 1) else { throw OtaSelectionError.invalidVersionCode }
        return value
    }

    static func sdk(_ raw: String) throws -> String {
        let parts = trim(raw).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { throw OtaSelectionError.invalidSDKVersion }
        do {
            let values = try parts.map { try digits(String($0)) }
            return (values + Array(repeating: "0", count: 3 - values.count)).joined(separator: ".")
        } catch { throw OtaSelectionError.invalidSDKVersion }
    }

    static func matchesCode(_ value: String?, range: OtaVersionCodeRange?) -> Bool {
        guard let range else { return true }
        if range.min == nil && range.max == nil { return true }
        guard let value, let number = try? decimal(value) else { return false }
        do {
            let lower = try range.min.map { try decimal($0) }
            let upper = try range.max.map { try decimal($0) }
            if let lower, let upper, lower > upper { return false }
            return (lower == nil || number >= lower!) && (upper == nil || number <= upper!)
        } catch { return false }
    }

    static func validateCodeRange(_ range: OtaVersionCodeRange?) throws {
        guard let range else { return }
        let lower = try range.min.map { try decimal($0) }
        let upper = try range.max.map { try decimal($0) }
        if let lower, let upper, lower > upper { throw OtaSelectionError.invalidSelectionMetadata }
    }

    static func validateSDKRange(_ range: OtaReleaseVersionRange?) throws {
        guard let range else { return }
        let lower = try range.min.map(sdk)
        _ = try range.max.map(sdk)
        if let lower, !matchesVersion(lower, range: range, strict: true) { throw OtaSelectionError.invalidSelectionMetadata }
    }

    static func matchesVersion(_ value: String?, range: OtaReleaseVersionRange?, strict: Bool = false) -> Bool {
        guard let range, range.min != nil || range.max != nil else { return true }
        func parts(_ text: String) throws -> [String] {
            let normalized = strict ? try sdk(text) : trim(text)
            return try normalized.split(separator: ".", omittingEmptySubsequences: false).map { try digits(String($0)) }
        }
        func compare(_ left: [String], _ right: [String]) -> Int {
            for i in 0..<max(left.count, right.count) {
                let a = i < left.count ? left[i] : "0"; let b = i < right.count ? right[i] : "0"
                if a.count != b.count { return a.count < b.count ? -1 : 1 }
                if a != b { return a < b ? -1 : 1 }
            }
            return 0
        }
        guard let value else { return false }
        do {
            let actual = try parts(value); let lower = try range.min.map(parts); let upper = try range.max.map(parts)
            if let lower, let upper, compare(lower, upper) > 0 { return false }
            return (lower == nil || compare(actual, lower!) >= 0) && (upper == nil || compare(actual, upper!) <= 0)
        } catch { return false }
    }

    static func digest(_ parts: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

enum OtaOperationContext {
    @TaskLocal static var identity: OtaUserContext?
    @TaskLocal static var selection: OtaStoredSelection?
    @TaskLocal static var expectedCandidate: String?
}

/// Registration and the final State rename share this lock; file encoding/fsync occurs outside it.
final class OtaUserContextBox: @unchecked Sendable {
    // Synchronous observers may read epoch inside withCurrent; no await occurs under this lock.
    private let lock = NSRecursiveLock()
    private let saltLock = NSLock()
    private let configuration: OtaSDKConfiguration
    private var userId: String?
    private var epoch: UInt64 = 0
    private var salt: String?
    private var initializationError: Error?
    var enabled: Bool { configuration.versionCode != nil }

    init(configuration: OtaSDKConfiguration) {
        self.configuration = configuration
        do { userId = try OtaSelectionValidation.userId(configuration.userId) }
        catch { initializationError = error }
    }

    func register(_ raw: String?) throws -> Bool {
        let value = try OtaSelectionValidation.userId(raw)
        lock.lock(); defer { lock.unlock() }
        guard value.map({ Array($0.utf8) }) != userId.map({ Array($0.utf8) }) || initializationError != nil else { return false }
        guard epoch < UInt64.max else { throw OtaSelectionError.staleIdentity }
        userId = value; epoch += 1; initializationError = nil
        return true
    }

    var identityEpoch: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }

    func capture() throws -> OtaUserContext {
        let code = try configuration.versionCode.map { String(try OtaSelectionValidation.decimal($0)) }
        let sdk: String?
        if code != nil {
            guard let raw = configuration.lynxSdkVersion else { throw OtaSelectionError.invalidSDKVersion }
            sdk = try OtaSelectionValidation.sdk(raw)
        } else { sdk = configuration.lynxSdkVersion }
        let installationSalt = try loadSalt()
        lock.lock(); defer { lock.unlock() }
        if let initializationError { throw initializationError }
        let audience = OtaSelectionValidation.digest([installationSalt, configuration.environment.rawValue, configuration.app.rawValue, userId.map { "user:" + $0 } ?? "anonymous"])
        let contextKey = OtaSelectionValidation.digest([audience, configuration.platform.rawValue, code ?? "legacy", sdk ?? "", configuration.appVersion, configuration.nativeProtocolVersion ?? ""])
        return OtaUserContext(userId: userId, identityEpoch: epoch, audienceKey: audience, clientContextKey: contextKey,
                              env: configuration.environment, app: configuration.app, platform: configuration.platform,
                              versionCode: code, lynxSdkVersion: sdk, appVersion: configuration.appVersion, nativeProtocolVersion: configuration.nativeProtocolVersion)
    }

    private func loadSalt() throws -> String {
        if !enabled { return "legacy" }
        // Disk work never holds the registration/commit lock.
        saltLock.lock(); defer { saltLock.unlock() }
        if salt == nil {
            let file = configuration.storageDirectory.appendingPathComponent("selection-salt")
            if let existing = try? String(contentsOf: file, encoding: .utf8), !existing.isEmpty { salt = existing }
            else {
                let created = UUID().uuidString
                try FileManager.default.createDirectory(at: configuration.storageDirectory, withIntermediateDirectories: true)
                try Data(created.utf8).write(to: file, options: .atomic)
                salt = created
            }
        }
        return salt!
    }

    func withCurrent<T>(_ expected: OtaUserContext, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard expected.identityEpoch == epoch, expected.userId.map({ Array($0.utf8) }) == userId.map({ Array($0.utf8) }) else { throw OtaSelectionError.staleIdentity }
        return try operation()
    }

    func validate(_ expected: OtaUserContext) throws { try withCurrent(expected) {} }
}
