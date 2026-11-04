import AVFoundation
import Combine
import XCTest

/// Nothing this device started may reach the Mac once the receiver surface
/// can't be used (Home over a kept session, Session Actions, Picture in
/// Picture, the app not active), once input is revoked, or once the session
/// pauses, ends or becomes another connection. A one-tap sequence used to
/// re-check only Allow Input between steps, so its later steps kept typing on
/// the Mac behind Home or the Session Actions overlay.
@MainActor
final class RemoteInputIsolationTests: XCTestCase {

    // MARK: - One-tap sequences

    /// A control source that records what it sends and lets a test change the
    /// session between a sequence's steps.
    private final class RecordingSource: ReceiverControlSource {
        var macProtocolVersion: Int { WireProtocol.version }
        var controlSessionPhase: ReceiverSessionPhase { .connected }
        var displayState: DisplayState { .running }
        var videoEnabled: Bool { true }
        var inputResetGeneration: Int { 0 }
        var controlResetGeneration: Int { 0 }
        var remoteInputTicket: RemoteInputTicket? = RemoteInputTicket(controlGeneration: 0, connectionGeneration: 1)
        private(set) var sent: [String] = []
        /// Runs after each send, as Home or a reconnect would between steps.
        var afterSend: ((String) -> Void)?

        func sendKeyboardPress(usage: Int, modifiers: [String]) { record("press \(usage)") }
        func sendKeyboardDown(usage: Int, modifiers: [String]) { record("down \(usage)") }
        func sendKeyboardUp(usage: Int, modifiers: [String]) { record("up \(usage)") }
        func sendModifier(_ modifier: ControlModifier, down: Bool) { record("modifier \(modifier.rawValue) \(down)") }
        func sendGesture(name: String) { record("gesture \(name)") }

        private func record(_ event: String) {
            sent.append(event)
            afterSend?(event)
        }
    }

    private final class Flag { var value = true }

    /// Three single keys (a, b, c) with a short pause after each but the last.
    private func threeKeySequence() -> ControlAction {
        .sequence([4, 5, 6].map {
            ControlActionStep(action: .keyboardShortcut(KeyboardShortcut(usage: $0, modifiers: ModifierChord())), delayMs: 20)
        })
    }

    private func run(_ action: ControlAction, on source: RecordingSource,
                     inputAllowed: @escaping @MainActor () -> Bool = { true }) async {
        await OneTapActionRunner.run(action, receiver: source, inputAllowed: inputAllowed)?.value
    }

    func testASequenceRunsToTheEndWhileNothingChanges() async {
        let source = RecordingSource()
        await run(threeKeySequence(), on: source)
        XCTAssertEqual(source.sent, ["press 4", "press 5", "press 6"])
    }

    /// Home or Session Actions releases local input, which moves the control
    /// generation: the rest of the sequence never goes out.
    func testHomeOrSessionActionsStopsTheRestOfASequence() async {
        let source = RecordingSource()
        source.afterSend = { [unowned source] event in
            if event == "press 4" { source.remoteInputTicket = RemoteInputTicket(controlGeneration: 1, connectionGeneration: 1) }
        }
        await run(threeKeySequence(), on: source)
        XCTAssertEqual(source.sent, ["press 4"], "nothing after Home or Session Actions opened")
    }

    /// The surface closed (Picture in Picture, the app inactive) and is still
    /// closed when the next step is due.
    func testAClosedSurfaceStopsTheRestOfASequence() async {
        let source = RecordingSource()
        source.afterSend = { [unowned source] event in
            if event == "press 4" { source.remoteInputTicket = nil }
        }
        await run(threeKeySequence(), on: source)
        XCTAssertEqual(source.sent, ["press 4"])
    }

    /// A disconnect and reconnect, or another Mac's connection, between two
    /// steps: the later steps must not reach the new session.
    func testAnotherConnectionStopsTheRestOfASequence() async {
        let source = RecordingSource()
        source.afterSend = { [unowned source] event in
            if event == "press 4" { source.remoteInputTicket = RemoteInputTicket(controlGeneration: 0, connectionGeneration: 2) }
        }
        await run(threeKeySequence(), on: source)
        XCTAssertEqual(source.sent, ["press 4"], "nothing reaches a different connection")
    }

    func testRevokedInputStopsTheRestOfASequence() async {
        let source = RecordingSource()
        let allowed = Flag()
        source.afterSend = { event in if event == "press 4" { allowed.value = false } }
        await run(threeKeySequence(), on: source, inputAllowed: { allowed.value })
        XCTAssertEqual(source.sent, ["press 4"])
    }

    func testNothingStartsWhileInputCantLeave() async {
        let source = RecordingSource()
        source.remoteInputTicket = nil
        XCTAssertNil(OneTapActionRunner.run(threeKeySequence(), receiver: source, inputAllowed: { true }))
        OneTapActionRunner.run(.keyboardShortcut(KeyboardShortcut(usage: 4, modifiers: ModifierChord())),
                               receiver: source, inputAllowed: { true })
        XCTAssertEqual(source.sent, [])
    }

