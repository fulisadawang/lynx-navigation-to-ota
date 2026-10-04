package com.example.lynxcapacitormodule

import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class NativeReadinessIOTest {
    @Test fun executorHasTwoRunningAndSixteenQueuedSlots() {
        val executor = NativeIOExecutor("test-bounds"); val release = CountDownLatch(1); val started = CountDownLatch(2)
        val running = AtomicInteger(); val peak = AtomicInteger(); val rejected = AtomicInteger(); val finished = CountDownLatch(18)
        try {
            repeat(18) { assertTrue(executor.submit(null, { rejected.incrementAndGet() }) {
                val count = running.incrementAndGet(); peak.updateAndGet { maxOf(it, count) }; started.countDown()
                release.await(); running.decrementAndGet(); finished.countDown()
            }) }
            assertTrue(started.await(2, TimeUnit.SECONDS))
            assertFalse(executor.submit(null, { rejected.incrementAndGet() }) { fail("超队列任务不该执行") })
            assertEquals(2, peak.get()); assertEquals(1, rejected.get()); release.countDown()
            assertTrue(finished.await(3, TimeUnit.SECONDS)); assertEquals(2, peak.get())
        } finally { release.countDown(); executor.shutdown() }
    }
    @Test fun cancelledQueuedOwnerNeverStarts() {
        val executor = NativeIOExecutor("test-cancel", 1, 1); val owner = NativeOwnerScope(); val hold = CountDownLatch(1); val started = CountDownLatch(1); val executed = AtomicInteger(); val final = CountDownLatch(1)
        try {
            executor.submit(null, {}) { started.countDown(); hold.await() }; assertTrue(started.await(2, TimeUnit.SECONDS))
            executor.submit(owner, {}) { executed.incrementAndGet() }; owner.end()
            assertTrue(executor.submit(null, {}) { final.countDown() }); hold.countDown(); assertTrue(final.await(2, TimeUnit.SECONDS))
            assertEquals(0, executed.get())
        } finally { hold.countDown(); executor.shutdown() }
    }
    @Test fun blockedNetworkDoesNotOccupyLocalExecutor() {
        val network = NativeIOExecutor("test-network", 1, 1); val local = NativeIOExecutor("test-local", 1, 1); val hold = CountDownLatch(1); val networkStarted = CountDownLatch(1); val heartbeat = CountDownLatch(1)
        try {
            network.submit(null, {}) { networkStarted.countDown(); hold.await() }; assertTrue(networkStarted.await(2, TimeUnit.SECONDS))
            local.submit(null, {}) { heartbeat.countDown() }; assertTrue(heartbeat.await(2, TimeUnit.SECONDS))
        } finally { hold.countDown(); network.shutdown(); local.shutdown() }
    }
    @Test fun executorRunsOffCallingThread() {
        val executor = NativeIOExecutor("test-thread"); val caller = Thread.currentThread(); val done = CountDownLatch(1); var actual: Thread? = null
        try { executor.submit(null, {}) { actual = Thread.currentThread(); done.countDown() }; assertTrue(done.await(2, TimeUnit.SECONDS)); assertNotSame(caller, actual) }
        finally { executor.shutdown() }
    }
    @Test fun inlineBudgetAcceptsEmptyExactAndRejectsNextByte() {
        assertEquals(0, NativePayloadBudget.read(ByteArrayInputStream(ByteArray(0))).size)
        for (size in listOf(NativePayloadBudget.INLINE_BYTES - 1, NativePayloadBudget.INLINE_BYTES)) assertEquals(size, NativePayloadBudget.read(ByteArrayInputStream(ByteArray(size))).size)
        try { NativePayloadBudget.read(ByteArrayInputStream(ByteArray(NativePayloadBudget.INLINE_BYTES + 1))); fail("应超过预算") }
        catch (error: NativeBudgetExceeded) { assertEquals("PAYLOAD_TOO_LARGE", error.code) }
    }
    @Test fun resultBudgetHasExactBoundary() {
        NativePayloadBudget.check(NativePayloadBudget.RESULT_BYTES.toLong(), NativePayloadBudget.RESULT_BYTES.toLong(), "RESULT_TOO_LARGE")
        try { NativePayloadBudget.check(NativePayloadBudget.RESULT_BYTES.toLong() + 1, NativePayloadBudget.RESULT_BYTES.toLong(), "RESULT_TOO_LARGE"); fail("应超过预算") }
        catch (error: NativeBudgetExceeded) { assertEquals("RESULT_TOO_LARGE", error.code) }
    }
    @Test fun imageBudgetRejectsInvalidAndOversizedDimensions() {
        NativePayloadBudget.checkImage(4096, 4096)
        for ((width, height) in listOf(4097 to 1, 1 to 4097, 0 to 100)) {
            try { NativePayloadBudget.checkImage(width, height); fail("应拒绝尺寸") }
            catch (_: NativeBudgetExceeded) { }
        }
    }
    @Test fun blockReadStopsWhenOwnerEnds() {
        val owner = NativeOwnerScope(); var reads = 0
        val input = object : ByteArrayInputStream(ByteArray(100_000)) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                reads++; val result = super.read(buffer, offset, length); owner.end(); return result
            }
        }
        try { NativeCallContext.withOwner(owner) { NativePayloadBudget.read(input) }; fail("应取消") }
        catch (_: NativeCallCancelled) { }
        assertEquals(1, reads)
    }
    @Test fun atomicWriteReplacesExistingTargetAndLeavesNoParts() {
        val directory = Files.createTempDirectory("lynx-cap-file").toFile()
        try { val target = File(directory, "data"); target.writeText("before"); NativeAtomicFile.write(target, "after".toByteArray()); assertEquals("after", target.readText()); assertEquals(listOf("data"), directory.listFiles()!!.map { it.name }) }
        finally { directory.deleteRecursively() }
    }
    @Test fun cancelledAtomicPublishPreservesOriginalAndRemovesPart() {
        val directory = Files.createTempDirectory("lynx-cap-cancel").toFile(); val owner = NativeOwnerScope()
        try {
            val target = File(directory, "data"); target.writeText("before")
            try { NativeCallContext.withOwner(owner) { NativeAtomicFile.write(target, "after".toByteArray()) { owner.end() } }; fail("应取消") }
            catch (_: NativeCallCancelled) { }
            assertEquals("before", target.readText()); assertEquals(listOf("data"), directory.listFiles()!!.map { it.name })
        } finally { directory.deleteRecursively() }
    }
}
