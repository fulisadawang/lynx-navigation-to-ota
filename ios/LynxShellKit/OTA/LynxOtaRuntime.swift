import Foundation

/**
 * 宿主只面向 LynxShellKit 的 OTA 配置；OTA 引擎源码已经编译在同一个 Router Module 内。
 *
 * clientToken 必须由业务安全配置提供；Router 不内置测试令牌，也不会把令牌写入日志。
 */
public struct LynxOtaConfiguration {
    public static let defaultPageRefreshInterval: TimeInterval = 30 * 60

    public let apiBaseURL: URL
    public let hostApp: String
    public let defaultLynxAppId: String
    public let environment: String
    public let appVersion: String?
    public let buildNumber: String?
    public let userId: String?
    public let deviceId: String?
    public let deviceModel: String?
    public let osVersion: String?
    public let channel: String?
    public let region: String?
    public let nativeProtocolVersion: String?
    public let lynxSDKVersion: String?
    public let clientToken: String
    public let storageDirectory: URL?
    public let pageRefreshInterval: TimeInterval
    public let candidateActivationEnabled: Bool

    public init(
        apiBaseURL: URL,
        hostApp: String = "capp",
        defaultLynxAppId: String = "10000000",
        environment: String = "PROD",
        appVersion: String? = nil,
        buildNumber: String? = nil,
        userId: String? = nil,
        deviceId: String? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil,
        channel: String? = nil,
        region: String? = nil,
        nativeProtocolVersion: String? = nil,
        lynxSDKVersion: String? = "4.0.0",
        clientToken: String,
        storageDirectory: URL? = nil,
        pageRefreshInterval: TimeInterval = Self.defaultPageRefreshInterval,
        candidateActivationEnabled: Bool = false
    ) {
        self.apiBaseURL = apiBaseURL
        self.hostApp = hostApp
        self.defaultLynxAppId = defaultLynxAppId
        self.environment = environment
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.userId = userId
        self.deviceId = deviceId
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.channel = channel
        self.region = region
        self.nativeProtocolVersion = nativeProtocolVersion
        self.lynxSDKVersion = lynxSDKVersion
        self.clientToken = clientToken
        self.storageDirectory = storageDirectory
        self.pageRefreshInterval = pageRefreshInterval
        self.candidateActivationEnabled = candidateActivationEnabled
    }

    private func makeSDKConfiguration() throws -> OtaSDKConfiguration {
        guard apiBaseURL.scheme?.lowercased() == "https",
              apiBaseURL.host?.isEmpty == false else {
            throw LynxOtaError.invalidConfiguration("OTA apiBaseURL 必须使用 HTTPS 并包含 Host")
        }
        guard !defaultLynxAppId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LynxOtaError.invalidConfiguration("defaultLynxAppId 不能为空")
        }
        guard !clientToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LynxOtaError.invalidConfiguration("clientToken 不能为空")
        }
        guard pageRefreshInterval >= 0 else {
            throw LynxOtaError.invalidConfiguration("pageRefreshInterval 不能为负数")
        }
        guard let app = OtaAppID(rawValue: hostApp.lowercased()) else {
            throw LynxOtaError.invalidConfiguration("hostApp 仅支持 capp/gapp")
        }
        guard let env = OtaEnvironment(rawValue: environment.uppercased()) else {
            throw LynxOtaError.invalidConfiguration("environment 仅支持 TEST/STAGING/PROD")
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let resolvedVersion = appVersion
            ?? (info["CFBundleShortVersionString"] as? String)
            ?? "0"
        let resolvedBuild = buildNumber
            ?? (info["CFBundleVersion"] as? String)
            ?? "0"
        let directory = storageDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("lynx-ota-store", isDirectory: true)
        return OtaSDKConfiguration(
            apiBaseURL: apiBaseURL,
            app: app,
            lynxAppId: defaultLynxAppId,
            environment: env,
            platform: .ios,
            appVersion: resolvedVersion,
            buildNumber: resolvedBuild,
            userId: userId,
            deviceId: deviceId,
            deviceModel: deviceModel,
            osVersion: osVersion,
            channel: channel,
            region: region,
            nativeProtocolVersion: nativeProtocolVersion,
            lynxSdkVersion: lynxSDKVersion,
            otaClientToken: clientToken,
            storageDirectory: directory,
            candidateActivationEnabled: candidateActivationEnabled
        )
    }

    /// 保留宿主配置内部封装，同时允许同文件的 Runtime 完成一次性 SDK 构造。
    fileprivate func makeSDKConfigurationForRuntime() throws -> OtaSDKConfiguration {
        try makeSDKConfiguration()
    }
}

