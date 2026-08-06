import Foundation

public protocol OtaTemplateRouting: Sendable {
    func routeURL(for release: OtaInstalledRelease, pageId: Int) -> URL?
}

public extension OtaTemplateRouting {
    /// 默认按 bundleName 解析；自定义 pageId router 无需因为新增能力而改实现。
    func routeURL(for release: OtaInstalledRelease, bundleName: String) -> URL? {
        guard let bundle = release.bundles.first(where: { $0.bundleName == bundleName }) else {
            return nil
        }
        return URL(fileURLWithPath: bundle.localFilePath)
    }
}

public struct DefaultOtaTemplateRouter: OtaTemplateRouting {
    public init() {}

    public func routeURL(for release: OtaInstalledRelease, pageId: Int) -> URL? {
        guard let bundle = release.bundles.first(where: { $0.pageId == pageId }) else {
            return nil
        }
        return URL(fileURLWithPath: bundle.localFilePath)
    }
}

public actor LynxHotUpdate {
    public static let shared = LynxHotUpdate()

    private var sdk: OtaSDK?
    private var templateRouter: OtaTemplateRouting = DefaultOtaTemplateRouter()

    public init() {}

    public func initialize(
        configuration: OtaSDKConfiguration,
        embeddedRelease: OtaInstalledRelease? = nil,
        templateRouter: OtaTemplateRouting? = nil
    ) async throws {
        let sdk = OtaSDK(configuration: configuration)
        self.sdk = sdk
        if let templateRouter {
            self.templateRouter = templateRouter
        }
        if let embeddedRelease {
            try await sdk.initializeEmbeddedRelease(embeddedRelease)
        }
    }

    public func checkForUpdate(_ request: OtaCheckRequest) async throws -> OtaPolicyMatchResponse {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.checkForUpdate(request)
    }

    public func downloadUpdate(_ response: OtaPolicyMatchResponse) async throws -> OtaInstalledRelease {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.downloadUpdate(response)
    }

    public func activateUpdate() async throws -> OtaInstalledRelease {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.activateStagedRelease()
    }

    public func sync(_ request: OtaCheckRequest) async throws -> OtaUpdateResult {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.updateIfNeeded(request)
    }

    public func syncLatestBundleList() async throws -> OtaLatestBundleListUpdateResult {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.updateToLatestBundleList()
    }

    public func syncLatestBundleLists() async throws -> OtaHostBundleListSyncResult {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.updateToLatestBundleLists()
    }

    public func rollback(reason: String = "manual_rollback") async throws -> OtaInstalledRelease? {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.rollback(reason: reason)
    }

    public func rollback(lynxAppId: String, reason: String = "manual_rollback") async throws -> OtaInstalledRelease? {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.rollback(lynxAppId: lynxAppId, reason: reason)
    }

    public func reportPageOpen(pageId: Int, lynxAppId: String? = nil, bundlePath: String? = nil) async {
        guard let sdk else {
            return
        }
        await sdk.reportPageOpen(pageId: pageId, lynxAppId: lynxAppId, bundlePath: bundlePath)
    }

    public func reportPageOpen(
        pageId: Int?,
        lynxAppId: String? = nil,
        bundleName: String? = nil,
        bundlePath: String? = nil
    ) async {
        guard let sdk else {
            return
        }
        await sdk.reportPageOpen(
            pageId: pageId,
            lynxAppId: lynxAppId,
            bundleName: bundleName,
            bundlePath: bundlePath
        )
    }

    public func clearUpdates() async throws {
        guard let sdk else {
            return
        }
        try await sdk.clearUpdates()
    }

    public func getCurrentVersion() async -> String {
        guard let sdk else {
            return "embedded"
        }
        return await sdk.getCurrentVersion()
    }

    public func getCurrentRelease() async -> OtaInstalledRelease? {
        guard let sdk else {
            return nil
        }
        return await sdk.getCurrentRelease()
    }

    public func getCurrentRelease(lynxAppId: String) async -> OtaInstalledRelease? {
        guard let sdk else {
            return nil
        }
        return await sdk.getCurrentRelease(lynxAppId: lynxAppId)
    }

    public func current(lynxAppId: String? = nil) async -> OtaInstalledRelease? {
        guard let sdk else {
            return nil
        }
        return await sdk.current(lynxAppId: lynxAppId)
    }

    /// Bundle Runtime 入口：按 `lynxAppId + bundleName` 返回 current 本地文件。
    public func current(lynxAppId: String, bundleName: String) async -> URL? {
        guard let sdk else {
            return nil
        }
        return await sdk.current(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    public func currentTemplateURL(pageId: Int) async -> URL? {
        guard let release = await getCurrentRelease() else {
            return nil
        }
        return templateRouter.routeURL(for: release, pageId: pageId)
    }

    public func currentTemplateURL(lynxAppId: String, pageId: Int) async -> URL? {
        guard let release = await getCurrentRelease(lynxAppId: lynxAppId) else {
            return nil
        }
        return templateRouter.routeURL(for: release, pageId: pageId)
    }

    public func currentTemplateURL(lynxAppId: String, bundleName: String) async -> URL? {
        guard let sdk else {
            return nil
        }
        return await sdk.currentTemplateURL(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    public func ensureBundleReady(lynxAppId: String, bundleName: String) async throws -> URL {
        guard let sdk else {
            throw OtaSDKError.notInitialized
        }
        return try await sdk.ensureBundleReady(lynxAppId: lynxAppId, bundleName: bundleName)
    }
}
