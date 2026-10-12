package com.example.lynxshell.container

import org.junit.Assert.*
import org.junit.Test

/** 只验证Group所有权、模板成本预算与释放；encodedBytes不等于native RAM。 */
class EngineGroupPoolTest {
    @Test fun idleGroupIsReusedWithoutCallingCreateAgain() {
        val harness = Harness()
        val first = harness.acquire("same", 5)
        assertFalse(first.reused)
        harness.assertSnapshot(active = 1, idle = 0, bytes = 0)
        first.close(reusable = true)
        harness.assertSnapshot(active = 0, idle = 1, bytes = 5)

        val second = harness.pool.acquire("same", 5) { error("已有idle Group不能再create") }
        assertTrue(second.reused)
        assertSame(first.value, second.value)
        harness.assertSnapshot(active = 1, idle = 0, bytes = 0)
        second.close(reusable = false)
        harness.assertSnapshot(active = 0, idle = 0, bytes = 0)
        assertEquals(listOf(first.value), harness.released)
    }

    @Test fun concurrentSameKeyCreatesAnIndependentGroupWithoutStealingActiveLease() {
        val harness = Harness()
        val first = harness.acquire("same", 5)
        val second = harness.acquire("same", 5)
        assertFalse(first.reused)
        assertFalse(second.reused)
        assertNotSame(first.value, second.value)
        harness.assertSnapshot(active = 2, idle = 0, bytes = 0)

        first.close(reusable = true)
        second.close(reusable = true)
        harness.assertSnapshot(active = 0, idle = 2, bytes = 10)
        assertTrue(harness.released.isEmpty())
        harness.pool.clear()
        assertEquals(setOf(first.value, second.value), harness.released.toSet())
        assertEquals(2, harness.released.size)
    }

    @Test fun differentKeysCannotBorrowEachOthersIdleGroup() {
        val harness = Harness()
        val oldScope = harness.acquire("app:10030071/release:a/epoch:0", 5)
        oldScope.close(reusable = true)
        val newScope = harness.acquire("app:10030071/release:a/epoch:1", 5)
        assertFalse(newScope.reused)
        assertNotSame(oldScope.value, newScope.value)
        harness.assertSnapshot(active = 1, idle = 1, bytes = 5)
        newScope.close(reusable = false)
        val oldScopeAgain = harness.acquire("app:10030071/release:a/epoch:0", 5)
        assertTrue(oldScopeAgain.reused)
        assertSame(oldScope.value, oldScopeAgain.value)
        oldScopeAgain.close(reusable = false)
    }

    @Test fun invalidateReleasesMatchingIdleImmediatelyButPreservesOtherKeys() {
        val harness = Harness()
        val retired = harness.acquire("old", 5)
        val valid = harness.acquire("valid", 7)
        retired.close(reusable = true)
        valid.close(reusable = true)
        harness.pool.invalidate { it == "old" }
        harness.assertSnapshot(active = 0, idle = 1, bytes = 7)
        assertEquals(listOf(retired.value), harness.released)
        val validAgain = harness.acquire("valid", 7)
        assertTrue(validAgain.reused)
        assertSame(valid.value, validAgain.value)
        validAgain.close(reusable = false)
    }

    @Test fun invalidatedActiveGroupIsRetiredUntilItsLeaseCloses() {
        val harness = Harness()
        val active = harness.acquire("same", 5)
        harness.pool.invalidate { it == "same" }
        harness.assertSnapshot(active = 1, idle = 0, bytes = 0)
        assertTrue("invalidate不能销毁仍active的Group", harness.released.isEmpty())

        val replacement = harness.acquire("same", 5)
        assertFalse(replacement.reused)
        assertNotSame(active.value, replacement.value)
        active.close(reusable = true)
        harness.assertSnapshot(active = 1, idle = 0, bytes = 0)
        assertEquals(listOf(active.value), harness.released)
        replacement.close(reusable = true)
        harness.assertSnapshot(active = 0, idle = 1, bytes = 5)
        val replacementAgain = harness.acquire("same", 5)
        assertTrue(replacementAgain.reused)
        assertSame(replacement.value, replacementAgain.value)
        replacementAgain.close(reusable = false)
    }

