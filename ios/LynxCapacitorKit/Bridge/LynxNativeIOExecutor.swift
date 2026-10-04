import Foundation

/** 所有内联大小按字节计数；大媒体沿用 URI 契约，超限返回错误而非截断成功。 */
enum LynxNativePayloadLimits {
    static let inputJSONBytes = 1024 * 1024
    static let inlineFileBytes = 512 * 1024
    static let inlineMediaBytes = 512 * 1024
    static let downloadedFileBytes = 20 * 1024 * 1024
    // 4096 最大边可保留常见 4032×3024 照片；更大文件先缩略，已有 UIImage 超限明确失败。
    // 16 MiPixels 约 64 MiB RGBA，仅约束本模块输出；两路并发、解码器和系统相机还需额外内存。
    static let maxImagePixels = 16 * 1024 * 1024
    static let maxImageDimension = 4096
    static let outputJSONBytes = 2 * 1024 * 1024
    static let concurrentOperations = 2
    static let queuedOperations = 16
}

final class LynxNativeIOExecutor {
    static let shared = LynxNativeIOExecutor()
    static let network = LynxNativeIOExecutor()
    final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            if isCancelled { throw Cancelled() }
        }
        /** 只包裹原子发布动作；长 IO 不持此锁，页面取消不能等待整个拷贝。 */
        func commit<T>(_ operation: () throws -> T) throws -> T {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw Cancelled() }
            return try operation()
        }
    }
    struct Cancelled: Error { }
    private struct Job { let ownerID: String?; let cancellation: Cancellation }
    private let lock = NSLock()
    private let queue: OperationQueue
    private let capacity: Int
    private var jobs: [UUID: Job] = [:]

    init(concurrent: Int = LynxNativePayloadLimits.concurrentOperations, queued: Int = LynxNativePayloadLimits.queuedOperations) {
        precondition(concurrent > 0 && queued >= 0)
        capacity = concurrent + queued
        queue = OperationQueue()
        queue.name = "lynx.native.io"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = concurrent
    }

    func submit(ownerID: String?, completion: @escaping (LynxNativeCapabilityResult) -> Void,
                work: @escaping (Cancellation) -> LynxNativeCapabilityResult) {
        submitAsync(ownerID: ownerID, completion: completion) { cancellation, finish in
            finish(autoreleasepool { work(cancellation) })
        }
    }

    func submitAsync(ownerID: String?, completion: @escaping (LynxNativeCapabilityResult) -> Void,
                     work: @escaping (Cancellation, @escaping (LynxNativeCapabilityResult) -> Void) -> Void) {
        lock.lock()
        guard jobs.count < capacity else {
            lock.unlock()
            completion(.failure("BUSY", "原生 IO 队列已满"))
            return
        }
        let id = UUID()
        let cancellation = Cancellation()
        jobs[id] = Job(ownerID: ownerID, cancellation: cancellation)
        lock.unlock()
        let operation = AsyncOperation { [self] operationFinished in
            let onceLock = NSLock()
            var finished = false
            let finish: (LynxNativeCapabilityResult) -> Void = { result in
                onceLock.lock()
                guard !finished else { onceLock.unlock(); return }
                finished = true
                onceLock.unlock()
                // 结果编码仍属于执行槽；不能先释放槽再并发分配大 JSON。
                completion(cancellation.isCancelled ? .failure("HOST_DESTROYED", "页面已销毁，IO 已取消") : result)
                self.lock.lock()
                self.jobs.removeValue(forKey: id)
                self.lock.unlock()
                operationFinished()
            }
            guard !cancellation.isCancelled, LynxNativeOwnerScope.isActive(ownerID) else {
                finish(.failure("HOST_DESTROYED", "页面已销毁，排队 IO 已取消"))
                return
            }
            work(cancellation, finish)
        }
        queue.addOperation(operation)
    }

    func cancel(ownerID: String) {
        lock.lock()
        let cancellations = jobs.values.filter { $0.ownerID == ownerID }.map(\.cancellation)
        lock.unlock()
        cancellations.forEach { $0.cancel() }
    }

    /** 异步系统文件读取也占用并发槽，源文件只在 provider 回调有效时立即复制。 */
    private final class AsyncOperation: Operation, @unchecked Sendable {
        private let stateLock = NSRecursiveLock()
        private var executionActive = false
        private var completionReached = false
        private let work: (@escaping () -> Void) -> Void
        init(work: @escaping (@escaping () -> Void) -> Void) { self.work = work; super.init() }
        override var isAsynchronous: Bool { true }
        override var isExecuting: Bool { stateLock.lock(); defer { stateLock.unlock() }; return executionActive }
        override var isFinished: Bool { stateLock.lock(); defer { stateLock.unlock() }; return completionReached }
        override func start() {
            stateLock.lock()
            willChangeValue(forKey: "isExecuting")
            executionActive = true
            didChangeValue(forKey: "isExecuting")
            stateLock.unlock()
            work { [weak self] in self?.finish() }
        }
        private func finish() {
            stateLock.lock()
            guard !completionReached else { stateLock.unlock(); return }
            willChangeValue(forKey: "isExecuting")
            willChangeValue(forKey: "isFinished")
            executionActive = false
            completionReached = true
            didChangeValue(forKey: "isFinished")
            didChangeValue(forKey: "isExecuting")
            stateLock.unlock()
        }
    }
}
