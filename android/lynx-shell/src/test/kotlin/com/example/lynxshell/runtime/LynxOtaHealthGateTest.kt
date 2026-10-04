package com.example.lynxshell.runtime

import org.junit.Assert.*
import org.junit.Test

class LynxOtaHealthGateTest {
    @Test fun businessBeforeFirstScreenWaitsForActualFirstScreen() {
        val gate = LynxOtaHealthGate()
        gate.markBusinessHealth()
        assertFalse(gate.beginConfirmation())
        gate.markFirstScreen()
        assertTrue(gate.beginConfirmation())
        assertTrue(gate.completeConfirmation())
        assertTrue(gate.confirmed)
    }

    @Test fun firstScreenBeforeBusinessNeverPromotesAlone() {
        val gate = LynxOtaHealthGate()
        gate.markFirstScreen()
        assertFalse(gate.beginConfirmation())
        gate.markBusinessHealth()
        assertTrue(gate.beginConfirmation())
    }

    @Test fun duplicateSignalsStartOnlyOneConfirmation() {
        val gate = readyGate()
        assertTrue(gate.beginConfirmation())
        gate.markFirstScreen()
        gate.markBusinessHealth()
        assertFalse(gate.beginConfirmation())
        assertTrue(gate.completeConfirmation())
        assertFalse(gate.beginConfirmation())
        assertFalse(gate.completeConfirmation())
    }

    @Test fun failureBeforeBothSignalsRejectsAllLateSignals() {
        val gate = LynxOtaHealthGate()
        gate.markBusinessHealth()
        gate.fail()
        gate.markFirstScreen()
        gate.markBusinessHealth()
        assertTrue(gate.failed)
        assertFalse(gate.firstScreenReached)
        assertFalse(gate.beginConfirmation())
        assertFalse(gate.completeConfirmation())
    }

    @Test fun destroyDuringConfirmationCannotAcceptCompletion() {
        val gate = readyGate()
        assertTrue(gate.beginConfirmation())
        gate.fail()
        assertFalse(gate.confirming)
        assertFalse(gate.completeConfirmation())
        assertFalse(gate.confirmed)
    }

    @Test fun failureAfterCommitRetainsConfirmedFactForNoRollback() {
        val gate = readyGate()
        assertTrue(gate.beginConfirmation())
        assertTrue(gate.completeConfirmation())
        gate.fail()
        assertTrue(gate.confirmed)
        assertTrue(gate.failed)
        assertFalse(gate.beginConfirmation())
    }

    @Test fun newGenerationDoesNotInheritOldSignals() {
        val old = readyGate()
        old.beginConfirmation()
        old.fail()
        val next = LynxOtaHealthGate()
        next.markFirstScreen()
        assertFalse(next.beginConfirmation())
        assertFalse(old.completeConfirmation())
        next.markBusinessHealth()
        assertTrue(next.beginConfirmation())
        assertTrue(next.completeConfirmation())
    }

    @Test fun rootTemplateErrorsFailEvenWhenSdkDoesNotMarkFatal() {
        assertTrue(failure(102).requiresErrorState)
        assertTrue(failure(10205).requiresErrorState)
        assertTrue(failure(0, subCode = 10203).requiresErrorState)
    }

    @Test fun resourcesAndWarningsKeepVisiblePageEvenWithFatalMetadata() {
        assertFalse(failure(301, fatal = true).requiresErrorState)
        assertFalse(failure(30202, fatal = true).requiresErrorState)
        assertFalse(failure(0, subCode = 30199, fatal = true).requiresErrorState)
        assertFalse(failure(20101, fatal = true, level = "warn").requiresErrorState)
    }

    @Test fun runtimeFatalFailsWhileNonFatalJsErrorRemainsMonitoredOnly() {
        assertTrue(failure(20101, fatal = true).requiresErrorState)
        assertFalse(failure(20101).requiresErrorState)
        assertFalse(failure(160103).requiresErrorState)
    }

    private fun readyGate() = LynxOtaHealthGate().apply {
        markFirstScreen()
        markBusinessHealth()
    }

    private fun failure(code: Int, subCode: Int = 0, fatal: Boolean = false, level: String = "error") =
        LynxLoadFailure(code, subCode, fatal, level, "测试错误")
}
