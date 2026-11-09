import Foundation

/// What the receiver should do next for "Show Lock Screen" (PROTOCOL.md 6.19, SECURITY.md
/// "Lock screen control"). The Mac decides everything and enforces it; this only asks and shows.
enum LockScreenAction: Equatable, Sendable {
    case none
    /// Ask for control of this session (granted without a prompt when the Mac offered this).
    case requestControl
    /// Switch to Full Desktop Mirror (the main display, where macOS shows its login window); the
    /// Mac's lock screen can't be shown from Window view.
    case switchToFullDesktop
    /// Ask the Mac to show (`true`) or hide (`false`) its lock screen on this device.
    case show(Bool)
    /// The Mac unlocked after a trip through Full Desktop: go back to Window view.
    case returnToWindowView
}

/// The "Show Lock Screen" steps as a pure state machine: no UI, no clock of its own, no
/// password. It never shows the lock screen unless the Mac said `lockScreen == .active`.
struct LockScreenFlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case waitingForControl
        case waitingForFullDesktop
        case waitingForActive
        case showing
        case failed(String)
    }

    /// How long any waiting step may take before it counts as a failure.
    static let timeout: TimeInterval = 30

    private(set) var phase: Phase = .idle
    /// The flow switched from Window view to Full Desktop and goes back once the Mac unlocks.
    private(set) var returnToWindowView = false
    private var waitingSince: Date?
    /// This device asked the Mac to show its lock screen (`show(true)`) on the current connection.
    /// Without that, the Mac saying `active` (a view left from before a reconnect) is never shown
    /// here: the flow asks it to hide instead.
    private(set) var askedOnThisConnection = false
    /// The flow failed after switching modes: go back to where it started on the next update
    /// with a connection (a refused or failed attempt doesn't strand the device in Mirror).
    private var returnPending = false

    var isWaiting: Bool {
        switch phase {
        case .waitingForControl, .waitingForFullDesktop, .waitingForActive: return true
        default: return false
        }
    }

    var isShowing: Bool { phase == .showing }

    /// The user tapped Show Lock Screen. Only when the Mac offers it to this device.
    mutating func begin(notice: MacLockNotice?, now: Date) -> LockScreenAction {
        switch phase {
        case .idle, .failed: break
        default: return .none
        }
        guard let notice, notice.isLocked, notice.remoteUnlock else { return .none }
        switch notice.lockScreen {
        case .active:
            // The user tapped while the Mac already shows it here.
            askedOnThisConnection = true
            phase = .showing
            waitingSince = nil
            return .none
        case .available:
            enter(.waitingForActive, now)
            askedOnThisConnection = true
            return .show(true)
        case .needsControl:
            enter(.waitingForControl, now)
            return .requestControl
        case .needsFullDesktop:
            returnToWindowView = true
            enter(.waitingForFullDesktop, now)
            return .switchToFullDesktop
        case .unavailable:
            return .none
        }
    }

    /// The user tapped Hide.
    mutating func hide(now: Date) -> LockScreenAction {
        guard phase == .showing else { return .none }
        phase = .idle
        waitingSince = nil
        askedOnThisConnection = false
        return .show(false)
    }

    /// The app couldn't carry out an action the flow asked for (for example, the mode switch
    /// wasn't possible): nothing will arrive, so say so now instead of waiting out the timeout.
    mutating func couldNotPerform() {
        guard isWaiting else { return }
        waitingSince = nil
        // The switch itself didn't happen: there is nothing to go back from.
        returnToWindowView = false
        returnPending = false
        phase = .failed(String(localized: "The Mac isn't offering its lock screen to this device."))
    }

    /// The connection is to another Mac than the one Show Lock Screen started on (identity
    /// uncertain): stop, without switching anything on this one.
    mutating func abandon() {
        guard phase != .idle else { return }
        reset()
        phase = .failed(String(localized: "Connected to a different Mac, so Show Lock Screen stopped."))
    }

    /// The failure message was read.
    mutating func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// The Mac's latest `macLockState` (nil = unlocked), and whether the connection is up.
    /// A drop while switching to Full Desktop is the mode switch reconnecting; any other drop ends
    /// the flow.
    mutating func update(notice: MacLockNotice?, connected: Bool, now: Date) -> LockScreenAction {
        checkTimeout(now)
        guard connected else {
            askedOnThisConnection = false   // a new connection has to ask again
            if phase != .waitingForFullDesktop, !returnPending { reset() }
            return .none
        }
        if returnPending { return takeReturn() }
        guard let notice, notice.isLocked else {
            // Nothing from the new connection yet: not an unlock while switching.
            if notice == nil, phase == .waitingForFullDesktop { return .none }
            return unlocked()
        }
        // Without `remoteUnlock` nothing is offered, whatever `lockScreen` says; keep the Mac's reason.
        var offer = notice.lockScreen
        if !notice.remoteUnlock, offer.offered { offer = .unavailable(nil) }
        switch phase {
        case .idle:
            guard offer == .active else { return .none }
            // Never resumed on its own (after a reconnect, or a late answer to Hide): only what
            // this device asked for on this connection shows.
            guard askedOnThisConnection else { return .show(false) }
            phase = .showing
            return .none
        case .failed:
            return .none
        case .showing:
            switch offer {
            case .active: return .none
            case .unavailable(let why): return failed(why)
            default: phase = .idle; return .none   // the Mac ended it
            }
        case .waitingForControl, .waitingForFullDesktop, .waitingForActive:
            switch offer {
            case .active:
                guard askedOnThisConnection else { return .show(false) }
                phase = .showing
                waitingSince = nil
                return .none
            case .unavailable(nil) where phase == .waitingForFullDesktop:
                // The new Full Desktop connection says it's locked before the Mac has matched it
                // to this device: no decision yet, keep waiting (the timeout still applies).
                return .none
            case .unavailable(let why):
                return failed(why)
            case .available:
                guard phase != .waitingForActive else { return .none }
                enter(.waitingForActive, now)
                askedOnThisConnection = true
                return .show(true)
            case .needsControl:
                guard phase == .waitingForFullDesktop else { return .none }
                enter(.waitingForControl, now)
                return .requestControl
            case .needsFullDesktop:
                return .none
            }
        }
    }

    /// Time passing with no news from the Mac.
    mutating func tick(now: Date) -> LockScreenAction {
        checkTimeout(now)
        return .none
    }

    // MARK: -

    private mutating func enter(_ next: Phase, _ now: Date) {
        phase = next
        waitingSince = now
    }

    private mutating func reset() {
        askedOnThisConnection = false
        returnPending = false
        phase = .idle
        returnToWindowView = false
        waitingSince = nil
    }

    private mutating func unlocked() -> LockScreenAction {
        let back = returnToWindowView
        reset()
        return back ? .returnToWindowView : .none
    }

    private mutating func checkTimeout(_ now: Date) {
        guard isWaiting, let since = waitingSince, now.timeIntervalSince(since) >= Self.timeout else { return }
        phase = .failed(String(localized: "The Mac didn't respond."))
        waitingSince = nil
        returnPending = returnToWindowView
    }

    private mutating func failed(_ reason: String?) -> LockScreenAction {
        fail(reason)
        returnPending = returnToWindowView
        return takeReturn()
    }

    /// Back to where the flow started (Window view or Extend), once.
    private mutating func takeReturn() -> LockScreenAction {
        returnPending = false
        guard returnToWindowView else { return .none }
        returnToWindowView = false
        return .returnToWindowView
    }

    private mutating func fail(_ reason: String?) {
        waitingSince = nil
        switch reason {
        case "turnedOff"?:
            phase = .failed(String(localized: "Lock Screen Control is off for this device on the Mac."))
        case "controlBeforeLock"?:
            phase = .failed(String(localized: "Control wasn't allowed before the Mac locked."))
        default:
            phase = .failed(String(localized: "The Mac isn't offering its lock screen to this device."))
        }
    }
}

