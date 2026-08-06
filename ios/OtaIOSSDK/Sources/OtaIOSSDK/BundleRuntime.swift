import Foundation

/// iOS Bundle Runtime 门面。
///
/// 路由只通过这个 actor 读取已提交 current，不直接拼接 staged、previous 或
/// release 目录路径。网络 repair 仍由 `OtaSDK.ensureBundleReady` 负责。
public actor BundleRuntime {
    private let transaction: ReleaseTransaction

    public init(transaction: ReleaseTransaction) {
        self.transaction = transaction
    }

    /// 精确按 `hostApp + lynxAppId + bundleName` 读取 current 文件。
    public func current(scope: OtaReleaseScope, bundleName: String) async throws -> URL? {
        try await transaction.currentBundle(scope: scope, bundleName: bundleName)
    }

    public func current(scope: OtaReleaseScope) async -> OtaInstalledRelease? {
        await transaction.current(scope: scope)
    }

    /// 当前 release 无该 bundle 时抛结构化 not-found；不会读取 staged 文件。
    public func ensureBundleReady(scope: OtaReleaseScope, bundleName: String) async throws -> URL {
        guard let url = try await current(scope: scope, bundleName: bundleName) else {
            throw OtaSDKError.bundleNotFound(
                lynxAppId: scope.lynxAppId,
                bundleName: bundleName
            )
        }
        return url
    }
}
