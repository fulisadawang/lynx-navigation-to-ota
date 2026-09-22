#if DEBUG
import Foundation
import Lynx

/** Shell 对可选开发 DebugKit 的无 UI 诊断 SPI。默认没有 sink，不分配缓存。 */
public struct LynxDebugContainerSnapshot {
    public let viewId: String
    public let containerKind: String
    public let visibility: String
    public let pageId: String
    public let routeKey: String
    public let title: String
    public let bundleURL: String
    public let bundleMetadata: [String: Any]
    public let globalProps: [String: Any]
    public let updatedAtMs: Int64

    public init(
        viewId: String,
        containerKind: String,
        visibility: String,
        pageId: String,
        routeKey: String,
        title: String,
        bundleURL: String,
        bundleMetadata: [String: Any],
        globalProps: [String: Any],
        updatedAtMs: Int64
    ) {
        self.viewId = viewId
        self.containerKind = containerKind
        self.visibility = visibility
        self.pageId = pageId
        self.routeKey = routeKey
        self.title = title
        self.bundleURL = bundleURL
        self.bundleMetadata = bundleMetadata
        self.globalProps = globalProps
        self.updatedAtMs = updatedAtMs
    }
}

public protocol LynxDebugSink: AnyObject {
    func attach(_ snapshot: LynxDebugContainerSnapshot)
    func attachConsole(viewId: String, registration: LynxDebugConsoleRegistration)
    func updateVisibility(viewId: String, visibility: String)
    func updateGlobalProps(viewId: String, globalProps: [String: Any])
    func record(_ event: LynxMonitorEvent)
    func recordMethod(_ invocation: LynxDebugMethodInvocation)
    func detach(viewId: String)
    func detachConsole(viewId: String)
}

/** 只暴露 Console 注册能力，不把 LynxView 类型放进 DebugKit 的 sink 合约。 */
public final class LynxDebugConsoleRegistration {
    private let owner: LynxBaseInspectorOwner?
    private var delegate: LynxDebugConsoleDelegate?
    private var registered = false

    fileprivate init(view: LynxView) {
        // LynxView 的公开 API 正确标注为 nullable，并且对应当前页面真实 TemplateRender。
        // 缺少 DevTool service 时保留 nil，不能为调试面板另外创建第二套 LynxDevtool。
        owner = view.baseInspectorOwner
    }

    @discardableResult
    public func register(_ handler: @escaping (String) -> Void) -> Bool {
        guard let owner else { return false }
        let delegate = LynxDebugConsoleDelegate(handler: handler)
        self.delegate = delegate
        owner.setLynxInspectorConsoleDelegate(delegate)
        registered = true
        return true
    }

    public func unregister() {
        guard registered else {
            delegate = nil
            return
        }
        owner?.setLynxInspectorConsoleDelegate(LynxDebugConsoleDelegate(handler: { _ in }))
        registered = false
        delegate = nil
    }

    deinit { unregister() }
}

private final class LynxDebugConsoleDelegate: NSObject, LynxInspectorConsoleDelegate {
    private let handler: (String) -> Void

    init(handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    func onConsoleMessage(_ msg: String) {
        guard !msg.isEmpty else { return }
        handler(msg)
    }
}

/** 本地手写 NativeModule 的调用快照；不包含跨页面或 Sparkling 的隐藏方法。 */
public struct LynxDebugMethodInvocation {
    public let name: String
    public let params: String
    public let viewId: String?
    public let startTimeMs: Int64
    public let endTimeMs: Int64?
    public let code: Int?
    public let success: Bool?
    public let result: String?

    public init(
        name: String,
        params: String,
        viewId: String?,
        startTimeMs: Int64,
        endTimeMs: Int64? = nil,
        code: Int? = nil,
        success: Bool? = nil,
        result: String? = nil
    ) {
        self.name = name
        self.params = params
        self.viewId = viewId
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.code = code
        self.success = success
        self.result = result
    }
}

public final class LynxDebugBridge {
    private static let lock = NSLock()
    private static var sink: LynxDebugSink?
    private static let views = NSMapTable<AnyObject, NSString>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private init() {}

    public static func install(_ value: LynxDebugSink) {
        lock.monitorLocked { sink = value }
    }

    public static func uninstall(_ value: LynxDebugSink) {
        lock.monitorLocked {
            if sink === value { sink = nil }
        }
    }

    public static func attach(
        view: LynxView,
        viewId: String?,
        containerKind: String,
        pageId: String,
        routeKey: String,
        title: String,
        bundleURL: String,
        bundleMetadata: [String: Any]?,
        globalProps: [String: Any],
        visibility: String
    ) -> String {
        guard let activeSink = lock.monitorLocked({ sink }) else {
            return viewId ?? ""
        }
        let id = viewId?.isEmpty == false ? viewId! : UUID().uuidString
        lock.monitorLocked { views.setObject(id as NSString, forKey: view) }
        let snapshot = LynxDebugContainerSnapshot(
            viewId: id,
            containerKind: containerKind,
            visibility: visibility,
            pageId: pageId,
            routeKey: routeKey,
            title: title,
            bundleURL: bundleURL,
            bundleMetadata: bundleMetadata ?? [:],
            globalProps: globalProps,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        activeSink.attach(snapshot)
        activeSink.attachConsole(
            viewId: id,
            registration: LynxDebugConsoleRegistration(view: view)
        )
        return id
    }

    public static func updateVisibility(view: LynxView?, visibility: String) {
        guard let view else { return }
        let target: (sink: LynxDebugSink, viewId: String)? = lock.monitorLocked {
            guard let sink, let value = views.object(forKey: view) else { return nil }
            return (sink, String(value))
        }
        if let target {
            target.sink.updateVisibility(viewId: target.viewId, visibility: visibility)
        }
    }

    public static func updateGlobalProps(view: LynxView?, globalProps: [String: Any]) {
        guard let view else { return }
        let target: (sink: LynxDebugSink, viewId: String)? = lock.monitorLocked {
            guard let sink, let value = views.object(forKey: view) else { return nil }
            return (sink, String(value))
        }
        if let target {
            target.sink.updateGlobalProps(viewId: target.viewId, globalProps: globalProps)
        }
    }

    public static func record(_ event: LynxMonitorEvent) {
        lock.monitorLocked { sink }?.record(event)
    }

    public static func detach(view: LynxView?) {
        guard let view else { return }
        let target: (sink: LynxDebugSink, viewId: String)? = lock.monitorLocked {
            guard let sink, let value = views.object(forKey: view) else { return nil }
            views.removeObject(forKey: view)
            return (sink, String(value))
        }
        guard let target else { return }
        target.sink.detachConsole(viewId: target.viewId)
        target.sink.detach(viewId: target.viewId)
    }

    public static func recordMethod(_ invocation: LynxDebugMethodInvocation) {
        lock.monitorLocked { sink }?.recordMethod(invocation)
    }

    public static func viewId(for view: LynxView?) -> String? {
        guard let view else { return nil }
        return lock.monitorLocked { views.object(forKey: view).map(String.init) }
    }
}
#endif
