import Foundation

// Session Actions (iPhone/iPad): touch and hold the session's Settings control
// to open a modal overlay with Back to Home — Keep Connected, Lock Mac (when
// the Mac supports it) and Disconnect from Mac. Pure values only, so every decision is unit-tested on macOS
// (ReceiverSessionActionsTests); ReceiverScreen and ReceiverControlOverlay act
// on what they return. Nothing here reaches the wire.

enum ReceiverSessionAction: Hashable, Sendable {
    /// `ReceiverModel.showHomeKeepingSession()` (#121).
    case backToHome
    /// Lock This Mac (LockMacFlow): its own confirmation, shown from the overlay, which
    /// stays up; Request Control comes first when this device doesn't have control.
    case lockMac
    /// The same call as Settings → Connections → Disconnect: a deliberate
    /// goodbye, so neither side reconnects by itself (#162).
    case disconnect
}

enum ReceiverSessionActionsPolicy {
    /// Whether the overlay is offered at all: a connected Mac session on
    /// screen. Not in the demo, not on Home over a kept session, not while
    /// recovering (the interruption card owns that).
    static func available(sessionConnected: Bool, sessionOnScreen: Bool) -> Bool {
        sessionConnected && sessionOnScreen
    }

    /// Whether a hold on the Settings control opens it. Not while a shortcut
    /// palette is open (a wheel segment can be drawn over the gear), and not
    /// while Auto-hide has faded the control (a touch there belongs to the Mac).
    static func holdOpens(available: Bool, paletteOpen: Bool, settingsControlVisible: Bool) -> Bool {
        available && !paletteOpen && settingsControlVisible
    }

    /// What the overlay offers, top to bottom. Back to Home needs a surface to
    /// come back to; Lock Mac needs a Mac that supports it; Disconnect is always
    /// there while the overlay is.
    static func actions(surfaceRetained: Bool,
                        presentation: ReceiverSessionPresentation,
                        canLockMac: Bool = false) -> [ReceiverSessionAction] {
        var actions: [ReceiverSessionAction] = []
        if surfaceRetained, presentation == .session { actions.append(.backToHome) }
        if canLockMac { actions.append(.lockMac) }
        actions.append(.disconnect)
        return actions
    }
}

/// Whether the overlay is up, and what dismissing it gives back. While it is
/// up nothing reaches the Mac (see `surfaceInteractive`); Cancel restores the
/// keyboard exactly as it was and changes nothing else.
struct ReceiverSessionActionsState: Equatable, Sendable {
    private(set) var isPresented = false
    private var keyboardWasActive = false

    /// What a chosen action leaves for the screen to do.
    enum Outcome: Equatable, Sendable {
        /// Resume from Home reopens the keyboard if it was open here.
        case backToHome(reopenKeyboardOnResume: Bool)
        /// The overlay stays up; the flow's confirmation opens over it.
        case lockMac
        case disconnect
    }

    mutating func open(keyboardActive: Bool) -> Bool {
        guard !isPresented else { return false }
        isPresented = true
        keyboardWasActive = keyboardActive
        return true
    }

    /// Cancel, a tap outside or the escape gesture. Returns whether the
    /// keyboard should reopen (if it is still allowed).
    mutating func dismiss() -> Bool {
        guard isPresented else { return false }
        let reopen = keyboardWasActive
        self = ReceiverSessionActionsState()
        return reopen
    }

    mutating func choose(_ action: ReceiverSessionAction) -> Outcome? {
        guard isPresented else { return nil }
        if action == .lockMac { return .lockMac }
        let keyboard = keyboardWasActive
        self = ReceiverSessionActionsState()
        switch action {
        case .backToHome: return .backToHome(reopenKeyboardOnResume: keyboard)
        case .lockMac: return .lockMac
        case .disconnect: return .disconnect
        }
    }

    /// The session went away under the overlay: close it, restore nothing.
    mutating func sessionEnded() {
        self = ReceiverSessionActionsState()
    }

    /// Folded into `BlockedInputAttemptPolicy.inputReachesMac`: touch,
    /// pointer, hover, scroll and both keyboards stop while the overlay is up,
    /// exactly as on Home over a kept session.
    func surfaceInteractive(_ presentation: ReceiverSessionPresentation) -> Bool {
        presentation.surfaceInteractive && !isPresented
    }
}
