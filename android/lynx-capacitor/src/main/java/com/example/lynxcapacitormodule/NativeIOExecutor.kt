package com.example.lynxcapacitormodule

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** 网络与本地 IO 各有 2 个槽和 16 个排队位，编码结束前不会释放调用占用的槽。 */
internal class NativeIOExecutor(name: String, parallelism: Int = 2, queueLimit: Int = 16) {
    private val sequence = AtomicInteger()
    private val executor = ThreadPoolExecutor(parallelism, parallelism, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue(queueLimit), { action ->
            Thread(action, "$name-${sequence.incrementAndGet()}").apply { isDaemon = true }
        }, ThreadPoolExecutor.AbortPolicy()).apply { allowCoreThreadTimeOut(true) }

    fun submit(owner: NativeOwnerScope?, onRejected: () -> Unit, work: () -> Unit): Boolean {
        lateinit var task: FutureTask<Unit>
        task = FutureTask {
            try { NativeCallContext.withOwner(owner, work) }
            catch (_: NativeCallCancelled) { /* owner 终态已经负责回包 */ }
            finally { owner?.disown(task) }
        }
        owner?.own(task) { task.cancel(true); executor.remove(task) }
        if (task.isCancelled) return false
        return try {
            if (owner == null) executor.execute(task) else owner.commit { executor.execute(task) }
            true
        } catch (_: NativeCallCancelled) { owner?.disown(task); task.cancel(true); false }
        catch (_: RejectedExecutionException) { owner?.disown(task); onRejected(); false }
    }
    internal fun shutdown() { executor.shutdownNow() }
}

internal object NativeIO {
    val local = NativeIOExecutor("lynx-native-io")
    val network = NativeIOExecutor("lynx-native-network")
}
