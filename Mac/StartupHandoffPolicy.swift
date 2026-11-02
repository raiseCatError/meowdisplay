import Foundation

/// What session startup does with the connection it is waiting on before
/// capture starts (see `MacSender.awaitAdmittedConnection`).
enum StartupHandoffDecision: Equatable {
    /// Start capture for this admitted connection.
    case proceed
    /// The connection was superseded (transport switch, reconnect): wait for the next one.
    case follow
    /// The session stopped, or the connection kept changing: end startup.
    case giveUp
}

/// Startup runs once per session. A connection superseded before capture
/// starts — the Personal Hotspot hot swap to TCP lands ~60 ms after the QUIC
/// hello — must hand startup to the next connection, not end it: giving up
/// left the session connected and admitted with no capture and no Window
/// mode engine, so the window picker stayed empty.
enum StartupHandoffPolicy {
    static let limit = 8

    static func afterHello(isLive: Bool, attempt: Int, stopped: Bool) -> StartupHandoffDecision {
        if stopped { return .giveUp }
        if isLive { return .proceed }
        return attempt + 1 < limit ? .follow : .giveUp
    }

    /// Capture belongs only to the connection the receiver admitted.
    static func afterAdmission(admittedGeneration: UInt64, helloGeneration: UInt64, isAdmitted: Bool,
                               attempt: Int, stopped: Bool) -> StartupHandoffDecision {
        if stopped { return .giveUp }
        if admittedGeneration == helloGeneration, isAdmitted { return .proceed }
        return attempt + 1 < limit ? .follow : .giveUp
    }
}
