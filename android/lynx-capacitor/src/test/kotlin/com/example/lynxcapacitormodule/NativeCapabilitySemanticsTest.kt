package com.example.lynxcapacitormodule

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android 目录是三端协议事实源；这些测试只检查纯目录和语义映射，不启动 Activity。
 */
class NativeCapabilitySemanticsTest {
    @Test
    fun catalogKeepsTheCrossPlatformContract() {
        assertEquals(40, NativeCapabilityCatalog.specs.size)
        assertEquals(146, NativeCapabilityCatalog.specs.sumOf { it.methods.size })
        assertEquals("Motion", NativeCapabilityCatalog.specs[23].id)
        assertEquals(
            listOf("addListener", "removeListener", "removeAllListeners", "start", "stop"),
            NativeCapabilityCatalog.specs[23].methods,
        )
    }

    @Test
    fun statusContainsMethodLevelSemanticFields() {
        NativeCapabilityCatalog.specs.forEach { spec ->
            val methodStatus = spec.methodStatus()
            assertEquals(spec.methods.size, methodStatus.length())
            assertTrue(spec.semanticState in setOf("native", "partial", "unsupported"))
            assertTrue(spec.reasonCode.isNotBlank())
            assertTrue(spec.reason.isNotBlank())
        }

        val biometrics = NativeCapabilityCatalog.find("Biometrics") ?: error("Biometrics missing")
        assertEquals("unsupported", biometrics.semanticState)
        assertEquals("PLATFORM_UNSUPPORTED", biometrics.reasonCode)
        assertEquals(
            "PLATFORM_UNSUPPORTED",
            biometrics.methodStatus().getJSONObject(0).getString("reasonCode"),
        )

        val browser = NativeCapabilityCatalog.find("Browser") ?: error("Browser missing")
        val browserClose = browser.methodStatus().getJSONObject(1)
        assertEquals("close", browserClose.getString("name"))
        assertEquals("unsupported", browserClose.getString("state"))
        assertEquals("EXTERNAL_OWNER", browserClose.getString("reasonCode"))
    }

    @Test
    fun errorCodesHaveStableReasonCodes() {
        assertEquals("METHOD_GAP", LynxCapabilitySemantics.errorReasonCode("UNIMPLEMENTED"))
        assertEquals("PLATFORM_UNSUPPORTED", LynxCapabilitySemantics.errorReasonCode("UNSUPPORTED"))
        assertEquals("RUNTIME_PERMISSION_DENIED", LynxCapabilitySemantics.errorReasonCode("PERMISSION_DENIED"))
        assertEquals("NATIVE_ERROR", LynxCapabilitySemantics.errorReasonCode("SOME_NATIVE_ERROR"))
        assertFalse(LynxCapabilitySemantics.verification().getString("host").isBlank())
    }
}
