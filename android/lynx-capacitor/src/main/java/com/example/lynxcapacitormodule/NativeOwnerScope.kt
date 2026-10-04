package com.example.lynxcapacitormodule

import java.util.concurrent.atomic.AtomicBoolean

/** 每个 NativeModule 独立持有终态和资源，不能把 Activity 当成多个 Tab 的共同 owner。 */
internal class NativeOwnerScope {
    private val lock = Any()
    private var ended = false
    private val calls = LinkedHashSet<Call>()
    private val resources = LinkedHashMap<Any, () -> Unit>()
    val isActive: Boolean get() = synchronized(lock) { !ended }

    fun call(onDestroyed: () -> Unit): Call {
        val call = Call(onDestroyed)
        val cancelled = synchronized(lock) {
            if (ended) true else { calls.add(call); false }
        }
        if (cancelled) call.destroy()
        return call
    }

    inner class Call(private val onDestroyed: () -> Unit) {
        private val done = AtomicBoolean(false)
        fun complete(action: () -> Unit): Boolean {
            // 与 destroy 共用线性化点；自然完成先获得终态时允许该次结果交付。
            val accepted = synchronized(lock) {
                if (ended || !done.compareAndSet(false, true)) false else { calls.remove(this); true }
            }
            if (accepted) action()
            return accepted
        }
        fun destroy() { if (done.compareAndSet(false, true)) onDestroyed() }
    }

    fun own(key: Any, cleanup: () -> Unit) {
        val immediately = synchronized(lock) {
            if (ended) true else { resources[key] = cleanup; false }
        }
        if (immediately) cleanup()
    }
    fun disown(key: Any) { synchronized(lock) { resources.remove(key) } }
    fun <T> commit(action: () -> T): T = synchronized(lock) {
        if (ended || Thread.currentThread().isInterrupted) throw NativeCallCancelled()
        action()
    }
    fun end(): List<Throwable> {
        val snapshot = synchronized(lock) {
            if (ended) return emptyList()
            ended = true
            val result = calls.toList() to resources.values.toList()
            calls.clear(); resources.clear()
            result
        }
        val failures = mutableListOf<Throwable>()
        snapshot.first.forEach { call -> try { call.destroy() } catch (error: Throwable) { failures.add(error) } }
        snapshot.second.forEach { cleanup -> try { cleanup() } catch (error: Throwable) { failures.add(error) } }
        return failures
    }
}

internal class NativeCallCancelled : RuntimeException("调用页面已销毁")
internal class NativeBudgetExceeded(val code: String, message: String) : RuntimeException(message)

/** 只在线程内传播当前调用，不持有全局 Activity，也不改变跨页共享业务数据的所有权。 */
internal object NativeCallContext {
    private val current = ThreadLocal<NativeOwnerScope?>()
    val owner: NativeOwnerScope? get() = current.get()
    fun checkActive() { if (Thread.currentThread().isInterrupted || owner?.isActive == false) throw NativeCallCancelled() }
    fun <T> commit(action: () -> T): T { checkActive(); return owner?.commit(action) ?: action() }
    fun <T> withOwner(owner: NativeOwnerScope?, work: () -> T): T {
        val previous = current.get()
        current.set(owner)
        try { checkActive(); return work() } finally { current.set(previous) }
    }
}
