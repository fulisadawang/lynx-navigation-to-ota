package com.example.lynxshell.monitoring

internal enum class BusinessEventRejection(val code: Int, val reasonCode: String, val message: String) {
    INVALID_ARGUMENT(1001, "invalid_argument", "业务事件参数不合法"),
    EVENT_TOO_LARGE(1001, "event_too_large", "业务事件超过大小上限"),
    PAGE_CONTEXT_UNAVAILABLE(1002, "page_context_unavailable", "当前页面没有活动监控上下文"),
    NOT_CONFIGURED(1004, "not_configured", "宿主尚未启用监控或配置 Provider"),
    NOT_READY(1004, "not_ready", "监控当前无法接受业务事件"),
    MONITOR_CLOSED(1004, "monitor_closed", "监控已经关闭"),
    EVENT_UNSUPPORTED(1004, "event_unsupported", "当前 Provider 不支持业务事件"),
    QUEUE_REJECTED(1004, "queue_rejected", "监控队列无法接受本次业务事件"),
    INTERNAL_ERROR(1500, "internal_error", "业务事件接收失败"),
}

/** Queued 只证明 Core 已完成 append，不代表 Provider 或云端收件。 */
internal sealed interface QueueAdmissionResult {
    data class Queued(val eventId: String, val monitorState: String) : QueueAdmissionResult
    data class Rejected(val rejection: BusinessEventRejection) : QueueAdmissionResult
}
