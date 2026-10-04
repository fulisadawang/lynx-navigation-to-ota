package com.example.lynxcapacitormodule

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeReadinessConstructionTest {
    @Test fun oldOwnerReleaseAllowsNewLazyModuleToActivate() {
        val gate = NativeActiveContext<Any>(); val oldContext = Any(); val next = Any()
        gate.activate(oldContext); assertFalse(gate.canActivate(next)); assertTrue(gate.release(oldContext))
        assertTrue(gate.canActivate(next)); gate.activate(next); assertTrue(gate.canActivate(next))
    }
    @Test fun alreadyActiveNewViewRetainsLazyModuleRouteWhenOldOwnerEnds() {
        val gate = NativeActiveContext<Any>(); val oldContext = Any(); val next = Any()
        gate.activate(oldContext); gate.activate(next); assertFalse(gate.release(oldContext))
        assertTrue(gate.canActivate(next)); assertFalse(gate.canActivate(oldContext))
    }
    @Test fun delayedOldActivationCannotOverrideNewView() {
        val gate = NativeActiveContext<Any>(); val delayed = Any(); val next = Any()
        assertTrue(gate.canActivate(delayed)); gate.activate(next)
        assertFalse(gate.canActivate(delayed)); assertTrue(gate.canActivate(next))
    }
    @Test fun realDirectoryAdapterUsesProductionLocalRouteAndLeavesMainHeartbeatFree() {
        val folder = Files.createTempDirectory("lynx-cap-route").toFile()
        val owner = NativeOwnerScope(); val callingThread = Thread.currentThread()
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val done = CountDownLatch(1)
        val mainQueue = ConcurrentLinkedQueue<() -> Unit>()
        var worker: Thread? = null; var result: JSONArray? = null
        try {
            File(folder, "b").createNewFile(); File(folder, "a").createNewFile()
            NativeExecutionPolicy.schedule("Filesystem", "readdir", owner,
                { mainQueue.add(it) }, { fail("不应拒绝正常目录请求") }) {
                worker = Thread.currentThread(); entered.countDown(); release.await()
                val actual = NativeDirectoryIO.read(folder)
                mainQueue.add { result = actual }
                done.countDown()
            }
            assertTrue(entered.await(2, TimeUnit.SECONDS)); assertNotSame(callingThread, worker)
            var heartbeat = false
            mainQueue.add { heartbeat = true }; mainQueue.poll()!!.invoke()
            assertTrue(heartbeat); assertNull(result)
            release.countDown(); assertTrue(done.await(3, TimeUnit.SECONDS)); mainQueue.poll()!!.invoke()
            assertEquals("a", result!!.getJSONObject(0).getString("name")); assertEquals("b", result!!.getJSONObject(1).getString("name"))
        } finally { release.countDown(); owner.end(); folder.deleteRecursively() }
    }
    @Test fun contentProviderMethodsUseLocalRouteAndPermissionRequestsStayOnUI() {
        for ((plugin, methods) in mapOf("Contacts" to listOf("save", "find", "remove"), "Calendar" to listOf("createCalendar", "createEvent", "findEvents", "deleteEvent", "deleteCalendar", "listCalendars"))) {
            methods.forEach { assertEquals(NativeExecutionPolicy.Lane.LOCAL, NativeExecutionPolicy.lane(plugin, it)) }
            for (method in listOf("checkPermissions", "requestPermissions")) assertEquals(NativeExecutionPolicy.Lane.UI, NativeExecutionPolicy.lane(plugin, method))
        }
        for (method in listOf("readFile", "writeFile", "readdir", "stat", "mkdir", "getUri")) assertEquals(NativeExecutionPolicy.Lane.LOCAL, NativeExecutionPolicy.lane("Filesystem", method))
        assertEquals(NativeExecutionPolicy.Lane.UI, NativeExecutionPolicy.lane("Dialog", "alert"))
    }
    @Test fun multiColumnRowRejectsFourthLargeCellBeforeItIsAppended() {
        val budget = NativeJsonBudget(); val text = "a".repeat(NativePayloadBudget.INLINE_BYTES); var produced = 0
        val cells = sequence { repeat(100) { produced++; yield(text) } }
        try { budget.row(cells); fail("不能先构建 100 个大列") }
        catch (error: NativeBudgetExceeded) { assertEquals("RESULT_TOO_LARGE", error.code) }
        assertEquals(4, produced); assertTrue(budget.usedBytes <= NativePayloadBudget.RESULT_BYTES)
    }
    @Test fun rejectedArrayElementDoesNotMutateExistingCollection() {
        val budget = NativeJsonBudget(limit = 64, initialBytes = 0); val items = budget.array()
        budget.append(items, "first")
        try { budget.append(items, JSONObject().put("uri", "a".repeat(100))); fail("应拒绝过大 URI 结果") }
        catch (error: NativeBudgetExceeded) { assertEquals("RESULT_TOO_LARGE", error.code) }
        assertEquals(1, items.length()); assertEquals("first", items.getString(0))
    }
    @Test fun escapedStringConsumesEncodedBudgetBeforeSerialization() {
        val budget = NativeJsonBudget(limit = 128, initialBytes = 0); val values = budget.array()
        try { budget.append(values, "\u0000".repeat(22)); fail("转义后超过预算") }
        catch (_: NativeBudgetExceeded) { }
        assertEquals(0, values.length())
    }
    @Test fun realLargeDirectoryStopsAtBudgetWithoutReturningHugeSuccessfulArray() {
        val folder = Files.createTempDirectory("lynx-cap-dir").toFile()
        try {
            repeat(4096) { File(folder, "n${it.toString().padStart(4, '0')}-" + "a".repeat(225)).createNewFile() }
            try { NativeDirectoryIO.read(folder); fail("应拒绝超过 2 MiB 的实际目录") }
            catch (error: NativeBudgetExceeded) { assertEquals("RESULT_TOO_LARGE", error.code) }
        } finally { folder.deleteRecursively() }
    }
    @Test fun mediaCopyDoesNotWriteChunkReadAfterOwnerDestroyed() {
        val owner = NativeOwnerScope(); val output = ByteArrayOutputStream()
        val input = object : ByteArrayInputStream(ByteArray(20_000)) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                val count = super.read(buffer, offset, length); owner.end(); return count
            }
        }
        try { NativeCallContext.withOwner(owner) { NativePayloadBudget.copy(input, output) }; fail("应取消") }
        catch (_: NativeCallCancelled) { }
        assertEquals(0, output.size())
    }
    @Test fun mediaCopyStopsBetweenChunks() {
        val owner = NativeOwnerScope(); var written = 0
        val output = object : ByteArrayOutputStream() {
            override fun write(buffer: ByteArray, offset: Int, length: Int) {
                super.write(buffer, offset, length); written += length; owner.end()
            }
        }
        try { NativeCallContext.withOwner(owner) { NativePayloadBudget.copy(ByteArrayInputStream(ByteArray(20_000)), output) }; fail("应取消") }
        catch (_: NativeCallCancelled) { }
        assertEquals(8192, written)
    }
}