    @Test fun clearRetiresActiveAndDropsIdleWithoutAllowingOldGroupToBeBorrowed() {
        val harness = Harness()
        val active = harness.acquire("same", 5)
        val idle = harness.acquire("idle", 7)
        idle.close(reusable = true)
        harness.pool.clear()
        harness.assertSnapshot(active = 1, idle = 0, bytes = 0)
        assertEquals(listOf(idle.value), harness.released)

        val fresh = harness.acquire("same", 5)
        assertFalse(fresh.reused)
        assertNotSame(active.value, fresh.value)
        active.close(reusable = true)
        fresh.close(reusable = false)
        harness.pool.clear()
        harness.assertSnapshot(active = 0, idle = 0, bytes = 0)
        assertEquals(3, harness.released.size)
        assertEquals(setOf(active.value, idle.value, fresh.value), harness.released.toSet())
    }

    @Test fun idleCountLimitEvictsByReturnOrderRatherThanAcquireOrder() {
        val harness = Harness(maxIdleCount = 2)
        val acquiredFirst = harness.acquire("a", 5)
        val returnedFirst = harness.acquire("b", 5)
        val returnedLast = harness.acquire("c", 5)
        returnedFirst.close(reusable = true)
        acquiredFirst.close(reusable = true)
        returnedLast.close(reusable = true)
        harness.assertSnapshot(active = 0, idle = 2, bytes = 10)
        assertEquals(listOf(returnedFirst.value), harness.released)

        val retained = harness.acquire("a", 5)
        assertTrue(retained.reused)
        assertSame(acquiredFirst.value, retained.value)
        retained.close(reusable = false)
        val evicted = harness.acquire("b", 5)
        assertFalse(evicted.reused)
        assertNotSame(returnedFirst.value, evicted.value)
        evicted.close(reusable = false)
        harness.pool.clear()
    }

    @Test fun encodedByteLimitAcceptsExactBoundaryThenEvictsOldestIdleGroup() {
        val harness = Harness(maxIdleBytes = 10)
        val first = harness.acquire("a", 6)
        val second = harness.acquire("b", 4)
        val third = harness.acquire("c", 5)
        first.close(reusable = true)
        second.close(reusable = true)
        harness.assertSnapshot(active = 1, idle = 2, bytes = 10)
        assertTrue(harness.released.isEmpty())
        third.close(reusable = true)
        harness.assertSnapshot(active = 0, idle = 2, bytes = 9)
        assertEquals(listOf(first.value), harness.released)
        harness.pool.clear()
    }

    @Test fun oversizedGroupIsReleasedOnReturnWithoutEvictingValidIdleGroup() {
        val harness = Harness(maxIdleBytes = 10)
        val valid = harness.acquire("valid", 5)
        valid.close(reusable = true)
        val oversized = harness.acquire("large", 11)
        harness.assertSnapshot(active = 1, idle = 1, bytes = 5)
        oversized.close(reusable = true)
        harness.assertSnapshot(active = 0, idle = 1, bytes = 5)
        assertEquals(listOf(oversized.value), harness.released)
        harness.pool.clear()
    }

    @Test fun zeroIdleCountDisablesRetentionWithoutDestroyingActiveLease() {
        val harness = Harness(maxIdleCount = 0)
        val active = harness.acquire("a", 5)
        harness.assertSnapshot(active = 1, idle = 0, bytes = 0)
        assertTrue(harness.released.isEmpty())
        active.close(reusable = true)
        harness.assertSnapshot(active = 0, idle = 0, bytes = 0)
        assertEquals(listOf(active.value), harness.released)
    }

