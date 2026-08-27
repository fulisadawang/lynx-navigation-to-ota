import Foundation

/**
 * Native Tab 异步加载的代际门禁。
 *
 * 切换/刷新会让上一代 resolveCurrent 结果失效；即使旧任务在取消后才返回，
 * 也不能把旧 Bundle 或旧错误写回新建的 LynxView。
 */
struct LynxTabLoadGeneration {
    private(set) var current = UUID()

    mutating func begin() -> UUID {
        current = UUID()
        return current
    }

    mutating func invalidate() {
        current = UUID()
    }

    func accepts(_ generation: UUID) -> Bool {
        generation == current
    }
}
