import CryptoKit
import Network
import XCTest

private final class RecordingHints: RemoteEndpointHinting {
    private(set) var saved: [(host: String, port: UInt16, peerID: String)] = []
    func setEndpoint(_ host: String, port: UInt16, forPeerID peerID: String) {
        saved.append((host, port, peerID))
    }
}

final class RemotePairingTests: XCTestCase {
    private let macID = "11111111-1111-1111-1111-111111111111"
    private let phoneID = "22222222-2222-2222-2222-222222222222"

    /// The phone dials (initiator); the Mac listens (responder). Returns the
    /// phone's view: the result naming the Mac, plus the Mac's confirmation source.
    private func pair(macSPKI: Data = Data("mac identity".utf8))
        throws -> (phone: PairingResult, mac: PairingResult) {
        let phone = PairingHandshake(role: .initiator, deviceID: phoneID, displayName: "Phone",
                                     identitySPKI: Data("phone identity".utf8))
        let mac = PairingHandshake(role: .responder, deviceID: macID, displayName: "Mac",
                                   identitySPKI: macSPKI)
        return (try phone.result(peerHello: mac.localHello), try mac.result(peerHello: phone.localHello))
    }

    // 1. Explicit endpoint, no Bonjour.
    func testEndpointIsExplicitHostPortWithDefaultsAndNoBonjour() throws {
        let endpoint = try RemotePairingEndpoint.make(host: "  mac.tail1234.ts.net ").get()
        XCTAssertEqual(endpoint.host, "mac.tail1234.ts.net")
        XCTAssertEqual(endpoint.port, WireCrypto.remotePairingPort)
        guard case .hostPort = endpoint.nwEndpoint else { return XCTFail("must not be a Bonjour service") }
        XCTAssertEqual(try RemotePairingEndpoint.make(host: "100.64.0.7", port: "9100").get().port, 9100)
        XCTAssertEqual(try RemotePairingEndpoint.make(host: "[fd7a::1]").get().host, "fd7a::1")
        XCTAssertEqual(RemotePairingEndpoint.make(host: "   "), .failure(.emptyHost))
        XCTAssertEqual(RemotePairingEndpoint.make(host: "bad host!"), .failure(.invalidHost))
        XCTAssertEqual(RemotePairingEndpoint.make(host: "100.64.0.7", port: "0"), .failure(.invalidPort))
    }

    // 2. Both confirmations required; pin only after completion.
    func testPinWrittenOnlyAfterVerifiedPeerConfirmation() throws {
        let (phone, mac) = try pair()
        XCTAssertEqual(phone.pending.sas, mac.pending.sas)
        let store = InMemoryPeerTrustStore()
        try PairingFinalizer.complete(result: phone, pending: phone.pending,
                                      peerConfirmation: mac.confirmation(accepted: true), store: store)
        XCTAssertEqual(store.pin(peerID: macID), Data("mac identity".utf8))
    }

    // 3. Rejected by peer / cancelled: no pin.
    func testPeerRejectionWritesNoPin() throws {
        let (phone, mac) = try pair()
        let store = InMemoryPeerTrustStore()
        XCTAssertThrowsError(try PairingFinalizer.complete(
            result: phone, pending: phone.pending,
            peerConfirmation: mac.confirmation(accepted: false), store: store)) {
            XCTAssertEqual($0 as? PairingError, .rejected)
        }
        XCTAssertNil(store.pin(peerID: macID))
    }