    @Test fun ttlExpiresAtExactIdleBoundaryWithoutExpiringActiveLease() {
        val harness = Harness(idleTtlMs = 100)
        val idle = harness.acquire("idle", 5)
        val active = harness.acquire("active", 5)
        harness.nowMs = 100
        idle.close(reusable = true)
        harness.nowMs = 199
        harness.pool.evictExpired()
        harness.assertSnapshot(active = 1, idle = 1, bytes = 5)
        assertTrue(harness.released.isEmpty())
        harness.nowMs = 200
        harness.pool.evictExpired()
        harness.assertSnapshot(active = 1, idle = 0, bytes = 0)
        assertEquals(listOf(idle.value), harness.released)
        active.close(reusable = false)
    }

    @Test fun ttlStartsAgainWhenReusedLeaseReturnsToIdle() {
        val harness = Harness(idleTtlMs = 100)
        val first = harness.acquire("same", 5)
        first.close(reusable = true)
        harness.nowMs = 90
        val second = harness.acquire("same", 5)
        assertTrue(second.reused)
        harness.nowMs = 120
        second.close(reusable = true)
        harness.nowMs = 219
        harness.pool.evictExpired()
        harness.assertSnapshot(active = 0, idle = 1, bytes = 5)
        harness.nowMs = 220
        harness.pool.evictExpired()
        harness.assertSnapshot(active = 0, idle = 0, bytes = 0)
        assertEquals(listOf(first.value), harness.released)
    }

    @Test fun acquireCannotBorrowAnExpiredIdleGroup() {
        val harness = Harness(idleTtlMs = 100)
        val first = harness.acquire("same", 5)
        first.close(reusable = true)
        harness.nowMs = 100
        val second = harness.acquire("same", 5)
        assertFalse(second.reused)
        assertNotSame(first.value, second.value)
        assertEquals(listOf(first.value), harness.released)
        second.close(reusable = false)
    }

    @Test fun leaseCloseIsIdempotentAndCannotChangeItsFirstReturnDecision() {
        val harness = Harness()
        val idle = harness.acquire("idle", 5)
        idle.close(reusable = true)
        idle.close(reusable = false)
        harness.assertSnapshot(active = 0, idle = 1, bytes = 5)
        assertTrue(harness.released.isEmpty())
        harness.pool.clear()
        idle.close(reusable = true)
        harness.pool.clear()
        assertEquals(listOf(idle.value), harness.released)

        val dropped = harness.acquire("drop", 5)
        dropped.close(reusable = false)
        dropped.close(reusable = true)
        harness.pool.clear()
        harness.assertSnapshot(active = 0, idle = 0, bytes = 0)
        assertEquals(listOf(idle.value, dropped.value), harness.released)
    }

    @Test fun createFailureLeavesNoEntryAndPreservesOriginalException() {
        val harness = Harness()
        val original = IllegalStateException("真实create失败")
        try {
            harness.pool.acquire("same", 5) { throw original }
            fail("create失败必须向上传递")
        } catch (error: IllegalStateException) {
            assertSame(original, error)
        }
        harness.assertSnapshot(active = 0, idle = 0, bytes = 0)
        assertTrue(harness.released.isEmpty())
        val valid = harness.acquire("same", 5)
        assertFalse(valid.reused)
        valid.close(reusable = false)
    }

    private class Group(val sequence: Int)

    private class Harness(
        maxIdleCount: Int = 10,
        maxIdleBytes: Long = 100,
        idleTtlMs: Long = 1000,
    ) {
        var nowMs = 0L
        private var sequence = 0
        val released = mutableListOf<Group>()
        val pool = EngineGroupPool<String, Group>(
            maxIdleCount, maxIdleBytes, idleTtlMs, now = { nowMs }, release = { released += it },
        )

        fun acquire(key: String, encodedBytes: Long): EngineGroupPool.Lease<Group> =
            pool.acquire(key, encodedBytes) { Group(++sequence) }

        fun assertSnapshot(active: Int, idle: Int, bytes: Long) {
            val snapshot = pool.snapshot
            assertEquals("活体lease数量", active, snapshot.activeCount)
            assertEquals("idle Group数量", idle, snapshot.idleCount)
            assertEquals("idle模板成本", bytes, snapshot.idleEncodedBytes)
        }
    }
}
