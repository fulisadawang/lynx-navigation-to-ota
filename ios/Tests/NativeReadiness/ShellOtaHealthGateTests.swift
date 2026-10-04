import XCTest
@testable import LynxShellKitE2ECore

final class ShellOtaHealthGateTests: XCTestCase {
    func testFirstScreenAloneDoesNotConfirmCandidate() {
        var gate = LynxOtaHealthGate()
        gate.markFirstScreen()
        XCTAssertFalse(gate.beginConfirmation())
        XCTAssertFalse(gate.confirmed)
    }

    func testBusinessSignalAloneDoesNotConfirmCandidate() {
        var gate = LynxOtaHealthGate()
        gate.markBusinessHealth()
        XCTAssertFalse(gate.beginConfirmation())
    }

    func testBothSignalOrdersConfirmExactlyOnce() {
        for businessFirst in [true, false] {
            var gate = LynxOtaHealthGate()
            if businessFirst { gate.markBusinessHealth(); gate.markFirstScreen() }
            else { gate.markFirstScreen(); gate.markBusinessHealth() }
            XCTAssertTrue(gate.beginConfirmation())
            XCTAssertFalse(gate.beginConfirmation())
            XCTAssertTrue(gate.completeConfirmation())
            XCTAssertTrue(gate.confirmed)
            XCTAssertFalse(gate.completeConfirmation())
            XCTAssertFalse(gate.beginConfirmation())
        }
    }

    func testFailureInvalidatesQueuedReadyAndHealthSignals() {
        var gate = LynxOtaHealthGate()
        gate.markFirstScreen()
        gate.fail()
        gate.markBusinessHealth()
        gate.markFirstScreen()
        XCTAssertFalse(gate.beginConfirmation())
        XCTAssertFalse(gate.confirmed)
    }

    func testFailureDuringConfirmationRejectsLateSuccess() {
        var gate = LynxOtaHealthGate()
        gate.markFirstScreen(); gate.markBusinessHealth()
        XCTAssertTrue(gate.beginConfirmation())
        gate.fail()
        XCTAssertFalse(gate.completeConfirmation())
        XCTAssertFalse(gate.confirmed)
    }

    func testFailureAfterConfirmationDoesNotReclassifyStableReleaseAsTrial() {
        var gate = LynxOtaHealthGate()
        gate.markFirstScreen(); gate.markBusinessHealth()
        XCTAssertTrue(gate.beginConfirmation())
        XCTAssertTrue(gate.completeConfirmation())
        gate.fail()
        XCTAssertTrue(gate.confirmed)
        XCTAssertFalse(gate.beginConfirmation())
    }

    func testNewGenerationUsesFreshGateWithoutOldHealthFacts() {
        var old = LynxOtaHealthGate()
        old.markFirstScreen(); old.markBusinessHealth(); old.fail()
        var replacement = LynxOtaHealthGate()
        XCTAssertFalse(replacement.firstScreenReached)
        XCTAssertFalse(replacement.businessHealthMarked)
        XCTAssertFalse(replacement.beginConfirmation())
    }
}
