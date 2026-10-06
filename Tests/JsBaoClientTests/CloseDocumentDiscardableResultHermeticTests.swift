import Foundation
import XCTest

/// `closeDocument` returns `CloseDocumentResult`, and almost every caller —
/// ours and an app's — closes a document without reading the `evicted` flag
/// back. That is what its `@discardableResult` is for.
///
/// #3437 inserted `discardQueuedOutboundUpdates`, doc comment and all, BETWEEN
/// `closeDocument`'s doc comment and its declaration. Swift binds an attribute
/// to the next declaration, so the attribute moved onto a function returning
/// `Void` (one warning), `closeDocument` lost it (four `[#NoUsage]` warnings at
/// call sites across the client and the app layer), and the
/// "Returns `{ evicted }`" paragraph came to document the wrong function. None
/// of it was caught, because the gate that forbids exactly this could not match
/// a colored diagnostic (#3588).
///
/// An attribute's placement is not something the compiler will ever complain
/// about — it is only wrong relative to what the code means — so it is pinned
/// by reading the source, the way the other structural invariants in this
/// target are.
final class CloseDocumentDiscardableResultHermeticTests: XCTestCase {

    private static let closeDocument = "public func closeDocument("
    private static let discardQueued = "func discardQueuedOutboundUpdates("

    func testCloseDocumentCarriesDiscardableResult() throws {
        let source = try ClientSourceText.clientSource("JsBaoClient.swift")

        XCTAssertEqual(
            ClientSourceText.attributes(before: Self.closeDocument, in: source),
            ["@discardableResult"],
            """
            `closeDocument` must carry @discardableResult: it returns \
            `{ evicted }` for the callers that want it, and every caller that \
            just closes a document would otherwise report `result of call to \
            'closeDocument(_:options:)' is unused`.
            """
        )
    }

    func testDiscardQueuedOutboundUpdatesCarriesNoAttribute() throws {
        let source = try ClientSourceText.clientSource("JsBaoClient.swift")

        XCTAssertEqual(
            ClientSourceText.attributes(before: Self.discardQueued, in: source),
            [],
            """
            `discardQueuedOutboundUpdates` returns Void, so an attribute above \
            it — @discardableResult above all — is at best meaningless and at \
            worst one that belongs to the declaration below.
            """
        )
    }
}
