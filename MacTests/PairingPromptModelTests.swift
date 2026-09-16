import XCTest

@MainActor
final class PairingPromptModelTests: XCTestCase {
    private func pending(_ peerID: String = "peer-a", sas: String = "123 456") -> PendingPairing {
        PendingPairing(peerID: peerID, peerName: "Phone", peerSPKI: Data([1]), sas: sas)
    }

    func testPublishingAndPresentingDoesNotResolveConfirmation() async {
        let model = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
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
        let model = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
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
        let model = PairingPromptModel(timeoutNanoseconds: 1_000_000)
        let result = await model.request(pending())

        XCTAssertFalse(result)
        XCTAssertNil(model.pending)
    }

    func testWindowClosedByUserResolvesAsRejectionAndAllowsAnImmediateNextRequest() async {
        let model = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
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
        let model = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
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
        let model = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
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
}
