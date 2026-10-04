package com.example.lynxcapacitormodule

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class NativeReadinessOwnerTest {
    @Test fun destroyEndsPendingOnceAndRejectsLateSuccess() {
        val owner = NativeOwnerScope(); val destroyed = AtomicInteger(); val success = AtomicInteger()
        val call = owner.call { destroyed.incrementAndGet() }
        owner.end(); owner.end()
        assertFalse(call.complete { success.incrementAndGet() })
        assertEquals(1, destroyed.get()); assertEquals(0, success.get())
    }
    @Test fun naturalCompletionWinsOnce() {
        val owner = NativeOwnerScope(); val results = AtomicInteger()
        val call = owner.call { results.incrementAndGet() }
        assertTrue(call.complete { results.incrementAndGet() })
        assertFalse(call.complete { results.incrementAndGet() })
        owner.end(); assertEquals(1, results.get())
    }
    @Test fun completedResourcesAreReturnedBeforeDestroy() {
        val owner = NativeOwnerScope(); val key = Any(); val cleanup = AtomicInteger()
        owner.own(key) { cleanup.incrementAndGet() }; owner.disown(key); owner.end()
        assertEquals(0, cleanup.get())
    }
    @Test fun unrelatedOwnerRetainsSameLogicalRequest() {
        val a = NativeOwnerScope(); val b = NativeOwnerScope(); val aDone = AtomicInteger(); val bDone = AtomicInteger()
        a.call { aDone.incrementAndGet() }; val next = b.call { bDone.incrementAndGet() }
        a.end(); assertTrue(next.complete { bDone.incrementAndGet() }); b.end()
        assertEquals(1, aDone.get()); assertEquals(1, bDone.get())
    }
    @Test fun cleanupAddedAfterDestroyRunsImmediately() {
        val owner = NativeOwnerScope(); val count = AtomicInteger(); owner.end()
        owner.own(Any()) { count.incrementAndGet() }; assertEquals(1, count.get())
    }
    @Test fun destroyAndCompletionRaceHasOneTerminal() {
        repeat(100) {
            val owner = NativeOwnerScope(); val result = AtomicInteger(); val call = owner.call { result.incrementAndGet() }
            val start = CountDownLatch(1)
            val a = Thread { start.await(); owner.end() }; val b = Thread { start.await(); call.complete { result.incrementAndGet() } }
            a.start(); b.start(); start.countDown(); a.join(2000); b.join(2000)
            assertFalse(a.isAlive); assertFalse(b.isAlive); assertEquals(1, result.get())
        }
    }
    @Test fun cancellationBeforeCommitDoesNotWrite() {
        val owner = NativeOwnerScope(); var committed = false; owner.end()
        try { NativeCallContext.withOwner(owner) { NativeCallContext.commit { committed = true } }; fail("应取消") }
        catch (_: NativeCallCancelled) { }
        assertFalse(committed)
    }
    @Test fun commitLinearizesBeforeConcurrentDestroy() {
        val owner = NativeOwnerScope(); val inside = CountDownLatch(1); val release = CountDownLatch(1); val ended = CountDownLatch(1)
        var committed = false
        val writer = Thread { NativeCallContext.withOwner(owner) { NativeCallContext.commit { inside.countDown(); release.await(); committed = true } } }
        writer.start(); assertTrue(inside.await(2, TimeUnit.SECONDS))
        val destroy = Thread { owner.end(); ended.countDown() }; destroy.start()
        assertFalse(ended.await(50, TimeUnit.MILLISECONDS)); release.countDown(); writer.join(2000); destroy.join(2000)
        assertTrue(committed); assertFalse(owner.isActive)
    }
    @Test fun windowLeasePreservesOtherOwnerAndOriginalValue() {
        var flag = false; val window = Any(); val a = Any(); val b = Any()
        val leases = NativeBooleanLeases<Any, Any>({ flag }, { _, value -> flag = value })
        leases.acquire(window, a); leases.acquire(window, b); leases.release(window, a); assertTrue(flag)
        leases.release(window, b); assertFalse(flag); leases.release(window, b); assertFalse(flag)
    }
    @Test fun preexistingWindowFlagRestoredAfterFinalRelease() {
        var flag = true; val window = Any(); val owner = Any()
        val leases = NativeBooleanLeases<Any, Any>({ flag }, { _, value -> flag = value })
        leases.acquire(window, owner); leases.acquire(window, owner); leases.release(window, owner); assertTrue(flag)
    }
}
