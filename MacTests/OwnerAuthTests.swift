import XCTest

/// Local device-owner authentication before NEW trust, on the shared prompt.
/// The authenticator is injected, so no LocalAuthentication hardware is involved.
@MainActor
final class OwnerAuthTests: XCTestCase {
    private final class FakeAuthenticator: OwnerAuthenticating {
        private(set) var requests = 0
        private(set) var reasons: [String] = []
        private(set) var invalidated = 0
        private var continuation: CheckedContinuation<OwnerAuthResult, Never>?
        func authenticate(reason: String) async -> OwnerAuthResult {
            requests += 1; reasons.append(reason)
            return await withCheckedContinuation { continuation = $0 }
        }
        func invalidate() { invalidated += 1 }
        func finish(_ result: OwnerAuthResult) { continuation?.resume(returning: result); continuation = nil }
    }

    private func pending(_ classification: PairingClassification, id: String = "peer-a") -> PendingPairing {
        PendingPairing(peerID: id, peerName: "Jai's iPhone", peerSPKI: Data([1]), sas: "123 456",
                       classification: classification)
    }

    /// Shows a SAS for `token` and returns the request task plus a cancel-call counter.
    private func showSAS(_ prompt: PairingPromptModel, token: UUID, _ p: PendingPairing,
                         cancelCalls: @escaping () -> Void = {}) async -> Task<Bool, Never> {
        prompt.registerAttempt(token) { cancelCalls(); return true }
        let task = Task { await prompt.request(p, token: token) }
        while prompt.pending == nil { await Task.yield() }
        return task
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    // 1. new peer + auth success → pairing may continue (waiting only after auth).
    func testNewPeerAuthSuccessAllowsLocalAcceptance() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
        let auth = FakeAuthenticator(); prompt.ownerAuthenticator = auth
        let request = await showSAS(prompt, token: UUID(), pending(.newPeer))
        prompt.decide(accept: true)
        await settle()
        XCTAssertEqual(auth.requests, 1)
        XCTAssertTrue(auth.reasons[0].contains("Jai's iPhone"))
        XCTAssertTrue(prompt.isAuthenticating)
        XCTAssertNil(prompt.confirmedLocally, "no Waiting state before owner auth succeeds")
        XCTAssertNotNil(prompt.pending, "SAS stays up while the OS prompt is on screen")
        auth.finish(.success)
        let accepted = await request.value
        XCTAssertTrue(accepted)
        XCTAssertNotNil(prompt.confirmedLocally)
        XCTAssertFalse(prompt.isAuthenticating)
    }

