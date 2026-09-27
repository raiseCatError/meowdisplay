import XCTest

final class ReceiverPictureInPictureTests: XCTestCase {

    // MARK: - Preference

    func testPictureInPictureIsOnForANewInstall() {
        XCTAssertTrue(ReceiverControlPreferences().pictureInPictureEnabled)
    }

    func testTurningPictureInPictureOffSurvivesARelaunch() throws {
        let suite = "ReceiverPictureInPictureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var preferences = repository.load()
        preferences.pictureInPictureEnabled = false
        repository.save(preferences)

        XCTAssertFalse(repository.load().pictureInPictureEnabled)
    }

    func testSchemaFourteenPreferencesMigrateWithPictureInPictureOnAndKeepOtherChoices() throws {
        let suite = "ReceiverPictureInPictureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var old = ReceiverControlPreferences()
        old.version = 14
        old.smartTouchEnabled = true
        old.hapticsEnabled = false
        let encoded = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pictureInPictureEnabled")
        defaults.set(try JSONSerialization.data(withJSONObject: object),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = repository.load()
        XCTAssertEqual(migrated.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertTrue(migrated.pictureInPictureEnabled)
        XCTAssertTrue(migrated.smartTouchEnabled)
        XCTAssertFalse(migrated.hapticsEnabled)
    }

    // MARK: - Conditions and availability

    private func conditions(preference: Bool = true,
                            supported: Bool = true,
                            displayLayer: Bool = true,
                            surface: Bool = true,
                            phase: ReceiverSessionPhase = .connected,
                            video: Bool = true) -> ReceiverPictureInPictureConditions {
        ReceiverPictureInPictureConditions(
            preferenceEnabled: preference, systemSupported: supported,
            rendersThroughDisplayLayer: displayLayer, receiverSurfaceShown: surface,
            sessionPhase: phase, videoEnabled: video)
    }

    func testAvailableOnlyForALiveSessionTheSystemCanShow() {
        XCTAssertEqual(conditions().availability(systemPossible: true), .available)
        XCTAssertEqual(conditions().availability(systemPossible: false), .waitingForVideo)
    }

    func testTurnedOffNeverHostsAControllerSoNothingCanStartAutomatically() {
        let off = conditions(preference: false)
        XCTAssertFalse(off.hostsController)
        XCTAssertFalse(off.sustainsActiveWindow)
        XCTAssertEqual(off.availability(systemPossible: true), .turnedOff)
    }

    func testPersistentReasonsWinOverWaitingForVideo() {
        let unsupported = conditions(supported: false, surface: false, phase: .disconnected)
        XCTAssertEqual(unsupported.availability(systemPossible: false), .unsupported)
        let metal = conditions(displayLayer: false, surface: false, phase: .disconnected)
        XCTAssertEqual(metal.availability(systemPossible: false), .requiresSystemVideoLayer)
        XCTAssertFalse(metal.hostsController)
    }

    func testNoControllerWithoutAReceiverSurface() {
        let idle = conditions(surface: false, phase: .disconnected)
        XCTAssertFalse(idle.hostsController)
        XCTAssertEqual(idle.availability(systemPossible: true), .waitingForVideo)
    }

    func testVideoOffIsNotLiveAndClosesAnOpenWindow() {
        let videoOff = conditions(video: false)
        XCTAssertTrue(videoOff.hostsController)
        XCTAssertFalse(videoOff.showsLiveVideo)
        XCTAssertFalse(videoOff.sustainsActiveWindow)
        XCTAssertEqual(videoOff.availability(systemPossible: true), .waitingForVideo)
    }

    func testPauseAndRecoveryKeepAnOpenWindowButAreNotLive() {
        for phase in [ReceiverSessionPhase.paused, .reconnecting, .connecting] {
            let interrupted = conditions(phase: phase)
            XCTAssertTrue(interrupted.sustainsActiveWindow, "\(phase)")
            XCTAssertFalse(interrupted.showsLiveVideo, "\(phase)")
            XCTAssertEqual(interrupted.availability(systemPossible: true), .waitingForVideo, "\(phase)")
        }
    }

    func testEndedSessionsCloseAnOpenWindow() {
        for phase in [ReceiverSessionPhase.disconnected, .reconnectFailed, .unrecoverable, .peerDisconnected] {
            XCTAssertFalse(conditions(phase: phase).sustainsActiveWindow, "\(phase)")
        }
    }

    func testDisablingThePreferenceOrSwitchingToMetalClosesAnOpenWindow() {
        XCTAssertFalse(conditions(preference: false).sustainsActiveWindow)
        XCTAssertFalse(conditions(displayLayer: false).sustainsActiveWindow)
        XCTAssertTrue(conditions().sustainsActiveWindow)
    }

    // MARK: - Lifecycle

    func testAppSwitchWithoutPictureInPictureLingersAsBefore() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        XCTAssertEqual(lifecycle.sceneDidBackground(deviceLocked: false), .linger)
        XCTAssertFalse(lifecycle.sceneDidActivate())
    }

    func testDeviceLockStillSleepsEvenWithPictureInPictureUp() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        _ = lifecycle.pictureInPictureWillStart()
        lifecycle.pictureInPictureDidStart()
        XCTAssertEqual(lifecycle.sceneDidBackground(deviceLocked: true), .sleep)
        // The sleep already handled this background stint.
        XCTAssertFalse(lifecycle.pictureInPictureDidEnd())
    }

