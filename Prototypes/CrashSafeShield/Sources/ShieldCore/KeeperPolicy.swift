import Foundation

/// What the keeper shows. `held` is covered with no session: it stays until local unlock.
public enum KeeperPhase: Equatable {
    case idle
    case covering(Set<String>)
    case held
}

public enum KeeperEvent: Equatable {
    case peer(WireMessage)
    /// The app's end of the channel closed, or its process exited.
    case peerGone
    /// The Unlock control was used. `physical`: the click came from this Mac's own input.
    /// `authenticated`: macOS accepted the login password.
    case localUnlock(physical: Bool, authenticated: Bool)
    /// The keeper's own main thread stopped responding (watchdog thread).
    case mainThreadStalled
}

public enum KeeperAction: Equatable {
    case showCovers
    case hideCovers
    /// Lock the login session (defence in depth when the cover can't be trusted to stay).
    case lockScreen
    case notifyPeerUnlocked
    case exitProcess
    case log(String)
}

/// The keeper's rules, separated from AppKit so they can be tested.
///
/// - The app can only ask to cover. Nothing it sends removes the cover.
/// - Ending a session keeps the cover up (held) until this Mac's own input plus the password.
/// - The app disappearing without its clean-quit handshake while covering or held: the cover
///   stays, and the screen is locked as well.
/// - A clean quit while covering or held still leaves the cover up (fail closed).
/// - With nothing covered, the keeper exits when the app goes away: no orphan process or window.
/// - If the keeper's own main thread hangs while covering, its frozen windows can't take the
///   unlock, so it locks the screen and exits. The lock, not the cover, then protects the Mac.
public struct KeeperPolicy {
    public private(set) var phase: KeeperPhase = .idle
    public private(set) var peerConnected = true
    public private(set) var cleanQuitAnnounced = false
    public let nonce: String

    public init(nonce: String) { self.nonce = nonce }

    public var isCovering: Bool { phase != .idle }

    public mutating func handle(_ event: KeeperEvent) -> [KeeperAction] {
        switch event {
        case .peer(let message):
            return handle(message)

        case .peerGone:
            guard peerConnected else { return [] }
            peerConnected = false
            switch phase {
            case .idle:
                return [.log("app gone, nothing covered: exiting"), .exitProcess]
            case .covering, .held:
                phase = .held
                if cleanQuitAnnounced {
                    return [.log("app quit normally while covering: staying covered until unlocked here")]
                }
                return [.log("app gone without a clean quit while covering: staying covered and locking"), .lockScreen]
            }

        case .localUnlock(let physical, let authenticated):
            guard isCovering else { return [] }
            guard physical else { return [.log("unlock ignored: not this Mac's own input")] }
            guard authenticated else { return [.log("unlock refused: password not accepted")] }
            phase = .idle
            var actions: [KeeperAction] = [.hideCovers, .log("unlocked with this Mac's login password")]
            if peerConnected { actions.append(.notifyPeerUnlocked) } else { actions.append(.exitProcess) }
            return actions

        case .mainThreadStalled:
            if isCovering { return [.log("main thread stalled while covering: locking, then exiting"), .lockScreen, .exitProcess] }
            return [.log("main thread stalled: exiting"), .exitProcess]
        }
    }

    private mutating func handle(_ message: WireMessage) -> [KeeperAction] {
        switch message {
        case .cover(let session):
            switch phase {
            case .idle:
                phase = .covering([session])
                return [.showCovers]
            case .covering(var sessions):
                sessions.insert(session)
                phase = .covering(sessions)
                return []
            case .held:
                phase = .covering([session])
                return []
            }
        case .sessionEnded(let session):
            guard case .covering(var sessions) = phase else { return [] }
            sessions.remove(session)
            phase = sessions.isEmpty ? .held : .covering(sessions)
            return sessions.isEmpty ? [.log("last session ended: held until unlocked here")] : []
        case .cleanQuit(let n):
            guard n == nonce else { return [.log("clean quit with a wrong nonce: ignored")] }
            cleanQuitAnnounced = true
            return []
        case .testHang:
            return []   // handled by the test build only
        case .rejected(let what):
            return [.log("rejected message: \(what)")]
        }
    }
}