extension MacLockNotice {
    /// The Mac's own lock screen is up on this device (`lockScreen == .active`): show the picture
    /// (the Mac sends fresh frames) instead of the opaque cover. Never true without the Mac saying so.
    var showsMacLockScreen: Bool {
        state == .locked && remoteUnlock && lockScreen == .active
    }
}

/// What the receiver shows while the Mac is locked, as pure decisions (the views only draw them).
/// The opaque cover stays up until the Mac's lock screen is both `active` and playing here: no
/// moment shows the video-off surface (Trackpad) or anything else behind it, the mode switch's
/// reconnect included.
enum MacLockedCoverPolicy {
    /// The Mac's lock screen picture shows (with its banner): the Mac says `active` for this
    /// device, this device asked for it (`flow.isShowing`), and video is on. Never without the
    /// Mac saying so.
    static func showsLockScreen(notice: MacLockNotice?, flow: LockScreenFlow, videoEnabled: Bool) -> Bool {
        (notice?.showsMacLockScreen ?? false) && flow.isShowing && videoEnabled
    }

    /// The cover is up: the Mac is locked and its lock screen isn't playing here yet, or the flow
    /// is between steps with nothing said by the Mac (the drop and reconnect of the switch to Full
    /// Desktop, which clears `macLock`).
    static func showsCover(notice: MacLockNotice?, flow: LockScreenFlow, videoEnabled: Bool) -> Bool {
        if let notice { return notice.isLocked && !showsLockScreen(notice: notice, flow: flow, videoEnabled: videoEnabled) }
        return flow.isWaiting
    }