public enum LynxOtaError: LocalizedError {
    case invalidConfiguration(String)
    case runtimeNotInstalled
    case invalidIdentity(String)
    case unreadableBundle(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): return message
        case .runtimeNotInstalled: return "当前没有安装 Router OTA runtime"
        case let .invalidIdentity(message): return message
        case let .unreadableBundle(path): return "OTA SDK 返回的 Bundle 不可读：\(path)"
        }
    }
}

/** OTA Runtime 向页面容器交付的已校验 current，不暴露 Manifest 或 staging 路径。 */
struct PreparedOtaBundle {
    let lynxAppId: String
    let bundleName: String
    let fileURL: URL
    let releaseId: String?
    /** 页面可见的来源标签；不参与 Bundle 解析或 OTA 激活。 */
    let source: String
    /** downloaded Release 的进程内租约；容器放弃结果或销毁时必须 close。 */
    let releaseLease: OtaBundleLease?

    init(
        lynxAppId: String,
        bundleName: String,
        fileURL: URL,
        releaseId: String?,
        source: String = "ota_current",
        releaseLease: OtaBundleLease? = nil
    ) {
        self.lynxAppId = lynxAppId
        self.bundleName = bundleName
        self.fileURL = fileURL
        self.releaseId = releaseId
        self.source = source
        self.releaseLease = releaseLease
    }
}

/** 页面容器只依赖这个最小能力；无 OTA 服务配置时由 embedded-only runtime 实现。 */
protocol LynxBundleRuntime {
    func prepare(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle
    func resolveCurrent(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle?
    /** 普通页面可在 candidate trial 期间读取候选；Native Tab 继续只读 current。 */
    func resolvePage(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle?
    /** 普通页面命中 remote current 后的非阻塞 App ID 级 30 分钟后台检查；Tab 不调用。 */
    func refreshAppBundleIfNeeded(lynxAppId: String) async
    func rollback(lynxAppId: String, reason: String) async throws -> Bool
    func confirmCandidateHealthy(lynxAppId: String) async throws -> Bool
    func reportPageOpen(lynxAppId: String, bundleName: String) async
    func deleteBundles(lynxAppId: String) async throws
    func deleteAllBundles() async throws
    func storageSnapshot() async throws -> OtaStorageSnapshot?
}

extension LynxBundleRuntime {
    func storageSnapshot() async throws -> OtaStorageSnapshot? { nil }
}

/**
 * 串行化同一个 Router 实例对 OTA SDK 的写操作。
 *
 * `OtaSDK` 本身是 actor，但 actor 在网络下载、文件移动等 `await` 期间可以
 * 重入。启动全量同步、页面补包和删除若同时进入，就可能在 release 目录上形成
 * 竞争：一个任务刚创建目录，另一个任务已经把目录删掉。这里用一个轻量异步锁，
 * 保证一次只有一个 SDK 操作触碰本地 release/store。
 */
private actor OtaSDKGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
    }
}

#if DEBUG
/** Debug/XCUITest 进程中断标记；写入 UserDefaults 只用于测试时序观测。 */
enum OtaDebugProcessFaultMarker {
    private static let key = "lynx.shell.debug.rollback.process.marker"

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func markAfterRollbackCommit() {
        UserDefaults.standard.set("after_rollback_commit", forKey: key)
    }

