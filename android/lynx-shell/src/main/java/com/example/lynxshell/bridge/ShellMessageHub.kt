package com.example.lynxshell.bridge

import android.app.Activity
import android.os.Handler
import android.os.Looper
import com.lynx.jsbridge.Arguments
import com.lynx.react.bridge.JavaOnlyArray
import com.lynx.react.bridge.JavaOnlyMap
import com.lynx.tasm.LynxView
import java.lang.ref.WeakReference

/** 三端统一的 Lynx 页面身份；pageId 指向一次页面实例，而不是 Bundle 名称。 */
data class LynxRouterPageInfo(
    val pageId: String,
    val containerId: String,
    val pageKey: String,
    val hostMode: String,
)

/** 页面向 Android 宿主发送的消息。 */
data class LynxRouterMessage(
    val source: LynxRouterPageInfo,
    val eventName: String,
    val payload: Map<String, Any?>,
)

/** JS -> Native 消息处理器的统一结果。 */
data class LynxRouterMessageReply(
    val accepted: Boolean = true,
    val message: String = "消息已处理",
    val data: Map<String, Any?> = emptyMap(),
)

typealias LynxRouterMessageHandler = (LynxRouterMessage) -> LynxRouterMessageReply

/**
 * Android Activity-first 页面消息中心。
 *
 * 只持有 Activity/LynxView 弱引用；Activity 销毁、singleTop 原位换 Bundle 或重建时，
 * 页面必须先注销旧 Endpoint，再登记新 View。所有发给 Lynx 的事件都切到主线程。
 */
object ShellMessageHub {
    const val LIFECYCLE_EVENT = "lynxRouterLifecycle"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val endpoints = linkedMapOf<String, Endpoint>()
    private var messageHandler: LynxRouterMessageHandler? = null

    private class Endpoint(
        val info: LynxRouterPageInfo,
        activity: Activity,
        view: LynxView,
    ) {
        val activity = WeakReference(activity)
        val view = WeakReference(view)
    }

    fun setMessageHandler(handler: LynxRouterMessageHandler?) {
        synchronized(lock) { messageHandler = handler }
    }

    fun register(info: LynxRouterPageInfo, activity: Activity, view: LynxView) {
        synchronized(lock) {
            endpoints[info.pageId] = Endpoint(info, activity, view)
            pruneLocked()
        }
    }

    fun unregister(pageId: String) {
        if (pageId.isBlank()) return
        synchronized(lock) { endpoints.remove(pageId) }
    }

    fun pageIdFor(activity: Activity): String? = synchronized(lock) {
        pruneLocked()
        endpoints.values.firstOrNull { it.activity.get() === activity }?.info?.pageId
    }

    fun pages(): List<LynxRouterPageInfo> = synchronized(lock) {
        pruneLocked()
        endpoints.values.map { it.info }.sortedBy { it.pageId }
    }

    fun dispatchFromActivity(
        activity: Activity,
        eventName: String,
        payload: Map<String, Any?>,
    ): LynxRouterMessageReply {
        val endpoint: Endpoint
        val handler: LynxRouterMessageHandler?
        synchronized(lock) {
            pruneLocked()
            endpoint = endpoints.values.firstOrNull { it.activity.get() === activity }
                ?: return LynxRouterMessageReply(false, "页面已销毁或 pageId 已失效")
            handler = messageHandler
        }
        if (handler == null) {
            return LynxRouterMessageReply(false, "宿主尚未安装 LynxRouterMessageHandler")
        }
        return runCatching {
            validateEventName(eventName, allowLifecycle = true)
            handler.invoke(LynxRouterMessage(endpoint.info, eventName, payload))
        }.getOrElse { LynxRouterMessageReply(false, it.message ?: "消息参数不合法") }
    }

    fun broadcast(eventName: String, payload: Map<String, Any?>): Int {
        validateEventName(eventName, allowLifecycle = false)
        val live = synchronized(lock) {
            pruneLocked()
            endpoints.values.toList()
        }
        live.forEach { post(it, eventName, payload) }
        return live.size
    }

    fun sendToPage(pageId: String, eventName: String, payload: Map<String, Any?>): Boolean {
        validateEventName(eventName, allowLifecycle = false)
        val endpoint = synchronized(lock) {
            pruneLocked()
            endpoints[pageId]
        } ?: return false
        post(endpoint, eventName, payload)
        return true
    }

    fun sendLifecycle(pageId: String, state: String, reason: String) {
        val endpoint = synchronized(lock) { endpoints[pageId] } ?: return
        post(
            endpoint,
            LIFECYCLE_EVENT,
            mapOf(
                "pageId" to endpoint.info.pageId,
                "containerId" to endpoint.info.containerId,
                "pageKey" to endpoint.info.pageKey,
                "hostMode" to endpoint.info.hostMode,
                "state" to state,
                "reason" to reason,
                "timestampMillis" to System.currentTimeMillis(),
            ),
        )
    }

    private fun post(endpoint: Endpoint, eventName: String, payload: Map<String, Any?>) {
        mainHandler.post {
            endpoint.view.get()?.sendGlobalEvent(
                eventName,
                JavaOnlyArray.of(toNativeMap(payload)),
            )
        }
    }

    private fun toNativeMap(payload: Map<String, Any?>): JavaOnlyMap {
        val values = HashMap<String, Any>()
        payload.forEach { (key, value) ->
            if (value != null) values[key] = value
        }
        return Arguments.makeNativeMap(values)
    }

    private fun validateEventName(value: String, allowLifecycle: Boolean) {
        require(value.trim().isNotEmpty() && value.length <= 128) {
            "eventName 不能为空且不能超过 128 个字符"
        }
        require(allowLifecycle || value != LIFECYCLE_EVENT) {
            "lynxRouterLifecycle 是宿主保留事件"
        }
    }

    private fun pruneLocked() {
        endpoints.entries.removeAll { (_, endpoint) ->
            endpoint.activity.get() == null || endpoint.view.get() == null
        }
    }
}
