package com.example.lynxshell.runtime

import com.lynx.xelement.XElementBehaviors
import org.junit.Assert.assertTrue
import org.junit.Test

class XElementRuntimeTest {
    @Test
    fun `Lynx 4 1 aggregate registers video`() {
        val behaviorNames = XElementBehaviors().create().map { it.name }.toSet()

        assertTrue("4.1 xelement aggregate must register video", "video" in behaviorNames)
    }
}