    static func state() -> String? {
        UserDefaults.standard.string(forKey: key)
    }
}

/**
 * 只在显式 Debug 环境中暂停真实 CanonicalOtaStore 的 afterRollbackCommit 点。
 * state 已经原子写入后才设置 marker，XCUITest 可以 terminate 进程并验证冷启动读取。
 */
final class OtaDebugPauseAfterRollbackCommitFaultInjector: OtaTransactionFaultInjecting, @unchecked Sendable {
    func check(_ point: OtaTransactionFaultPoint) throws {
        guard point == .afterRollbackCommit else { return }
        OtaDebugProcessFaultMarker.markAfterRollbackCommit()
        Thread.sleep(forTimeInterval: 30)
    }
}
#endif

/**
 * Router 与内置 OTA 引擎之间的真实异步接缝。
 *
 * 启动/回前台使用 host 全量接口；页面命中 current 时立即返回并按 appId 30 分钟门控后台
 * 刷新；缺包或 SHA 损坏时忽略门控，等待定向下载、校验和原子激活。
 */
public actor LynxOtaRuntime: LynxBundleRuntime {
    private let sdk: OtaSDK
    private let embeddedBundleRegistry: EmbeddedBundleRegistry
    private let sdkGate = OtaSDKGate()
    private let pageRefreshInterval: TimeInterval
    private let candidateActivationEnabled: Bool
    private var lastPageRefreshAt: [String: Date] = [:]
    private var pageRefreshTasks: [String: Task<Void, Never>] = [:]
    private var fullSyncTask: Task<OtaHostBundleListSyncResult?, Never>?
    private var fullSyncTaskID: UUID?
    private var fullSyncPending = false

    public init(configuration: LynxOtaConfiguration) throws {
        let sdkConfiguration = try configuration.makeSDKConfigurationForRuntime()
#if DEBUG
        if ProcessInfo.processInfo.environment["LYNX_TEST_PAUSE_AFTER_ROLLBACK_COMMIT"] == "1" {
            if ProcessInfo.processInfo.environment["LYNX_TEST_RESET_PROCESS_FAULT_MARKER"] == "1" {
                OtaDebugProcessFaultMarker.reset()
            }
            sdk = OtaSDK(
                configuration: sdkConfiguration,
                transactionFaultInjector: OtaDebugPauseAfterRollbackCommitFaultInjector()
            )
        } else {
            sdk = OtaSDK(configuration: sdkConfiguration)
        }
#else
        sdk = OtaSDK(configuration: sdkConfiguration)
#endif
        embeddedBundleRegistry = EmbeddedBundleRegistry()
        pageRefreshInterval = configuration.pageRefreshInterval
        candidateActivationEnabled = configuration.candidateActivationEnabled
    }

    /** App 启动和每次回前台都执行；并发触发时合并为当前任务之后再补一次。 */
    func synchronizeAllBundles() async -> Bool {
        if let existingTask = fullSyncTask {
            fullSyncPending = true
            return await existingTask.value != nil
        }
        var succeeded = true
        repeat {
            fullSyncPending = false
            let task = Task<OtaHostBundleListSyncResult?, Never> { [weak self] in
                guard let self else { return nil }
                return try? await self.withSDK { sdk in
                    try await sdk.pruneUnreferencedBundles()
                    return try await sdk.updateToLatestBundleLists()
                }
            }
            let taskID = UUID()
            fullSyncTask = task
            fullSyncTaskID = taskID
            if let result = await task.value {
                let now = Date()
                for appId in result.results.keys { lastPageRefreshAt[appId] = now }
            } else {
                succeeded = false
            }
            if fullSyncTaskID == taskID {
                fullSyncTask = nil
                fullSyncTaskID = nil
            }
        } while fullSyncPending
        return succeeded
    }

#if DEBUG
    /** XCUITest F12 准备真实 canonical current/previous downloaded pair。 */
    func debugSeedRollbackPair(lynxAppId: String, bundleName: String) async throws {
        fullSyncPending = false
        let startupTask = fullSyncTask
        startupTask?.cancel()
        if let startupTask {
            _ = await startupTask.value
        }
        fullSyncTask = nil
        fullSyncTaskID = nil
        guard let embedded = try embeddedBundleRegistry.resolve(
            lynxAppId: lynxAppId,
            bundleName: bundleName
        ) else {
            throw LynxOtaError.unreadableBundle("embedded/\(lynxAppId)/\(bundleName)")
        }
        try await withSDK { sdk in
            try await sdk.debugSeedRollbackPair(
                lynxAppId: lynxAppId,
                bundleName: bundleName,
                sourceURL: embedded.fileURL
            )
        }
    }
#endif

    /** 页面打开：有 current 立即交付；缺失/损坏才等待网络修复。 */
    func prepare(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle {
        try validateIdentity(lynxAppId: lynxAppId, bundleName: bundleName)
        if let lease = try await withSDK({ sdk in
            try await sdk.acquireCurrentBundleLease(lynxAppId: lynxAppId, bundleName: bundleName)
        }) {
            schedulePageRefreshIfNeeded(lynxAppId: lynxAppId)
            return try prepared(lynxAppId: lynxAppId, bundleName: bundleName, lease: lease)
        }

        // App Bundle 内置版本是无网络 baseline；启动全量同步尚未完成时可先直接交付。
        if let embedded = try embeddedBundleRegistry.resolve(
            lynxAppId: lynxAppId,
            bundleName: bundleName
        ) {
            return PreparedOtaBundle(
                lynxAppId: embedded.lynxAppId,
                bundleName: embedded.bundleName,
                fileURL: embedded.fileURL,
                releaseId: embedded.releaseId,
                source: "embedded_baseline"
            )
        }

        // 缺包/损坏不受 30 分钟门控影响，等待内置 OTA 引擎完整校验和激活。
        let repairedURL = try await withSDK { sdk in
            try await sdk.ensureBundleReady(
                lynxAppId: lynxAppId,
                bundleName: bundleName
            )
        }
        lastPageRefreshAt[lynxAppId] = Date()
        let repairedLease = try await withSDK { sdk in
            try await sdk.acquireCurrentBundleLease(lynxAppId: lynxAppId, bundleName: bundleName)
        }
        guard let repairedLease else {
            throw LynxOtaError.unreadableBundle(repairedURL.path)
        }
        return try prepared(lynxAppId: lynxAppId, bundleName: bundleName, lease: repairedLease)
    }

    /**
     * 只读取启动/前台同步后已经提交的 current；不会触发定向网络刷新或 repair。
     * Native Tab 容器只能使用这个入口，切换 Tab 不应重新检查每个 Bundle。
     */
    func resolveCurrent(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        try validateIdentity(lynxAppId: lynxAppId, bundleName: bundleName)
        guard let lease = try await withSDK({ sdk in
            try await sdk.acquireCurrentBundleLease(lynxAppId: lynxAppId, bundleName: bundleName)
        }) else {
            guard let embedded = try embeddedBundleRegistry.resolve(
                lynxAppId: lynxAppId,
                bundleName: bundleName
            ) else {
                return nil
            }
            return PreparedOtaBundle(
                lynxAppId: embedded.lynxAppId,
                bundleName: embedded.bundleName,
                fileURL: embedded.fileURL,
                releaseId: embedded.releaseId,
                source: "embedded_baseline"
            )
        }
        return try prepared(lynxAppId: lynxAppId, bundleName: bundleName, lease: lease)
    }

    func resolvePage(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        try validateIdentity(lynxAppId: lynxAppId, bundleName: bundleName)
        if candidateActivationEnabled,
           let candidate = try await withSDK({ sdk -> OtaCandidateSnapshot? in
               guard let candidate = await sdk.candidate(lynxAppId: lynxAppId) else {
                   return nil
               }
               if candidate.status == .pending {
                   return try await sdk.beginCandidateTrial(lynxAppId: lynxAppId)
               }
               return candidate
           }),
           let candidateLease = try await withSDK({ sdk in
               try await sdk.acquireCandidateBundleLease(lynxAppId: lynxAppId, bundleName: bundleName)
           }) {
            return try prepared(
                lynxAppId: lynxAppId,
                bundleName: bundleName,
                lease: candidateLease,
                releaseId: candidate.release.context.releaseId,
                source: "candidate_trial"
            )
        }
        return try await resolveCurrent(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    /** cache-first 普通页面使用的后台刷新入口；schedulePageRefreshIfNeeded 自带 AppId 门控。 */
    func refreshAppBundleIfNeeded(lynxAppId: String) async {
#if DEBUG
        // F12 只验证 rollback commit 的进程边界；禁止旁路的 30 分钟刷新抢占同一 SDK gate。
        if ProcessInfo.processInfo.environment["LYNX_TEST_PAUSE_AFTER_ROLLBACK_COMMIT"] == "1" {
            return
        }
#endif
        schedulePageRefreshIfNeeded(lynxAppId: lynxAppId)
    }

    /** 首屏失败最多由容器调用一次；恢复 previous/embedded 后重新走 prepare。 */
    func rollback(lynxAppId: String, reason: String) async throws -> Bool {
        try validateAppId(lynxAppId)
        if candidateActivationEnabled,
           try await withSDK({ sdk in await sdk.candidate(lynxAppId: lynxAppId) }) != nil {
            try await withSDK { sdk in
                try await sdk.discardCandidate(lynxAppId: lynxAppId)
            }
            lastPageRefreshAt.removeValue(forKey: lynxAppId)
            return true
        }
        let restoredRemote = try await withSDK { sdk in
            try await sdk.rollback(lynxAppId: lynxAppId, reason: reason)
        }
        if restoredRemote != nil { return true }
        guard embeddedBundleRegistry.containsApp(lynxAppId: lynxAppId) else { return false }

        // 没有 previous remote release 时丢弃坏的 downloaded current；下一次 prepare
        // 会直接从 App Bundle 读取 baseline，不需要把 baseline 复制到沙盒磁盘。
        do {
            try await withSDK { sdk in
                try await sdk.deleteDownloadedBundles(lynxAppId: lynxAppId)
            }
            lastPageRefreshAt.removeValue(forKey: lynxAppId)
            return true
        } catch {
            return false
        }
    }

    func confirmCandidateHealthy(lynxAppId: String) async throws -> Bool {
        try validateAppId(lynxAppId)
        guard candidateActivationEnabled else { return false }
        _ = try await withSDK { sdk in
            try await sdk.confirmCandidateHealthy(lynxAppId: lynxAppId)
        }
        lastPageRefreshAt[lynxAppId] = Date()
        return true
    }

    func reportPageOpen(lynxAppId: String, bundleName: String) async {
        try? await withSDK { sdk in
            await sdk.reportPageOpen(
                pageId: nil,
                lynxAppId: lynxAppId,
                bundleName: bundleName,
                bundlePath: bundleName
            )
        }
    }

    public func deleteBundles(lynxAppId: String) async throws {
        try validateAppId(lynxAppId)
        // host 全量任务也可能正在写这个 appId；删除优先，先取消再清磁盘，避免被回填。
        fullSyncPending = false
        fullSyncTask?.cancel()
        fullSyncTask = nil
        fullSyncTaskID = nil
        pageRefreshTasks.removeValue(forKey: lynxAppId)?.cancel()
        try await withSDK { sdk in
            try await sdk.deleteDownloadedBundles(lynxAppId: lynxAppId)
        }
        lastPageRefreshAt.removeValue(forKey: lynxAppId)
    }

    public func deleteAllBundles() async throws {
        fullSyncPending = false
        fullSyncTask?.cancel()
        fullSyncTask = nil
        fullSyncTaskID = nil
        for task in pageRefreshTasks.values { task.cancel() }
        pageRefreshTasks.removeAll()
        try await withSDK { sdk in
            try await sdk.deleteAllDownloadedBundles()
        }
        lastPageRefreshAt.removeAll()
    }

    public func storageSnapshot() async throws -> OtaStorageSnapshot? {
        try await withSDK { sdk in
            try await sdk.storageSnapshot()
        }
    }

    private func schedulePageRefreshIfNeeded(lynxAppId: String) {
        guard fullSyncTask == nil, pageRefreshTasks[lynxAppId] == nil else { return }
        if let last = lastPageRefreshAt[lynxAppId],
           pageRefreshInterval > 0,
           Date().timeIntervalSince(last) < pageRefreshInterval {
            return
        }
        pageRefreshTasks[lynxAppId] = Task { [weak self] in
            guard let self else { return }
            await self.refreshPageApp(lynxAppId)
        }
    }

    private func refreshPageApp(_ lynxAppId: String) async {
        defer { pageRefreshTasks.removeValue(forKey: lynxAppId) }
        guard fullSyncTask == nil else { return }
        if (try? await withSDK({ sdk in
            try await sdk.updateToLatestBundleList(lynxAppId: lynxAppId)
        })) != nil {
            lastPageRefreshAt[lynxAppId] = Date()
        }
    }

    private func prepared(
        lynxAppId: String,
        bundleName: String,
        lease: OtaBundleLease,
        releaseId: String? = nil,
        source: String = "ota_current"
    ) throws -> PreparedOtaBundle {
        let url = lease.fileURL
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            Task { await lease.close() }
            throw LynxOtaError.unreadableBundle(url.path)
        }
        return PreparedOtaBundle(
            lynxAppId: lynxAppId,
            bundleName: bundleName,
            fileURL: url,
            releaseId: releaseId ?? lease.release.context.releaseId,
            source: source,
            releaseLease: lease
        )
    }

    /** 所有 SDK 访问都经由这里，避免文件事务在 `await` 期间交叉执行。 */
    private func withSDK<T>(
        _ operation: (OtaSDK) async throws -> T
    ) async throws -> T {
        await sdkGate.acquire()
        do {
            let value = try await operation(sdk)
            await sdkGate.release()
            return value
        } catch {
            await sdkGate.release()
            throw error
        }
    }

    private func validateIdentity(lynxAppId: String, bundleName: String) throws {
        try validateAppId(lynxAppId)
        let trimmed = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard trimmed.lowercased().hasSuffix(".lynx.bundle"),
              !(trimmed as NSString).isAbsolutePath,
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw LynxOtaError.invalidIdentity("bundleName 必须是安全的相对 .lynx.bundle 路径")
        }
    }

    private func validateAppId(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[0-9]{8}$", options: .regularExpression) != nil else {
            throw LynxOtaError.invalidIdentity("lynxAppId 必须是 8 位数字")
        }
    }
}

/** 没有 API 地址或 clientToken 时仍可消费 App Bundle 内置版本，不会发起网络请求。 */
actor LynxEmbeddedOnlyRuntime: LynxBundleRuntime {
    private let registry: EmbeddedBundleRegistry

    init(registry: EmbeddedBundleRegistry = EmbeddedBundleRegistry()) {
        self.registry = registry
    }

    func prepare(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle {
        guard let embedded = try registry.resolve(
            lynxAppId: lynxAppId,
            bundleName: bundleName
        ) else {
            throw LynxOtaError.unreadableBundle("embedded/\(lynxAppId)/\(bundleName)")
        }
        return PreparedOtaBundle(
            lynxAppId: embedded.lynxAppId,
            bundleName: embedded.bundleName,
            fileURL: embedded.fileURL,
            releaseId: embedded.releaseId,
            source: "embedded_baseline"
        )
    }

    func resolveCurrent(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        guard let embedded = try registry.resolve(
            lynxAppId: lynxAppId,
            bundleName: bundleName
        ) else {
            return nil
        }
        return PreparedOtaBundle(
            lynxAppId: embedded.lynxAppId,
            bundleName: embedded.bundleName,
            fileURL: embedded.fileURL,
            releaseId: embedded.releaseId,
            source: "embedded_baseline"
        )
    }

    func resolvePage(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        try await resolveCurrent(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func refreshAppBundleIfNeeded(lynxAppId: String) async {}

    func rollback(lynxAppId: String, reason: String) async throws -> Bool { false }

    func confirmCandidateHealthy(lynxAppId: String) async throws -> Bool { false }

    func reportPageOpen(lynxAppId: String, bundleName: String) async {}

    func deleteBundles(lynxAppId: String) async throws {}

    func deleteAllBundles() async throws {}

    func storageSnapshot() async throws -> OtaStorageSnapshot? { nil }
}

#if DEBUG
/**
 * 只供 LynxShellUITests 使用的真实容器故障 runtime。
 *
 * 它仍然读取 App Bundle 内的真实 Manifest/Bundle 字节，只替换 OTA current/previous
 * 的可控指针和 rollback 结果；Release 构建不会编译这段代码，也不会改变生产 runtime。
 */
actor LynxDebugFaultRuntime: LynxBundleRuntime {
    enum Scenario: String {
        case firstScreenPrevious = "first_screen_previous"
        case firstScreenEmbedded = "first_screen_embedded"
    }

    private let registry: EmbeddedBundleRegistry
    private let scenario: Scenario
    private var currentRelease: String? = "fault-v2"

    init(
        scenario: Scenario,
        registry: EmbeddedBundleRegistry = EmbeddedBundleRegistry()
    ) {
        self.scenario = scenario
        self.registry = registry
    }

    func prepare(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle {
        try await resolvePage(lynxAppId: lynxAppId, bundleName: bundleName)
            ?? embedded(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func resolveCurrent(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        if let currentRelease {
            return try bundle(
                lynxAppId: lynxAppId,
                bundleName: bundleName,
                releaseId: currentRelease,
                source: "ota_current"
            )
        }
        return try? embedded(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func resolvePage(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        try await resolveCurrent(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func refreshAppBundleIfNeeded(lynxAppId: String) async {}

    func rollback(lynxAppId: String, reason: String) async throws -> Bool {
        switch scenario {
        case .firstScreenPrevious:
            currentRelease = "fault-v1"
        case .firstScreenEmbedded:
            currentRelease = nil
        }
        return true
    }

    func confirmCandidateHealthy(lynxAppId: String) async throws -> Bool { false }

    func reportPageOpen(lynxAppId: String, bundleName: String) async {}

    func deleteBundles(lynxAppId: String) async throws {
        currentRelease = nil
    }

    func deleteAllBundles() async throws {
        currentRelease = nil
    }

    private func bundle(
        lynxAppId: String,
        bundleName: String,
        releaseId: String,
        source: String
    ) throws -> PreparedOtaBundle {
        guard let descriptor = try registry.resolve(
            lynxAppId: lynxAppId,
            bundleName: bundleName
        ) else {
            throw LynxOtaError.unreadableBundle("embedded/\(lynxAppId)/\(bundleName)")
        }
        return PreparedOtaBundle(
            lynxAppId: descriptor.lynxAppId,
            bundleName: descriptor.bundleName,
            fileURL: descriptor.fileURL,
            releaseId: releaseId,
            source: source
        )
    }

    private func embedded(lynxAppId: String, bundleName: String) throws -> PreparedOtaBundle {
        guard let descriptor = try registry.resolve(
            lynxAppId: lynxAppId,
            bundleName: bundleName
        ) else {
            throw LynxOtaError.unreadableBundle("embedded/\(lynxAppId)/\(bundleName)")
        }
        return PreparedOtaBundle(
            lynxAppId: descriptor.lynxAppId,
            bundleName: descriptor.bundleName,
            fileURL: descriptor.fileURL,
            releaseId: descriptor.releaseId,
            source: "embedded_baseline"
        )
    }
}

/**
 * 外网不可用时的 Debug OTA 语义模拟器：使用真实 embedded Bundle 字节，但模拟
 * latest-list/下载成功后的 current，并让主动刷新继续走同一 Router/Tab 协议。
 */
actor LynxDebugMockOtaRuntime: LynxBundleRuntime {
    private let registry: EmbeddedBundleRegistry
    private var releaseId = "mock-ota-r20260825"

    init(registry: EmbeddedBundleRegistry = EmbeddedBundleRegistry()) {
        self.registry = registry
    }

    func synchronizeAllBundles() async -> Bool {
        OtaDebugHTTPMetrics.recordRequest()
        return true
    }

    func prepare(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle {
        try await resolvePage(lynxAppId: lynxAppId, bundleName: bundleName)
            ?? embedded(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func resolveCurrent(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        try bundle(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func resolvePage(lynxAppId: String, bundleName: String) async throws -> PreparedOtaBundle? {
        try await resolveCurrent(lynxAppId: lynxAppId, bundleName: bundleName)
    }

    func refreshAppBundleIfNeeded(lynxAppId: String) async {}

    func rollback(lynxAppId: String, reason: String) async throws -> Bool {
        releaseId = "mock-embedded-baseline"
        return true
    }

    func confirmCandidateHealthy(lynxAppId: String) async throws -> Bool { false }
    func reportPageOpen(lynxAppId: String, bundleName: String) async {}
    func deleteBundles(lynxAppId: String) async throws {}
    func deleteAllBundles() async throws {}

    private func bundle(lynxAppId: String, bundleName: String) throws -> PreparedOtaBundle {
        guard let descriptor = try registry.resolve(lynxAppId: lynxAppId, bundleName: bundleName) else {
            throw LynxOtaError.unreadableBundle("embedded/\(lynxAppId)/\(bundleName)")
        }
        return PreparedOtaBundle(
            lynxAppId: descriptor.lynxAppId,
            bundleName: descriptor.bundleName,
            fileURL: descriptor.fileURL,
            releaseId: releaseId,
            source: "ota_current"
        )
    }

    private func embedded(lynxAppId: String, bundleName: String) throws -> PreparedOtaBundle {
        guard let descriptor = try registry.resolve(lynxAppId: lynxAppId, bundleName: bundleName) else {
            throw LynxOtaError.unreadableBundle("embedded/\(lynxAppId)/\(bundleName)")
        }
        return PreparedOtaBundle(
            lynxAppId: descriptor.lynxAppId,
            bundleName: descriptor.bundleName,
            fileURL: descriptor.fileURL,
            releaseId: descriptor.releaseId,
            source: "embedded_baseline"
        )
    }
}
#endif