    /// The notice the cover draws: the Mac's, or, mid-switch before the new connection says
    /// anything, locked with nothing offered (the flow's status says what's happening).
    static func coverNotice(_ notice: MacLockNotice?) -> MacLockNotice {
        notice ?? MacLockNotice(state: .locked)
    }

    /// One plain line about Show Lock Screen for this device: before the tap, what it will do;
    /// when it isn't offered, why. Nil while it's active or the Mac isn't showing its lock screen.
    static func offerText(_ notice: MacLockNotice) -> String? {
        guard notice.state == .locked else { return nil }
        var offer = notice.lockScreen
        if !notice.remoteUnlock, offer.offered { offer = .unavailable(nil) }
        switch offer {
        case .active:
            return nil
        case .available:
            return String(localized: "Shows the Mac’s own lock screen here, so you can type its password.")
        case .needsControl:
            return String(localized: "Asks this Mac for control first, then shows its lock screen here.")
        case .needsFullDesktop:
            return String(localized: "Switches to Full Desktop first, then shows the Mac’s lock screen here. Your view comes back once it’s unlocked.")
        case .unavailable(let why):
            switch why {
            case "turnedOff"?:
                return String(localized: "Lock Screen Control is off for this device. It can be turned on in this device’s settings on the Mac.")
            case "controlBeforeLock"?:
                return String(localized: "This device didn’t have control before the Mac locked, and nobody can allow it while it’s locked. Unlock it at the Mac.")
            case "windowView"?:
                return String(localized: "This view can’t show the lock screen, and this device can’t get control again while the Mac is locked.")
            case "neverAllow"?:
                return String(localized: "This device is set to Never Allow control on the Mac.")
            case "inputOff"?:
                return String(localized: "Allow Input is off on the Mac.")
            default:
                return String(localized: "It can’t be unlocked from this device. Control can be requested once it’s unlocked.")
            }
        }
    }
}


/// Where the on-screen keyboard is, as the controls and the Mac are told it.
///
/// Only the Mac picture's surface reports the keyboard's place, and only while it asked for the
/// keyboard. A surface that goes away (a display-mode switch rebuilds it) can't report the
/// keyboard closing, and the new surface has nothing to report until the keyboard moves. Unlocking
/// the Mac from its lock screen does exactly that: the lock screen plays in Full Desktop, the Mac
/// goes back to Window view, and the keyboard closes. QA 9000034 (iPad): the keyboard went
/// away but the control tray stayed raised where the keyboard had been.
///
/// So a reported place counts only while this device's keyboard is open and the surface that
/// reported it is still shown; otherwise the keyboard is closed.
enum SoftwareKeyboardPresence {
    static func visibleRect(reported: CGRect?, keyboardActive: Bool, surfaceShown: Bool) -> CGRect? {
        guard keyboardActive, surfaceShown else { return nil }
        return reported
    }
}
