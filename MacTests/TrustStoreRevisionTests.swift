import XCTest

/// Replays racing `TrustStore` pin-snapshot schedules against the exact
/// `PinSnapshotState` rules TrustStore drives. Each step mirrors one
/// TrustStore call: a refresh takes `beginRefresh()` before its lock-free
/// Keychain read and later `commit`s that read; a mutation (`setPin`,
/// `forget`, `purgeAll`) calls `keychainDidMutate()` after its Keychain
/// writes and `commit`s its own read-back.
final class TrustStoreRevisionTests: XCTestCase {
    private typealias Pin = PinSnapshotState.Pin

    private let p = Pin(peerID: "P", spki: Data([1]))
    private let q = Pin(peerID: "Q", spki: Data([2]))

    private func stateHolding(_ pins: [Pin]) -> PinSnapshotState {
        var state = PinSnapshotState()
        XCTAssertTrue(state.commit(pins, readAt: state.beginRefresh()))
        return state
    }

    // MARK: Stale reads never undo a mutation

    /// A: listener-start refresh reads the Keychain (still holding P).
    /// B: forget(P) deletes P, bumps, commits its read-back.
    /// A: commits its stale read — must not re-add P.
    func testStaleRefreshReadTakenBeforeForgetCannotRestoreForgottenPin() {
        var state = stateHolding([p, q])

        let refresh = state.beginRefresh()
        let staleRead = [p, q]

        let forget = state.keychainDidMutate()
        XCTAssertTrue(state.commit([q], readAt: forget))

        XCTAssertFalse(state.commit(staleRead, readAt: refresh))
        XCTAssertEqual(state.pins, [q])
        XCTAssertNil(state.peerID(forSPKI: p.spki), "forgotten peer must not resolve")
        XCTAssertFalse(state.allSPKIs.contains(p.spki), "TLS verify must not accept the forgotten key")
        XCTAssertEqual(state.peerID(forSPKI: q.spki), "Q")
    }

    /// Same race, but A's stale commit lands between forget's bump and its
    /// read-back commit: still rejected, and the read-back wins.
    func testStaleRefreshCommittingMidForgetIsRejected() {
        var state = stateHolding([p])

        let refresh = state.beginRefresh()
        let forget = state.keychainDidMutate()
        XCTAssertFalse(state.commit([p], readAt: refresh))
        XCTAssertTrue(state.commit([], readAt: forget))

        XCTAssertTrue(state.pins.isEmpty)
        XCTAssertNil(state.peerID(forSPKI: p.spki))
    }

    /// A stale read that commits BEFORE forget's Keychain write finished is
    /// accepted (forget hasn't happened yet), and forget's read-back then
    /// replaces it.
    func testStaleRefreshCommittedBeforeForgetFinishesIsOverwritten() {
        var state = stateHolding([p])

        let refresh = state.beginRefresh()
        XCTAssertTrue(state.commit([p], readAt: refresh))
        let forget = state.keychainDidMutate()
        XCTAssertTrue(state.commit([], readAt: forget))

        XCTAssertNil(state.peerID(forSPKI: p.spki))
    }

    func testStaleRefreshCannotResurrectPinsAfterPurgeAll() {
        var state = stateHolding([p, q])

        let refresh = state.beginRefresh()
        let staleRead = [p, q]

        let purge = state.keychainDidMutate()
        XCTAssertTrue(state.commit([], readAt: purge))

        XCTAssertFalse(state.commit(staleRead, readAt: refresh))
        XCTAssertTrue(state.pins.isEmpty)
        XCTAssertTrue(state.allSPKIs.isEmpty)
        XCTAssertNil(state.peerID(forSPKI: p.spki))
        XCTAssertNil(state.peerID(forSPKI: q.spki))
    }

    func testRefreshStartedBeforeSetPinCannotDropNewPin() {
        var state = stateHolding([q])

        let refresh = state.beginRefresh()
        let readWithoutP = [q]

        let setPin = state.keychainDidMutate()
        XCTAssertTrue(state.commit([q, p], readAt: setPin))

        XCTAssertFalse(state.commit(readWithoutP, readAt: refresh))
        XCTAssertEqual(state.peerID(forSPKI: p.spki), "P")
        XCTAssertEqual(state.allSPKIs, [q.spki, p.spki])
    }

    /// Re-pair with allowIdentityChange: a read of the OLD key taken before
    /// the replacement must not bring the old key back.
    func testRefreshStartedBeforeKeyReplacementCannotRestoreOldKey() {
        let oldKey = Pin(peerID: "P", spki: Data([7]))
        let newKey = Pin(peerID: "P", spki: Data([8]))
        var state = stateHolding([oldKey])

        let refresh = state.beginRefresh()
        let setPin = state.keychainDidMutate()
        XCTAssertTrue(state.commit([newKey], readAt: setPin))

        XCTAssertFalse(state.commit([oldKey], readAt: refresh))
        XCTAssertNil(state.peerID(forSPKI: oldKey.spki))
        XCTAssertEqual(state.peerID(forSPKI: newKey.spki), "P")
    }

