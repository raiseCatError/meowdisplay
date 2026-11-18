import XCTest
import Network

final class MacSenderCaptureRecoveryTests: XCTestCase {
    func testAudioOnWithoutACarrierRequestsRecoveryOnlyForAnAdmittedIdleAudioOnlySession() async throws {
        let keychain = try TemporaryTestKeychain(prefix: "meowdisplay-audio-carrier-tests")
        defer { keychain.delete() }
        let identity = try keychain.makeIdentity()
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                                   pinnedPeerSPKI: identity.spki, peerID: "audio-carrier-test")
        let helloFields: [String: Any] = [
            "type": "hello", "pixelsWide": 1920, "pixelsHigh": 1080, "scale": 1.0,
            "device": "iPad", "id": "audio-carrier-test", "pv": WireProtocol.version,
        ]
        let hello = try JSONSerialization.data(withJSONObject: helloFields)
        let cases: [(MacSender.AudioCarrierContextForTesting, Bool, Bool, Bool)] = [
            (.ready, true, false, true), (.starting, true, false, false),
            (.rebuilding, true, false, false), (.paused, true, false, false),
            (.resuming, true, false, false),
            (.stopped, true, false, false), (.startup, true, false, false),
            (.ready, false, false, false), (.ready, true, true, false),
        ]
        for (context, admitted, video, shouldRecover) in cases {
            let sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                                   name: "Audio Carrier Test", mode: .mirror)
            if admitted {
                _ = try await sender.admitConnectionForTesting(
                    helloJSON: hello, pinnedSPKI: Data([0x30, 0x59]), eventSink: RecordingEventSink(), sent: { _ in })
            } else {
                _ = try await sender.helloWithoutAdmissionForTesting(
                    helloJSON: hello, pinnedSPKI: Data([0x30, 0x59]), eventSink: RecordingEventSink(), sent: { _ in })
            }
            try await sender.prepareAudioCarrierForTesting(context, video: video)
            let label = "\(context) admitted=\(admitted) video=\(video)"
            for _ in 0..<2 {
                try await sender.receiveControlForTesting(Data("{\"type\":\"audioRequest\",\"enabled\":true}".utf8))
                let probe = try await sender.audioCarrierProbeForTesting
                XCTAssertEqual(probe.admitted, admitted, label)
                // Verified peers may record preferences before admission,
                // but must not start capture until the session is admitted.
                if admitted { XCTAssertTrue(probe.requested, label) }
                XCTAssertEqual(probe.recoveryScheduled, shouldRecover, label)
                if shouldRecover { XCTAssertEqual(probe.phase, "recovering", label) }
            }
            if shouldRecover {
                try await sender.receiveControlForTesting(Data("{\"type\":\"audioRequest\",\"enabled\":false}".utf8))
                let idle = try await sender.audioCarrierProbeForTesting
                XCTAssertFalse(idle.requested, label)
                XCTAssertEqual(idle.phase, "running", label)
                try await sender.expireUnwantedAudioCarrierRecoveryForTesting()
                try await sender.receiveControlForTesting(Data("{\"type\":\"audioRequest\",\"enabled\":true}".utf8))
                let restarted = try await sender.audioCarrierProbeForTesting
                XCTAssertTrue(restarted.recoveryScheduled, label)
                XCTAssertEqual(restarted.phase, "recovering", label)
            } else {
                let before = try await sender.audioCarrierProbeForTesting
                try await sender.receiveControlForTesting(Data("{\"type\":\"audioRequest\",\"enabled\":false}".utf8))
                let after = try await sender.audioCarrierProbeForTesting
                XCTAssertEqual(after.phase, before.phase, label)
                XCTAssertFalse(after.recoveryScheduled, label)
            }
        }
    }

    func testFailedRoundsStayBoundedForVideoAndAudioOnlyWithoutCountingLockedRounds() async throws {
        let keychain = try TemporaryTestKeychain(prefix: "meowdisplay-capture-recovery-tests")
        defer { keychain.delete() }
        let identity = try keychain.makeIdentity()
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                                   pinnedPeerSPKI: identity.spki, peerID: "capture-recovery-test")
        for video in [false, true] {
            for audio in [false, true] {
                for interactive in [false, true] {
                    // Never started or dialed; no ScreenCaptureKit or input.
                    let sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                                           name: "Capture Recovery Test", mode: .mirror)
                    let probes = try await sender.failedCaptureRecoveryRoundsForTesting(
                        video: video, audio: audio, interactive: interactive, rounds: 6)
                    let label = "video=\(video) audio=\(audio) interactive=\(interactive)"
                    if (video || audio) && interactive {
                        XCTAssertEqual(probes.map(\.failedAttempts), [1, 2, 3, 4, 5, 5], label)
                        XCTAssertEqual(probes.map(\.phase),
                                       ["recovering", "recovering", "recovering", "recovering", "stopped", "stopped"], label)
                        XCTAssertEqual(probes.map(\.endedSession), [false, false, false, false, true, true], label)
                    } else {
                        XCTAssertEqual(probes.map(\.failedAttempts), Array(repeating: 0, count: 6), label)
                        XCTAssertTrue(probes.allSatisfy { $0.phase == "recovering" && !$0.endedSession }, label)
                    }
                }
            }
        }
    }
}

