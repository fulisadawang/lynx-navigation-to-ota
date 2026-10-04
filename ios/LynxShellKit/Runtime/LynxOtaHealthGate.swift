import Foundation

/** 首屏与业务初始化是独立事实；失败后迟到信号不能重新确认同一代页面。 */
struct LynxOtaHealthGate {
    private(set) var firstScreenReached = false
    private(set) var businessHealthMarked = false
    private(set) var confirming = false
    private(set) var confirmed = false
    private(set) var failed = false

    mutating func markFirstScreen() {
        guard !failed else { return }
        firstScreenReached = true
    }

    mutating func markBusinessHealth() {
        guard !failed else { return }
        businessHealthMarked = true
    }

    mutating func beginConfirmation() -> Bool {
        guard firstScreenReached, businessHealthMarked, !failed, !confirmed, !confirming else { return false }
        confirming = true
        return true
    }

    mutating func completeConfirmation() -> Bool {
        guard confirming, !failed else { return false }
        confirming = false
        confirmed = true
        return true
    }

    mutating func fail() {
        failed = true
        confirming = false
    }
}
