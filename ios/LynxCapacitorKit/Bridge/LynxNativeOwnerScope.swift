import Foundation

/** 页面实例的生命周期门禁；回包和资源关闭使用同一 owner，换包不能复用旧 owner。 */
final class LynxNativeOwnerScope {
    private static let registryLock = NSLock()
    private static var scopes: [String: LynxNativeOwnerScope] = [:]
    let id = UUID().uuidString
    private let lock = NSLock()
    private var closed = false
    private var pending: [UUID: (LynxNativeCapabilityResult) -> Void] = [:]
    private var resources: [UUID: () -> Void] = [:]

    init() {
        Self.registryLock.lock()
        Self.scopes[id] = self
        Self.registryLock.unlock()
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed
    }

    var resourceCount: Int { lock.lock(); defer { lock.unlock() }; return resources.count }

    /** 提交与关闭在同一 owner 边界排序；这里只允许快速原子提交，不放长 IO。 */
    static func commit<T>(ownerID: String?, _ operation: () throws -> T) throws -> T {
        guard let ownerID else { return try operation() }
        registryLock.lock()
        let scope = scopes[ownerID]
        registryLock.unlock()
        guard let scope else { throw LynxNativeIOExecutor.Cancelled() }
        scope.lock.lock(); defer { scope.lock.unlock() }
        guard !scope.closed else { throw LynxNativeIOExecutor.Cancelled() }
        return try operation()
    }

    static func isActive(_ ownerID: String?) -> Bool {
        guard let ownerID else { return true }
        registryLock.lock()
        let scope = scopes[ownerID]
        registryLock.unlock()
        return scope?.isActive == true
    }

    func begin(_ callback: @escaping (LynxNativeCapabilityResult) -> Void) -> UUID? {
        lock.lock()
        guard !closed else {
            lock.unlock()
            callback(.failure("HOST_DESTROYED", "页面已销毁"))
            return nil
        }
        let token = UUID()
        pending[token] = callback
        lock.unlock()
        return token
    }

    func complete(_ token: UUID, _ result: LynxNativeCapabilityResult) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in complete(token, result) }
            return
        }
        lock.lock()
        let callback = pending.removeValue(forKey: token)
        lock.unlock()
        callback?(result)
    }

    @discardableResult
    static func retain(ownerID: String?, cleanup: @escaping () -> Void) -> UUID? {
        guard let ownerID else { return nil }
        registryLock.lock()
        let scope = scopes[ownerID]
        registryLock.unlock()
        guard let scope else { cleanup(); return nil }
        scope.lock.lock()
        guard !scope.closed else { scope.lock.unlock(); cleanup(); return nil }
        let token = UUID()
        scope.resources[token] = cleanup
        scope.lock.unlock()
        return token
    }

    static func forget(ownerID: String?, token: UUID?) {
        guard let ownerID, let token else { return }
        registryLock.lock()
        let scope = scopes[ownerID]
        registryLock.unlock()
        scope?.lock.lock()
        scope?.resources.removeValue(forKey: token)
        scope?.lock.unlock()
    }

    @discardableResult
    func close() -> Bool {
        lock.lock()
        guard !closed else { lock.unlock(); return false }
        closed = true
        let callbacks = Array(pending.values)
        let cleanups = Array(resources.values)
        pending.removeAll()
        resources.removeAll()
        lock.unlock()
        Self.registryLock.lock()
        Self.scopes.removeValue(forKey: id)
        Self.registryLock.unlock()
        callbacks.forEach { $0(.failure("HOST_DESTROYED", "页面已销毁，原生请求已取消")) }
        let clean = { cleanups.forEach { $0() } }
        if Thread.isMainThread { clean() } else { DispatchQueue.main.async(execute: clean) }
        return true
    }
}

/** 系统 completion 可早于 retain 返回，attach/finish 都通过同一对象归还取消资源。 */
final class LynxNativeOwnedResource {
    private let ownerID: String?
    private let lock = NSLock()
    private var token: UUID?
    private var finished = false
    init(ownerID: String?) { self.ownerID = ownerID }
    func attach(cleanup: @escaping () -> Void) {
        let registered = LynxNativeOwnerScope.retain(ownerID: ownerID, cleanup: cleanup)
        lock.lock()
        if finished { lock.unlock(); LynxNativeOwnerScope.forget(ownerID: ownerID, token: registered) }
        else { token = registered; lock.unlock() }
    }
    func finish() {
        lock.lock()
        finished = true
        let registered = token
        token = nil
        lock.unlock()
        LynxNativeOwnerScope.forget(ownerID: ownerID, token: registered)
    }
}