final class CaptureLifecycleTests: XCTestCase {
    func testInputIsAllowedWhileRunningAndRecoveryButBlockedDuringPause() {
        var state = CaptureLifecycleState()
        XCTAssertTrue(state.allowsInput) // Initial capture/recovery window.
        XCTAssertTrue(state.captureStarted())
        XCTAssertTrue(state.allowsInput)
        XCTAssertTrue(state.requestPause())
        XCTAssertFalse(state.allowsInput)
        XCTAssertTrue(state.pauseCompleted())
        XCTAssertFalse(state.allowsInput)
        XCTAssertTrue(state.requestResume())
        XCTAssertFalse(state.allowsInput)
        XCTAssertTrue(state.ownsCaptureStop)
        XCTAssertTrue(state.captureStarted())
        XCTAssertTrue(state.allowsInput)
        XCTAssertFalse(state.ownsCaptureStop)
    }

    func testUnexpectedStopRecoversButIntentionalPauseDoesNotRetry() {
        var running = CaptureLifecycleState()
        XCTAssertTrue(running.captureStarted())
        XCTAssertTrue(running.unexpectedStop())
        XCTAssertEqual(running.phase, .recovering)
        XCTAssertTrue(running.shouldRetryCapture)

        var paused = CaptureLifecycleState()
        XCTAssertTrue(paused.requestPause())
        XCTAssertTrue(paused.pauseCompleted())
        XCTAssertFalse(paused.unexpectedStop())
        XCTAssertFalse(paused.shouldRetryCapture)

        var stopped = CaptureLifecycleState()
        stopped.stop()
        XCTAssertTrue(stopped.ownsCaptureStop)
        XCTAssertFalse(stopped.unexpectedStop())
        XCTAssertFalse(stopped.shouldRetryCapture)
    }

    func testRecoveryBudgetIsBoundedAndResettable() {
        var budget = CaptureRecoveryBudget(maximumAttempts: 2)
        XCTAssertTrue(budget.recordFailure())
        XCTAssertFalse(budget.recordFailure())
        budget.reset()
        XCTAssertEqual(budget.failedAttempts, 0)
        XCTAssertTrue(budget.recordFailure())
    }

    func testRecoveryReattachesWhenTargetDisplayStillExists() {
        XCTAssertEqual(CaptureRecoveryPath.resolve(mode: .mirror, targetDisplayAvailable: true),
                       .reattachMirrorCapture)
        XCTAssertEqual(CaptureRecoveryPath.resolve(mode: .mirror, targetDisplayAvailable: false),
                       .rebuildMirrorPipeline)
        XCTAssertEqual(CaptureRecoveryPath.resolve(mode: .extend, targetDisplayAvailable: true),
                       .reattachExtendCapture)
        XCTAssertEqual(CaptureRecoveryPath.resolve(mode: .extend, targetDisplayAvailable: false),
                       .rebuildExtendPipeline)
    }

    func testGenerationGateAcceptsMatchingGeneration() {
        XCTAssertFalse(GenerationGate.isStale(capturedAt: 4, current: 4))
    }

    func testGenerationGateRejectsSupersededGeneration() {
        // A topology health check captured generation 4 but a newer topology
        // event bumped the counter to 5 before the check completed — it must
        // recognize itself as stale rather than acting on outdated readings.
        XCTAssertTrue(GenerationGate.isStale(capturedAt: 4, current: 5))
    }