    // 4. Confirmation timeout: prompt resolves false, no pin.
    @MainActor
    func testPromptTimeoutRejectsAndWritesNoPin() async throws {
        let (phone, mac) = try pair()
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 20_000_000)
        let accepted = await prompt.request(phone.pending)
        XCTAssertFalse(accepted)
        let store = InMemoryPeerTrustStore()
        XCTAssertThrowsError(try PairingFinalizer.complete(
            result: mac, pending: mac.pending,
            peerConfirmation: phone.confirmation(accepted: accepted), store: store))
        XCTAssertTrue(store.pins.isEmpty)
    }

    // 5. Changed key against an existing pin is a hard failure; pin preserved.
    func testChangedKeyIsHardFailureAndPreservesExistingPin() throws {
        let store = InMemoryPeerTrustStore()
        store.setPin(peerID: macID, spki: Data("original".utf8), displayName: "Mac")
        let (phone, _) = try pair(macSPKI: Data("impostor".utf8))
        let pending = PairingClassifier.classify(phone.pending, existingPin: store.pin(peerID: macID))
        XCTAssertEqual(pending.classification, .identityChanged)
        XCTAssertThrowsError(try PairingClassifier.check(pending, allowIdentityChange: false)) {
            XCTAssertEqual($0 as? PairingError, .identityChanged)
        }
        XCTAssertEqual(store.pin(peerID: macID), Data("original".utf8))
    }

    // 6. Confirmed peerID gets the endpoint hint, only after the pin.
    func testHintSavedForConfirmedPeerOnlyAfterSuccess() throws {
        let (phone, mac) = try pair()
        let store = InMemoryPeerTrustStore()
        let hints = RecordingHints()
        XCTAssertThrowsError(try PairingFinalizer.complete(
            result: phone, pending: phone.pending, peerConfirmation: mac.confirmation(accepted: false),
            store: store, remoteHost: "100.64.0.7", hints: hints))
        XCTAssertTrue(hints.saved.isEmpty)
        try PairingFinalizer.complete(
            result: phone, pending: phone.pending, peerConfirmation: mac.confirmation(accepted: true),
            store: store, remoteHost: "100.64.0.7", hints: hints)
        XCTAssertEqual(hints.saved.count, 1)
        XCTAssertEqual(hints.saved.first?.peerID, macID)
        XCTAssertEqual(hints.saved.first?.host, "100.64.0.7")
        XCTAssertEqual(hints.saved.first?.port, WireCrypto.remoteRequestPort)
    }

    // 7. Pairing mode disabled: unsolicited attempts rejected.
    func testAttemptRejectedWhenWindowNeverOpenedOrClosed() {
        var window = RemotePairingWindow()
        let now = Date()
        XCTAssertEqual(window.admit(now: now), .notOpen)
        window.open(now: now)
        window.close()
        XCTAssertEqual(window.admit(now: now), .notOpen)
    }

    // 8. Window timeout rejects new attempts, and limits concurrency/retries.
    func testWindowExpiryConcurrencyAndCooldown() {
        var window = RemotePairingWindow()
        let t0 = Date()
        window.open(now: t0)
        XCTAssertEqual(window.admit(now: t0.addingTimeInterval(1)), .admitted)
        XCTAssertEqual(window.admit(now: t0.addingTimeInterval(2)), .busy)
        window.finishAttempt(success: false, now: t0.addingTimeInterval(3))
        for i in 0..<2 {
            XCTAssertEqual(window.admit(now: t0.addingTimeInterval(4 + Double(i))), .admitted)
            window.finishAttempt(success: false, now: t0.addingTimeInterval(4 + Double(i)))
        }
        XCTAssertEqual(window.admit(now: t0.addingTimeInterval(10)), .coolingDown)
        XCTAssertEqual(window.admit(now: t0.addingTimeInterval(40)), .admitted)
        window.finishAttempt(success: false, now: t0.addingTimeInterval(41))
        XCTAssertEqual(window.admit(now: t0.addingTimeInterval(RemotePairingWindow.openDuration + 1)), .notOpen)
    }

    func testSuccessConsumesWindow() {
        var window = RemotePairingWindow()
        let now = Date()
        window.open(now: now)
        XCTAssertEqual(window.admit(now: now), .admitted)
        window.finishAttempt(success: true, now: now)
        XCTAssertEqual(window.admit(now: now), .notOpen)
    }

    // 9. Stale generation cannot complete.
    func testCancelledAttemptCannotCompleteAndDuplicateIsRefused() throws {
        var tracker = PairingAttemptTracker()
        let first = try XCTUnwrap(tracker.begin())
        XCTAssertNil(tracker.begin())
        tracker.cancel()
        XCTAssertFalse(tracker.isCurrent(first))
        XCTAssertFalse(tracker.finish(first))
        let second = try XCTUnwrap(tracker.begin())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(tracker.finish(first))
        XCTAssertTrue(tracker.finish(second))
    }

    func testStaleAttemptWritesNoPin() throws {
        let (phone, mac) = try pair()
        let store = InMemoryPeerTrustStore()
        let validity = PairingAttemptValidity()
        validity.invalidate()
        XCTAssertThrowsError(try PairingFinalizer.complete(
            result: phone, pending: phone.pending, peerConfirmation: mac.confirmation(accepted: true),
            store: store, isCurrent: { validity.isValid }))
        XCTAssertTrue(store.pins.isEmpty)
    }

    // 10. Already-trusted peer: deterministic, never overwritten with a different key.
    func testAlreadyTrustedSameKeyIsRePairAndKeepsPin() throws {
        let store = InMemoryPeerTrustStore()
        store.setPin(peerID: macID, spki: Data("mac identity".utf8), displayName: "Mac")
        let (phone, mac) = try pair()
        let pending = PairingClassifier.classify(phone.pending, existingPin: store.pin(peerID: macID))
        XCTAssertEqual(pending.classification, .rePairSameKey)
        try PairingFinalizer.complete(result: phone, pending: pending,
                                      peerConfirmation: mac.confirmation(accepted: true), store: store)
        XCTAssertEqual(store.pin(peerID: macID), Data("mac identity".utf8))
        XCTAssertEqual(store.pins.count, 1)
    }

    func testPhaseIsDerivedFromExistingState() {
        XCTAssertEqual(.derive(windowOpen: false, attemptInProgress: false, awaitingConfirmation: false), RemotePairingPhase.off)
        XCTAssertEqual(.derive(windowOpen: true, attemptInProgress: false, awaitingConfirmation: false), RemotePairingPhase.available)
        XCTAssertEqual(.derive(windowOpen: true, attemptInProgress: true, awaitingConfirmation: false), RemotePairingPhase.inProgress)
        XCTAssertEqual(.derive(windowOpen: true, attemptInProgress: true, awaitingConfirmation: true), RemotePairingPhase.awaitingConfirmation)
    }

    func testFailureMessagesAreCompact() {
        XCTAssertEqual(RemotePairingFailure.message(for: PairingError.invalidConfirmation), "Codes did not match")
        XCTAssertEqual(RemotePairingFailure.message(for: PairingError.rejected, timedOut: true), "Pairing timed out")
        XCTAssertFalse(RemotePairingFailure.message(for: NWError.posix(.ECONNREFUSED)).contains("POSIX"))
    }

    // MARK: Progress / lifecycle / feedback

    private func classify(_ error: Error, user: Bool = false, deadline: Bool = false,
                          handshake: Bool) -> RemotePairingFailureKind? {
        RemotePairingFailure.classify(error, cancelledByUser: user, deadlineFired: deadline,
                                      handshakeReached: handshake)
    }

    // 1. Pair tapped -> connecting -> progress UI condition.
    func testConnectingShowsProgressUntilSASTakesOver() {
        XCTAssertTrue(RemotePairingUIState.connecting.showsProgress(sasPending: false))
        XCTAssertFalse(RemotePairingUIState.connecting.showsProgress(sasPending: true))
        XCTAssertFalse(RemotePairingUIState.idle.showsProgress(sasPending: false))
        XCTAssertFalse(RemotePairingUIState.failed(.unreachable).showsProgress(sasPending: false))
    }

    // 2 + 3. Cancel / swipe-down: generation invalidated, stale completion ignored, quiet outcome.
    func testCancelInvalidatesAttemptAndIsQuiet() throws {
        var tracker = PairingAttemptTracker()
        let generation = try XCTUnwrap(tracker.begin())
        tracker.cancel()
        XCTAssertFalse(tracker.finish(generation), "stale completion must not report anything")
        XCTAssertNil(classify(NWError.posix(.ECANCELED), user: true, handshake: false))
        XCTAssertNil(classify(PairingError.rejected, user: true, handshake: true))
    }

    func testCancelledAttemptNeverPresentsSASOrPersists() throws {
        let (phone, mac) = try pair()
        let validity = PairingAttemptValidity()
        validity.invalidate()
        let store = InMemoryPeerTrustStore()
        XCTAssertFalse(validity.isValid) // network layer refuses to prompt when !isValid
        XCTAssertThrowsError(try PairingFinalizer.complete(
            result: phone, pending: phone.pending, peerConfirmation: mac.confirmation(accepted: true),
            store: store, isCurrent: { validity.isValid }))
        XCTAssertTrue(store.pins.isEmpty)
    }

    // 4. Mac becomes reachable during the wait: still the same live attempt, handshake proceeds.
    func testLiveAttemptCanProceedToSASWhenMacBecomesReachable() throws {
        var tracker = PairingAttemptTracker()
        let generation = try XCTUnwrap(tracker.begin())
        XCTAssertTrue(tracker.isCurrent(generation))
        let (phone, _) = try pair()
        XCTAssertFalse(RemotePairingUIState.connecting.showsProgress(sasPending: true))
        XCTAssertFalse(phone.pending.sas.isEmpty)
        XCTAssertTrue(tracker.finish(generation))
    }

    // 5. Timeout without handshake is reachability, never "rejected".
    func testTimeoutWithoutHandshakeIsUnreachableNotRejected() {
        XCTAssertEqual(classify(PairingError.rejected, deadline: true, handshake: false), .unreachable)
        XCTAssertEqual(classify(NWError.posix(.ECONNREFUSED), handshake: false), .unreachable)
        XCTAssertNotEqual(classify(PairingError.rejected, handshake: false), .rejected)
        XCTAssertEqual(RemotePairingFailureKind.unreachable.title, "Couldn't reach the Mac")
        XCTAssertTrue(RemotePairingFailureKind.unreachable.detail?.contains("Pair Over Remote") == true)
    }

    // 6. Genuine rejection after handshake.
    func testRejectionAfterHandshakeIsRejected() {
        XCTAssertEqual(classify(PairingError.rejected, handshake: true), .rejected)
        XCTAssertEqual(classify(PairingError.rejected, deadline: true, handshake: true), .timedOut)
        XCTAssertEqual(classify(PairingError.identityChanged, handshake: true), .keyChanged)
        XCTAssertEqual(classify(PairingError.invalidConfirmation, handshake: true), .codesDidNotMatch)
    }

    // 7. Try Again after transport failure: fresh generation.
    func testTryAgainCreatesFreshGeneration() throws {
        var tracker = PairingAttemptTracker()
        let first = try XCTUnwrap(tracker.begin())
        XCTAssertTrue(tracker.finish(first))
        let second = try XCTUnwrap(tracker.begin())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(tracker.isCurrent(first))
    }

    // 8. Success: trust only after both confirmations; success feedback only on true completion.
    func testSuccessFeedbackOnlyAfterTrueCompletion() throws {
        let (phone, mac) = try pair()
        let store = InMemoryPeerTrustStore()
        XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.failure(PairingError.rejected)), .none)
        XCTAssertThrowsError(try PairingFinalizer.complete(
            result: phone, pending: phone.pending, peerConfirmation: mac.confirmation(accepted: false), store: store))
        XCTAssertTrue(store.pins.isEmpty)
        XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.failure(PairingError.cancelledByPeer)), .none)
        XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.failure(PairingError.identityChanged)), .none)
        try PairingFinalizer.complete(result: phone, pending: phone.pending,
                                      peerConfirmation: mac.confirmation(accepted: true), store: store)
        XCTAssertNotNil(store.pin(peerID: macID))
        XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.success(())), .success)
    }

    // MARK: Try Again / Forget confirmation

    private func endpoint(_ host: String) throws -> RemotePairingEndpoint {
        try RemotePairingEndpoint.make(host: host).get()
    }

    // 1 + 3. The Try Again action resolves the remembered host from a retryable failure only.
    func testTryAgainActionUsesRememberedHostFromRetryableFailure() throws {
        var context = RemotePairingRetryContext()
        XCTAssertNil(context.endpointForRetry(state: .failed(.unreachable)), "nothing attempted yet")
        context.remember(try endpoint("mac.tail1234.ts.net"))
        XCTAssertEqual(context.endpointForRetry(state: .failed(.unreachable))?.host, "mac.tail1234.ts.net")
        XCTAssertEqual(context.endpointForRetry(state: .failed(.rejected))?.host, "mac.tail1234.ts.net")
        XCTAssertNil(context.endpointForRetry(state: .failed(.keyChanged)))
        XCTAssertNil(context.endpointForRetry(state: .failed(.updateRequired)))
        XCTAssertNil(context.endpointForRetry(state: .connecting))
        XCTAssertNil(context.endpointForRetry(state: .idle))
    }

    // 2 + 4. Retry is a new generation; the failed attempt's late callbacks are stale.
    func testRetryIsFreshGenerationAndOldAttemptIsStale() throws {
        var tracker = PairingAttemptTracker()
        let first = try XCTUnwrap(tracker.begin())
        let oldValidity = PairingAttemptValidity()
        XCTAssertTrue(tracker.finish(first)) // attempt failed
        var context = RemotePairingRetryContext()
        context.remember(try endpoint("100.64.0.7"))
        let retryHost = try XCTUnwrap(context.endpointForRetry(state: .failed(.unreachable)))
        XCTAssertEqual(retryHost.host, "100.64.0.7")
        let second = try XCTUnwrap(tracker.begin())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(tracker.finish(first), "late callback from the failed attempt must be ignored")
        XCTAssertTrue(tracker.isCurrent(second))
        oldValidity.invalidate()
        XCTAssertTrue(PairingAttemptValidity().isValid, "fresh attempt gets its own liveness flag")
    }

    // 5. Cancel leaves trust untouched.
    func testForgetCancelDoesNotForget() {
        var confirmation = PeerForgetPrompt()
        var forgotten: [String] = []
        confirmation.request(peerID: macID, name: "Mac")
        XCTAssertTrue(confirmation.isPresented)
        XCTAssertTrue(forgotten.isEmpty, "requesting must not forget")
        confirmation.cancel()
        confirmation.confirm { forgotten.append($0) }
        XCTAssertTrue(forgotten.isEmpty)
        XCTAssertFalse(confirmation.isPresented)
    }

    // 6. Destructive confirm forgets exactly once with the existing operation.
    func testForgetConfirmPerformsExistingForgetOnce() {
        let store = InMemoryPeerTrustStore()
        store.setPin(peerID: macID, spki: Data([1]), displayName: "Mac")
        store.setPin(peerID: phoneID, spki: Data([2]), displayName: "Other")
        var confirmation = PeerForgetPrompt()
        confirmation.request(peerID: macID, name: "Mac")
        XCTAssertNotNil(store.pin(peerID: macID))
        confirmation.confirm { store.forget(peerID: $0) }
        confirmation.confirm { store.forget(peerID: $0) }
        XCTAssertNil(store.pin(peerID: macID))
        XCTAssertNotNil(store.pin(peerID: phoneID))
    }

    // MARK: SAS guidance / waiting for peer

    // 1. SAS ready: helper says both devices must confirm.
    func testSASHelperRequiresBothDevices() {
        XCTAssertEqual(PairingCopy.sasTitle, "Confirm on both devices")
        XCTAssertTrue(PairingCopy.sasHelper.contains("both devices"))
        XCTAssertEqual(PairingStage.derive(state: .connecting, sasPending: true, confirmedLocally: false), .sasReady)
    }

    // 2 + 3. Local confirmation only -> waiting for peer; not success, no trust.
    @MainActor
    func testLocalConfirmationOnlyWaitsForPeerAndIsNotSuccess() async throws {
        let (phone, _) = try pair()
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let store = InMemoryPeerTrustStore()
        let token = UUID()
        let request = Task { await prompt.request(phone.pending, token: token) }
        while prompt.pending == nil { await Task.yield() }
        prompt.decide(accept: true)
        let acceptedLocally = await request.value
        XCTAssertTrue(acceptedLocally)
        XCTAssertNil(prompt.pending)
        XCTAssertEqual(prompt.confirmedLocally?.peerID, macID)
        XCTAssertEqual(PairingStage.derive(state: .connecting, sasPending: false,
                                           confirmedLocally: prompt.confirmedLocally != nil), .waitingForPeer)
        XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.failure(PairingError.rejected)), .none)
        XCTAssertTrue(store.pins.isEmpty, "local confirmation alone never writes trust")
        prompt.attemptEnded(token: token)
        XCTAssertNil(prompt.confirmedLocally)
    }

    // 4. Success only after peer confirmation + finalization.
    func testSuccessOnlyAfterPeerConfirmationFinalizes() throws {
        let (phone, mac) = try pair()
        let store = InMemoryPeerTrustStore()
        XCTAssertNil(store.pin(peerID: macID))
        try PairingFinalizer.complete(result: phone, pending: phone.pending,
                                      peerConfirmation: mac.confirmation(accepted: true), store: store)
        XCTAssertNotNil(store.pin(peerID: macID))
        XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.success(())), .success)
    }

    // 5. Cancel while waiting: cleared, generation dead, late peer confirmation persists nothing.
    @MainActor
    func testCancelWhileWaitingPreventsLaterCompletion() async throws {
        let (phone, mac) = try pair()
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let request = Task { await prompt.request(phone.pending, token: UUID()) }
        while prompt.pending == nil { await Task.yield() }
        prompt.decide(accept: true)
        _ = await request.value
        var tracker = PairingAttemptTracker()
        let generation = try XCTUnwrap(tracker.begin())
        let validity = PairingAttemptValidity()
        prompt.cancel(); tracker.cancel(); validity.invalidate()
        XCTAssertNil(prompt.confirmedLocally)
        XCTAssertFalse(tracker.finish(generation))
        let store = InMemoryPeerTrustStore()
        XCTAssertThrowsError(try PairingFinalizer.complete(
            result: phone, pending: phone.pending, peerConfirmation: mac.confirmation(accepted: true),
            store: store, isCurrent: { validity.isValid }))
        XCTAssertTrue(store.pins.isEmpty)
    }

    // 6. Role-aware copy.
    func testRoleAwareCopyNamesTheOtherDevice() {
        XCTAssertEqual(PairingCopy.waitingHelper(otherDevice: PairingCopy.otherDevice(localIsMac: false, peerName: "Studio")),
                       "Confirm the matching code on your Mac to finish pairing.")
        XCTAssertEqual(PairingCopy.waitingHelper(otherDevice: PairingCopy.otherDevice(localIsMac: true, peerName: "Jai\u{2019}s iPhone")),
                       "Confirm the matching code on \u{201C}Jai\u{2019}s iPhone\u{201D} to finish pairing.")
        XCTAssertEqual(PairingCopy.connectingHelper(target: .mac), "Make sure Pair Over Remote is turned on on the Mac.")
        XCTAssertEqual(PairingCopy.connectingHelper(target: .iPhone), "Make sure Pair Over Remote is turned on on the iPhone.")
    }

    // Mac: local confirm -> waiting -> Cancel/close terminates the real attempt.
    @MainActor
    func testCancelOrCloseWhileWaitingTerminatesAttemptAndBlocksLateCompletion() async throws {
        for closeWindow in [false, true] {
            let (phone, mac) = try pair()
            let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
            let cancelled = PairingFlag()
            let token = UUID()
            prompt.registerAttempt(token) { cancelled.set(); return true }
            let request = Task { await prompt.request(phone.pending, token: token) }
            while prompt.pending == nil { await Task.yield() }
            prompt.decide(accept: true)
            _ = await request.value
            XCTAssertNotNil(prompt.confirmedLocally)
            XCTAssertFalse(cancelled.isSet)
            if closeWindow { prompt.windowClosedByUser() } else { prompt.cancelWaiting() }
            XCTAssertTrue(cancelled.isSet, "the live connection owner must be told to stop")
            XCTAssertNil(prompt.confirmedLocally)
            let store = InMemoryPeerTrustStore()
            XCTAssertThrowsError(try PairingFinalizer.complete(
                result: phone, pending: phone.pending, peerConfirmation: mac.confirmation(accepted: true),
                store: store, isCurrent: { !cancelled.isSet }))
            XCTAssertTrue(store.pins.isEmpty)
        }
    }

    @MainActor
    func testClosingPanelDuringSASOnlyRejectsAndDoesNotCancelConnectionTwice() async throws {
        let (phone, _) = try pair()
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let cancelled = PairingFlag()
        let token = UUID()
        prompt.registerAttempt(token) { cancelled.set(); return true }
        let request = Task { await prompt.request(phone.pending, token: token) }
        while prompt.pending == nil { await Task.yield() }
        prompt.windowClosedByUser()
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(cancelled.isSet, "rejection already ends the attempt via the network layer")
    }
}
