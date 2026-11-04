import Foundation

// Back to Home — Keep Connected (#121) for the iOS/iPadOS receiver. Pure
// values only, so every decision is unit-tested on macOS; ReceiverModel and
// ReceiverScreen act on what they return. Nothing here reaches the wire: the
// Mac keeps its session, display and encoder exactly as they were.

/// Whether the person is in the session or on Home with the session kept
/// behind it. The session surface stays mounted under Home (zoom, Move View,
/// panes, Stage Peek and the decoder all survive); only what reaches the Mac
/// and what plays locally changes.
enum ReceiverSessionPresentation: Equatable, Sendable {
    case session
    /// `macPeerID`: the Mac the session belonged to when Home opened (nil
    /// while not known, e.g. during recovery). Another Mac taking over the
    /// session shows that session instead of keeping it hidden.
    case homeKeepingSession(macPeerID: String?)

    var keepsSessionOnHome: Bool {
        if case .homeKeepingSession = self { return true }
        return false
    }

    /// Touch, pointer, hover, scroll and both keyboards reach the Mac only
    /// while the session is on screen.
    var surfaceInteractive: Bool { !keepsSessionOnHome }

    /// Opens Home with the session kept. Only a session whose surface is
    /// actually retained can be kept; there is nothing to come back to
    /// otherwise.
    mutating func showHome(surfaceRetained: Bool, macPeerID: String?) -> Bool {
        guard surfaceRetained, !keepsSessionOnHome else { return false }
        self = .homeKeepingSession(macPeerID: macPeerID)
        return true
    }

    mutating func resume() -> Bool {
        guard keepsSessionOnHome else { return false }
        self = .session
        return true
    }

    /// Follows the session underneath. Once the surface is no longer
    /// retained (disconnect, Forget, sleep) the kept session is over, so a
    /// later session never starts hidden behind Home. Recovery and a
    /// transport migration (through `connecting`) keep the surface and stay
    /// kept; a different Mac's session replacing it is shown.
    mutating func sessionChanged(retainsSurface: Bool, macPeerID: String?) -> Bool {
        guard case .homeKeepingSession(let kept) = self else { return false }
        guard retainsSurface else {
            self = .session
            return true
        }
        guard let macPeerID else { return false }
        if let kept, kept != macPeerID {
            self = .session
            return true
        }
        guard kept == nil else { return false }
        self = .homeKeepingSession(macPeerID: macPeerID)
        return true
    }
}

/// Receiver-local video rendering and audio playback, and whether recovery is
/// parked. Never a wire message: the Mac keeps encoding and keep-alive pings
/// continue, so coming back only flushes and asks for a keyframe.
struct ReceiverLocalMediaPolicy: Equatable, Sendable {
    var renderingPaused: Bool
    var audioSuspended: Bool
    var recoveryParked: Bool

    static let live = ReceiverLocalMediaPolicy(renderingPaused: false, audioSuspended: false, recoveryParked: false)

    static func resolve(presence: ReceiverPictureInPictureLifecycle.Presence,
                        presentation: ReceiverSessionPresentation,
                        pictureInPictureEngaged: Bool) -> ReceiverLocalMediaPolicy {
        switch presence {
        case .asleep, .lingering:
            // Off screen with nothing showing the picture (the existing linger).
            return ReceiverLocalMediaPolicy(renderingPaused: true, audioSuspended: true, recoveryParked: true)
        case .live:
            return .live
        case .foreground:
            // Home in front: nothing on screen shows the picture, so decoding
            // and playing it is wasted work. A Picture in Picture window that is
            // already up still does. Recovery keeps going; the app is in front.
            guard presentation.keepsSessionOnHome, !pictureInPictureEngaged else { return .live }
            return ReceiverLocalMediaPolicy(renderingPaused: true, audioSuspended: true, recoveryParked: false)
        }
    }
}

/// What a Mac's row on Home offers while this device has a session. One
/// session at a time: connecting to or pairing with another Mac from Home
/// would start a second one behind the kept session.
enum HomeMacSessionRole: Equatable, Sendable {
    /// No session: the row's usual Connect or Pair.
    case available
    /// This row's Mac is the session's: Connected (and Resume while kept).
    case current
    /// Another Mac's session holds this device.
    case otherMacInSession

    static func resolve(rowPeerID: String?, sessionMacPeerID: String?, sessionActive: Bool) -> HomeMacSessionRole {
        guard sessionActive else { return .available }
        if let rowPeerID, rowPeerID == sessionMacPeerID { return .current }
        return .otherMacInSession
    }
}
