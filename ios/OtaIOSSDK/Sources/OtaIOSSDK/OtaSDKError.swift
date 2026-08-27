import Foundation

public enum OtaSDKError: Error, LocalizedError, Equatable {
    case notInitialized
    case missingReleaseIdentifier
    case missingCurrentRelease
    case missingStagedRelease
    case missingCandidateRelease
    case candidateNotInTrial
    case sizeMismatch(expected: Int, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case invalidResponse(statusCode: Int, body: String)
    case unsupportedDownloadScheme(String)
    case fileNotFound(String)
    case invalidBundleName(String)
    case bundleNotFound(lynxAppId: String, bundleName: String)
    case invalidReleaseScope(expectedApp: OtaAppID, expectedLynxAppId: String, actualApp: OtaAppID, actualLynxAppId: String)
    case invalidReleaseStatus(String)
    case invalidBundleURL(String)
    case missingBundleSize(String)
    case bundleTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "OTA SDK 尚未初始化"
        case .missingReleaseIdentifier:
            return "更新命中结果缺少 releaseId"
        case .missingCurrentRelease:
            return "当前没有可用于测试准备的已校验版本"
        case .missingStagedRelease:
            return "当前没有可激活的已下载版本"
        case .missingCandidateRelease:
            return "当前没有可用的候选版本"
        case .candidateNotInTrial:
            return "候选版本尚未进入试运行状态"
        case let .sizeMismatch(expected, actual):
            return "Bundle 大小校验失败，期望 \(expected) 字节，实际 \(actual) 字节"
        case let .checksumMismatch(expected, actual):
            return "Bundle 校验失败，期望 \(expected)，实际 \(actual)"
        case let .invalidResponse(statusCode, body):
            return "服务端响应异常：\(statusCode) \(body)"
        case let .unsupportedDownloadScheme(scheme):
            return "不支持的下载协议：\(scheme)"
        case let .fileNotFound(path):
            return "找不到文件：\(path)"
        case let .invalidBundleName(bundleName):
            return "非法 bundleName：\(bundleName)"
        case let .bundleNotFound(lynxAppId, bundleName):
            return "找不到 bundle：lynxAppId=\(lynxAppId), bundleName=\(bundleName)"
        case let .invalidReleaseScope(expectedApp, expectedLynxAppId, actualApp, actualLynxAppId):
            return "Release 作用域不一致：期望 \(expectedApp.rawValue)/\(expectedLynxAppId)，实际 \(actualApp.rawValue)/\(actualLynxAppId)"
        case let .invalidReleaseStatus(status):
            return "Release 状态不可激活：\(status)"
        case let .invalidBundleURL(bundlePath):
            return "Bundle URL 必须使用 HTTPS：\(bundlePath)"
        case let .missingBundleSize(bundlePath):
            return "Bundle 缺少 size：\(bundlePath)"
        case let .bundleTooLarge(bundlePath):
            return "Bundle 超过 20 MB：\(bundlePath)"
        }
    }
}