    func testManualWindowKeepsTheStreamLiveThenLingersWhenClosedInTheBackground() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        XCTAssertFalse(lifecycle.pictureInPictureWillStart())
        lifecycle.pictureInPictureDidStart()
        XCTAssertEqual(lifecycle.sceneDidBackground(deviceLocked: false), .keepLive)

        lifecycle.pictureInPictureWillStop()
        XCTAssertTrue(lifecycle.pictureInPictureDidEnd())
        // Applied once only.
        XCTAssertFalse(lifecycle.pictureInPictureDidEnd())
    }

    func testAutomaticStartAfterTheLingerUndoesItAndClosingReappliesIt() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        XCTAssertEqual(lifecycle.sceneDidBackground(deviceLocked: false), .linger)
        XCTAssertTrue(lifecycle.pictureInPictureWillStart())
        lifecycle.pictureInPictureDidStart()

        XCTAssertTrue(lifecycle.pictureInPictureDidEnd())
    }

    func testAutomaticStartBeforeTheBackgroundCallbackNeverLingers() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        XCTAssertFalse(lifecycle.pictureInPictureWillStart())
        XCTAssertEqual(lifecycle.sceneDidBackground(deviceLocked: false), .keepLive)
        lifecycle.pictureInPictureDidStart()
    }

    func testFailedStartAfterTheLingerDoesNotLingerTwice() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        XCTAssertEqual(lifecycle.sceneDidBackground(deviceLocked: false), .linger)
        XCTAssertFalse(lifecycle.pictureInPictureDidEnd())
    }

    func testLockWhileTheWindowShowsInTheBackgroundReplacesTheDeferredLinger() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        _ = lifecycle.pictureInPictureWillStart()
        lifecycle.pictureInPictureDidStart()
        XCTAssertEqual(lifecycle.sceneDidBackground(deviceLocked: false), .keepLive)
        lifecycle.deviceWillLock()
        XCTAssertFalse(lifecycle.pictureInPictureDidEnd())
    }

    func testReturningToTheAppStopsTheWindow() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        _ = lifecycle.pictureInPictureWillStart()
        lifecycle.pictureInPictureDidStart()
        _ = lifecycle.sceneDidBackground(deviceLocked: false)
        XCTAssertTrue(lifecycle.sceneDidActivate())
        // The stop then arrives through AVKit while in the foreground.
        lifecycle.pictureInPictureWillStop()
        XCTAssertFalse(lifecycle.pictureInPictureDidEnd())
    }

    func testAWindowStartedInTheForegroundIsNotStoppedByReactivation() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        _ = lifecycle.pictureInPictureWillStart()
        lifecycle.pictureInPictureDidStart()
        XCTAssertFalse(lifecycle.sceneDidActivate())
    }

    func testAWindowAlreadyRestoringIsNotStoppedAgain() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        _ = lifecycle.pictureInPictureWillStart()
        lifecycle.pictureInPictureDidStart()
        _ = lifecycle.sceneDidBackground(deviceLocked: false)
        lifecycle.pictureInPictureWillStop()
        XCTAssertFalse(lifecycle.sceneDidActivate())
    }

    func testPlaceholderShowsOnlyWhileTheWindowIsUp() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        XCTAssertFalse(lifecycle.isShowingWindow)
        _ = lifecycle.pictureInPictureWillStart()
        XCTAssertTrue(lifecycle.isShowingWindow)
        lifecycle.pictureInPictureDidStart()
        XCTAssertTrue(lifecycle.isShowingWindow)
        // Cleared as the stop begins so the restore lands on the real layer.
        lifecycle.pictureInPictureWillStop()
        XCTAssertFalse(lifecycle.isShowingWindow)
        XCTAssertTrue(lifecycle.isEngaged)
        _ = lifecycle.pictureInPictureDidEnd()
        XCTAssertFalse(lifecycle.isEngaged)
    }

    func testRepeatedWindowsInOneBackgroundStintLingerOnlyWhileNothingShows() {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        XCTAssertEqual(lifecycle.sceneDidBackground(deviceLocked: false), .linger)
        for _ in 0..<3 {
            XCTAssertTrue(lifecycle.pictureInPictureWillStart())
            lifecycle.pictureInPictureDidStart()
            lifecycle.pictureInPictureWillStop()
            XCTAssertTrue(lifecycle.pictureInPictureDidEnd())
        }
        XCTAssertFalse(lifecycle.sceneDidActivate())
    }

    // MARK: - Local audio outside Picture in Picture

    func testSuspendingStopsPlaybackAndBlocksEveryWayBackToPlaying() {
        var audio = ReceiverLocalAudioSuspension()
        XCTAssertEqual(audio.setSuspended(true, hasAudioFormat: true), .stopPlayback)
        XCTAssertFalse(audio.admitsPackets)
        // A config frame arriving while suspended must not start the chain
        // or activate the session.
        XCTAssertFalse(audio.mayStartPlayback)
        // Interruption-ended / route-change recovery must not reactivate it.
        XCTAssertFalse(audio.reactivatesSession(afterDisruption: true))
    }

    func testResumingRebuildsPlaybackOnlyWhenAFormatIsKnown() {
        var audio = ReceiverLocalAudioSuspension()
        _ = audio.setSuspended(true, hasAudioFormat: true)
        XCTAssertEqual(audio.setSuspended(false, hasAudioFormat: true), .resumePlayback(rebuildChain: true))
        XCTAssertTrue(audio.admitsPackets)
        XCTAssertTrue(audio.mayStartPlayback)
        XCTAssertTrue(audio.reactivatesSession(afterDisruption: true))

        _ = audio.setSuspended(true, hasAudioFormat: false)
        // Audio off (no format): the next config frame starts playback as usual.
        XCTAssertEqual(audio.setSuspended(false, hasAudioFormat: false), .resumePlayback(rebuildChain: false))
    }

    func testRepeatedRequestsAreNoOps() {
        var audio = ReceiverLocalAudioSuspension()
        XCTAssertEqual(audio.setSuspended(false, hasAudioFormat: true), .none)
        _ = audio.setSuspended(true, hasAudioFormat: true)
        XCTAssertEqual(audio.setSuspended(true, hasAudioFormat: true), .none)
    }

    func testDisruptionRecoveryStillHonorsTheSystemWhenNotSuspended() {
        let audio = ReceiverLocalAudioSuspension()
        XCTAssertFalse(audio.reactivatesSession(afterDisruption: false))
        XCTAssertTrue(audio.reactivatesSession(afterDisruption: true))
    }

    /// Drives the lifecycle and the audio suspension together exactly as
    /// `ReceiverModel` does: linger suspends, resume/foreground unsuspends.
    private struct BackgroundAudioHarness {
        var lifecycle = ReceiverPictureInPictureLifecycle()
        var audio = ReceiverLocalAudioSuspension()

        mutating func background() {
            if lifecycle.sceneDidBackground(deviceLocked: false) == .linger {
                _ = audio.setSuspended(true, hasAudioFormat: true)
            }
        }
        mutating func foreground() {
            _ = lifecycle.sceneDidActivate()
            _ = audio.setSuspended(false, hasAudioFormat: true)
        }
        mutating func pictureInPictureStarts() {
            if lifecycle.pictureInPictureWillStart() {
                _ = audio.setSuspended(false, hasAudioFormat: true)
            }
            lifecycle.pictureInPictureDidStart()
        }
        mutating func pictureInPictureFailsToStart() {
            if lifecycle.pictureInPictureDidEnd() {
                _ = audio.setSuspended(true, hasAudioFormat: true)
            }
        }
        mutating func pictureInPictureCloses() {
            lifecycle.pictureInPictureWillStop()
            if lifecycle.pictureInPictureDidEnd() {
                _ = audio.setSuspended(true, hasAudioFormat: true)
            }
        }
    }

    func testAppSwitchWithoutPictureInPictureSilencesLocalAudio() {
        var harness = BackgroundAudioHarness()
        harness.background()
        XCTAssertFalse(harness.audio.admitsPackets)
        harness.foreground()
        XCTAssertTrue(harness.audio.admitsPackets)
    }

    func testAudioKeepsPlayingWhileAPictureInPictureWindowShows() {
        var harness = BackgroundAudioHarness()
        harness.pictureInPictureStarts()
        harness.background()
        XCTAssertTrue(harness.audio.admitsPackets)
    }

    func testLateAutomaticStartUndoesTheAudioSuspension() {
        var harness = BackgroundAudioHarness()
        harness.background()
        XCTAssertFalse(harness.audio.admitsPackets)
        harness.pictureInPictureStarts()
        XCTAssertTrue(harness.audio.admitsPackets)
    }

    func testClosingTheWindowInTheBackgroundSilencesAudioAgain() {
        var harness = BackgroundAudioHarness()
        harness.pictureInPictureStarts()
        harness.background()
        harness.pictureInPictureCloses()
        XCTAssertFalse(harness.audio.admitsPackets)
        harness.foreground()
        XCTAssertTrue(harness.audio.admitsPackets)
    }

    func testFailedStartLeavesAudioSilencedInTheBackground() {
        var harness = BackgroundAudioHarness()
        harness.background()
        harness.pictureInPictureFailsToStart()
        XCTAssertFalse(harness.audio.admitsPackets)
    }
}
