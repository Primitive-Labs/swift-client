import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Verifies YText semantics that the LiveText helper in primitive-app depends on.
///
/// **Key finding: YText indices are UTF-16 code units** (matching Yjs's JS heritage),
/// even though the Swift docstring on YText.insert(at:) says "UTF-8 buffer view".
/// `length('🎉') == 2` (surrogate pair), `length('aéb') == 3`. Diff algorithms
/// for editing YText must compute positions in UTF-16, not UTF-8 bytes or Characters.
///
/// 1. Indices for `insert(at:)` / `removeRange(start:length:)` are UTF-16 code units.
/// 2. The observer fires AFTER local writes commit, and is safe to read state from.
/// 3. `getOrCreateText` is safe to call once and reuse — and it must be called
///    OUTSIDE any open transaction (same gotcha as getMap).
/// 4. Two YDocuments syncing via update bytes converge correctly when each side
///    issues incremental insert/removeRange ops.
final class YTextSemanticsTests: XCTestCase {

    // MARK: - Index semantics

    /// Inserts a BMP character ('é') to confirm length is NOT UTF-8 bytes.
    /// Could be Characters / code points / UTF-16 units (all 3 for this string).
    func testBMPCharIsOneUnit() async {
        let doc = YDocument()
        let text = doc.getOrCreateText(named: "t")

        // 'aéb': 3 Characters / 3 code points / 3 UTF-16 units / 4 UTF-8 bytes
        await text.append("aéb")

        let length = await text.lengthAsync()
        XCTAssertEqual(length, 3, "BMP char 'é' should count as 1 unit (not UTF-8 bytes).")

        // Removing 1 unit at index 1 should remove 'é'.
        await text.removeRange(start: 1, length: 1)

        let result = await text.getStringAsync()
        XCTAssertEqual(result, "ab")
    }

    /// Confirms indices are UTF-16 code units using a non-BMP character.
    /// '🎉' = U+1F389 = 1 grapheme cluster, 1 code point, 2 UTF-16 units (surrogate pair),
    /// 4 UTF-8 bytes. If indices were any encoding other than UTF-16, length would differ.
    func testIndicesAreUTF16CodeUnits() async {
        let doc = YDocument()
        let text = doc.getOrCreateText(named: "t")

        await text.append("🎉")
        let length = await text.lengthAsync()
        XCTAssertEqual(length, 2, "Expected UTF-16 code units (2 for surrogate pair).")
        XCTAssertEqual(Int(length), "🎉".utf16.count)

        // Sanity: removing 2 UTF-16 units should remove the whole emoji.
        await text.removeRange(start: 0, length: length)
        let result = await text.getStringAsync()
        XCTAssertEqual(result, "")
    }

    /// Mixed ASCII + non-BMP: confirm offsets stack as UTF-16 units.
    func testInsertNonBMPInMiddle() async {
        let doc = YDocument()
        let text = doc.getOrCreateText(named: "t")

        // "ab" — 2 UTF-16 units. Inserting 🎉 at position 1 (between a and b).
        await text.append("ab")
        await text.insert("🎉", at: 1)

        let result = await text.getStringAsync()
        XCTAssertEqual(result, "a🎉b")

        // a + 🎉 + b = 1 + 2 + 1 = 4 UTF-16 units
        let length = await text.lengthAsync()
        XCTAssertEqual(length, 4)
        XCTAssertEqual(Int(length), "a🎉b".utf16.count)
    }

    // MARK: - getOrCreateText safety

    /// `getOrCreateText` outside any transaction works repeatedly and returns
    /// handles that act on the same shared text.
    func testGetOrCreateTextIsIdempotent() async {
        let doc = YDocument()
        let text1 = doc.getOrCreateText(named: "shared")
        let text2 = doc.getOrCreateText(named: "shared")

        await text1.append("hello")
        let read = await text2.getStringAsync()
        XCTAssertEqual(read, "hello", "Both handles should reference the same shared text")
    }