    /// Stopping between steps never leaves a key held: each chord's downs and
    /// ups go out together.
    func testAStoppedSequenceLeavesNoKeyHeld() async {
        let source = RecordingSource()
        let chord = KeyboardShortcut(usage: 4, modifiers: ModifierChord(), additionalUsages: [5])
        let action = ControlAction.sequence([
            ControlActionStep(action: .keyboardShortcut(chord), delayMs: 20),
            ControlActionStep(action: .keyboardShortcut(chord), delayMs: 20),
        ])
        source.afterSend = { [unowned source] event in
            if event.hasPrefix("up") { source.remoteInputTicket = RemoteInputTicket(controlGeneration: 1, connectionGeneration: 1) }
        }
        await run(action, on: source)
        let downs = source.sent.filter { $0.hasPrefix("down") }.count
        let ups = source.sent.filter { $0.hasPrefix("up") }.count
        XCTAssertEqual(downs, 2, "the first chord went out whole, the second not at all")
        XCTAssertEqual(downs, ups, "every key that went down came up")
    }

    // MARK: - The receiver's ticket

    private func makeReceiver() -> StreamReceiver {
        StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "Test", fallbackServiceName: "Test")
    }

    func testClosingTheSurfaceReleasesInputAndEndsEarlierTickets() {
        let receiver = makeReceiver()
        let before = receiver.controlResetGeneration
        XCTAssertTrue(receiver.localInputSurfaceOpen)

        receiver.setLocalInputSurfaceOpen(false)
        XCTAssertFalse(receiver.localInputSurfaceOpen)
        XCTAssertEqual(receiver.controlResetGeneration, before + 1, "closing releases what's held")
        receiver.setLocalInputSurfaceOpen(false)
        XCTAssertEqual(receiver.controlResetGeneration, before + 1, "closing twice releases once")

        receiver.setLocalInputSurfaceOpen(true)
        XCTAssertTrue(receiver.localInputSurfaceOpen)
        XCTAssertEqual(receiver.controlResetGeneration, before + 1,
                       "reopening starts nothing, and an earlier ticket stays stale")
    }

    func testNoTicketWithoutALiveConnection() {
        XCTAssertNil(makeReceiver().remoteInputTicket)
    }

    func testAPauseOrTheSessionEndingEndsEarlierTickets() {
        let receiver = makeReceiver()
        let start = receiver.controlResetGeneration
        receiver.applyDisplayStateUpdate(.paused)
        XCTAssertEqual(receiver.controlResetGeneration, start + 1, "a pause ends what was started before it")
        receiver.applyDisplayStateUpdate(.paused)
        receiver.applyDisplayStateUpdate(.running)
        XCTAssertEqual(receiver.controlResetGeneration, start + 1, "resuming starts nothing")

        var live = ReceiverSessionState()
        _ = live.connectionAdopted()
        _ = live.connectionEstablished()
        receiver.applyUISessionSnapshot(live)
        XCTAssertEqual(receiver.controlResetGeneration, start + 1)
        var paused = live
        _ = paused.displayPaused()
        receiver.applyUISessionSnapshot(paused)
        XCTAssertEqual(receiver.controlResetGeneration, start + 2, "the session leaving live input ends it")
    }

    func testATicketNeedsTheSurfaceARunningDisplayALiveSessionAndAConnection() {
        func ticket(surface: Bool = true, running: Bool = true, live: Bool = true,
                    connection: Int? = 7) -> RemoteInputTicket? {
            RemoteInputTicket.current(surfaceOpen: surface, displayRunning: running, sessionLive: live,
                                      controlGeneration: 3, connectionGeneration: connection)
        }
        XCTAssertEqual(ticket(), RemoteInputTicket(controlGeneration: 3, connectionGeneration: 7))
        XCTAssertNil(ticket(surface: false))
        XCTAssertNil(ticket(running: false))
        XCTAssertNil(ticket(live: false))
        XCTAssertNil(ticket(connection: nil))
    }

    func testAClosedSurfaceLetsOnlyReleasesOut() {
        XCTAssertTrue(RemoteInputTransmission.mayLeave(surfaceOpen: true, isRelease: false))
        XCTAssertTrue(RemoteInputTransmission.mayLeave(surfaceOpen: false, isRelease: true))
        XCTAssertFalse(RemoteInputTransmission.mayLeave(surfaceOpen: false, isRelease: false))
        XCTAssertTrue(RemoteInputTransmission.isRelease(phase: "ended"))
        XCTAssertTrue(RemoteInputTransmission.isRelease(phase: "cancelled"))
        for phase in ["began", "moved", "hover"] {
            XCTAssertFalse(RemoteInputTransmission.isRelease(phase: phase), phase)
        }
    }
}
