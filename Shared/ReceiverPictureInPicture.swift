import Foundation

// Picture in Picture policy for the iOS receiver — pure values only, no
// AVKit, so every decision here is unit-testable on macOS. The AVKit side
// (`ReceiverPictureInPictureController`, iOS only) feeds these values in and
// acts on what they return.
//
// PiP is deliberately view-only: it shows the same `AVSampleBufferDisplayLayer`
// the receiver already decodes into, so there is no second stream, decoder,
// or render path. All control of the Mac stays in the full receiver.

/// Why Picture in Picture can or can't be offered right now. Ordered from the
/// most persistent reason to the most transient, so Settings can explain the
/// one the user can actually act on.
enum ReceiverPictureInPictureAvailability: Equatable {
    case available
    /// The user's Picture in Picture preference is off.
    case turnedOff
    /// The OS/device doesn't support Picture in Picture.
    case unsupported
    /// The experimental Metal renderer draws frames itself, so there is no
    /// system video layer for Picture in Picture to show.
    case requiresSystemVideoLayer
    /// No live picture yet (not streaming, Video Off, paused, recovering) or
    /// the system isn't ready to start.
    case waitingForVideo
}

/// Everything outside AVKit that decides whether Picture in Picture may run.
struct ReceiverPictureInPictureConditions: Equatable {
    var preferenceEnabled: Bool
    var systemSupported: Bool
    /// False while the experimental Metal renderer is on.
    var rendersThroughDisplayLayer: Bool
    /// The receiver surface (and therefore the display layer) is on screen.
    var receiverSurfaceShown: Bool
    var sessionPhase: ReceiverSessionPhase
    /// Mac-confirmed Video On/Off.
    var videoEnabled: Bool

    static let inactive = ReceiverPictureInPictureConditions(
        preferenceEnabled: false, systemSupported: false, rendersThroughDisplayLayer: false,
        receiverSurfaceShown: false, sessionPhase: .disconnected, videoEnabled: false)

    /// Whether a Picture in Picture controller should exist at all. Tearing
    /// it down whenever this is false keeps nothing attached to the display
    /// layer while PiP can't be used.
    var hostsController: Bool {
        preferenceEnabled && systemSupported && rendersThroughDisplayLayer && receiverSurfaceShown
    }

    /// Frames are arriving from a live session.
    var showsLiveVideo: Bool {
        sessionPhase == .connected && videoEnabled
    }

    /// Whether an already-running Picture in Picture window stays up. A pause
    /// or an automatic recovery (including a transport migration passing
    /// back through `connecting`) keeps the window, showing as paused, so a
    /// brief drop doesn't throw the user out. A session that ended, or
    /// recovery that gave up, closes it: nobody can act on those from a
    /// floating window.
    var sustainsActiveWindow: Bool {
        guard hostsController, videoEnabled else { return false }
        switch sessionPhase {
        case .connected, .connecting, .paused, .reconnecting:
            return true
        case .disconnected, .reconnectFailed, .unrecoverable, .peerDisconnected:
            return false
        }
    }

    /// `systemPossible` is AVKit's own `isPictureInPicturePossible`.
    func availability(systemPossible: Bool) -> ReceiverPictureInPictureAvailability {
        if !preferenceEnabled { return .turnedOff }
        if !systemSupported { return .unsupported }
        if !rendersThroughDisplayLayer { return .requiresSystemVideoLayer }
        guard hostsController, showsLiveVideo, systemPossible else { return .waitingForVideo }
        return .available
    }
}

/// Coordinates Picture in Picture with the receiver's existing background
/// handling. Normally an app switch pauses rendering and parks recovery (the
/// "linger"); while Picture in Picture is up the picture has to keep flowing,
/// so the linger is held off for as long as the window is showing and applied
/// once it closes with the app still in the background.
///
/// Automatic Picture in Picture (`canStartPictureInPictureAutomaticallyFromInline`)
/// starts during the transition to the background, and its start callbacks
/// are not guaranteed to arrive before the scene reports `background`. So a
/// start is allowed to undo a linger that was already applied.
struct ReceiverPictureInPictureLifecycle: Equatable {
    enum Phase: Equatable {
        case inactive
        case starting
        case active
        case stopping
    }

    /// Where the app is, and which background handling currently applies.
    enum Presence: Equatable {
        case foreground
        /// Backgrounded by a device lock: the session was put to sleep.
        case asleep
        /// Backgrounded without Picture in Picture: rendering paused,
        /// recovery parked.
        case lingering
        /// Backgrounded with Picture in Picture showing the stream.
        case live
    }

    /// What the app should do on entering the background.
    enum BackgroundAction: Equatable {
        /// The device locked: end the session, exactly as without PiP.
        case sleep
        /// A plain app switch without PiP: pause rendering and park recovery.
        case linger
        /// Picture in Picture is showing the stream: keep it live.
        case keepLive
    }

    private(set) var phase = Phase.inactive
    private(set) var presence = Presence.foreground

    /// PiP is up or on its way up or down — the stream must keep flowing.
    var isEngaged: Bool { phase != .inactive }

    /// The floating window is (or is about to be) showing the stream, so the
    /// inline receiver surface shows a placeholder instead. Cleared as soon
    /// as a stop begins so the restore animation lands on the real layer.
    var isShowingWindow: Bool { phase == .starting || phase == .active }

    mutating func sceneDidBackground(deviceLocked: Bool) -> BackgroundAction {
        if deviceLocked {
            presence = .asleep
            return .sleep
        }
        if isEngaged {
            presence = .live
            return .keepLive
        }
        presence = .lingering
        return .linger
    }

    /// Returns whether Picture in Picture should be stopped: coming back to
    /// the app brings the full receiver back, which makes the floating copy
    /// redundant. Only a return from the background counts — a transient
    /// `inactive` blip (Control Center, a system alert) never backgrounds the
    /// scene, and a window the user just started in the foreground must stay
    /// up.
    mutating func sceneDidActivate() -> Bool {
        let returningFromBackground = presence != .foreground
        presence = .foreground
        return returningFromBackground && isShowingWindow
    }

    /// The device is locking while backgrounded; the sleep that follows
    /// replaces any linger, applied or deferred.
    mutating func deviceWillLock() {
        if presence != .foreground { presence = .asleep }
    }

    /// Returns whether an already-applied linger must be undone (resume
    /// rendering and recovery) because Picture in Picture is starting after
    /// the scene was already backgrounded.
    mutating func pictureInPictureWillStart() -> Bool {
        phase = .starting
        guard presence == .lingering else { return false }
        presence = .live
        return true
    }

    mutating func pictureInPictureDidStart() { phase = .active }
    mutating func pictureInPictureWillStop() { phase = .stopping }

    /// Picture in Picture stopped or failed to start. Returns whether the
    /// linger held off while it was showing must be applied now, because the
    /// app is still in the background with nothing on screen.
    mutating func pictureInPictureDidEnd() -> Bool {
        phase = .inactive
        guard presence == .live else { return false }
        presence = .lingering
        return true
    }
}
