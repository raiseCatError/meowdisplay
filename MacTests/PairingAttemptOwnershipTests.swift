import XCTest

/// Attempt isolation on the shared `PairingPromptModel`: only the attempt that
/// owns the prompt may change, cancel or clear it.
@MainActor
final class PairingAttemptOwnershipTests: XCTestCase {
    private func pending(_ id: String = "peer-a") -> PendingPairing {
        PendingPairing(peerID: id, peerName: "Phone", peerSPKI: Data([1]), sas: "123 456")
    }

    private final class Callback { var calls = 0 }

    /// Attempt A: SAS accepted locally, now waiting for the peer.
    private func waitingOwner(_ prompt: PairingPromptModel, token: UUID, callback: Callback) async {
        prompt.registerAttempt(token) { callback.calls += 1; return true }
        let request = Task { await prompt.request(pending(), token: token) }
        while prompt.pending == nil { await Task.yield() }
        prompt.decide(accept: true)
        _ = await request.value
    }

    // 1-3. B starts: refused, does not replace A's cancel callback or ownership.
    func testSecondAttemptCannotReplaceOwnerOrItsCancelCallback() async {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let (a, b) = (UUID(), UUID())
        let aCallback = Callback(), bCallback = Callback()
        await waitingOwner(prompt, token: a, callback: aCallback)
        prompt.registerAttempt(b) { bCallback.calls += 1; return true }
        let bAccepted = await prompt.request(pending("peer-b"), token: b)
        XCTAssertFalse(bAccepted, "duplicate attempt is refused, not allowed to take over")
        XCTAssertEqual(prompt.owner, a)
        XCTAssertNotNil(prompt.confirmedLocally)
        prompt.cancelWaiting()
        XCTAssertEqual(aCallback.calls, 1, "Cancel reaches A's own connection")
        XCTAssertEqual(bCallback.calls, 0)
    }

    // 4-6. B ends: A's waiting state survives.
    func testOtherAttemptEndingDoesNotClearOwnersWaitingState() async {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let (a, b) = (UUID(), UUID())
        await waitingOwner(prompt, token: a, callback: Callback())
        prompt.attemptEnded(token: b)
        XCTAssertEqual(prompt.owner, a)
        XCTAssertNotNil(prompt.confirmedLocally)
        prompt.markCommitting(token: b)
        XCTAssertFalse(prompt.isCommitting, "only the owner can mark committing")
    }

    // 7-9. B's valid abort does not touch A (SAS showing and waiting variants).
    func testOtherAttemptsAbortLeavesOwnerUntouched() async {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let (a, b) = (UUID(), UUID())
        let request = Task { await prompt.request(pending(), token: a) }
        while prompt.pending == nil { await Task.yield() }
        prompt.peerAborted(token: b)
        XCTAssertNotNil(prompt.pending, "A's SAS must stay on screen")
        prompt.decide(accept: true)
        _ = await request.value
        prompt.peerAborted(token: b)
        XCTAssertNotNil(prompt.confirmedLocally, "A's waiting state must stay")
        prompt.peerAborted(token: a)
        XCTAssertNil(prompt.confirmedLocally, "A's own abort does end A")
    }

    // The abort of an attempt that has not yet claimed the prompt still prevents its SAS.
    func testAbortBeforeRequestPreventsSAS() async {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let token = UUID()
        prompt.peerAborted(token: token)
        let shown = await prompt.request(pending(), token: token)
        XCTAssertFalse(shown)
        XCTAssertNil(prompt.pending)
    }

    // 10. A's Cancel invokes A's real callback exactly once, and honours "too late".
    func testOwnerCancelInvokesItsRealCallbackAndRespectsTooLate() async {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let a = UUID()
        let callback = Callback()
        await waitingOwner(prompt, token: a, callback: callback)
        prompt.cancelWaiting()
        XCTAssertEqual(callback.calls, 1)
        XCTAssertNil(prompt.confirmedLocally)

        let late = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let c = UUID()
        late.registerAttempt(c) { false }
        let request = Task { await late.request(pending(), token: c) }
        while late.pending == nil { await Task.yield() }
        late.decide(accept: true)
        _ = await request.value
        late.cancelWaiting()
        XCTAssertNotNil(late.confirmedLocally, "too late to cancel: state is kept")
    }

    // 11. Stale cleanup after a newer attempt owns the prompt is a no-op.
    func testStaleAttemptCleanupIsNoOpAgainstNewerOwner() async {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let (old, new) = (UUID(), UUID())
        prompt.registerAttempt(old) { true }
        let first = Task { await prompt.request(pending(), token: old) }
        while prompt.pending == nil { await Task.yield() }
        prompt.decide(accept: false)
        _ = await first.value
        prompt.attemptEnded(token: old)               // old attempt finished
        await waitingOwner(prompt, token: new, callback: Callback())
        prompt.attemptEnded(token: old)               // stale, late duplicate cleanup
        XCTAssertEqual(prompt.owner, new)
        XCTAssertNotNil(prompt.confirmedLocally)
    }

    func testEndingOwnerClearsItsStateAndFreesThePrompt() async {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let (a, b) = (UUID(), UUID())
        await waitingOwner(prompt, token: a, callback: Callback())
        prompt.attemptEnded(token: a)
        XCTAssertNil(prompt.owner); XCTAssertNil(prompt.confirmedLocally)
        let request = Task { await prompt.request(pending("peer-b"), token: b) }
        while prompt.pending == nil { await Task.yield() }
        XCTAssertEqual(prompt.owner, b)
        prompt.decide(accept: false)
        _ = await request.value
    }
}
