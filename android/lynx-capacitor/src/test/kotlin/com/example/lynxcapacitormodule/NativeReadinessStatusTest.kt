package com.example.lynxcapacitormodule

import android.content.Context
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class NativeReadinessStatusTest {
    @Test fun missingHostKeepsWritesPartialAndReadFallbackAvailable() {
        val previous = NativeHostRegistry.provider
        try {
            NativeHostRegistry.install(null)
            val status = JSONArray(NativeCapabilityStatusSnapshot.build())
            val item = (0 until status.length()).map { status.getJSONObject(it) }.first { it.getString("name") == "StatusBar" }
            assertEquals("partial", item.getString("state")); assertEquals("partial", item.getString("semanticState")); assertFalse(item.getBoolean("hostConfigured"))
            val methods = item.getJSONArray("methodStatus")
            assertEquals("native", methods.getJSONObject(0).getString("state"))
            assertEquals("partial", methods.getJSONObject(1).getString("state"))
        } finally { NativeHostRegistry.install(previous) }
    }
    @Test fun installedSnapshotNeverResolvesHostSynchronously() {
        val previous = NativeHostRegistry.provider
        val provider = object : LynxCapacitorHostProvider {
            override val supportedMethods = setOf("StatusBar.setStyle", "TextZoom.set")
            override fun resolve(callerContext: Context): LynxCapacitorHost? = error("同步查询不能访问实际 Host")
            override fun release(callerContext: Context) = error("同步查询不能释放实际 Host")
        }
        try {
            NativeHostRegistry.install(provider)
            val status = JSONArray(NativeCapabilityStatusSnapshot.build())
            val item = (0 until status.length()).map { status.getJSONObject(it) }.first { it.getString("name") == "StatusBar" }
            assertTrue(item.getBoolean("hostConfigured")); assertEquals("checkRequired", item.getString("runtimeAvailability")); assertEquals("partial", item.getString("state"))
            assertEquals("StatusBar.setStyle", item.getJSONArray("hostMethods").getString(0))
        } finally { NativeHostRegistry.install(previous) }
    }
    @Test fun capabilityCountAndMethodOrderArePreserved() {
        val items = JSONArray(NativeCapabilityStatusSnapshot.build())
        assertEquals(40, items.length()); assertEquals(146, NativeCapabilityCatalog.specs.sumOf { it.methods.size })
        NativeCapabilityCatalog.specs.forEachIndexed { index, spec ->
            assertEquals(spec.id, items.getJSONObject(index).getString("name"))
            assertEquals(spec.methods, (0 until items.getJSONObject(index).getJSONArray("methods").length()).map { items.getJSONObject(index).getJSONArray("methods").getString(it) })
        }
    }
}
