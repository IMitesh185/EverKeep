import XCTest
@testable import EverKeepCore

final class TransactionTests: XCTestCase {
    private func makeTransaction() -> PreservationTransaction {
        PreservationTransaction(id: "t1", assetId: "a1", originalBytes: 100, plan: nil, at: Date(timeIntervalSince1970: 0))
    }

    func testHappyPathIsLegalStepByStep() throws {
        var tx = makeTransaction()
        let path: [TransactionState] = [.preparing, .validating, .ready, .replacing, .verifying, .deleting, .committed]
        for state in path { try tx.move(to: state, at: Date(timeIntervalSince1970: 1), note: nil) }
        XCTAssertEqual(tx.state, .committed)
        XCTAssertTrue(tx.state.isTerminal)
    }

    func testSkippingAStateIsRejected() {
        var tx = makeTransaction()
        XCTAssertThrowsError(try tx.move(to: .deleting, at: Date())) { error in
            XCTAssertEqual(error as? InvalidTransition, InvalidTransition(from: .proposed, to: .deleting))
        }
        XCTAssertEqual(tx.state, .proposed)
    }

    func testTerminalStatesCannotMove() {
        for state in TransactionState.allCases where state.isTerminal {
            for next in TransactionState.allCases {
                XCTAssertFalse(state.canMove(to: next), "\(state) must not move to \(next)")
            }
        }
    }

    func testFailedItemsCanBeRetried() throws {
        var tx = makeTransaction()
        try tx.move(to: .preparing, at: Date())
        try tx.move(to: .failed, at: Date(), note: "boom")
        try tx.move(to: .proposed, at: Date())
        XCTAssertEqual(tx.state, .proposed)
        XCTAssertEqual(tx.note, "boom")
    }

    func testTheLadderCanReturnToPreparing() throws {
        var tx = makeTransaction()
        try tx.move(to: .preparing, at: Date())
        try tx.move(to: .validating, at: Date())
        try tx.move(to: .preparing, at: Date())
        XCTAssertEqual(tx.state, .preparing)
    }

    func testTransactionRoundTripsThroughJSON() throws {
        var tx = makeTransaction()
        try tx.move(to: .preparing, at: Date(timeIntervalSince1970: 5))
        tx.stagingFile = "t1-0.mov"
        tx.finding = goodFinding()
        let data = try JSONEncoder().encode(tx)
        XCTAssertEqual(try JSONDecoder().decode(PreservationTransaction.self, from: data), tx)
    }
}