    /// `getOrCreateText` should be safe to call when no transaction is open
    /// (it goes through the document's syncQueue internally — fine on a background queue).
    func testGetOrCreateTextDoesNotDeadlock() {
        let doc = YDocument()
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        DispatchQueue.global(qos: .userInitiated).async {
            // No raw transact open — this is the safe pattern.
            let _ = doc.getOrCreateText(named: "t")
            success = true
            semaphore.signal()
        }

        XCTAssertEqual(semaphore.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(success)
    }

    // MARK: - Observer behavior

    /// The observer callback fires after local writes commit, with deltas describing
    /// the change. Crucially, we must be able to dispatch a `Task` from the callback
    /// that calls back into YText (e.g. `getStringAsync`) without deadlocking.
    func testObserverCanReadStateAfterCallback() async throws {
        let doc = YDocument()
        let text = doc.getOrCreateText(named: "t")

        let received = Received<String>()

        let subscription = text.observe { _ in
            // Dispatch off the callback thread so we don't try to re-enter the lock
            // that fired our notification. This is the pattern LiveText will use.
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = text.getString()
                received.set(snapshot)
            }
        }
        defer { subscription.cancel() }

        await text.append("hello")

        // Wait up to 1s for the observer's snapshot to land.
        for _ in 0..<20 {
            if received.value != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(received.value, "hello")
    }

    /// observeAsync stream version — verifies two distinct properties:
    ///   1. The stream is wired up and yields at least once per local write.
    ///   2. The document state authoritatively converges to "abc" after all
    ///      writes complete.
    ///
    /// Earlier versions of this test tried to read `getStringAsync()` inside
    /// the for-await loop and assert the *last* snapshot it observed equalled
    /// "abc". That was racy: the for-await iterator runs concurrently with the
    /// writes, and `getStringAsync()` goes through the document's serial
    /// transact queue, so the iterator's read for yield N can be scheduled
    /// against the still-in-flight write N+1 in either order. The third
    /// snapshot read inside the loop could legitimately see "ab" if the third
    /// yield was picked up before the third write's read became visible — even
    /// though the document itself does converge to "abc". The right way to
    /// test convergence is to read the state OUTSIDE the loop, after waiting
    /// for both the writes and the iterator to settle.
    func testObserveAsyncStreamYieldsAfterWrites() async throws {
        let doc = YDocument()
        let text = doc.getOrCreateText(named: "t")

        let stream = text.observeAsync()
        let yieldCount = Received<Int>()
        yieldCount.set(0)

        let task = Task {
            for await _ in stream {
                yieldCount.set((yieldCount.value ?? 0) + 1)
                if (yieldCount.value ?? 0) >= 3 { break }
            }
        }

        await text.append("a")
        await text.append("b")
        await text.append("c")

        // Wait for the iterator to see all 3 yields.
        for _ in 0..<40 {
            if (yieldCount.value ?? 0) >= 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        task.cancel()

        XCTAssertGreaterThanOrEqual(yieldCount.value ?? 0, 3, "Expected at least 3 yields after 3 writes")

        // Read the final state authoritatively, after all writes have committed
        // and the iterator has settled. This is the only convergence assertion
        // that's not racy against the iterator's own read scheduling.
        let finalSnapshot = await text.getStringAsync()
        XCTAssertEqual(finalSnapshot, "abc", "Document should converge to 'abc' after 3 appends")
    }

    // MARK: - Cross-doc convergence (mimics two clients syncing)

    /// Two YDocuments converge when each applies updates from the other,
    /// and writes are issued at byte offsets (the LiveText pattern).
    func testTwoDocsConvergeWithIncrementalEdits() async {
        let docA = YDocument()
        let docB = YDocument()
        let textA = docA.getOrCreateText(named: "shared")
        let textB = docB.getOrCreateText(named: "shared")

        // A writes "hello"
        await textA.append("hello")
        applyUpdate(from: docA, to: docB)

        // B inserts " world" at end (byte offset 5)
        await textB.insert(" world", at: 5)
        applyUpdate(from: docB, to: docA)

        let resultA = await textA.getStringAsync()
        let resultB = await textB.getStringAsync()
        XCTAssertEqual(resultA, "hello world")
        XCTAssertEqual(resultB, "hello world")

        // A removes "hello " (byte 0..6) leaving "world"
        await textA.removeRange(start: 0, length: 6)
        applyUpdate(from: docA, to: docB)

        let finalA = await textA.getStringAsync()
        let finalB = await textB.getStringAsync()
        XCTAssertEqual(finalA, "world")
        XCTAssertEqual(finalB, "world")
    }

    // MARK: - LiveText-style edit pattern

    /// Verifies the exact pattern LiveText uses: compute a UTF-16 prefix/suffix delta
    /// from before/after string snapshots, then apply it as removeRange + insert at
    /// the same UTF-16 index. The result should match `new` exactly, even with emojis.
    func testLiveTextEditPatternConverges() async {
        let doc = YDocument()
        let text = doc.getOrCreateText(named: "t")

        // Sequence of edits a user might make.
        let edits: [(String, String)] = [
            ("", "h"),
            ("h", "he"),
            ("he", "hel"),
            ("hel", "hell"),
            ("hell", "hello"),
            ("hello", "hello world"),
            ("hello world", "hello "),  // backspace several
            ("hello ", "hello 🎉"),     // insert emoji
            ("hello 🎉", "hello 🎈"),  // replace emoji (surrogate-pair edge case)
            ("hello 🎈", "Goodbye 🎈"),
        ]

        for (old, new) in edits {
            let delta = computeDelta(from: old, to: new)
            if delta.removeCount > 0 {
                await text.removeRange(start: UInt32(delta.start), length: UInt32(delta.removeCount))
            }
            if !delta.insert.isEmpty {
                await text.insert(delta.insert, at: UInt32(delta.start))
            }
            let actual = await text.getStringAsync()
            XCTAssertEqual(actual, new, "After edit '\(old)' -> '\(new)' YText state diverged")
        }
    }

    /// Inline copy of the StringEditDelta algorithm from primitive-app's LiveText —
    /// kept here so this test stays self-contained against YText. If you change the
    /// algorithm, update this and `Sources/PrimitiveApp/State/LiveText.swift` together.
    private func computeDelta(from old: String, to new: String) -> (start: Int, removeCount: Int, insert: String) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        let oldLen = oldUnits.count
        let newLen = newUnits.count

        var prefix = 0
        let maxPrefix = min(oldLen, newLen)
        while prefix < maxPrefix && oldUnits[prefix] == newUnits[prefix] { prefix += 1 }

        var suffix = 0
        let maxSuffix = min(oldLen, newLen) - prefix
        while suffix < maxSuffix && oldUnits[oldLen - 1 - suffix] == newUnits[newLen - 1 - suffix] { suffix += 1 }

        if prefix > 0, (0xD800...0xDBFF).contains(oldUnits[prefix - 1]) { prefix -= 1 }
        if suffix > 0, (0xDC00...0xDFFF).contains(oldUnits[oldLen - suffix]) { suffix -= 1 }

        let removeCount = oldLen - prefix - suffix
        let insertUnits = Array(newUnits[prefix..<(newLen - suffix)])
        let insertString = String(decoding: insertUnits, as: UTF16.self)
        return (prefix, removeCount, insertString)
    }

    // MARK: - Helpers

    /// Encode the full state of `source` and apply it to `target`.
    private func applyUpdate(from source: YDocument, to target: YDocument) {
        let svTxn = target.document.transact(origin: nil)
        let sv = svTxn.transactionStateVector()
        svTxn.free()

        let diffTxn = source.document.transact(origin: nil)
        let update = (try? diffTxn.transactionEncodeStateAsUpdateFromSv(stateVector: sv)) ?? []
        diffTxn.free()

        if !update.isEmpty {
            let applyTxn = target.document.transact(origin: nil)
            try? applyTxn.transactionApplyUpdate(update: update)
            applyTxn.free()
        }
    }
}

/// Tiny thread-safe holder so test observers can hand a value back to the test body.
private final class Received<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?

    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set(_ v: T) {
        lock.lock(); defer { lock.unlock() }
        _value = v
    }
}
