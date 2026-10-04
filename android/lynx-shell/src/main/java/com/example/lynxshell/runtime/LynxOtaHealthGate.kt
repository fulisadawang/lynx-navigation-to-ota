package com.example.lynxshell.runtime

/** 首屏和业务初始化是独立事实；失败后的迟到信号不能确认同一代页面。 */
internal class LynxOtaHealthGate {
    var firstScreenReached = false
        private set
    var businessHealthMarked = false
        private set
    var confirming = false
        private set
    var confirmed = false
        private set
    var failed = false
        private set

    fun markFirstScreen() {
        if (!failed) firstScreenReached = true
    }

    fun markBusinessHealth() {
        if (!failed) businessHealthMarked = true
    }

    fun beginConfirmation(): Boolean {
        if (!firstScreenReached || !businessHealthMarked || failed || confirmed || confirming) return false
        confirming = true
        return true
    }

    fun completeConfirmation(): Boolean {
        if (!confirming || failed) return false
        confirming = false
        confirmed = true
        return true
    }

    fun fail() {
        failed = true
        confirming = false
    }
}

/** 在 SDK 回调线程复制错误字段，UI 队列不再读取可变的 LynxError。 */
internal data class LynxLoadFailure(
    val code: Int,
    val subCode: Int,
    val fatal: Boolean,
    val level: String,
    val message: String,
) {
    val requiresErrorState: Boolean
        get() {
            if (level == "warn" || level == "warning") return false
            if (code == 301 || code in 30000..39999 || subCode in 30000..39999) return false
            return fatal || code == 102 || code in 10201..10299 || subCode in 10201..10299
        }
}