    /// Mutations are serialized in TrustStore, but the revision alone still
    /// keeps an older mutation's read-back from overwriting a newer one.
    func testOlderMutationReadBackCannotOverwriteNewerMutation() {
        var state = stateHolding([p])

        let forget = state.keychainDidMutate()
        let setPin = state.keychainDidMutate()
        XCTAssertTrue(state.commit([p, q], readAt: setPin))
        XCTAssertFalse(state.commit([], readAt: forget))

        XCTAssertEqual(state.pins, [p, q])
    }

    // MARK: Normal refreshes still commit

    func testRefreshWithNoInterveningMutationCommits() {
        var state = PinSnapshotState()

        let refresh = state.beginRefresh()
        XCTAssertTrue(state.commit([p], readAt: refresh))

        XCTAssertEqual(state.pins, [p])
        XCTAssertEqual(state.allSPKIs, [p.spki])
        XCTAssertEqual(state.peerID(forSPKI: p.spki), "P")
        XCTAssertNil(state.peerID(forSPKI: q.spki))
    }

    func testRefreshStartedAfterMutationCommits() {
        var state = stateHolding([p])

        let forget = state.keychainDidMutate()
        XCTAssertTrue(state.commit([], readAt: forget))
        let refresh = state.beginRefresh()
        XCTAssertTrue(state.commit([q], readAt: refresh))

        XCTAssertEqual(state.pins, [q])
    }

    /// A refresh that starts after the bump reads after the write, so it may
    /// commit even before the mutation's own read-back does.
    func testRefreshStartedMidMutationCommitsAlongsideReadBack() {
        var state = stateHolding([p])

        let forget = state.keychainDidMutate()
        let refresh = state.beginRefresh()
        XCTAssertTrue(state.commit([], readAt: refresh))
        XCTAssertTrue(state.commit([], readAt: forget))

        XCTAssertTrue(state.pins.isEmpty)
    }

    func testOverlappingRefreshesWithoutMutationBothCommit() {
        var state = PinSnapshotState()

        let first = state.beginRefresh()
        let second = state.beginRefresh()
        XCTAssertTrue(state.commit([p], readAt: second))
        XCTAssertTrue(state.commit([p], readAt: first))

        XCTAssertEqual(state.pins, [p])
    }

    // MARK: TrustStore drives the rules in the required order

    /// The value-type tests above only hold if TrustStore takes a refresh
    /// ticket before reading, bumps only after its Keychain writes (under
    /// `pinWriteLock`), and never commits a mutation through the refresh path.
    func testTrustStoreDrivesPinSnapshotStateInRequiredOrder() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Shared/TrustStore.swift"),
                                encoding: .utf8)

        func body(of declaration: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: declaration), declaration)
            let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex),
                                    declaration)
            return String(source[start.lowerBound..<end.upperBound])
        }
        func assertOrder(_ steps: [String], in declaration: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
            let text = try body(of: declaration)
            var cursor = text.startIndex
            for step in steps {
                let found = text.range(of: step, range: cursor..<text.endIndex)
                XCTAssertNotNil(found, "\(declaration): expected `\(step)` after the previous step",
                                file: file, line: line)
                cursor = found?.upperBound ?? cursor
            }
        }

        try assertOrder(["pinState.beginRefresh()", "readPinsFromKeychain()",
                         "pinState.commit(fresh, readAt: ticket)"],
                        in: "func refreshSnapshot()")
        try assertOrder(["pinState.keychainDidMutate()", "readPinsFromKeychain()",
                         "pinState.commit(fresh, readAt: ticket)"],
                        in: "private func finishPinMutation(")
        try assertOrder(["pinWriteLock.lock()", "pin(peerID: peerID)", "SecItemDelete(",
                         "SecItemAdd(", "finishPinMutation()"],
                        in: "func setPin(peerID: String, spki: Data, displayName: String,")
        try assertOrder(["pinWriteLock.lock()", "SecItemDelete(", "finishPinMutation()"],
                        in: "func forget(peerID: String)")
        try assertOrder(["pinWriteLock.lock()", "SecItemDelete(", "finishPinMutation(purged: true)"],
                        in: "func purgeAll()")

        XCTAssertEqual(source.components(separatedBy: "pinState.keychainDidMutate()").count - 1, 1,
                       "only finishPinMutation may bump the revision")
        for mutation in ["func setPin(peerID: String, spki: Data, displayName: String,",
                         "func forget(peerID: String)", "func purgeAll()"] {
            XCTAssertFalse(try body(of: mutation).contains("refreshSnapshot("),
                           "\(mutation): mutations must commit via finishPinMutation")
        }
    }
}
