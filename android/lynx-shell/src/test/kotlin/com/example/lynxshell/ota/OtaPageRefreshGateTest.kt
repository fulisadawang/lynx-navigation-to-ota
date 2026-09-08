package com.example.lynxshell.ota

import org.junit.Assert.*
import org.junit.Test

class OtaPageRefreshGateTest {
    @Test fun oldCapturedEpochCannotReserveAfterUserSwitch() {
        val gate = OtaPageRefreshGate(1)
        gate.reset(2)
        assertFalse(gate.reserve("10000001", 1, 0, 1800000))
        assertTrue(gate.reserve("10000001", 2, 0, 1800000))
    }
    @Test fun oldCompletionCannotRemoveNewUserReservation() {
        val gate = OtaPageRefreshGate(1)
        assertTrue(gate.reserve("10000001", 1, 0, 0))
        gate.reset(2)
        assertTrue(gate.reserve("10000001", 2, 0, 0))
        gate.complete("10000001", 1)
        assertFalse(gate.reserve("10000001", 2, 1, 0))
        gate.complete("10000001", 2)
        assertTrue(gate.reserve("10000001", 2, 1, 0))
    }
    @Test fun oldSuccessCannotPostponeNewUserRefresh() {
        val gate = OtaPageRefreshGate(1)
        gate.reset(2)
        gate.markSuccess(listOf("10000001"), 1, 100)
        assertTrue(gate.reserve("10000001", 2, 101, 1800000))
    }
    @Test fun thirtyMinuteBoundaryAndAppIsolationArePreserved() {
        val gate = OtaPageRefreshGate(1)
        gate.markSuccess(listOf("10000001"), 1, 0)
        assertFalse(gate.reserve("10000001", 1, 1799999, 1800000))
        assertTrue(gate.reserve("10000001", 1, 1800000, 1800000))
        assertTrue(gate.reserve("10000002", 1, 1, 1800000))
    }
    @Test fun switchClearsSuccessWhileSameEpochClearAppAllowsExplicitRepair() {
        val gate = OtaPageRefreshGate(1)
        gate.markSuccess(listOf("10000001"), 1, 100)
        gate.reset(2)
        assertTrue(gate.reserve("10000001", 2, 101, 1800000))
        gate.clearApp("10000001")
        assertTrue(gate.reserve("10000001", 2, 102, 1800000))
    }
}