    func testSuccessfulModeReplacementSynchronizesStalePausedReceiverToRunning() {
        var oldSession = CaptureLifecycleState()
        XCTAssertTrue(oldSession.captureStarted())
        XCTAssertTrue(oldSession.requestPause())
        XCTAssertEqual(oldSession.receiverDisplayState, .paused)

        // A mode switch creates a replacement sender while the receiver keeps
        // the old session's last semantic display state until told otherwise.
        var replacementSession = CaptureLifecycleState()
        XCTAssertTrue(replacementSession.captureStarted())
        XCTAssertEqual(replacementSession.receiverDisplayState, .running)
    }
}

final class DisplayStateTests: XCTestCase {
    func testDisplayStateDecodesKnownAdditiveMessagesAndIgnoresUnknownValues() {
        XCTAssertEqual(DisplayState.decode(messageType: "displayState", value: "paused"), .paused)
        XCTAssertEqual(DisplayState.decode(messageType: "displayState", value: "running"), .running)
        XCTAssertNil(DisplayState.decode(messageType: "gesture", value: "paused"))
        XCTAssertNil(DisplayState.decode(messageType: "displayState", value: "stalled"))
        XCTAssertNil(DisplayState.decode(messageType: "displayState", value: nil))
    }
}

final class VideoStateUpdateTests: XCTestCase {
    func testDecodesStateAndRetainedMappingGeometry() {
        XCTAssertEqual(VideoStateUpdate(message: [
            "type": WireMessage.videoState,
            "enabled": false,
            "width": 2556,
            "height": 1179,
        ]), VideoStateUpdate(enabled: false, width: 2556, height: 1179))
    }

    func testToleratesGeometryThatIsNotKnownYet() {
        XCTAssertEqual(VideoStateUpdate(message: [
            "type": WireMessage.videoState,
            "enabled": false,
            "width": 0,
            "height": 0,
        ]), VideoStateUpdate(enabled: false, width: nil, height: nil))
    }

    func testRejectsWrongTypeOrMissingAuthoritativeState() {
        XCTAssertNil(VideoStateUpdate(message: ["type": "displayState", "enabled": false]))
        XCTAssertNil(VideoStateUpdate(message: ["type": WireMessage.videoState]))
    }
}

final class VideoModePolicyTests: XCTestCase {
    func testVideoOffNormalizesAndRestrictsModeToMirror() {
        XCTAssertEqual(VideoModePolicy.normalized(mode: .extend, videoEnabled: false), .mirror)
        XCTAssertTrue(VideoModePolicy.allows(.mirror, videoEnabled: false))
        XCTAssertFalse(VideoModePolicy.allows(.extend, videoEnabled: false))
    }

    func testVideoOnDoesNotRestoreExtendImplicitly() {
        let off = VideoModePolicy.normalized(mode: .extend, videoEnabled: false)
        XCTAssertEqual(VideoModePolicy.normalized(mode: off, videoEnabled: true), .mirror)
    }
}

final class NativeAppGestureProtocolTests: XCTestCase {
    func testContinuousLifecycleRequiresBeginAndCleansUp() throws {
        var state = NativeAppGestureSessionState()
        let changed = try XCTUnwrap(NativeAppGestureUpdate(message: [
            "type": WireMessage.nativeAppGesture, "kind": "magnify",
            "phase": "changed", "delta": 0.1,
        ]))
        XCTAssertFalse(state.accept(changed))
        let began = try XCTUnwrap(NativeAppGestureUpdate(message: [
            "type": WireMessage.nativeAppGesture, "kind": "magnify",
            "phase": "began", "delta": 0,
        ]))
        XCTAssertTrue(state.accept(began))
        XCTAssertTrue(state.accept(changed))
        let ended = try XCTUnwrap(NativeAppGestureUpdate(message: [
            "type": WireMessage.nativeAppGesture, "kind": "magnify",
            "phase": "ended", "delta": 0,
        ]))
        XCTAssertTrue(state.accept(ended))
        XCTAssertTrue(state.active.isEmpty)
    }

    func testMagnifyAndRotateCanRemainActiveSimultaneously() throws {
        var state = NativeAppGestureSessionState()
        for kind in ["magnify", "rotate"] {
            let update = try XCTUnwrap(NativeAppGestureUpdate(message: [
                "type": WireMessage.nativeAppGesture, "kind": kind,
                "phase": "began", "delta": 0,
            ]))
            XCTAssertTrue(state.accept(update))
        }
        XCTAssertEqual(state.active, Set([.magnify, .rotate]))
        state.cancelAll()
        XCTAssertTrue(state.active.isEmpty)
    }
}
