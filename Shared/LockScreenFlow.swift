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
            phase = .showing
            waitingSince = nil
            return .none
        case .available:
            enter(.waitingForActive, now)
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
        return .show(false)
    }

    /// The app couldn't carry out an action the flow asked for (for example, the mode switch
    /// wasn't possible): nothing will arrive, so say so now instead of waiting out the timeout.
    mutating func couldNotPerform() {
        guard isWaiting else { return }
        waitingSince = nil
        phase = .failed(String(localized: "The Mac isn't offering its lock screen to this device."))
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
            if phase != .waitingForFullDesktop { reset() }
            return .none
        }
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
            if offer == .active { phase = .showing }
            return .none
        case .failed:
            return .none
        case .showing:
            switch offer {
            case .active: return .none
            case .unavailable(let why): fail(why); return .none
            default: phase = .idle; return .none   // the Mac ended it
            }
        case .waitingForControl, .waitingForFullDesktop, .waitingForActive:
            switch offer {
            case .active:
                phase = .showing
                waitingSince = nil
                return .none
            case .unavailable(nil) where phase == .waitingForFullDesktop:
                // The new Full Desktop connection says it's locked before the Mac has matched it
                // to this device: no decision yet, keep waiting (the timeout still applies).
                return .none
            case .unavailable(let why):
                fail(why)
                return .none
            case .available:
                guard phase != .waitingForActive else { return .none }
                enter(.waitingForActive, now)
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
