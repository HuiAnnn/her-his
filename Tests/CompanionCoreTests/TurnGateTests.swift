import XCTest
@testable import CompanionCore
final class TurnGateTests: XCTestCase {
    func testClosedConversationCannotStartOrAcceptModelOutput() {
        let gate = TurnGate()
        var mutable = gate
        XCTAssertNil(mutable.beginTurn())
        XCTAssertFalse(gate.accepts(0))
    }
    func testNewUserSpeechInvalidatesPreviousModelTurn() {
        var gate = TurnGate(); gate.open()
        let first = gate.beginTurn()!
        let second = gate.beginTurn()!
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }
    func testDeletionInvalidationRejectsInFlightOutput() {
        var gate = TurnGate(); gate.open()
        let token = gate.beginTurn()!
        gate.invalidate()
        XCTAssertFalse(gate.accepts(token))
        XCTAssertTrue(gate.isOpen)
    }
    func testClosedAndReopenedSessionCannotAcceptOldOutput() {
        var gate = TurnGate(); gate.open()
        let old = gate.beginTurn()!
        gate.close(); gate.open()
        XCTAssertFalse(gate.accepts(old))
    }
}
