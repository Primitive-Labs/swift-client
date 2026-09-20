import Foundation

/// Wire constants for large documents (`documentFormat: 2`) on the Swift
/// transport.
///
/// Every value here has a counterpart the server or the JS client already
/// reads; none of them may be restated as a literal at a call site. A number
/// that disagrees with the room is not a Swift bug the Swift tests can see —
/// the room simply refuses the connection.
public enum Format2Transport {

    /// `documentFormat` of a large document.
    public static let documentFormat = 2

    /// The formats this client can read, declared on every `syncStep1`.
    ///
    /// A room hosting a large document refuses any client whose frame does not
    /// contain `2` (`src/yjs-room-v2.ts`, `handleSyncStep1FromLayer`): such a
    /// client would read the current epoch's overlay out of the document's
    /// Y.Maps and take it for the whole document. Mirrors the JS client's
    /// `formats: [1, 2]`.
    public static let formats = [1, 2]

    /// The highest snapshot-manifest shape this client can read
    /// (`FORMAT2_MANIFEST_VERSION` in js-bao, #3432).
    ///
    /// A document whose base is written in a newer shape closes the connection
    /// with the upgrade refusal rather than letting a load finish missing the
    /// chunks this client did not recognize. The Swift loader reads the
    /// sourced chunk-path form and `version: 3` from the start, so this client
    /// declares 3 rather than growing into it.
    public static let manifestVersion = 3

    /// WebSocket close code the room uses for `CLIENT_UPGRADE_REQUIRED`
    /// (`WS_CLOSE_CLIENT_UPGRADE_REQUIRED`, `src/large-documents/handshake.ts`).
    ///
    /// It is a permanent refusal of this client BUILD, not a transient fault,
    /// so it is the one close the reconnect policy does not act on.
    public static let upgradeRequiredCloseCode = 4426

    /// Receive limit for a socket that may carry format-2 frames (#2477).
    ///
    /// Foundation's default is 1 MiB, and `epoch.info` grows with the sealed
    /// chain — one signed download path per sealed epoch — so the frame the
    /// handshake depends on is exactly the one that can exceed the default.
    /// `URLSessionWebSocketTask` fails the RECEIVE, not the handler, on an
    /// oversized message, so the limit has to be raised before the frame can
    /// arrive rather than in response to it.
    ///
    /// A client whose documents are all locally known to be format 1 never
    /// raises it, which is what keeps the intent's "without changing the
    /// format-1 limit" decision true.
    public static let maximumMessageSize = 16 * 1024 * 1024

    /// How long a mid-load grant refresh is waited for
    /// (`FORMAT2_GRANT_REFRESH_TIMEOUT_MS` in the JS client).
    ///
    /// Bounded: a socket that has gone away must not park a load for ever. The
    /// read is then repeated with the grant already held, fails, and is
    /// reported with the status that said what happened.
    public static let grantRefreshTimeout: TimeInterval = 15

    /// Whether opening a document with this locally recorded `documentFormat`
    /// has to raise the socket's receive limit BEFORE `syncStep1` goes out
    /// (decision 3436-SO-07).
    ///
    /// The question deliberately is NOT "is this a large document". On a first
    /// open there is no local metadata, so the format is learned from
    /// `epoch.info` — which is the very frame the limit protects, and which
    /// `URLSessionWebSocketTask` fails at the RECEIVE rather than in the
    /// handler. A client that waited to find out would be refused the answer
    /// that would have told it.
    ///
    /// So the question is the one that CAN be answered before the handshake:
    /// is this document locally known to be format 1? Only then does the
    /// socket keep Foundation's default, which is what makes the intent's
    /// "without changing the format-1 limit" true for a client whose documents
    /// all resolve locally as format 1.
    public static func needsRaisedMessageSize(storedDocumentFormat: Int?) -> Bool {
        storedDocumentFormat != 1
    }
}
