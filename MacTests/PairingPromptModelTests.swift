import XCTest

@MainActor
final class PairingPromptModelTests: XCTestCase {
    private func pending(_ peerID: String = "peer-a", sas: String = "123 456") -> PendingPairing {
        PendingPairing(peerID: peerID, peerName: "Phone", peerSPKI: Data([1]), sas: sas)
    }

    func testPublishingAndPresentingDoesNotResolveConfirmation() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        var presented = false
        model.onPending = { _ in presented = true }
        let task = Task { @MainActor in await model.request(self.pending()) }
        await Task.yield()

        XCTAssertTrue(presented)
        XCTAssertNotNil(model.pending)
        model.notePresentationDismissed()
        XCTAssertNotNil(model.pending)

        model.decide(accept: true)
        let accepted = await task.value
        XCTAssertTrue(accepted)
    }

    func testDuplicateRequestDoesNotReplaceOrRejectVisiblePrompt() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let first = pending("peer-a", sas: "111 111")
        let firstTask = Task { @MainActor in await model.request(first) }
        await Task.yield()

        let duplicateResult = await model.request(pending("peer-a", sas: "222 222"))
        XCTAssertFalse(duplicateResult)
        XCTAssertEqual(model.pending, first)

        model.decide(accept: true)
        let firstAccepted = await firstTask.value
        XCTAssertTrue(firstAccepted)
    }

    func testTimeoutIsTheOnlyAutomaticResolution() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 1_000_000)
        let result = await model.request(pending())

        XCTAssertFalse(result)
        XCTAssertNil(model.pending)
    }

    func testWindowClosedByUserResolvesAsRejectionAndAllowsAnImmediateNextRequest() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let firstTask = Task { @MainActor in await model.request(self.pending()) }
        await Task.yield()

        // Closing the presentation surface itself must be an explicit
        // rejection of the pending confirmation, not a no-op that leaves an
        // invisible `pending` behind — otherwise the very next request is
        // wrongly refused as a duplicate.
        model.windowClosedByUser()
        let firstAccepted = await firstTask.value
        XCTAssertFalse(firstAccepted)
        XCTAssertNil(model.pending)

        let secondTask = Task { @MainActor in await model.request(self.pending("peer-b")) }
        await Task.yield()
        XCTAssertEqual(model.pending?.peerID, "peer-b")

        model.decide(accept: true)
        let secondAccepted = await secondTask.value
        XCTAssertTrue(secondAccepted)
    }

    func testWindowClosedByUserAfterAlreadyResolvedDoesNotDoubleResolve() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let task = Task { @MainActor in await model.request(self.pending()) }
        await Task.yield()

        model.decide(accept: true)
        let accepted = await task.value
        XCTAssertTrue(accepted)

        // A programmatic dismissal (e.g. closing the panel after the model
        // already resolved via Accept) must be a safe no-op, never a second
        // resolution of the same confirmation.
        model.windowClosedByUser()
        XCTAssertNil(model.pending)
    }

    func testNetworkFinishCannotDismissAnActiveConfirmation() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let request = pending()
        let task = Task { @MainActor in await model.request(request) }
        await Task.yield()

        model.finish("Duplicate connection ended")
        XCTAssertEqual(model.pending, request)
        XCTAssertNil(model.status)

        model.decide(accept: false)
        let accepted = await task.value
        XCTAssertFalse(accepted)
    }

    // A prompt can come from any host on the network: only an accepted code may interrupt this
    // device's sessions (onAccepted), never a prompt that is shown, declined or left to time out.
    func testOnlyAnAcceptedCodeReachesOnAccepted() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        var accepted: [PendingPairing] = []
        model.onAccepted = { accepted.append($0) }

        let declined = Task { @MainActor in await model.request(self.pending("peer-a")) }
        await Task.yield()
        XCTAssertTrue(accepted.isEmpty, "showing the prompt interrupts nothing")
        model.decide(accept: false)
        _ = await declined.value
        XCTAssertTrue(accepted.isEmpty, "a declined code interrupts nothing")

        let approved = Task { @MainActor in await model.request(self.pending("peer-b")) }
        await Task.yield()
        model.decide(accept: true)
        _ = await approved.value
        XCTAssertEqual(accepted.map(\.peerID), ["peer-b"])
    }

    func testATimedOutPromptNeverReachesOnAccepted() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 20_000_000)
        var accepted = 0
        model.onAccepted = { _ in accepted += 1 }
        let result = await model.request(pending())
        XCTAssertFalse(result)
        XCTAssertEqual(accepted, 0)
    }

    func testRefusedGrantIsVisibleOnlyForThePendingAttempt() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        model.noteRefusedGrant()
        XCTAssertFalse(model.grantRefused)
        let first = Task { @MainActor in await model.request(self.pending()) }
        await Task.yield()
        model.noteRefusedGrant()
        model.noteRefusedGrant()
        XCTAssertTrue(model.grantRefused)
        XCTAssertNotNil(model.pending)
        model.decide(accept: false)
        let accepted = await first.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(model.grantRefused)
        let second = Task { @MainActor in await model.request(self.pending("peer-b")) }
        await Task.yield()
        XCTAssertFalse(model.grantRefused)
        model.decide(accept: false)
        _ = await second.value
    }

    func testRefusedGrantDoesNotPreventTimeoutOrAuthorizeLater() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 50_000_000)
        var accepted = 0
        model.onAccepted = { _ in accepted += 1 }
        let attempt = Task { @MainActor in await model.request(self.pending()) }
        await Task.yield()
        model.noteRefusedGrant()
        XCTAssertTrue(model.grantRefused)
        let result = await attempt.value
        XCTAssertFalse(result)
        XCTAssertFalse(model.grantRefused)
        model.decide(accept: true)
        XCTAssertEqual(accepted, 0)
        XCTAssertNil(model.pending)
    }

    // MARK: Refused presses (#236 review C5)

    /// Repeated injected clicks: the explanation shows, but the announcement
    /// is asked for only once per prompt; the next prompt starts over.
    func testRepeatedRefusalsAnnounceOncePerPrompt() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        XCTAssertFalse(model.noteRefusedGrant(), "no prompt: nothing to explain or announce")
        let first = Task { @MainActor in await model.request(self.pending()) }
        await Task.yield()
        XCTAssertTrue(model.noteRefusedGrant())
        for _ in 0..<20 { XCTAssertFalse(model.noteRefusedGrant()) }
        XCTAssertTrue(model.grantRefused)
        model.decide(accept: false)
        _ = await first.value
        XCTAssertFalse(model.grantRefused, "the flag resets with the prompt")
        XCTAssertFalse(model.noteRefusedGrant(), "nothing pending any more")
        let second = Task { @MainActor in await model.request(self.pending("peer-b")) }
        await Task.yield()
        XCTAssertFalse(model.grantRefused)
        XCTAssertTrue(model.noteRefusedGrant(), "a new prompt announces again, once")
        XCTAssertFalse(model.noteRefusedGrant())
        model.decide(accept: false)
        _ = await second.value
    }

    /// Negative: any number of refused presses leaves the attempt exactly as
    /// it was. Nothing is accepted, the same code stays up, no waiting state
    /// starts, and only a real decision (here the owner's Cancel) ends it.
    func testRefusedGrantNeverResolvesOrExtendsTheAttempt() async {
        let model = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        var accepted = 0
        model.onAccepted = { _ in accepted += 1 }
        let shown = pending(sas: "314 159")
        final class Finished { var value = false }
        let finished = Finished()
        let attempt = Task { @MainActor in
            let result = await model.request(shown)
            finished.value = true
            return result
        }
        await Task.yield()
        for _ in 0..<50 { model.noteRefusedGrant() }
        await Task.yield()
        XCTAssertEqual(model.pending, shown)
        XCTAssertNil(model.confirmedLocally)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertFalse(finished.value, "a refused press never resolves the attempt")
        XCTAssertEqual(accepted, 0)
        model.decide(accept: false)
        let result = await attempt.value
        XCTAssertFalse(result)
        XCTAssertEqual(accepted, 0)
    }

    /// The explanation says what happened and when approving is right, and
    /// never coaches pressing again: the press may have come from a device
    /// controlling this Mac.
    func testRefusalCopyNeverAsksToTryAgain() {
        let text = PairingCopy.refusedGrant
        XCTAssertFalse(text.localizedCaseInsensitiveContains("try again"))
        XCTAssertTrue(text.hasPrefix("Nothing was approved"))
        XCTAssertTrue(text.contains("device controlling this Mac"))
        XCTAssertTrue(text.contains("started this pairing"))
        XCTAssertTrue(text.contains("codes match"))
        XCTAssertTrue(text.contains("this Mac's own mouse, trackpad or keyboard"))
    }
}
