import XCTest
@testable import JsBaoClient

/// Holding owed sequences back from every claim until they are judged
/// (#3437, behavior 27, finding 3437-SO-02).
///
/// Swift's whole-state claim starts at the DURABLE acked mark plus one, and an
/// ordinary claim starts at this session's floor. After any deferred carry —
/// a flagged seal's, or a returning client's move with a conflict ledger — the
/// deferred sequences are the lowest unacknowledged ones and their content is
/// on no frame this client has sent. A claim that covered them would get them
/// acknowledged by the room and pruned from `_pending_ops` unsent: the writes
/// would be gone with nothing left to resend them.
///
/// The JS client withholds only for the flagged case because its claims come
/// from an in-session ledger of what it has actually transmitted. Swift's
/// mechanism differs (decision 3436's `seqFrom` rule reads the durable mark),
/// so the withhold has to cover EVERY deferral.
final class Format2WithholdHermeticTests: XCTestCase {

    func testAnOrdinaryClaimStopsAboveTheWithheldCeiling() {
        let ledger = Format2OutboundAckLedger()
        ledger.withhold("doc", upTo: 4)
        ledger.note("doc", seq: 5)
        ledger.note("doc", seq: 6)

        let claim = ledger.take("doc", covering: 2)
        XCTAssertEqual(claim?.range?.from, 5)
        XCTAssertEqual(claim?.range?.to, 6)
    }

    func testAClaimWhollyBelowTheCeilingCarriesNoRangeAtAll() {
        let ledger = Format2OutboundAckLedger()
        ledger.note("doc", seq: 1)
        ledger.note("doc", seq: 2)
        ledger.withhold("doc", upTo: 3)

        let claim = ledger.take("doc", covering: 2)
        XCTAssertNotNil(claim, "the places are still taken, so the queue stays aligned")
        XCTAssertNil(
            claim?.range,
            "a frame that can claim nothing above the ceiling stamps no span"
        )
    }

    func testTheWholeStateClaimAlsoStopsAboveTheCeiling() {
        let ledger = Format2OutboundAckLedger()
        ledger.withhold("doc", upTo: 4)

        let claim = ledger.wholeState("doc", from: 1, upTo: 7)
        XCTAssertEqual(
            claim.range?.from, 5,
            "everything the server has not acknowledged EXCEPT what is owed a "
                + "judgement"
        )
        XCTAssertEqual(claim.range?.to, 7)

        XCTAssertNil(
            ledger.wholeState("doc", from: 1, upTo: 4).range,
            "when the whole owed span is withheld the frame claims nothing"
        )
    }

    func testTheCeilingSurvivesForgettingTheQueue() {
        let ledger = Format2OutboundAckLedger()
        ledger.withhold("doc", upTo: 4)
        ledger.note("doc", seq: 5)
        ledger.forgetQueued("doc")
        XCTAssertEqual(
            ledger.withheldCeiling("doc"), 4,
            "a move discards the frames queued against the overlay it leaves, "
                + "and the judgement those sequences are owed is exactly as "
                + "outstanding afterwards as it was before"
        )
    }

    func testAReleaseRestoresTheOrdinaryFloor() {
        let ledger = Format2OutboundAckLedger()
        ledger.withhold("doc", upTo: 4)
        ledger.note("doc", seq: 2)
        XCTAssertNil(
            ledger.take("doc", covering: 1)?.range,
            "while the judgement is owed the frame claims nothing"
        )

        ledger.releaseWithheld("doc")
        XCTAssertEqual(ledger.withheldCeiling("doc"), 0)
        ledger.note("doc", seq: 3)
        XCTAssertEqual(
            ledger.take("doc", covering: 1)?.range?.from, 2,
            "the ordinary floor — this session's own, which never moves "
                + "backwards — applies again once the survivors are stated"
        )
    }

    func testTheCeilingOnlyEverRises() {
        let ledger = Format2OutboundAckLedger()
        ledger.withhold("doc", upTo: 6)
        ledger.withhold("doc", upTo: 3)
        XCTAssertEqual(
            ledger.withheldCeiling("doc"), 6,
            "a second deferral before the first is judged must not lower the "
                + "floor under the sequences already held back"
        )
    }

    func testForgettingADocumentForgetsItsCeiling() {
        let ledger = Format2OutboundAckLedger()
        ledger.withhold("doc", upTo: 4)
        ledger.forget("doc")
        XCTAssertEqual(ledger.withheldCeiling("doc"), 0)
    }

    func testWithholdingIsPerDocument() {
        let ledger = Format2OutboundAckLedger()
        ledger.withhold("held", upTo: 9)
        ledger.note("free", seq: 1)
        ledger.note("free", seq: 2)
        XCTAssertEqual(ledger.take("free", covering: 2)?.range?.from, 1)
    }
}
