package com.example.lynxshell.transition

import android.content.Intent
import android.graphics.Rect
import android.os.SystemClock

/** 单个共享元素在源 Activity 侧冻结的几何和快照。 */
data class AndroidSharedElementSnapshot(
    val key: String,
    val rectOnScreen: Rect,
    val snapshotToken: String,
)

enum class LynxTransitionStatus(val wireName: String) {
    IDLE("idle"),
    ACCEPTED("accepted"),
    WAITING_TARGET("waitingTarget"),
    RUNNING("running"),
    SETTLING("settling"),
    COMPLETED("completed"),
    CANCELLED("cancelled"),
    DEGRADED("degraded"),
    FAILED("failed"),
}

enum class LynxTransitionDirection(val wireName: String) {
    PUSH("push"),
    POP("pop"),
}

/** Bitmap 仅通过 token 留在进程内存；此 ticket 自身可以安全写成小型 Intent metadata。 */
data class AndroidTransitionTicket(
    val transactionID: String,
    val requestedTransition: LynxTransitionStyle,
    val effectiveTransition: LynxTransitionStyle,
    val fallbackTransition: LynxTransitionStyle,
    val direction: LynxTransitionDirection = LynxTransitionDirection.PUSH,
    val routeKey: String,
    val sourceEntryID: String?,
    val targetEntryID: String,
    val spec: LynxTransitionSpec,
    val sourceElements: List<AndroidSharedElementSnapshot> = emptyList(),
    // 下面两个字段保留给旧单元素事务；新事务统一读 sourceElements。
    val sourceRectOnScreen: Rect? = null,
    val sourceWindowSnapshotToken: String? = null,
    val sourceElementSnapshotToken: String? = null,
    val sourceWindowWidth: Int = 0,
    val sourceWindowHeight: Int = 0,
    val reason: String? = null,
    val createdAtElapsedMs: Long = SystemClock.elapsedRealtime(),
)

data class LynxTransitionState(
    val transactionID: String = "",
    val status: LynxTransitionStatus = LynxTransitionStatus.IDLE,
    val requestedTransition: LynxTransitionStyle = LynxTransitionStyle.DEFAULT,
    val effectiveTransition: LynxTransitionStyle = LynxTransitionStyle.DEFAULT,
    val direction: LynxTransitionDirection = LynxTransitionDirection.PUSH,
    val progress: Float = 0f,
    val reason: String? = null,
    val routeKey: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
) {
    fun toMap(): HashMap<String, Any> = hashMapOf<String, Any>(
        "transactionID" to transactionID,
        "status" to status.wireName,
        "requestedTransition" to requestedTransition.wireName,
        "effectiveTransition" to effectiveTransition.wireName,
        "direction" to direction.wireName,
        "progress" to progress.coerceIn(0f, 1f),
        "updatedAt" to updatedAt,
    ).apply {
        reason?.let { put("reason", it) }
        routeKey?.let { put("routeKey", it) }
    }
}

/** 只把恢复后仍有诊断价值的小字段写进 Intent，绝不写 Bitmap 或页面 View。 */
object LynxTransitionIntent {
    const val EXTRA_TRANSACTION_ID = "lynx_shell.transition.transaction_id"
    private const val EXTRA_REQUESTED = "lynx_shell.transition.requested"
    private const val EXTRA_EFFECTIVE = "lynx_shell.transition.effective"
    private const val EXTRA_DIRECTION = "lynx_shell.transition.direction"
    private const val EXTRA_REASON = "lynx_shell.transition.reason"
    private const val EXTRA_ROUTE_KEY = "lynx_shell.transition.route_key"
    private const val EXTRA_DURATION = "lynx_shell.transition.duration_ms"
    private const val EXTRA_READY_TIMEOUT = "lynx_shell.transition.ready_timeout_ms"
    const val EXTRA_PREPARED_ROUTE_TOKEN = "lynx_shell.prepared_route_token"

    fun write(intent: Intent, ticket: AndroidTransitionTicket): Intent = intent.apply {
        putExtra(EXTRA_TRANSACTION_ID, ticket.transactionID)
        putExtra(EXTRA_REQUESTED, ticket.requestedTransition.wireName)
        putExtra(EXTRA_EFFECTIVE, ticket.effectiveTransition.wireName)
        putExtra(EXTRA_DIRECTION, ticket.direction.wireName)
        putExtra(EXTRA_ROUTE_KEY, ticket.routeKey)
        putExtra(EXTRA_DURATION, ticket.spec.durationMs)
        putExtra(EXTRA_READY_TIMEOUT, ticket.spec.readyTimeoutMs)
        ticket.reason?.let { putExtra(EXTRA_REASON, it) }
    }

    fun transactionID(intent: Intent): String? =
        intent.getStringExtra(EXTRA_TRANSACTION_ID)?.takeIf { it.isNotBlank() }

    fun effectiveTransition(intent: Intent): LynxTransitionStyle? =
        intent.getStringExtra(EXTRA_EFFECTIVE)
            ?.let { runCatching { LynxTransitionStyle.fromWireName(it) }.getOrNull() }

    fun markDegraded(
        intent: Intent,
        effectiveTransition: LynxTransitionStyle,
        reason: String,
    ) {
        intent.putExtra(EXTRA_EFFECTIVE, effectiveTransition.wireName)
        intent.putExtra(EXTRA_REASON, reason)
    }

    fun diagnosticState(intent: Intent): LynxTransitionState? {
        val transactionID = transactionID(intent) ?: return null
        val requested = intent.getStringExtra(EXTRA_REQUESTED)
            ?.let { runCatching { LynxTransitionStyle.fromWireName(it) }.getOrNull() }
            ?: LynxTransitionStyle.DEFAULT
        val effective = intent.getStringExtra(EXTRA_EFFECTIVE)
            ?.let { runCatching { LynxTransitionStyle.fromWireName(it) }.getOrNull() }
            ?: requested
        val direction = if (
            intent.getStringExtra(EXTRA_DIRECTION) == LynxTransitionDirection.POP.wireName
        ) {
            LynxTransitionDirection.POP
        } else {
            LynxTransitionDirection.PUSH
        }
        return LynxTransitionState(
            transactionID = transactionID,
            status = LynxTransitionStatus.DEGRADED,
            requestedTransition = requested,
            effectiveTransition = if (
                effective == LynxTransitionStyle.SHARED_ELEMENT ||
                effective == LynxTransitionStyle.OPEN_CONTAINER
            ) {
                LynxTransitionStyle.FADE
            } else {
                effective
            },
            direction = direction,
            reason = intent.getStringExtra(EXTRA_REASON) ?: "snapshot_unavailable",
            routeKey = intent.getStringExtra(EXTRA_ROUTE_KEY),
        )
    }

    /** 在 LynxView 创建前注入，使目标页面首屏即可取得 transactionID。 */
    fun globalProps(intent: Intent): HashMap<String, Any>? {
        val transactionID = transactionID(intent) ?: return null
        return hashMapOf(
            "transactionID" to transactionID,
            "requestedTransition" to (
                intent.getStringExtra(EXTRA_REQUESTED)
                    ?: LynxTransitionStyle.DEFAULT.wireName
                ),
            "effectiveTransition" to (
                intent.getStringExtra(EXTRA_EFFECTIVE)
                    ?: LynxTransitionStyle.DEFAULT.wireName
                ),
            "direction" to (
                intent.getStringExtra(EXTRA_DIRECTION)
                    ?: LynxTransitionDirection.PUSH.wireName
                ),
        )
    }
}
