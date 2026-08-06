import Foundation
import Lynx
import UIKit

/**
 * 页面通过 `NativeModules.LynxShellModule` 调用的稳定宿主模块。
 *
 * 设计边界：
 * - 本类只做参数转换、主线程切换和回调封装；
 * - 导航栈规则统一放在 ShellNavigator，媒体实现放在 ShellMediaBridge；
 * - 不接入 sparkling-method、spkPipe、autolink 或 codegen；
 * - 导航成功回调表示“UIKit 栈事务已提交/执行”，不代表目标 Lynx 首帧完成。
 *
 * Native 原始协议为 `code == 0` 成功；Playground wrapper 会归一化为页面侧
 * `code == 1` 成功。业务页面直接调用 NativeModules 时应使用原始协议。
 */
@objc(LynxShellModule)
@objcMembers
public final class LynxShellModule: NSObject, LynxContextModule {
    /** 弱持有调用页面上下文，避免 Module -> Context -> LynxView 的生命周期环。 */
    private weak var lynxContext: LynxContext?
    /** Lynx Runtime 注册与页面侧 NativeModules 访问使用的固定模块名。 */
    public static var name: String { "LynxShellModule" }

    /**
     * Lynx 4.0 iOS 使用 methodLookup 把 JS 方法名映射到 Objective-C selector。
     *
     * 新增方法必须同时更新 Android `@LynxMethod`、TypeScript 声明和静态契约检查。
     */
    public static var methodLookup: [String: String] {
        [
            "open": NSStringFromSelector(#selector(open(_:optionsJSON:completion:))),
            "close": NSStringFromSelector(#selector(close(_:))),
            "back": NSStringFromSelector(#selector(back(_:optionsJSON:completion:))),
            "popTo": NSStringFromSelector(#selector(popTo(_:completion:))),
            "popToWithOptions": NSStringFromSelector(
                #selector(popToWithOptions(_:optionsJSON:completion:))
            ),
            "closeAll": NSStringFromSelector(#selector(closeAll(_:))),
            "closeAllWithOptions": NSStringFromSelector(
                #selector(closeAllWithOptions(_:completion:))
            ),
            "reLaunch": NSStringFromSelector(#selector(reLaunch(_:completion:))),
            "redirect": NSStringFromSelector(#selector(redirect(_:optionsJSON:completion:))),
            "getNavigationState": NSStringFromSelector(#selector(getNavigationState(_:))),
            "closeWithResult": NSStringFromSelector(#selector(closeWithResult(_:completion:))),
            "consumeNavigationResult": NSStringFromSelector(
                #selector(consumeNavigationResult(_:))
            ),
            "emitToNative": NSStringFromSelector(
                #selector(emitToNative(_:payload:completion:))
            ),
            "broadcast": NSStringFromSelector(
                #selector(broadcast(_:payload:completion:))
            ),
            "sendToPage": NSStringFromSelector(
                #selector(sendToPage(_:eventName:payload:completion:))
            ),
            "setStorageItem": NSStringFromSelector(#selector(setStorageItem(_:value:))),
            "getStorageItem": NSStringFromSelector(#selector(getStorageItem(_:completion:))),
            "removeStorageItem": NSStringFromSelector(#selector(removeStorageItem(_:))),
            "clearStorage": NSStringFromSelector(#selector(clearStorage)),
            "deleteOtaBundles": NSStringFromSelector(
                #selector(deleteOtaBundles(_:completion:))
            ),
            "deleteAllOtaBundles": NSStringFromSelector(
                #selector(deleteAllOtaBundles(_:))
            ),
            "getAppInfo": NSStringFromSelector(#selector(getAppInfo(_:))),
            "chooseMedia": NSStringFromSelector(#selector(chooseMedia(_:completion:))),
            "uploadFile": NSStringFromSelector(#selector(uploadFile(_:completion:))),
            "uploadImage": NSStringFromSelector(#selector(uploadImage(_:completion:))),
            "downloadFile": NSStringFromSelector(#selector(downloadFile(_:completion:))),
            "saveDataURL": NSStringFromSelector(#selector(saveDataURL(_:completion:))),
            "prepareRoute": NSStringFromSelector(
                #selector(prepareRoute(_:optionsJSON:completion:))
            ),
            "cancelPreparedRoute": NSStringFromSelector(
                #selector(cancelPreparedRoute(_:completion:))
            ),
            "markTransitionReady": NSStringFromSelector(
                #selector(markTransitionReady(_:completion:))
            ),
            "getTransitionState": NSStringFromSelector(#selector(getTransitionState(_:))),
        ]
    }

    /**
     * Lynx 运行时会通过 `init(param:)` 创建 Module。
     *
     * 当前壳没有注入业务依赖；生产宿主可把 Router/Service 容器放进 param，再在这里解析。
     */
    public init(param: Any) {
        super.init()
    }

    /** 保留无参初始化，便于 ObjC Runtime 和单元测试创建。 */
    public override init() {
        super.init()
    }

    /**
     * Lynx 4.0 会优先通过 LynxContextModule 初始化。
     *
     * 这样 open 的共享元素源节点属于哪个 LynxView 是确定的，不再用 keyWindow 或
     * 栈顶页面猜测；仍是完全手写 NativeModule，不依赖 autolink/codegen。
     */
    public required init(lynxContext: LynxContext) {
        self.lynxContext = lynxContext
        super.init()
    }

    /** 兼容宿主未来通过 LynxConfig registerModule:param: 注入依赖的创建路径。 */
    public required init(lynxContext: LynxContext, withParam param: Any) {
        self.lynxContext = lynxContext
        super.init()
    }

    public func destroy() {
        lynxContext = nil
    }

    /**
     * 打开页面。
     *
     * optionsJSON 可同时包含 routeKey、launchMode、animated、backGestureEnabled 和
     * deduplicateWindowMs 等页面/导航字段。
     */
    public func open(
        _ url: String,
        optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        do {
            let request = try LynxRouteParser.request(from: url, optionsJSON: optionsJSON)
            let options = try ShellNavigationOptions.fromJSON(optionsJSON)
            let sourceLynxView = lynxContext?.getLynxView()
            performNavigation(completion) {
                ShellNavigator.shared.open(
                    request,
                    options: options,
                    sourceLynxView: sourceLynxView
                )
            }
        } catch {
            completion(Self.result(code: 1001, message: error.localizedDescription))
        }
    }

    /**
     * 关闭当前容器。
     *
     * 与 back(delta) 不同，当前页是 session 首页时也允许 pop 到宿主页。
     */
    public func close(_ completion: @escaping (NSDictionary) -> Void) {
        performNavigation(completion) { ShellNavigator.shared.close() }
    }

    /**
     * 在当前 Lynx session 内回退 delta 页。
     *
     * options.result 可带 JSON Object 给目标页；超过可退深度时只回到 session 首页。
     */
    public func back(
        _ delta: Int,
        optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        do {
            let options = try ShellNavigationOptions.fromJSON(optionsJSON)
            performNavigation(completion) {
                ShellNavigator.shared.back(delta: delta, options: options)
            }
        } catch {
            completion(Self.result(code: 1001, message: error.localizedDescription))
        }
    }

    /** 保留兼容签名：使用默认动画回到当前 session 已存在的 routeKey。 */
    public func popTo(
        _ routeKey: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        performNavigation(completion) {
            ShellNavigator.shared.popTo(routeKey: routeKey)
        }
    }

    /** popTo 的可配置版本，支持 animated、result 和防重复参数。 */
    public func popToWithOptions(
        _ routeKey: String,
        optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        do {
            let options = try ShellNavigationOptions.fromJSON(optionsJSON)
            performNavigation(completion) {
                ShellNavigator.shared.popTo(routeKey: routeKey, options: options)
            }
        } catch {
            completion(Self.result(code: 1001, message: error.localizedDescription))
        }
    }

    /** 保留兼容签名：关闭当前 Lynx session 并返回进入前宿主页。 */
    public func closeAll(_ completion: @escaping (NSDictionary) -> Void) {
        performNavigation(completion) { ShellNavigator.shared.closeAll() }
    }

    /** closeAll 的可配置版本，主要用于控制动画和防重复窗口。 */
    public func closeAllWithOptions(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        do {
            let options = try ShellNavigationOptions.fromJSON(optionsJSON)
            performNavigation(completion) {
                ShellNavigator.shared.closeAll(options: options)
            }
        } catch {
            completion(Self.result(code: 1001, message: error.localizedDescription))
        }
    }

    /**
     * 关闭当前 session，并由业务宿主注入的 AppHomeHandler 回到主 Tab。
     *
     * 通用壳不会猜测 UITabBarController；未安装 Handler 时明确返回 1004。
     */
    public func reLaunch(
        _ optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        do {
            let options = try ShellNavigationOptions.fromJSON(optionsJSON)
            performNavigation(completion) {
                ShellNavigator.shared.reLaunch(
                    optionsJSON: optionsJSON,
                    navigationOptions: options
                )
            }
        } catch {
            completion(Self.result(code: 1001, message: error.localizedDescription))
        }
    }

    /**
     * 用新请求原位替换当前 entry。
     *
     * sessionID、entryID、order 与页面返回目标保持不变，Bundle 和页面参数重新加载。
     */
    public func redirect(
        _ url: String,
        optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        do {
            let request = try LynxRouteParser.request(from: url, optionsJSON: optionsJSON)
            let options = try ShellNavigationOptions.fromJSON(optionsJSON)
            performNavigation(completion) {
                ShellNavigator.shared.redirect(request, options: options)
            }
        } catch {
            completion(Self.result(code: 1001, message: error.localizedDescription))
        }
    }

    /** 查询当前 session 的 route、stack、depth、canGoBack 和宿主锚点状态。 */
    public func getNavigationState(_ completion: @escaping (NSDictionary) -> Void) {
        performNavigation(completion) { ShellNavigator.shared.navigationState() }
    }

    /**
     * 关闭当前页，并把 JSON Object 返回给它下面的 Lynx entry。
     *
     * 结果按目标 entryID 持久化，不依赖会随页面销毁失效的 JS callback 闭包。
     */
    public func closeWithResult(
        _ resultJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        // 提前校验可以稳定返回 1001；Navigator 仍负责真正写入与回退。
        do {
            _ = try ShellNavigationOptions.withResultJSON(resultJSON)
            performNavigation(completion) {
                ShellNavigator.shared.closeWithResult(resultJSON)
            }
        } catch {
            completion(Self.result(code: 1001, message: error.localizedDescription))
        }
    }

    /** 一次性读取发给当前 entry 的页面结果；没有结果时成功返回 hasResult=false。 */
    public func consumeNavigationResult(_ completion: @escaping (NSDictionary) -> Void) {
        performNavigation(completion) {
            ShellNavigator.shared.consumeNavigationResult()
        }
    }

    /** 页面向宿主发送消息；回复结构与 Android/Harmony 的 emitToNative 对齐。 */
    public func emitToNative(
        _ eventName: String,
        payload: NSDictionary?,
        completion: @escaping (NSDictionary) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.lynxContext?.getLynxView() else {
                completion(Self.result(code: 1002, message: "当前 Lynx 页面实例不存在"))
                return
            }
            let reply = ShellMessageHub.dispatchFromPage(
                view: view,
                eventName: eventName,
                payload: (payload as? [String: Any]) ?? [:]
            )
            completion(Self.result(reply))
        }
    }

    /** 页面向进程内全部活体 Lynx 页面广播事件。 */
    public func broadcast(
        _ eventName: String,
        payload: NSDictionary?,
        completion: @escaping (NSDictionary) -> Void
    ) {
        DispatchQueue.main.async {
            do {
                let count = try ShellMessageHub.broadcast(
                    eventName: eventName,
                    payload: (payload as? [String: Any]) ?? [:]
                )
                completion([
                    "code": 0,
                    "message": "广播已发送",
                    "data": ["affectedCount": count],
                ])
            } catch {
                completion(Self.result(code: 1001, message: error.localizedDescription))
            }
        }
    }

    /** 页面按 pageId 向另一个 Lynx 页面发送事件。 */
    public func sendToPage(
        _ targetPageId: String,
        eventName: String,
        payload: NSDictionary?,
        completion: @escaping (NSDictionary) -> Void
    ) {
        DispatchQueue.main.async {
            do {
                let sent = try ShellMessageHub.sendToPage(
                    pageId: targetPageId,
                    eventName: eventName,
                    payload: (payload as? [String: Any]) ?? [:]
                )
                completion([
                    "code": sent ? 0 : 1,
                    "message": sent ? "定向消息已发送" : "目标页面不存在或已经销毁",
                    "data": ["affectedCount": sent ? 1 : 0],
                ])
            } catch {
                completion(Self.result(code: 1001, message: error.localizedDescription))
            }
        }
    }

    /** 写入带固定前缀的 UserDefaults Key，不覆盖宿主业务存储。 */
    public func setStorageItem(_ key: String, value: String) {
        UserDefaults.standard.set(value, forKey: Self.storageKey(key))
    }

    /** 读取字符串；Key 不存在时返回空字符串，保持现有 Playground 契约。 */
    public func getStorageItem(_ key: String, completion: @escaping (NSString) -> Void) {
        completion((UserDefaults.standard.string(forKey: Self.storageKey(key)) ?? "") as NSString)
    }

    /** 删除一个 LynxShellModule 隔离存储 Key。 */
    public func removeStorageItem(_ key: String) {
        UserDefaults.standard.removeObject(forKey: Self.storageKey(key))
    }

    /** 只清除固定前缀 Key，不影响 App 其他 UserDefaults。 */
    public func clearStorage() {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.storagePrefix) }
            .forEach(UserDefaults.standard.removeObject(forKey:))
    }

    /** 页面按 appId 直接删除磁盘 OTA Bundle；不会生成隐藏备份目录。 */
    public func deleteOtaBundles(
        _ lynxAppId: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        Task {
            do {
                try await LynxRouter.deleteOtaBundles(lynxAppId: lynxAppId)
                await MainActor.run {
                    completion(Self.result(code: 0, message: "指定 appId 的 OTA Bundle 已删除"))
                }
            } catch {
                await MainActor.run {
                    completion(Self.result(code: 1500, message: error.localizedDescription))
                }
            }
        }
    }

    /** 页面直接删除全部 appId 的磁盘 OTA Bundle；App 内置资源保留。 */
    public func deleteAllOtaBundles(_ completion: @escaping (NSDictionary) -> Void) {
        Task {
            do {
                try await LynxRouter.deleteAllOtaBundles()
                await MainActor.run {
                    completion(Self.result(code: 0, message: "全部 OTA Bundle 已删除"))
                }
            } catch {
                await MainActor.run {
                    completion(Self.result(code: 1500, message: error.localizedDescription))
                }
            }
        }
    }

    /** 返回不含 IDFA、IDFV 等设备标识的 App/系统基础信息。 */
    public func getAppInfo(_ completion: @escaping (NSDictionary) -> Void) {
        let info = Bundle.main.infoDictionary ?? [:]
        completion([
            "platform": "ios",
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "",
            "buildNumber": info["CFBundleVersion"] as? String ?? "",
            "systemVersion": UIDevice.current.systemVersion,
        ])
    }

    /** 调系统相册/相机选择媒体；权限和控制器生命周期由媒体桥处理。 */
    public func chooseMedia(
        _ optionsJSON: String,
        completion: @escaping LynxCallbackBlock
    ) {
        ShellMediaBridge.shared.chooseMedia(optionsJSON: optionsJSON, callback: completion)
    }

    /** 上传本地文件；与 uploadImage 共用受大小限制的 URLSession 实现。 */
    public func uploadFile(
        _ optionsJSON: String,
        completion: @escaping LynxCallbackBlock
    ) {
        ShellMediaBridge.shared.upload(optionsJSON: optionsJSON, callback: completion)
    }

    /** 兼容 Playground 的图片上传方法名。 */
    public func uploadImage(
        _ optionsJSON: String,
        completion: @escaping LynxCallbackBlock
    ) {
        ShellMediaBridge.shared.upload(optionsJSON: optionsJSON, callback: completion)
    }

    /** 下载远程文件到 App temporary directory。 */
    public func downloadFile(
        _ optionsJSON: String,
        completion: @escaping LynxCallbackBlock
    ) {
        ShellMediaBridge.shared.download(optionsJSON: optionsJSON, callback: completion)
    }

    /** 把 Data URL 解码到 App temporary directory，不直接写系统相册。 */
    public func saveDataURL(
        _ optionsJSON: String,
        completion: @escaping LynxCallbackBlock
    ) {
        ShellMediaBridge.shared.saveDataURL(optionsJSON: optionsJSON, callback: completion)
    }

    /**
     * 安全解析路由并预取 Bundle 字节。
     *
     * token 最多保留 30 秒、只能消费一次；不缓存 UIViewController、LynxView 或 JS
     * Runtime，因此它不是对微信 preset-route 私有缓存语义的假装实现。
     */
    public func prepareRoute(
        _ url: String,
        optionsJSON: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        do {
            let options = try ShellNavigationOptions.fromJSON(optionsJSON)
            let request = try LynxRouteParser.request(
                from: url,
                optionsJSON: optionsJSON
            ).withTransitionSpec(options.transitionSpec)
            DispatchQueue.main.async {
                ShellPreparedRouteStore.shared.prepare(request: request) { result in
                    switch result {
                    case let .success(data):
                        completion([
                            "code": 0,
                            "message": "路由 Bundle 已预取",
                            "data": data,
                        ])
                    case let .failure(error):
                        completion(Self.result(code: 1500, message: error.localizedDescription))
                    }
                }
            }
        } catch {
            completion(Self.result(code: 1001, message: error.localizedDescription))
        }
    }

    /** 取消尚未消费的 prepareRoute token；重复取消返回 1003。 */
    public func cancelPreparedRoute(
        _ token: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        DispatchQueue.main.async {
            let cancelled = ShellPreparedRouteStore.shared.cancel(token: token)
            completion(cancelled
                ? ["code": 0, "message": "预置路由已取消", "data": ["token": token]]
                : Self.result(code: 1003, message: "预置路由不存在、已消费或已过期"))
        }
    }

    /**
     * 业务页面可选调用一次，说明异步图片等内容已经稳定。
     *
     * 这里只传 transactionID，不接收几何和动画 progress；转场仍由原生主线程驱动。
     */
    public func markTransitionReady(
        _ transactionID: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        performNavigation(completion) {
            ShellNavigator.shared.markTransitionReady(transactionID)
        }
    }

    /** 低频读取最近一笔原生转场状态，不用于 JS 逐帧回写。 */
    public func getTransitionState(_ completion: @escaping (NSDictionary) -> Void) {
        performNavigation(completion) {
            ShellNavigator.shared.transitionState()
        }
    }

    /**
     * 把导航操作串行投递到主线程，并统一处理意外异常边界。
     *
     * 参数解析错误由调用方法返回 1001；平台操作的结构化失败由 ShellNavigator 返回。
     */
    private func performNavigation(
        _ completion: @escaping (NSDictionary) -> Void,
        operation: @escaping () -> LynxNavigationResult
    ) {
        DispatchQueue.main.async {
            completion(Self.result(operation()))
        }
    }

    /** Module 普通存储前缀；与导航快照、页面结果使用不同命名空间。 */
    private static let storagePrefix = "lynx_shell_storage."
    private static func storageKey(_ key: String) -> String { storagePrefix + key }

    /** 构造不带 data 的统一错误结构。 */
    private static func result(code: Int, message: String) -> NSDictionary {
        ["code": code, "message": message]
    }

    /** 合并 affectedCount 和导航扩展 data，输出 Lynx 可消费 NSDictionary。 */
    private static func result(_ value: LynxNavigationResult) -> NSDictionary {
        var data = value.data
        data["affectedCount"] = value.affectedCount
        return [
            "code": value.code,
            "message": value.message,
            "data": data,
        ]
    }

    /** 把消息处理器回复转换为页面可消费的稳定结果。 */
    private static func result(_ value: LynxRouterMessageReply) -> NSDictionary {
        [
            "code": value.accepted ? 0 : 1,
            "message": value.message,
            "data": value.data,
        ]
    }
}
