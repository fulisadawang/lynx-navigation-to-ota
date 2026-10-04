import Foundation
import Lynx

/** 宿主只提供页面容器控制；supportedMethods 安装时快照，查询不得访问 UIKit 或等待权限。 */
public protocol LynxCapacitorHostProvider: AnyObject {
    var supportedMethods: [String: [String]] { get }
    func host(for context: LynxContext) -> AnyObject?
    func releaseHost(for context: LynxContext)
}

public extension LynxCapacitorHostProvider {
    func releaseHost(for context: LynxContext) { }
}

enum LynxCapacitorHostRegistry {
    private static let lock = NSLock()
    private static var provider: LynxCapacitorHostProvider?
    private static var methods: [String: [String]] = [:]

    static func install(_ value: LynxCapacitorHostProvider?) {
        precondition(Thread.isMainThread, "Host provider 必须在主线程安装")
        let snapshot = value?.supportedMethods ?? [:]
        lock.lock()
        provider = value
        methods = snapshot
        lock.unlock()
    }

    static func current() -> LynxCapacitorHostProvider? {
        lock.lock(); defer { lock.unlock() }
        return provider
    }

    static func supportedMethods() -> [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        return methods
    }
}