    // 2. auth failure → no local acceptance, attempt aborted through its real cancel path.
    func testAuthFailureSendsNoAcceptanceAndAbortsAttempt() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
        let auth = FakeAuthenticator(); prompt.ownerAuthenticator = auth
        let token = UUID(); var cancelled = 0
        let request = await showSAS(prompt, token: token, pending(.newPeer)) { cancelled += 1 }
        prompt.decide(accept: true); await settle()
        auth.finish(.failed)
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertNil(prompt.confirmedLocally)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(prompt.takeOutcomeError(token: token), .ownerAuthenticationFailed)
    }

    // 3. user cancels auth → clean cancellation, not a security error.
    func testUserCancelledAuthIsACleanCancellation() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
        let auth = FakeAuthenticator(); prompt.ownerAuthenticator = auth
        let token = UUID(); var cancelled = 0
        let request = await showSAS(prompt, token: token, pending(.newPeer)) { cancelled += 1 }
        prompt.decide(accept: true); await settle()
        auth.finish(.cancelled)
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(prompt.takeOutcomeError(token: token), .cancelledLocally)
        XCTAssertNil(RemotePairingFailure.classify(PairingError.cancelledLocally, cancelledByUser: false,
                                                   deadlineFired: false, handshakeReached: true),
                     "quiet return, no failure state")
    }

    // 4. stale auth success after the attempt was cancelled/ended → ignored.
    func testLateAuthSuccessAfterAttemptEndedIsIgnored() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
        let auth = FakeAuthenticator(); prompt.ownerAuthenticator = auth
        let token = UUID()
        let request = await showSAS(prompt, token: token, pending(.newPeer))
        prompt.decide(accept: true); await settle()
        prompt.attemptEnded(token: token)           // cancelled / replaced / timed out
        XCTAssertEqual(auth.invalidated, 1, "OS prompt is dismissed")
        auth.finish(.success)                       // late success
        await settle()
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertNil(prompt.confirmedLocally)
        XCTAssertFalse(prompt.isAuthenticating)
    }

    // 5. peer abort while the owner-auth prompt is pending → late success cannot revive it.
    func testPeerAbortDuringAuthCannotBeRevived() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
        let auth = FakeAuthenticator(); prompt.ownerAuthenticator = auth
        let token = UUID()
        let request = await showSAS(prompt, token: token, pending(.newPeer))
        prompt.decide(accept: true); await settle()
        prompt.peerAborted(token: token)
        auth.finish(.success)
        await settle()
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertNil(prompt.confirmedLocally)
        XCTAssertEqual(auth.invalidated, 1)
    }

    // Local Cancel / reject during auth also invalidates it.
    func testRejectDuringAuthInvalidatesIt() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
        let auth = FakeAuthenticator(); prompt.ownerAuthenticator = auth
        let request = await showSAS(prompt, token: UUID(), pending(.newPeer))
        prompt.decide(accept: true); await settle()
        prompt.decide(accept: false)
        auth.finish(.success)
        await settle()
        let accepted = await request.value
        XCTAssertFalse(accepted)
        XCTAssertNil(prompt.confirmedLocally)
    }

    // 6. same-key re-pair of an already-trusted peer creates no new trust → no owner auth.
    func testMatchingPinRePairRequestsNoOwnerAuth() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
        let auth = FakeAuthenticator(); prompt.ownerAuthenticator = auth
        prompt.trustPinLookup = { _ in Data([1]) }          // the matching pin still exists
        let request = await showSAS(prompt, token: UUID(), pending(.rePairSameKey))
        prompt.decide(accept: true)
        let accepted = await request.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(auth.requests, 0)
    }

    // 7 + 8. Forgotten peer (unknown again) requires auth; USB/LAN/Remote share the same policy.
    func testForgottenPeerRequiresOwnerAuthOnEveryTransport() {
        let store = InMemoryPeerTrustStore()
        store.setPin(peerID: "peer-a", spki: Data([1]), displayName: "Phone")
        store.forget(peerID: "peer-a")
        let reclassified = PairingClassifier.classify(pending(.rePairSameKey),
                                                      existingPin: store.pin(peerID: "peer-a"))
        XCTAssertEqual(reclassified.classification, .newPeer)
        XCTAssertTrue(OwnerAuthPolicy.isRequired(reclassified, currentPin: .absent))
        // Transport never appears in the policy: there is no USB/loopback bypass parameter.
        XCTAssertTrue(OwnerAuthPolicy.isRequired(pending(.newPeer), currentPin: .absent))
    }

    // 9. Changed identity: the hard failure happens before the prompt, so owner auth can't bypass it.
    func testChangedIdentityIsHardFailureBeforeAnyOwnerAuth() async {
        let auth = FakeAuthenticator()
        let changed = pending(.identityChanged)
        XCTAssertThrowsError(try PairingClassifier.check(changed, allowIdentityChange: false)) {
            XCTAssertEqual($0 as? PairingError, .identityChanged)
        }
        XCTAssertEqual(auth.requests, 0)
        XCTAssertTrue(OwnerAuthPolicy.isRequired(changed, currentPin: .present(Data([9]))), "explicit LAN replacement also needs the owner")
    }

    func testReasonIsConciseAndSanitised() {
        XCTAssertEqual(OwnerAuthPolicy.reason(peerName: "Mac"), "Confirm that you want to trust \u{201C}Mac\u{201D} in MEOW.")
        XCTAssertEqual(OwnerAuthPolicy.reason(peerName: "\n\t\u{202E}"), "Confirm that you want to trust this device in MEOW.")
        XCTAssertLessThanOrEqual(OwnerAuthPolicy.reason(peerName: String(repeating: "x", count: 500)).count, 90)
    }

    /// Both apps must actually wire the real authenticator into the prompt.
    func testAppsInstallTheRealAuthenticator() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Shared/StreamReceiver.swift", "Mac/OpenSidecarMacApp.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("ownerAuthenticator = LocalOwnerAuthenticator()"), path)
            XCTAssertTrue(source.contains("trustPinLookup = { TrustStore.shared.pin(peerID: $0) }"), path)
        }
    }

    // MARK: Fail-closed / re-check / endpoint hint / sanitisation

    // 1. Auth required + no authenticator installed → fails closed.
    func testMissingAuthenticatorFailsClosed() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)   // nothing installed
        let token = UUID(); var cancelled = 0
        let request = await showSAS(prompt, token: token, pending(.newPeer)) { cancelled += 1 }
        prompt.decide(accept: true)
        let accepted = await request.value
        XCTAssertFalse(accepted, "no local acceptance")
        XCTAssertNil(prompt.confirmedLocally)
        XCTAssertEqual(cancelled, 1, "attempt aborted through its real cancel path")
        XCTAssertEqual(prompt.takeOutcomeError(token: token), .ownerAuthenticationFailed)
    }

    // 2a. Same-key classification captured, pin removed before confirmation → auth required.
    func testPinRemovedBeforeConfirmationBecomesNewTrustRequiringAuth() async {
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)
        let auth = FakeAuthenticator(); prompt.ownerAuthenticator = auth
        var pin: Data? = Data([1])
        prompt.trustPinLookup = { _ in pin }
        let request = await showSAS(prompt, token: UUID(), pending(.rePairSameKey))
        pin = nil                                  // Forget while the SAS is on screen
        prompt.decide(accept: true); await settle()
        XCTAssertEqual(auth.requests, 1, "stale same-key classification must not skip owner auth")
        XCTAssertNil(prompt.confirmedLocally)
        auth.finish(.success)
        _ = await request.value
    }

    /// Unverifiable trust (no lookup) is never assumed.
    func testUnverifiablePinIsTreatedAsNewTrust() {
        XCTAssertTrue(OwnerAuthPolicy.isRequired(pending(.rePairSameKey), currentPin: .unavailable))
        XCTAssertTrue(OwnerAuthPolicy.isRequired(pending(.rePairSameKey), currentPin: .absent))
        XCTAssertTrue(OwnerAuthPolicy.isRequired(pending(.rePairSameKey), currentPin: .present(Data([2]))))
    }

    // 2b. Defense in depth: the finalizer refuses to recreate a vanished pin from a stale classification.
    func testFinalizerRefusesToRecreatePinFromStaleSameKeyClassification() throws {
        let phone = PairingHandshake(role: .initiator, deviceID: "22222222-2222-2222-2222-222222222222",
                                     displayName: "Phone", identitySPKI: Data("phone".utf8))
        let mac = PairingHandshake(role: .responder, deviceID: "11111111-1111-1111-1111-111111111111",
                                   displayName: "Mac", identitySPKI: Data("mac".utf8))
        let result = try phone.result(peerHello: mac.localHello)
        let macResult = try mac.result(peerHello: phone.localHello)
        var stale = result.pending; stale.classification = .rePairSameKey
        let store = InMemoryPeerTrustStore()      // pin already gone
        XCTAssertThrowsError(try PairingFinalizer.complete(
            result: result, pending: stale, peerConfirmation: macResult.confirmation(accepted: true), store: store)) {
            XCTAssertEqual($0 as? PairingError, .trustStateChanged)
        }
        XCTAssertTrue(store.pins.isEmpty)
    }

    // 3. Unchanged same-key trust still skips owner auth (covered above with a live pin).
    func testUnchangedSameKeyTrustSkipsAuth() {
        XCTAssertFalse(OwnerAuthPolicy.isRequired(pending(.rePairSameKey), currentPin: .present(Data([1]))))
    }

    // 4. A changed Remote endpoint hint cannot be persisted through a no-auth re-pair.
    func testChangedEndpointHintRequiresOwnerAuthEvenForSameKeyRePair() async {
        var changing = pending(.rePairSameKey); changing.changesRemoteEndpoint = true
        XCTAssertTrue(OwnerAuthPolicy.isRequired(changing, currentPin: .present(Data([1]))))
        let prompt = PairingPromptModel(timeoutNanoseconds: 5_000_000_000)   // no authenticator: fails closed
        prompt.trustPinLookup = { _ in Data([1]) }
        let token = UUID()
        let request = await showSAS(prompt, token: token, changing)
        prompt.decide(accept: true)
        let accepted = await request.value
        XCTAssertFalse(accepted, "hint change is never silently approved")
        XCTAssertTrue(OwnerAuthPolicy.reason(peerName: "Mac", updatingEndpointOnly: true).contains("remote address"))
    }

    // 5. An unchanged hint causes no extra auth.
    func testUnchangedEndpointHintCausesNoAuth() {
        XCTAssertFalse(RemoteHintChange.wouldChange(
            existing: (host: "Mac.tail1234.ts.net", port: WireCrypto.remoteRequestPort), newHost: "mac.tail1234.ts.net"))
        XCTAssertTrue(RemoteHintChange.wouldChange(existing: nil, newHost: "100.64.0.7"))
        XCTAssertTrue(RemoteHintChange.wouldChange(
            existing: (host: "100.64.0.7", port: WireCrypto.remoteRequestPort), newHost: "100.64.0.8"))
        XCTAssertFalse(OwnerAuthPolicy.isRequired(pending(.rePairSameKey), currentPin: .present(Data([1]))))
    }

    // 6. Dangerous bidi / invisible formatting characters are removed.
    func testBidiAndFormattingCharactersAreStrippedFromPrompt() {
        let hostile = "Mac\u{202E}gnp.exe\u{2066}x\u{2069}\u{200F}\u{200B}\u{FEFF}"
        let cleaned = OwnerAuthPolicy.sanitizedName(hostile)
        for scalar in cleaned.unicodeScalars {
            XCTAssertFalse((0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value))
            XCTAssertFalse([0x200B, 0x200E, 0x200F, 0xFEFF].contains(scalar.value))
        }
        XCTAssertEqual(cleaned, "Macgnp.exex")
        XCTAssertEqual(OwnerAuthPolicy.reason(peerName: "\u{202E}\u{200F}"),
                       "Confirm that you want to trust this device in MEOW.")
    }

    // 7. Ordinary Unicode names stay usable (including emoji ZWJ sequences).
    func testOrdinaryUnicodeNamesArePreserved() {
        for name in ["Jai\u{2019}s iPhone", "日本語のiPhone", "Мой Mac", "أحمد", "👨\u{200D}👩\u{200D}👧 Mac"] {
            XCTAssertEqual(OwnerAuthPolicy.sanitizedName(name), name)
        }
    }
}
